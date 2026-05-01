import Foundation

// MARK: - GH models

struct GHRepo: Codable, Identifiable, Sendable {
    var id: String { fullName }
    let name: String
    let fullName: String
    let description: String?
    let url: String
    let updatedAt: String?
    let isPrivate: Bool

    enum CodingKeys: String, CodingKey {
        case name
        case fullName   = "nameWithOwner"
        case description
        case url        = "url"
        case updatedAt  = "updatedAt"
        case isPrivate  = "isPrivate"
    }
}

// MARK: - GitHubBridge

/// Wraps the `gh` CLI for Shiro-side GitHub orchestration.
/// (LLM-side GitHub intelligence uses the GitHub MCP server directly.)
actor GitHubBridge {

    // MARK: - Auth check

    /// Returns the authenticated GitHub username, or throws if `gh` is not authed.
    func checkAuth() async throws -> String {
        let (out, err, code) = shell("gh", args: ["api", "user", "--jq", ".login"])
        if code != 0 { throw GitHubError.notAuthenticated(err) }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True if `gh` is installed and authenticated.
    func isAvailable() async -> Bool {
        (try? await checkAuth()) != nil
    }

    // MARK: - Repo list

    /// Lists the authenticated user's repos (up to 100).
    func listRepos(limit: Int = 100) async throws -> [GHRepo] {
        let (out, err, code) = shell("gh", args: [
            "repo", "list",
            "--limit", "\(limit)",
            "--json", "name,nameWithOwner,description,url,updatedAt,isPrivate"
        ])
        guard code == 0 else { throw GitHubError.commandFailed("gh repo list: \(err)") }
        guard let data = out.data(using: .utf8) else { throw GitHubError.decodeFailed }
        return try JSONDecoder().decode([GHRepo].self, from: data)
    }

    // MARK: - Clone

    /// Clones `slug` (e.g. "owner/repo") to `dest` URL.
    func clone(slug: String, to dest: URL) async throws {
        // Remove existing dest if it's empty/broken
        if FileManager.default.fileExists(atPath: dest.path) {
            // Already cloned — skip
            print("[GitHubBridge] \(dest.path) already exists, skipping clone")
            return
        }
        let (_, err, code) = shell("gh", args: ["repo", "clone", slug, dest.path])
        if code != 0 { throw GitHubError.commandFailed("gh repo clone: \(err)") }
    }

    // MARK: - PR

    /// Creates a pull request and returns its URL.
    func createPR(
        repoPath: URL,
        base:  String,
        head:  String,
        title: String,
        body:  String
    ) async throws -> URL {
        let (out, err, code) = shell("gh", args: [
            "-C", repoPath.path,
            "pr", "create",
            "--base",  base,
            "--head",  head,
            "--title", title,
            "--body",  body
        ])
        guard code == 0 else { throw GitHubError.commandFailed("gh pr create: \(err)") }
        let urlStr = out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: urlStr) else { throw GitHubError.decodeFailed }
        return url
    }

    // MARK: - Shell helper

    @discardableResult
    private func shell(_ cmd: String, args: [String]) -> (stdout: String, stderr: String, code: Int32) {
        let p = Process()
        // Prefer full path for gh to avoid PATH issues in sandboxed context
        let ghPaths = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"]
        let ghPath  = ghPaths.first { FileManager.default.isExecutableFile(atPath: $0) } ?? cmd
        p.executableURL = cmd == "gh"
            ? URL(fileURLWithPath: ghPath)
            : URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = cmd == "gh" ? args : [cmd] + args
        // Pass PATH/HOME so gh can find its config
        var env = ProcessInfo.processInfo.environment
        if let token = KeychainHelper.get(.githubToken), !token.isEmpty {
            env["GITHUB_TOKEN"] = token
        }
        p.environment = env
        let outPipe = Pipe(); let errPipe = Pipe()
        p.standardOutput = outPipe; p.standardError = errPipe
        try? p.run(); p.waitUntilExit()
        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (out, err, p.terminationStatus)
    }
}

// MARK: - Errors

enum GitHubError: LocalizedError {
    case notAuthenticated(String)
    case commandFailed(String)
    case decodeFailed

    var errorDescription: String? {
        switch self {
        case .notAuthenticated(let s): return "gh not authenticated: \(s). Run: gh auth login"
        case .commandFailed(let s):    return "gh command failed: \(s)"
        case .decodeFailed:            return "Failed to decode gh output"
        }
    }
}
