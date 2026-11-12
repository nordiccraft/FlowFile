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

enum ArchiveError: LocalizedError {
    case unsafeEntryPath(String)
    case commandFailed(String)
    case compressionFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsafeEntryPath(let path):
            return "Utrygg sti i arkivet ble avvist: \(path)"
        case .commandFailed(let detail):
            return detail.isEmpty
                ? "Kunne ikke lese eller pakke ut arkivet (korrupt eller passordbeskyttet fil)."
                : "Arkivfeil: \(detail)"
        case .compressionFailed(let detail):
            return detail.isEmpty
                ? "Kunne ikke opprette .zip-arkivet."
                : "Komprimering feilet: \(detail)"
        }
    }
}

enum ArchiveService {
    private static let compoundTarSuffixes: [String] = [
        ".tar.gz", ".tar.bz2", ".tar.xz", ".tar.zst", ".tgz", ".tbz2", ".txz"
    ]

    static func archiveKind(for url: URL) -> ArchiveKind? {
        let lower = url.lastPathComponent.lowercased()
        if lower.hasSuffix(".zip") {
            return .zip
        }
        if lower.hasSuffix(".tar") || compoundTarSuffixes.contains(where: { lower.hasSuffix($0) }) {
            return .tar
        }
        return nil
    }

    static func isSupportedArchive(_ url: URL) -> Bool {
        archiveKind(for: url) != nil
    }

    static func archiveBaseName(for archiveURL: URL) -> String {
        let name = archiveURL.lastPathComponent
        let lower = name.lowercased()
        for suffix in compoundTarSuffixes where lower.hasSuffix(suffix) {
            let base = String(name.dropLast(suffix.count))
            return base.isEmpty ? "\(name)_utpakket" : base
        }
        let ext = archiveURL.pathExtension
        if ext.isEmpty {
            return "\(name)_utpakket"
        }
        let stem = String(name.dropLast(ext.count + 1))
        return stem.isEmpty ? "\(name)_utpakket" : stem
    }

    /// Rejects empty paths, `.` segments, and `..` segments to prevent Zip-Slip / path traversal.
    static func sanitizeArchiveEntryPath(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else { return nil }
        let components = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty else { return nil }
        for comp in components {
            if comp.isEmpty || comp == "." || comp == ".." {
                return nil
            }
        }
        return components.joined(separator: "/")
    }

    /// Escapes fnmatch glob characters (`\`, `[`, `]`, `*`, `?`) for `/usr/bin/unzip` and `/usr/bin/tar`.
    static func escapeArchiveGlob(_ literalPath: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(literalPath.count + 4)
        for ch in literalPath {
            switch ch {
            case "\\", "[", "]", "*", "?":
                escaped.append("\\")
                escaped.append(ch)
            default:
                escaped.append(ch)
            }
        }
        return escaped
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
            guard let cleanPath = sanitizeArchiveEntryPath(entry.entryPath) else { continue }
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

        var validatedEntries: [(cleanPath: String, isDirHint: Bool)] = []
        for rawPath in entryPaths {
            guard let clean = sanitizeArchiveEntryPath(rawPath) else {
                throw ArchiveError.unsafeEntryPath(rawPath)
            }
            validatedEntries.append((cleanPath: clean, isDirHint: rawPath.hasSuffix("/")))
        }

        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FlowFileExtract_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        switch kind {
        case .zip:
            var args = ["-q", "-o", archiveURL.path]
            for item in validatedEntries {
                let escaped = escapeArchiveGlob(item.cleanPath)
                if item.isDirHint {
                    args.append("\(escaped)/*")
                } else {
                    args.append(escaped)
                }
            }
            args.append(contentsOf: ["-d", tempDir.path])
            _ = try runProcess("/usr/bin/unzip", arguments: args)

        case .tar:
            var args = ["-xf", archiveURL.path, "-C", tempDir.path, "--"]
            for item in validatedEntries {
                args.append(escapeArchiveGlob(item.cleanPath))
            }
            _ = try runProcess("/usr/bin/tar", arguments: args)
        }

        var movedResults: [URL] = []
        let fm = FileManager.default
        let canonicalTempPrefix = tempDir.resolvingSymlinksInPath().standardizedFileURL.path + "/"

        for item in validatedEntries {
            let extractedAt = tempDir.appendingPathComponent(item.cleanPath)
            guard let attrs = try? fm.attributesOfItem(atPath: extractedAt.path) else { continue }

            // Refuse symlinks or resolved paths escaping the temporary extraction sandbox
            if (attrs[.type] as? FileAttributeType) == .typeSymbolicLink {
                let resolvedTarget = extractedAt.resolvingSymlinksInPath().standardizedFileURL.path
                guard resolvedTarget.hasPrefix(canonicalTempPrefix) else {
                    throw ArchiveError.unsafeEntryPath(item.cleanPath)
                }
            } else {
                let resolvedPath = extractedAt.resolvingSymlinksInPath().standardizedFileURL.path
                guard resolvedPath.hasPrefix(canonicalTempPrefix) else {
                    throw ArchiveError.unsafeEntryPath(item.cleanPath)
                }
            }

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
        guard let kind = archiveKind(for: archiveURL) else {
            throw ArchiveError.commandFailed("Ukjent arkivformat: \(archiveURL.lastPathComponent)")
        }

        let baseName = archiveBaseName(for: archiveURL)
        let targetFolder = FileSystemService.uniqueDestinationURL(
            for: parentDirectory.appendingPathComponent(baseName),
            in: parentDirectory
        )
        try FileManager.default.createDirectory(at: targetFolder, withIntermediateDirectories: true)

        do {
            switch kind {
            case .zip:
                _ = try runProcess("/usr/bin/ditto", arguments: ["-x", "-k", archiveURL.path, targetFolder.path])
            case .tar:
                _ = try runProcess("/usr/bin/tar", arguments: ["-xf", archiveURL.path, "-C", targetFolder.path])
            }
            return targetFolder
        } catch {
            try? FileManager.default.removeItem(at: targetFolder)
            throw error
        }
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

        let sourceParent = urls[0].deletingLastPathComponent().standardizedFileURL
        var args = ["-r", "-q", finalZipURL.path, "--"]
        for u in urls {
            args.append(u.lastPathComponent)
        }

        do {
            _ = try runProcess("/usr/bin/zip", arguments: args, currentDirectoryURL: sourceParent)
        } catch {
            try? FileManager.default.removeItem(at: finalZipURL)
            throw ArchiveError.compressionFailed(error.localizedDescription)
        }

        guard FileManager.default.fileExists(atPath: finalZipURL.path) else {
            throw ArchiveError.compressionFailed("")
        }
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
        return parseZipListing(out)
    }

    static func parseZipListing(_ out: String) -> [ArchiveRawEntry] {
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
        return parseTarListing(out)
    }

    static func parseTarListing(_ out: String) -> [ArchiveRawEntry] {
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

    static func decodeArchiveOutput(_ data: Data) -> String {
        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }
        if let latin1 = String(data: data, encoding: .isoLatin1) {
            return latin1
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func runProcess(
        _ launchPath: String,
        arguments: [String],
        currentDirectoryURL: URL? = nil
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        if let currentDirectoryURL {
            process.currentDirectoryURL = currentDirectoryURL
        }
        process.standardInput = FileHandle.nullDevice

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        try process.run()

        // Drain stdout and stderr concurrently to avoid pipe-buffer deadlocks on large output/errors
        var outData = Data()
        var errData = Data()
        let drainGroup = DispatchGroup()

        drainGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            drainGroup.leave()
        }

        drainGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            drainGroup.leave()
        }

        process.waitUntilExit()
        drainGroup.wait()

        if process.terminationStatus != 0 {
            let errText = decodeArchiveOutput(errData)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let firstLine = errText.components(separatedBy: .newlines).first ?? ""
            throw ArchiveError.commandFailed(firstLine)
        }

        return decodeArchiveOutput(outData)
    }
}
