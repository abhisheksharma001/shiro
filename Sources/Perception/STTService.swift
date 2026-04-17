import Foundation
import AVFoundation
import Combine

// MARK: - STT Service
// Two backends:
//   1. Deepgram (streaming, real-time) — used when DEEPGRAM_API_KEY is set
//   2. LM Studio Whisper (batch)        — fallback when no Deepgram key
//
// Meeting mode: Deepgram streaming → continuous transcript buffer
// Push-to-talk: record chunk → Deepgram/Whisper batch → result

@MainActor
final class STTService: NSObject, ObservableObject {

    @Published var isRecording: Bool = false
    @Published var liveTranscript: String = ""
    @Published var lastSegment: String = ""

    private let deepgramKey: String?
    private let lmStudio: LMStudioClient

    private var audioEngine: AVAudioEngine?
    private var deepgramWS: URLSessionWebSocketTask?
    private var wsSession: URLSession?

    // Buffer for meeting mode
    private var transcriptBuffer: [TranscriptSegment] = []
    private var meetingFlushTimer: Timer?

    // Callbacks
    var onSegment: ((TranscriptSegment) -> Void)?
    var onMeetingFlush: (([TranscriptSegment]) -> Void)?

    init(deepgramKey: String?, lmStudio: LMStudioClient) {
        self.deepgramKey = deepgramKey
        self.lmStudio = lmStudio
        super.init()
        print("[STT] Backend: \(deepgramKey != nil ? "Deepgram" : "LM Studio Whisper")")
    }

    // MARK: - Push-to-Talk

    /// Record for a fixed duration then transcribe. Returns transcript.
    func recordAndTranscribe(duration: TimeInterval = 10) async throws -> String {
        let audioData = try await recordAudio(duration: duration)
        return try await transcribe(audioData: audioData)
    }

    // MARK: - Meeting Mode (continuous streaming)

    func startMeetingMode() {
        guard !isRecording else { return }
        isRecording = true
        liveTranscript = ""
        transcriptBuffer = []

        if let key = deepgramKey {
            startDeepgramStream(apiKey: key)
        } else {
            startWhisperChunkedMode()
        }

        // Flush buffer every 2 minutes for task extraction
        meetingFlushTimer = Timer.scheduledTimer(withTimeInterval: Config.meetingTranscriptFlushInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.flushMeetingBuffer()
            }
        }
        print("[STT] 🎤 Meeting mode started")
    }

    func stopMeetingMode() -> [TranscriptSegment] {
        isRecording = false
        meetingFlushTimer?.invalidate()
        meetingFlushTimer = nil
        audioEngine?.stop()
        deepgramWS?.cancel()
        deepgramWS = nil
        print("[STT] 🛑 Meeting mode stopped, \(transcriptBuffer.count) segments")
        let all = transcriptBuffer
        transcriptBuffer = []
        return all
    }

    // MARK: - Deepgram Streaming

    private func startDeepgramStream(apiKey: String) {
        // Deepgram Nova-3 streaming WebSocket
        let urlStr = "wss://api.deepgram.com/v1/listen?model=nova-3&language=en&smart_format=true&interim_results=true&utterance_end_ms=1000&vad_events=true"
        guard let url = URL(string: urlStr) else { return }

        var request = URLRequest(url: url)
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")

        wsSession = URLSession(configuration: .default)
        deepgramWS = wsSession?.webSocketTask(with: request)
        deepgramWS?.resume()

        // Start receiving messages
        Task { await receiveDeepgramMessages() }

        // Start streaming mic audio
        startMicrophoneStream { [weak self] audioData in
            self?.deepgramWS?.send(.data(audioData)) { error in
                if let error = error {
                    print("[STT] Deepgram send error: \(error)")
                }
            }
        }
    }

    private func receiveDeepgramMessages() async {
        guard let ws = deepgramWS else { return }
        do {
            while isRecording {
                let message = try await ws.receive()
                switch message {
                case .data(let data):
                    handleDeepgramMessage(data)
                case .string(let str):
                    if let data = str.data(using: .utf8) {
                        handleDeepgramMessage(data)
                    }
                @unknown default:
                    break
                }
            }
        } catch {
            if isRecording {
                print("[STT] Deepgram WS error: \(error)")
            }
        }
    }

    private func handleDeepgramMessage(_ data: Data) {
        guard let response = try? JSONDecoder().decode(DeepgramResponse.self, from: data) else { return }
        let transcript = response.channel?.alternatives?.first?.transcript ?? ""
        guard !transcript.isEmpty else { return }

        if response.isFinal == true {
            let segment = TranscriptSegment(
                text: transcript,
                timestamp: Date(),
                isFinal: true,
                confidence: response.channel?.alternatives?.first?.confidence ?? 1.0
            )
            transcriptBuffer.append(segment)
            liveTranscript += " " + transcript
            lastSegment = transcript
            onSegment?(segment)
        }
    }

    // MARK: - Whisper Chunked Mode (fallback — no Deepgram key)

    private var whisperChunkBuffer = Data()
    private var whisperChunkTimer: Timer?

    private func startWhisperChunkedMode() {
        // Collect audio in 15-second chunks, transcribe each via LM Studio Whisper
        startMicrophoneStream { [weak self] audioData in
            self?.whisperChunkBuffer.append(audioData)
        }

        whisperChunkTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.flushWhisperChunk()
            }
        }
    }

    private func flushWhisperChunk() async {
        guard !whisperChunkBuffer.isEmpty else { return }
        let chunk = whisperChunkBuffer
        whisperChunkBuffer = Data()

        do {
            let wavData = wrapPCMInWAV(pcmData: chunk, sampleRate: 16000, channels: 1)
            let text = try await lmStudio.transcribe(audioData: wavData)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

            let segment = TranscriptSegment(text: text, timestamp: Date(), isFinal: true, confidence: 1.0)
            transcriptBuffer.append(segment)
            liveTranscript += " " + text
            lastSegment = text
            onSegment?(segment)
        } catch {
            print("[STT] Whisper chunk error: \(error)")
        }
    }

    // MARK: - Microphone Input

    private func startMicrophoneStream(onChunk: @escaping (Data) -> Void) {
        audioEngine = AVAudioEngine()
        guard let engine = audioEngine else { return }

        let inputNode = engine.inputNode
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            guard let channelData = buffer.int16ChannelData else { return }
            let frameLength = Int(buffer.frameLength)
            let data = Data(bytes: channelData[0], count: frameLength * 2)
            onChunk(data)
        }

        do {
            try engine.start()
        } catch {
            print("[STT] Audio engine start error: \(error)")
        }
    }

    private func recordAudio(duration: TimeInterval) async throws -> Data {
        return try await withCheckedThrowingContinuation { continuation in
            var recorded = Data()
            let engine = AVAudioEngine()
            let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!

            engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
                guard let channelData = buffer.int16ChannelData else { return }
                recorded.append(Data(bytes: channelData[0], count: Int(buffer.frameLength) * 2))
            }

            do {
                try engine.start()
                DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
                    engine.stop()
                    let wavData = self.wrapPCMInWAV(pcmData: recorded, sampleRate: 16000, channels: 1)
                    continuation.resume(returning: wavData)
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func transcribe(audioData: Data) async throws -> String {
        if let key = deepgramKey {
            return try await transcribeDeepgramBatch(audioData: audioData, apiKey: key)
        } else {
            return try await lmStudio.transcribe(audioData: audioData)
        }
    }

    private func transcribeDeepgramBatch(audioData: Data, apiKey: String) async throws -> String {
        let urlStr = "https://api.deepgram.com/v1/listen?model=nova-3&language=en&smart_format=true"
        guard let url = URL(string: urlStr) else { throw STTError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        request.httpBody = audioData

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw STTError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }

        let dgResp = try JSONDecoder().decode(DeepgramBatchResponse.self, from: data)
        return dgResp.results?.channels?.first?.alternatives?.first?.transcript ?? ""
    }

    // MARK: - Meeting Buffer Flush

    private func flushMeetingBuffer() {
        let segments = transcriptBuffer
        guard !segments.isEmpty else { return }
        onMeetingFlush?(segments)
    }

    // MARK: - WAV Wrapper

    private func wrapPCMInWAV(pcmData: Data, sampleRate: Int, channels: Int) -> Data {
        var wav = Data()
        let bitsPerSample = 16
        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8
        let dataSize = pcmData.count
        let chunkSize = 36 + dataSize

        func appendInt32(_ value: Int32) { var v = value; wav.append(Data(bytes: &v, count: 4)) }
        func appendInt16(_ value: Int16) { var v = value; wav.append(Data(bytes: &v, count: 2)) }
        func appendString(_ s: String) { wav.append(s.data(using: .ascii)!) }

        appendString("RIFF")
        appendInt32(Int32(chunkSize))
        appendString("WAVE")
        appendString("fmt ")
        appendInt32(16)                      // subchunk1 size
        appendInt16(1)                       // PCM format
        appendInt16(Int16(channels))
        appendInt32(Int32(sampleRate))
        appendInt32(Int32(byteRate))
        appendInt16(Int16(blockAlign))
        appendInt16(Int16(bitsPerSample))
        appendString("data")
        appendInt32(Int32(dataSize))
        wav.append(pcmData)

        return wav
    }
}

// MARK: - Models

struct TranscriptSegment {
    let text: String
    let timestamp: Date
    let isFinal: Bool
    let confidence: Double
}

// Deepgram streaming response
private struct DeepgramResponse: Decodable {
    let channel: Channel?
    let isFinal: Bool?

    enum CodingKeys: String, CodingKey {
        case channel
        case isFinal = "is_final"
    }

    struct Channel: Decodable {
        let alternatives: [Alternative]?
    }

    struct Alternative: Decodable {
        let transcript: String?
        let confidence: Double?
    }
}

// Deepgram batch response
private struct DeepgramBatchResponse: Decodable {
    let results: Results?

    struct Results: Decodable {
        let channels: [Channel]?
    }

    struct Channel: Decodable {
        let alternatives: [Alternative]?
    }

    struct Alternative: Decodable {
        let transcript: String?
    }
}

enum STTError: Error {
    case invalidURL
    case httpError(Int)
    case noTranscript
}
