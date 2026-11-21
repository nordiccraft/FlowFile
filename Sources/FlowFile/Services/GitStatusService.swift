import Foundation

enum GitFileBadge: String, Equatable {
    case modified = "M"
    case staged = "A"
    case untracked = "U"
    case deleted = "D"
    case conflict = "!"
    case ignored = "I"
}

struct GitRepoSnapshot {
    let repoRoot: URL
    let branchName: String
    let badgesByURL: [URL: GitFileBadge]
    let changedCount: Int
}

enum GitStatusService {
    private static let cacheLock = NSLock()
    private static var cachedSnapshots: [URL: (timestamp: Date, snapshot: GitRepoSnapshot)] = [:]
    private static let cacheTTLSeconds: TimeInterval = 1.5

    static func inspectDirectory(_ directoryURL: URL) async -> GitRepoSnapshot? {
        await Task.detached(priority: .utility) {
            inspectSync(directoryURL)
        }.value
    }

    /// Walks parent directories purely via FileManager so non-Git folders spawn zero subprocesses.
    static func findGitRepoRoot(from directoryURL: URL) -> URL? {
        let fm = FileManager.default
        var current = directoryURL.standardizedFileURL
        while true {
            let dotGit = current.appendingPathComponent(".git")
            if fm.fileExists(atPath: dotGit.path) {
                return current
            }
            let parent = current.deletingLastPathComponent().standardizedFileURL
            if parent.path == current.path {
                return nil
            }
            current = parent
        }
    }

    /// Resolves a real installed Git binary without ever invoking the `/usr/bin/git` shim when CLT is absent.
    private static func resolveRealGitExecutable() -> URL? {
        let candidates = [
            "/Library/Developer/CommandLineTools/usr/bin/git",
            "/Applications/Xcode.app/Contents/Developer/usr/bin/git",
            "/opt/homebrew/bin/git",
            "/usr/local/bin/git"
        ]
        let fm = FileManager.default
        for path in candidates where fm.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    private static func inspectSync(_ directoryURL: URL) -> GitRepoSnapshot? {
        guard let repoRoot = findGitRepoRoot(from: directoryURL),
              let gitExecutable = resolveRealGitExecutable() else {
            return nil
        }
        // Repositories with config that could execute programs during `git status` get no badges.
        guard isRepositoryConfigSafe(repoRoot: repoRoot) else {
            return nil
        }

        let now = Date()
        cacheLock.lock()
        if let cached = cachedSnapshots[repoRoot],
           now.timeIntervalSince(cached.timestamp) < cacheTTLSeconds {
            cacheLock.unlock()
            return cached.snapshot
        }
        cacheLock.unlock()

        guard let porcelain = runGit(
            executable: gitExecutable,
            in: repoRoot,
            args: ["--no-optional-locks", "status", "--porcelain=v1", "-b", "--ignored=matching"]
        ) else {
            return nil
        }

        var branch = "HEAD"
        var badges: [URL: GitFileBadge] = [:]
        var changedCount = 0

        for rawLine in porcelain.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            if line.hasPrefix("## ") {
                let header = String(line.dropFirst(3))
                if let dotIndex = header.range(of: "...")?.lowerBound {
                    branch = String(header[..<dotIndex])
                } else if let spaceIdx = header.firstIndex(of: " ") {
                    branch = String(header[..<spaceIdx])
                } else {
                    branch = header
                }
                continue
            }

            guard line.count >= 4 else { continue }
            let xy = String(line.prefix(2))
            var relPath = String(line.dropFirst(3))
            if let arrowRange = relPath.range(of: " -> ") {
                relPath = String(relPath[arrowRange.upperBound...])
            }
            relPath = relPath.trimmingCharacters(in: CharacterSet(charactersIn: "\"/"))
            guard !relPath.isEmpty else { continue }

            let badge = classifyPorcelain(xy)
            if badge != .ignored {
                changedCount += 1
            }

            let fileURL = repoRoot.appendingPathComponent(relPath).standardizedFileURL
            badges[fileURL] = mergePriority(existing: badges[fileURL], incoming: badge)

            // Propagate non-ignored status up parent folders inside the repo so directories show dirty indicator!
            if badge != .ignored {
                var parent = fileURL.deletingLastPathComponent().standardizedFileURL
                while parent.path.hasPrefix(repoRoot.path) && parent != repoRoot {
                    badges[parent] = mergePriority(existing: badges[parent], incoming: .modified)
                    parent = parent.deletingLastPathComponent().standardizedFileURL
                }
            }
        }

        let snapshot = GitRepoSnapshot(
            repoRoot: repoRoot,
            branchName: branch,
            badgesByURL: badges,
            changedCount: changedCount
        )
        cacheLock.lock()
        cachedSnapshots[repoRoot] = (timestamp: Date(), snapshot: snapshot)
        cacheLock.unlock()
        return snapshot
    }

    private static func classifyPorcelain(_ xy: String) -> GitFileBadge {
        if xy == "!!" { return .ignored }
        if xy == "??" { return .untracked }
        if xy.contains("U") || xy == "AA" || xy == "DD" { return .conflict }
        if xy.contains("D") { return .deleted }
        if xy.first == "A" || xy.first == "R" { return .staged }
        return .modified
    }

    private static func mergePriority(existing: GitFileBadge?, incoming: GitFileBadge) -> GitFileBadge {
        guard let existing else { return incoming }
        let rank: (GitFileBadge) -> Int = { badge in
            switch badge {
            case .conflict: return 5
            case .modified: return 4
            case .staged: return 3
            case .untracked: return 2
            case .deleted: return 2
            case .ignored: return 1
            }
        }
        return rank(incoming) > rank(existing) ? incoming : existing
    }

    private static func runGit(executable: URL, in directory: URL, args: [String]) -> String? {
        let proc = Process()
        proc.executableURL = executable
        proc.currentDirectoryURL = directory
        // Hardened invocation: never run hooks, fsmonitor, pagers, external diff tools or untracked caches,
        // and ignore global/system config so a repo can only influence `git status` via its own (pre-scanned) config.
        proc.arguments = [
            "-c", "core.fsmonitor=false",
            "-c", "core.untrackedCache=false",
            "-c", "core.hooksPath=/dev/null",
            "-c", "core.pager=cat",
            "-c", "diff.external=",
            "-c", "protocol.allow=never",
            "-c", "credential.helper="
        ] + args
        proc.environment = hardenedGitEnvironment()
        proc.standardInput = FileHandle.nullDevice

        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    static func hardenedGitEnvironment() -> [String: String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": home,
            "LANG": "en_US.UTF-8",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_OPTIONAL_LOCKS": "0",
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_NO_REPLACE_OBJECTS": "1",
            "GIT_ASKPASS": "",
            "SSH_ASKPASS": "",
            "GIT_PAGER": "cat",
            "GIT_EXTERNAL_DIFF": ""
        ]
    }

    // MARK: - Untrusted repository pre-scan

    /// Returns false when a repository's local config or attributes contain settings that could make
    /// `git status` execute programs (fsmonitor, clean/smudge filters, includes, ssh/proxy commands, textconv ...).
    /// Such repositories (e.g. from downloaded zips or USB sticks) simply get no Git badges.
    static func isRepositoryConfigSafe(repoRoot: URL) -> Bool {
        let fm = FileManager.default
        let dotGit = repoRoot.appendingPathComponent(".git")
        var gitDirs: [URL] = []

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dotGit.path, isDirectory: &isDir) else { return false }
        if isDir.boolValue {
            gitDirs.append(dotGit)
        } else {
            // Worktree/submodule: ".git" file containing "gitdir: <path>"
            guard let text = try? String(contentsOf: dotGit, encoding: .utf8),
                  let line = text.split(whereSeparator: \.isNewline).first,
                  line.lowercased().hasPrefix("gitdir:") else {
                return false
            }
            let raw = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
            let target = raw.hasPrefix("/")
                ? URL(fileURLWithPath: raw)
                : repoRoot.appendingPathComponent(raw)
            gitDirs.append(target.standardizedFileURL)
        }

        // Linked worktrees share config through "commondir"
        if let first = gitDirs.first,
           let common = try? String(contentsOf: first.appendingPathComponent("commondir"), encoding: .utf8) {
            let trimmed = common.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let commonURL = trimmed.hasPrefix("/")
                    ? URL(fileURLWithPath: trimmed)
                    : first.appendingPathComponent(trimmed)
                gitDirs.append(commonURL.standardizedFileURL)
            }
        }

        for dir in gitDirs {
            for configName in ["config", "config.worktree"] {
                let configURL = dir.appendingPathComponent(configName)
                guard fm.fileExists(atPath: configURL.path) else { continue }
                guard let text = try? String(contentsOf: configURL, encoding: .utf8),
                      isGitConfigTextSafe(text) else {
                    return false
                }
            }
        }
        // Note: `.gitattributes` / `info/attributes` may reference filters (e.g. `filter=lfs`), but a filter can only
        // execute when its command is defined in config. Global/system config is disabled and local filter sections
        // are refused above, so attribute references alone are harmless.
        return true
    }

    static func isGitConfigTextSafe(_ text: String) -> Bool {
        let dangerousSectionPrefixes = ["filter", "include", "includeif"]
        let dangerousCoreKeys: Set<String> = [
            "fsmonitor", "sshcommand", "gitproxy", "pager", "editor", "askpass", "worktree", "hookspath"
        ]
        let dangerousAnySectionKeys: Set<String> = ["textconv", "command", "external", "process", "clean", "smudge"]

        var currentSection = ""
        for rawLine in text.split(whereSeparator: \.isNewline) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }

            if line.hasPrefix("[") {
                guard let close = line.firstIndex(of: "]") else { return false }
                let header = line[line.index(after: line.startIndex)..<close]
                    .trimmingCharacters(in: .whitespaces)
                    .lowercased()
                currentSection = header.split(whereSeparator: { $0 == " " || $0 == "\"" || $0 == "." }).first.map(String.init) ?? header
                if dangerousSectionPrefixes.contains(currentSection) {
                    return false
                }
                line = String(line[line.index(after: close)...]).trimmingCharacters(in: .whitespaces)
                if line.isEmpty { continue }
            }

            let key = (line.split(separator: "=", maxSplits: 1).first ?? Substring(line))
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            if currentSection == "core" && dangerousCoreKeys.contains(key) {
                return false
            }
            if dangerousAnySectionKeys.contains(key) {
                return false
            }
        }
        return true
    }
}
