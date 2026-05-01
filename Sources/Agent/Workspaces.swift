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

        // Merge: keep existing entries, add new ones, remove stale ones.
        let existing = Dictionary(uniqueKeysWithValues: workspaces.map { ($0.path.path, $0) })
        workspaces = found.map { ws in
            var updated = ws
            if let prev = existing[ws.path.path] {
                updated.lastSeenAt = prev.lastSeenAt   // preserve timestamp
            }
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
