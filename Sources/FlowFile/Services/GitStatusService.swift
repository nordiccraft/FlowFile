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
        proc.arguments = args
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
}
