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
    static func inspectDirectory(_ directoryURL: URL) async -> GitRepoSnapshot? {
        await Task.detached(priority: .utility) {
            inspectSync(directoryURL)
        }.value
    }

    private static func inspectSync(_ directoryURL: URL) -> GitRepoSnapshot? {
        guard FileManager.default.fileExists(atPath: "/usr/bin/git") else { return nil }

        guard let topOut = runGit(in: directoryURL, args: ["rev-parse", "--show-toplevel"]),
              !topOut.isEmpty else {
            return nil
        }
        let repoRoot = URL(fileURLWithPath: topOut.trimmingCharacters(in: .whitespacesAndNewlines)).standardizedFileURL

        guard let porcelain = runGit(in: repoRoot, args: ["status", "--porcelain=v1", "-b", "--ignored=matching"]) else {
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

        return GitRepoSnapshot(
            repoRoot: repoRoot,
            branchName: branch,
            badgesByURL: badges,
            changedCount: changedCount
        )
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

    private static func runGit(in directory: URL, args: [String]) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.currentDirectoryURL = directory
        proc.arguments = args

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
