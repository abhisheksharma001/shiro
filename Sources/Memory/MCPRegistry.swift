import Foundation

// MARK: - MCPRegistry
//
// Swift-side mirror of the Node mcp-registry.ts.
// Reads ~/.shiro/mcp.json, surfaces the server list for the settings UI,
// and creates the default config on first launch (Node does the same on its
// side — whoever boots first wins, both are idempotent).
//
// This class does NOT launch MCP servers itself.
// That's the Node bridge's job (via the Claude Agent SDK's mcpServers option).

final class MCPRegistry: ObservableObject {

    // MARK: - Model

    struct ServerConfig: Codable, Identifiable {
        var id: String { name }
        var name: String
        var command: String
        var args: [String]
        var env: [String: String]
        var enabled: Bool
        var description: String?
    }

    struct RegistryFile: Codable {
        var servers: [ServerConfig]
    }

    // MARK: - Published state

    @Published private(set) var servers: [ServerConfig] = []
    @Published private(set) var enabledCount: Int = 0

    // MARK: - Path

    static var configURL: URL {
        let shiroDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".shiro", isDirectory: true)
        try? FileManager.default.createDirectory(at: shiroDir, withIntermediateDirectories: true)
        return shiroDir.appendingPathComponent("mcp.json")
    }

    // MARK: - Init

    init() {
        load()
    }

    // MARK: - Load / Save

    func load() {
        let url = Self.configURL

        if !FileManager.default.fileExists(atPath: url.path) {
            writeDefaults()
        }

        do {
            let data = try Data(contentsOf: url)
            let file = try JSONDecoder().decode(RegistryFile.self, from: data)
            servers = file.servers
            enabledCount = servers.filter(\.enabled).count
            print("[MCPRegistry] loaded \(servers.count) servers (\(enabledCount) enabled)")
        } catch {
            print("[MCPRegistry] load error: \(error.localizedDescription)")
        }
    }

    func save() {
        let file = RegistryFile(servers: servers)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(file)
            try data.write(to: Self.configURL, options: .atomic)
            enabledCount = servers.filter(\.enabled).count
            print("[MCPRegistry] saved \(servers.count) servers")
        } catch {
            print("[MCPRegistry] save error: \(error.localizedDescription)")
        }
    }

    /// Toggle a server on/off and persist.
    func setEnabled(_ name: String, enabled: Bool) {
        guard let idx = servers.firstIndex(where: { $0.name == name }) else { return }
        servers[idx].enabled = enabled
        save()
    }

    // MARK: - Default config

    private func writeDefaults() {
        let defaults = RegistryFile(servers: [
            ServerConfig(
                name: "github",
                command: "npx",
                args: ["-y", "@modelcontextprotocol/server-github"],
                env: ["GITHUB_PERSONAL_ACCESS_TOKEN": "${GITHUB_PERSONAL_ACCESS_TOKEN}"],
                enabled: true,
                description: "GitHub repositories, issues, PRs, code search"
            ),
            ServerConfig(
                name: "context7",
                command: "npx",
                args: ["-y", "@upstash/context7-mcp@latest"],
                env: [:],
                enabled: true,
                description: "Live library documentation — prevents hallucinated APIs"
            ),
            ServerConfig(
                name: "filesystem",
                command: "npx",
                args: ["-y", "@modelcontextprotocol/server-filesystem",
                       (FileManager.default.homeDirectoryForCurrentUser
                           .appendingPathComponent("Projects").path)],
                env: [:],
                enabled: true,
                description: "Read/write ~/Projects files directly"
            ),
            ServerConfig(
                name: "composio",
                command: "npx",
                args: ["-y", "composio-mcp"],
                env: ["COMPOSIO_API_KEY": "${COMPOSIO_API_KEY}"],
                enabled: false,
                description: "250+ integrations (Gmail, Slack, Notion, Linear, …)"
            ),
            ServerConfig(
                name: "huggingface",
                command: "npx",
                args: ["-y", "@huggingface/mcp-client"],
                env: ["HF_TOKEN": "${HF_TOKEN}"],
                enabled: false,
                description: "HuggingFace Hub — model search, dataset access, spaces"
            ),
        ])

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(defaults)
            try data.write(to: Self.configURL, options: .atomic)
            servers = defaults.servers
            enabledCount = servers.filter(\.enabled).count
            print("[MCPRegistry] created default config at \(Self.configURL.path)")
        } catch {
            print("[MCPRegistry] could not write default config: \(error.localizedDescription)")
        }
    }
}
