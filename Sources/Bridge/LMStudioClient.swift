import Foundation

// MARK: - Request / Response Types

struct ChatMessage: Codable {
    let role: String
    var content: MessageContent

    init(role: String, text: String) {
        self.role = role
        self.content = .text(text)
    }

    init(role: String, parts: [ContentPart]) {
        self.role = role
        self.content = .parts(parts)
    }
}

enum MessageContent: Codable {
    case text(String)
    case parts([ContentPart])

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let s): try container.encode(s)
        case .parts(let p): try container.encode(p)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) {
            self = .text(s)
        } else {
            self = .parts(try container.decode([ContentPart].self))
        }
    }
}

struct ContentPart: Codable {
    let type: String       // "text" | "image_url"
    let text: String?
    let imageURL: ImageURL?

    enum CodingKeys: String, CodingKey {
        case type, text
        case imageURL = "image_url"
    }

    static func text(_ s: String) -> ContentPart {
        ContentPart(type: "text", text: s, imageURL: nil)
    }

    static func image(base64 data: Data, mimeType: String = "image/png") -> ContentPart {
        let b64 = data.base64EncodedString()
        return ContentPart(type: "image_url", text: nil,
                           imageURL: ImageURL(url: "data:\(mimeType);base64,\(b64)"))
    }
}

struct ImageURL: Codable {
    let url: String
}

struct ToolDefinition: Codable {
    let type: String = "function"
    let function: FunctionDef

    struct FunctionDef: Codable {
        let name: String
        let description: String
        let parameters: JSONSchema
    }
}

struct JSONSchema: Codable {
    let type: String
    let properties: [String: PropertySchema]?
    let required: [String]?

    struct PropertySchema: Codable {
        let type: String
        let description: String?
        let enumValues: [String]?

        enum CodingKeys: String, CodingKey {
            case type, description
            case enumValues = "enum"
        }
    }
}

struct ChatCompletionRequest: Encodable {
    let model: String
    let messages: [ChatMessage]
    let tools: [ToolDefinition]?
    let toolChoice: String?
    let maxTokens: Int
    let temperature: Double
    let stream: Bool

    enum CodingKeys: String, CodingKey {
        case model, messages, tools, stream, temperature
        case toolChoice = "tool_choice"
        case maxTokens = "max_tokens"
    }
}

struct ChatCompletionResponse: Decodable {
    let id: String
    let choices: [Choice]
    let usage: Usage?

    struct Choice: Decodable {
        let message: ResponseMessage
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case message
            case finishReason = "finish_reason"
        }
    }

    struct ResponseMessage: Decodable {
        let role: String
        let content: String?
        let toolCalls: [ToolCall]?

        enum CodingKeys: String, CodingKey {
            case role, content
            case toolCalls = "tool_calls"
        }
    }

    struct Usage: Decodable {
        let promptTokens: Int
        let completionTokens: Int

        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
        }
    }
}

struct ToolCall: Decodable {
    let id: String
    let type: String
    let function: FunctionCall

    struct FunctionCall: Decodable {
        let name: String
        let arguments: String   // JSON string
    }
}

struct EmbeddingRequest: Encodable {
    let model: String
    let input: [String]
}

struct EmbeddingResponse: Decodable {
    let data: [EmbeddingData]

    struct EmbeddingData: Decodable {
        let embedding: [Float]
        let index: Int
    }
}

// MARK: - LMStudioClient

/// HTTP client for all LM Studio interactions.
/// Handles: chat, vision, embeddings, transcription.
final class LMStudioClient {
    private let baseURL: String
    private let session: URLSession

    init(baseURL: String = Config.lmStudioBaseURL) {
        self.baseURL = baseURL
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 600
        self.session = URLSession(configuration: config)
    }

    // MARK: - Health

    func healthCheck() async -> Bool {
        guard let url = URL(string: "\(baseURL)/v1/models") else { return false }
        do {
            let (_, response) = try await session.data(from: url)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    func loadedModels() async -> [String] {
        guard let url = URL(string: "\(baseURL)/v1/models") else { return [] }
        do {
            let (data, _) = try await session.data(from: url)
            struct ModelsResponse: Decodable {
                struct Model: Decodable { let id: String }
                let data: [Model]
            }
            let resp = try JSONDecoder().decode(ModelsResponse.self, from: data)
            return resp.data.map(\.id)
        } catch {
            return []
        }
    }

    // MARK: - Chat (text only)

    func chat(
        messages: [ChatMessage],
        model: String = Config.brainModel,
        tools: [ToolDefinition]? = nil,
        maxTokens: Int = 4096,
        temperature: Double = 0.7
    ) async throws -> ChatCompletionResponse {
        let req = ChatCompletionRequest(
            model: model,
            messages: messages,
            tools: tools,
            toolChoice: tools != nil ? "auto" : nil,
            maxTokens: maxTokens,
            temperature: temperature,
            stream: false
        )
        return try await post(path: "/v1/chat/completions", body: req)
    }

    // MARK: - Vision (image + text)

    func vision(
        prompt: String,
        imageData: Data,
        model: String = Config.visionModel,
        maxTokens: Int = 1024
    ) async throws -> String {
        let parts: [ContentPart] = [
            .text(prompt),
            .image(base64: imageData)
        ]
        let messages = [ChatMessage(role: "user", parts: parts)]
        let req = ChatCompletionRequest(
            model: model,
            messages: messages,
            tools: nil,
            toolChoice: nil,
            maxTokens: maxTokens,
            temperature: 0.3,
            stream: false
        )
        let resp: ChatCompletionResponse = try await post(path: "/v1/chat/completions", body: req)
        return resp.choices.first?.message.content ?? ""
    }

    // MARK: - Fast (uses qwen3-8b)

    func fast(
        prompt: String,
        systemPrompt: String? = nil,
        maxTokens: Int = 512
    ) async throws -> String {
        var messages: [ChatMessage] = []
        if let sys = systemPrompt {
            messages.append(ChatMessage(role: "system", text: sys))
        }
        messages.append(ChatMessage(role: "user", text: prompt))
        let resp = try await chat(messages: messages, model: Config.fastModel,
                                   maxTokens: maxTokens, temperature: 0.3)
        return resp.choices.first?.message.content ?? ""
    }

    // MARK: - Embeddings

    func embed(texts: [String]) async throws -> [[Float]] {
        let req = EmbeddingRequest(model: Config.embeddingModel, input: texts)
        let resp: EmbeddingResponse = try await post(path: "/v1/embeddings", body: req)
        return resp.data.sorted { $0.index < $1.index }.map(\.embedding)
    }

    func embed(text: String) async throws -> [Float] {
        let results = try await embed(texts: [text])
        return results.first ?? []
    }

    // MARK: - Transcription via LM Studio Whisper (batch/offline)
    // Used when DEEPGRAM_API_KEY is not set, or for offline fallback.

    func transcribe(audioData: Data, mimeType: String = "audio/wav") async throws -> String {
        guard let url = URL(string: "\(baseURL)/v1/audio/transcriptions") else {
            throw LMError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        // model field
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\nwhisper-large-v3-turbo\r\n".data(using: .utf8)!)
        // file field
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw LMError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        struct TranscriptionResponse: Decodable { let text: String }
        return try JSONDecoder().decode(TranscriptionResponse.self, from: data).text
    }

    // MARK: - Private

    private func post<Req: Encodable, Resp: Decodable>(path: String, body: Req) async throws -> Resp {
        guard let url = URL(string: "\(baseURL)\(path)") else { throw LMError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LMError.noResponse }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "(empty)"
            print("[LMStudio] ❌ HTTP \(http.statusCode): \(body)")
            throw LMError.httpError(http.statusCode)
        }
        do {
            return try JSONDecoder().decode(Resp.self, from: data)
        } catch {
            let raw = String(data: data, encoding: .utf8) ?? ""
            print("[LMStudio] ❌ Decode error: \(error)\nRaw: \(raw.prefix(500))")
            throw error
        }
    }
}

enum LMError: Error, LocalizedError {
    case invalidURL
    case noResponse
    case httpError(Int)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid LM Studio URL"
        case .noResponse: return "No response from LM Studio"
        case .httpError(let code): return "LM Studio returned HTTP \(code)"
        case .emptyResponse: return "LM Studio returned empty response"
        }
    }
}

// MARK: - Model Router

/// Decides which model to use based on task characteristics.
/// No LLM call — pure heuristics, sub-millisecond.
enum ModelRouter {
    static func route(prompt: String, hasImage: Bool = false, tools: [ToolDefinition]? = nil) -> String {
        if hasImage { return Config.visionModel }

        let lower = prompt.lowercased()
        let wordCount = prompt.split(separator: " ").count

        // Complex signals → brain model
        let complexKeywords = ["implement", "build", "create", "debug", "refactor",
                                "analyze", "explain in detail", "multi-step", "plan",
                                "write code", "function", "class", "architecture"]
        if complexKeywords.contains(where: { lower.contains($0) }) { return Config.brainModel }
        if let t = tools, !t.isEmpty { return Config.brainModel }
        if wordCount > 50 { return Config.brainModel }

        // Simple signals → fast model
        return Config.fastModel
    }
}
