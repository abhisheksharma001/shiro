import Foundation

// MARK: - Workspace model

struct Workspace: Codable, Identifiable, Sendable {
    var id: String { path.path }
    let name: String                // directory basename
    let path: URL
    let isGitRepo: Bool
    var lastSeenAt: Date
    var remoteOriginUrl: String?    // git remote origin, if available
}

// MARK: - Workspace preset (.shiro/workspace.toml)

struct WorkspacePreset: Codable, Equatable {
    var defaultModel:     String?   // e.g. "haiku" | "sonnet" | "opus"
    var allowedTools:     [String]? // subset of tool names
    var maxCostPerTask:   Double?   // USD ceiling per task
    var autoApproveRisk:  String?   // "low" | "med" (auto-approve threshold)

    /// Load from `<workspace>/.shiro/workspace.toml`. Returns nil if file missing.
    static func load(from workspace: URL) -> WorkspacePreset? {
        let tomlURL = workspace
            .appendingPathComponent(".shiro")
            .appendingPathComponent("workspace.toml")
        guard let contents = try? String(contentsOf: tomlURL, encoding: .utf8) else { return nil }
        return parse(toml: contents)
    }

    /// Write defaults to `<workspace>/.shiro/workspace.toml`.
    static func writeDefaults(to workspace: URL) throws {
        let dir = workspace.appendingPathComponent(".shiro")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let content = """
# Shiro workspace preset — overrides per-task defaults.
[shiro]
# default_model = "sonnet"          # haiku | sonnet | opus
# allowed_tools = ["Read", "Edit", "Bash", "Write"]
# max_cost_per_task = 2.00
# auto_approve_risk = "low"         # low | med
"""
        try content.write(to: dir.appendingPathComponent("workspace.toml"),
                           atomically: true, encoding: .utf8)
    }

    // MARK: - Minimal TOML subset parser

    private static func parse(toml: String) -> WorkspacePreset {
        var preset = WorkspacePreset()
        var inShiroSection = false
        for rawLine in toml.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") {
                inShiroSection = line == "[shiro]"
                continue
            }
            guard inShiroSection else { continue }
            let parts = line.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2 else { continue }
            let key   = parts[0]
            let value = parts[1].split(separator: "#").first
                .map { $0.trimmingCharacters(in: .whitespaces) } ?? parts[1]

            switch key {
            case "default_model":
                preset.defaultModel = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            case "max_cost_per_task":
                preset.maxCostPerTask = Double(value)
            case "auto_approve_risk":
                preset.autoApproveRisk = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            case "allowed_tools":
                // Parse: ["Read", "Edit", "Bash"] or ["Read","Edit"]
                let stripped = value
                    .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                let tools = stripped
                    .components(separatedBy: ",")
                    .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"'")) }
                    .filter { !$0.isEmpty }
                if !tools.isEmpty { preset.allowedTools = tools }
            default:
                break
            }
        }
        return preset
    }
}

// MARK: - WorkspacesRegistry

@MainActor
final class WorkspacesRegistry: ObservableObject {

    @Published private(set) var workspaces: [Workspace] = []

    private static var persistURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".shiro/workspaces.json")
    }

    // MARK: - Init

    init() {
        try? load()
    }

    // MARK: - Scan

    /// Scans `roots` (default: ~/Projects) for git repos and bare directories.
    func scan(roots: [URL]? = nil) async {
        let scanRoots = roots ?? [
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Projects")
        ]
        var found: [Workspace] = []

        for root in scanRoots {
            guard let items = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]) else { continue }

            for item in items {
                guard (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                else { continue }

                let isGit = FileManager.default.fileExists(
                    atPath: item.appendingPathComponent(".git").path)

                var origin: String? = nil
                if isGit {
                    origin = await shellOutput("git", args: ["-C", item.path,
                                                              "remote", "get-url", "origin"])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if origin?.isEmpty == true { origin = nil }
                }

                let ws = Workspace(
                    name:            item.lastPathComponent,
                    path:            item,
                    isGitRepo:       isGit,
                    lastSeenAt:      Date(),
                    remoteOriginUrl: origin
                )
                found.append(ws)
            }
        }

        // Merge: update lastSeenAt to now for all (re-)scanned workspaces.
        // [B8-fix] Previous code preserved the old timestamp, freezing it at first-scan time.
        // lastSeenAt should reflect when the workspace was last confirmed present.
        workspaces = found.map { ws in
            var updated = ws
            updated.lastSeenAt = Date()   // always refresh to current scan time
            return updated
        }

        try? save()
        print("[WorkspacesRegistry] \(workspaces.count) workspaces indexed")
    }

    // MARK: - Fuzzy resolve

    /// Match user text (e.g. "the shiro repo") to a workspace.
    /// Strategy: exact name match → prefix match → substring → first git repo.
    func resolve(hint: String) -> Workspace? {
        let h = hint.lowercased()
        if let exact = workspaces.first(where: { $0.name.lowercased() == h }) { return exact }
        if let prefix = workspaces.first(where: { $0.name.lowercased().hasPrefix(h) }) { return prefix }
        if let sub = workspaces.first(where: { $0.name.lowercased().contains(h) }) { return sub }
        // Fuzzy: check if any word in hint appears in workspace name
        let words = h.split(separator: " ").map(String.init)
        for ws in workspaces {
            if words.contains(where: { ws.name.lowercased().contains($0) }) { return ws }
        }
        return workspaces.first(where: { $0.isGitRepo })
    }

    // MARK: - Persistence

    func save() throws {
        let dir = Self.persistURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(workspaces)
        try data.write(to: Self.persistURL)
    }

    func load() throws {
        let data = try Data(contentsOf: Self.persistURL)
        workspaces = try JSONDecoder().decode([Workspace].self, from: data)
    }

    // MARK: - Workspace preset

    /// Returns the parsed preset for a workspace (or nil if none exists).
    func preset(for workspace: Workspace) -> WorkspacePreset? {
        WorkspacePreset.load(from: workspace.path)
    }

    /// Creates a default `.shiro/workspace.toml` in the given workspace (commented out).
    func scaffoldPreset(for workspace: Workspace) throws {
        try WorkspacePreset.writeDefaults(to: workspace.path)
    }

    // MARK: - GitHub clone

    /// Clone a GitHub repo by slug and add to registry.
    func cloneFromGitHub(_ slug: String,
                         into root: URL? = nil) async throws -> Workspace {
        let repoName = slug.split(separator: "/").last.map(String.init) ?? slug
        let dest = (root ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Projects"))
            .appendingPathComponent(repoName)

        let gh = GitHubBridge()
        try await gh.clone(slug: slug, to: dest)
        await scan()    // refresh registry
        if let found = resolve(hint: repoName) { return found }
        // [A9-fix] Verify .git directory before constructing fallback — a partial clone
        // can leave the dest directory without a valid repo.
        let gitPath = dest.appendingPathComponent(".git").path
        let isValid = FileManager.default.fileExists(atPath: gitPath)
        return Workspace(name: repoName, path: dest, isGitRepo: isValid,
                         lastSeenAt: Date(), remoteOriginUrl: "https://github.com/\(slug)")
    }

    // MARK: - Helpers

    private func shellOutput(_ cmd: String, args: [String]) async -> String {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                p.arguments = [cmd] + args
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError  = Pipe()
                try? p.run()
                p.waitUntilExit()
                let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                                 encoding: .utf8) ?? ""
                cont.resume(returning: out)
            }
        }
    }
}
