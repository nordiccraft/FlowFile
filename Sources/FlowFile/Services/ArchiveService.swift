import Foundation

struct ArchiveRawEntry {
    let entryPath: String
    let isDirectory: Bool
    let size: Int64
    let modificationDate: Date?
}

enum ArchiveKind {
    case zip
    case tar
}

enum ArchiveService {
    static func archiveKind(for url: URL) -> ArchiveKind? {
        let lower = url.lastPathComponent.lowercased()
        if lower.hasSuffix(".zip") {
            return .zip
        }
        if lower.hasSuffix(".tar")
            || lower.hasSuffix(".tar.gz")
            || lower.hasSuffix(".tgz")
            || lower.hasSuffix(".tar.bz2")
            || lower.hasSuffix(".tar.xz") {
            return .tar
        }
        return nil
    }

    static func isSupportedArchive(_ url: URL) -> Bool {
        archiveKind(for: url) != nil
    }

    static func listVirtualDirectory(
        archiveURL: URL,
        subpath: String,
        showHidden: Bool
    ) throws -> [FileItem] {
        guard let kind = archiveKind(for: archiveURL) else { return [] }
        let rawEntries: [ArchiveRawEntry]
        switch kind {
        case .zip:
            rawEntries = try readZipEntries(archiveURL: archiveURL)
        case .tar:
            rawEntries = try readTarEntries(archiveURL: archiveURL)
        }

        let normalizedPrefix: String = {
            let trimmed = subpath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return trimmed.isEmpty ? "" : trimmed + "/"
        }()

        struct AggregatedChild {
            var name: String
            var fullEntryPath: String
            var isDirectory: Bool
            var size: Int64
            var modificationDate: Date?
        }

        var directChildren: [String: AggregatedChild] = [:]

        for entry in rawEntries {
            let cleanPath = entry.entryPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !cleanPath.isEmpty else { continue }
            if cleanPath.hasPrefix("__MACOSX/") || cleanPath == "__MACOSX" { continue }

            let remainder: String
            if normalizedPrefix.isEmpty {
                remainder = cleanPath
            } else {
                guard cleanPath.hasPrefix(normalizedPrefix) else { continue }
                remainder = String(cleanPath.dropFirst(normalizedPrefix.count))
                guard !remainder.isEmpty else { continue }
            }

            let parts = remainder.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true)
            guard let childNameSub = parts.first else { continue }
            let childName = String(childNameSub)

            if !showHidden && childName.hasPrefix(".") {
                continue
            }

            let isSubdirImplicit = parts.count > 1
            let isDir = isSubdirImplicit || entry.isDirectory
            let childEntryPath = normalizedPrefix + childName + (isDir ? "/" : "")

            if var existing = directChildren[childName] {
                if isDir {
                    existing.isDirectory = true
                    existing.fullEntryPath = normalizedPrefix + childName + "/"
                }
                if !isSubdirImplicit {
                    existing.size = entry.size
                    if let d = entry.modificationDate {
                        existing.modificationDate = d
                    }
                }
                directChildren[childName] = existing
            } else {
                directChildren[childName] = AggregatedChild(
                    name: childName,
                    fullEntryPath: childEntryPath,
                    isDirectory: isDir,
                    size: isDir ? 0 : entry.size,
                    modificationDate: entry.modificationDate
                )
            }
        }

        let virtualRoot = URL(fileURLWithPath: "/.flowfile-archive").appendingPathComponent(archiveURL.lastPathComponent)
        return directChildren.values.map { child in
            let syntheticURL = virtualRoot
                .appendingPathComponent(normalizedPrefix + child.name)
                .standardizedFileURL
            return FileItem(
                virtualArchiveURL: syntheticURL,
                name: child.name,
                isDirectory: child.isDirectory,
                size: child.size,
                modificationDate: child.modificationDate,
                archiveEntryPath: child.fullEntryPath
            )
        }
    }

    /// Extracts specific entries from an archive into destinationDirectory (flattening relative to currentSubpath).
    @discardableResult
    static func extractEntries(
        from archiveURL: URL,
        entryPaths: [String],
        currentSubpath: String,
        to destinationDirectory: URL
    ) throws -> [URL] {
        guard let kind = archiveKind(for: archiveURL), !entryPaths.isEmpty else { return [] }
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FlowFileExtract_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        switch kind {
        case .zip:
            var args = ["-q", "-o", archiveURL.path]
            for path in entryPaths {
                if path.hasSuffix("/") {
                    args.append("\(path)*")
                } else {
                    args.append(path)
                }
            }
            args.append(contentsOf: ["-d", tempDir.path])
            _ = try runProcess("/usr/bin/unzip", arguments: args)

        case .tar:
            var args = ["-xf", archiveURL.path, "-C", tempDir.path]
            for path in entryPaths {
                let clean = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                args.append(clean)
            }
            _ = try runProcess("/usr/bin/tar", arguments: args)
        }

        var movedResults: [URL] = []
        let fm = FileManager.default
        for rawPath in entryPaths {
            let clean = rawPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let extractedAt = tempDir.appendingPathComponent(clean)
            guard fm.fileExists(atPath: extractedAt.path) else { continue }
            let target = FileSystemService.uniqueDestinationURL(for: extractedAt, in: destinationDirectory)
            try fm.moveItem(at: extractedAt, to: target)
            movedResults.append(target)
        }
        return movedResults
    }

    /// Extracts a single archive entry to a temporary preview path for Quick Look / Open!
    static func extractForPreview(archiveURL: URL, entryPath: String) throws -> URL {
        let previewRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FlowFileQuickLook", isDirectory: true)
        try FileManager.default.createDirectory(at: previewRoot, withIntermediateDirectories: true)
        let cleanName = URL(fileURLWithPath: entryPath).lastPathComponent
        let existing = previewRoot.appendingPathComponent(cleanName)
        try? FileManager.default.removeItem(at: existing)

        let extracted = try extractEntries(
            from: archiveURL,
            entryPaths: [entryPath],
            currentSubpath: "",
            to: previewRoot
        )
        guard let first = extracted.first else {
            throw FileSystemError.directoryNotAccessible(entryPath)
        }
        return first
    }

    @discardableResult
    static func extractEntireArchive(_ archiveURL: URL, in parentDirectory: URL) throws -> URL {
        let baseName: String = {
            let name = archiveURL.lastPathComponent
            if name.lowercased().hasSuffix(".tar.gz") {
                return String(name.dropLast(7))
            }
            let ext = archiveURL.pathExtension
            return ext.isEmpty ? "\(name)_utpakket" : String(name.dropLast(ext.count + 1))
        }()

        let targetFolder = FileSystemService.uniqueDestinationURL(
            for: parentDirectory.appendingPathComponent(baseName),
            in: parentDirectory
        )
        try FileManager.default.createDirectory(at: targetFolder, withIntermediateDirectories: true)

        guard let kind = archiveKind(for: archiveURL) else { return targetFolder }
        switch kind {
        case .zip:
            _ = try runProcess("/usr/bin/ditto", arguments: ["-x", "-k", archiveURL.path, targetFolder.path])
        case .tar:
            _ = try runProcess("/usr/bin/tar", arguments: ["-xf", archiveURL.path, "-C", targetFolder.path])
        }
        return targetFolder
    }

    @discardableResult
    static func compressToZip(urls: [URL], in directory: URL, archiveName: String? = nil) throws -> URL {
        guard !urls.isEmpty else { throw FileSystemError.emptyName }
        let defaultName = urls.count == 1
            ? "\(urls[0].deletingPathExtension().lastPathComponent).zip"
            : "Arkiv.zip"
        let chosen = archiveName ?? defaultName
        let finalZipURL = FileSystemService.uniqueDestinationURL(
            for: directory.appendingPathComponent(chosen),
            in: directory
        )

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        proc.currentDirectoryURL = directory
        var args = ["-r", "-q", finalZipURL.path]
        for u in urls {
            args.append(u.lastPathComponent)
        }
        proc.arguments = args
        try proc.run()
        proc.waitUntilExit()
        return finalZipURL
    }

    // MARK: - Internal Parsers

    private static let zipDateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyyMMdd.HHmmss"
        return df
    }()

    private static func readZipEntries(archiveURL: URL) throws -> [ArchiveRawEntry] {
        let out = try runProcess("/usr/bin/unzip", arguments: ["-Z", "-T", archiveURL.path])
        var entries: [ArchiveRawEntry] = []

        for line in out.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let firstChar = trimmed.first,
                  firstChar == "-" || firstChar == "d" || firstChar == "l" else {
                continue
            }
            // Format: -rw-r--r--  3.0 unx  688 tx defN 20261110.235710 path/to/file
            let scannerTokens = trimmed.split(separator: " ", maxSplits: 7, omittingEmptySubsequences: true)
            guard scannerTokens.count >= 8 else { continue }
            let size = Int64(scannerTokens[3]) ?? 0
            let dateStr = String(scannerTokens[6])
            let entryPath = String(scannerTokens[7])
            let isDir = firstChar == "d" || entryPath.hasSuffix("/")
            let modDate = zipDateFormatter.date(from: dateStr)

            entries.append(ArchiveRawEntry(
                entryPath: entryPath,
                isDirectory: isDir,
                size: size,
                modificationDate: modDate
            ))
        }
        return entries
    }

    private static func readTarEntries(archiveURL: URL) throws -> [ArchiveRawEntry] {
        let out = try runProcess("/usr/bin/tar", arguments: ["-tvf", archiveURL.path])
        var entries: [ArchiveRawEntry] = []

        for line in out.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let firstChar = trimmed.first,
                  firstChar == "-" || firstChar == "d" || firstChar == "l" else {
                continue
            }
            // macOS bsdtar -tvf: -rw-r--r--  0 user group  1234 Nov 10 23:57 path/to/file
            let tokens = trimmed.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: true)
            guard tokens.count >= 9 else { continue }
            let size = Int64(tokens[4]) ?? 0
            let rawPath = String(tokens[8])
            let cleanPath = rawPath.hasPrefix("./") ? String(rawPath.dropFirst(2)) : rawPath
            let isDir = firstChar == "d" || cleanPath.hasSuffix("/")

            entries.append(ArchiveRawEntry(
                entryPath: cleanPath,
                isDirectory: isDir,
                size: size,
                modificationDate: nil
            ))
        }
        return entries
    }

    private static func runProcess(_ launchPath: String, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        try process.run()
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
