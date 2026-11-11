import AppKit
import Foundation

enum FileSystemError: LocalizedError {
    case emptyName
    case targetAlreadyExists(String)
    case directoryNotAccessible(String)

    var errorDescription: String? {
        switch self {
        case .emptyName:
            return "Navnet kan ikke være tomt."
        case .targetAlreadyExists(let name):
            return "«\(name)» finnes allerede i denne mappen."
        case .directoryNotAccessible(let path):
            return "Ingen tilgang til mappen: \(path)"
        }
    }
}

enum FileSystemService {
    private static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey,
        .isPackageKey,
        .isSymbolicLinkKey,
        .isAliasFileKey,
        .isHiddenKey,
        .fileSizeKey,
        .totalFileAllocatedSizeKey,
        .contentModificationDateKey,
        .creationDateKey,
        .localizedTypeDescriptionKey,
        .ubiquitousItemDownloadingStatusKey,
        .ubiquitousItemIsDownloadingKey,
        .ubiquitousItemIsUploadingKey
    ]

    static func listDirectory(at directoryURL: URL, showHidden: Bool) throws -> [FileItem] {
        let fm = FileManager.default
        var options: FileManager.DirectoryEnumerationOptions = [.skipsSubdirectoryDescendants]
        if !showHidden {
            options.insert(.skipsHiddenFiles)
        }

        let keySet = Set(resourceKeys)
        let insideCloud = CloudStorageService.isInsideAnyCloudFolder(directoryURL)
        let urls: [URL]
        do {
            urls = try fm.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: resourceKeys,
                options: options
            )
        } catch {
            throw FileSystemError.directoryNotAccessible(directoryURL.path)
        }

        var items: [FileItem] = []
        items.reserveCapacity(urls.count)

        for url in urls {
            let name = url.lastPathComponent
            if !showHidden && name.hasPrefix(".") {
                continue
            }
            let values = try? url.resourceValues(forKeys: keySet)
            items.append(FileItem(url: url, resourceValues: values, insideCloudRoot: insideCloud))
        }

        return items
    }

    /// Windows Explorer / Total Commander rule: Navigable folders ALWAYS stay at the top,
    /// regardless of sort column or ascending/descending direction.
    static func sortItems(
        _ items: [FileItem],
        by column: SortColumn,
        ascending: Bool,
        folderSizes: [URL: Int64] = [:]
    ) -> [FileItem] {
        items.sorted { lhs, rhs in
            if lhs.isNavigableFolder != rhs.isNavigableFolder {
                return lhs.isNavigableFolder && !rhs.isNavigableFolder
            }

            let comparison: ComparisonResult
            switch column {
            case .name:
                comparison = lhs.name.localizedStandardCompare(rhs.name)
            case .ext:
                let extCmp = lhs.fileExtension.localizedStandardCompare(rhs.fileExtension)
                comparison = extCmp == .orderedSame
                    ? lhs.name.localizedStandardCompare(rhs.name)
                    : extCmp
            case .size:
                let lSize = lhs.isNavigableFolder ? (folderSizes[lhs.url] ?? -1) : lhs.size
                let rSize = rhs.isNavigableFolder ? (folderSizes[rhs.url] ?? -1) : rhs.size
                if lSize == rSize {
                    comparison = lhs.name.localizedStandardCompare(rhs.name)
                } else {
                    comparison = lSize < rSize ? .orderedAscending : .orderedDescending
                }
            case .dateModified:
                let lDate = lhs.modificationDate ?? .distantPast
                let rDate = rhs.modificationDate ?? .distantPast
                if lDate == rDate {
                    comparison = lhs.name.localizedStandardCompare(rhs.name)
                } else {
                    comparison = lDate < rDate ? .orderedAscending : .orderedDescending
                }
            case .kind:
                let kindCmp = lhs.kindDescription.localizedStandardCompare(rhs.kindDescription)
                comparison = kindCmp == .orderedSame
                    ? lhs.name.localizedStandardCompare(rhs.name)
                    : kindCmp
            }

            if comparison == .orderedSame {
                return false
            }
            return ascending ? (comparison == .orderedAscending) : (comparison == .orderedDescending)
        }
    }

    static func mountedVolumes() -> [VolumeInfo] {
        let keys: [URLResourceKey] = [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeIsInternalKey,
            .volumeIsRemovableKey,
            .volumeIsEjectableKey
        ]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) ?? [URL(fileURLWithPath: "/")]

        return urls.compactMap { url in
            guard let rv = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            let name = rv.volumeName ?? FileManager.default.displayName(atPath: url.path)
            let total = Int64(rv.volumeTotalCapacity ?? 0)
            let availImportant = rv.volumeAvailableCapacityForImportantUsage
            let availBasic = rv.volumeAvailableCapacity.map { Int64($0) }
            let avail = availImportant ?? availBasic ?? 0
            return VolumeInfo(
                url: url,
                name: name,
                totalCapacity: total,
                availableCapacity: avail,
                isInternal: rv.volumeIsInternal ?? (url.path == "/"),
                isRemovable: rv.volumeIsRemovable ?? false,
                isEjectable: rv.volumeIsEjectable ?? false
            )
        }
    }

    static func calculateFolderSize(at folderURL: URL) async -> Int64 {
        await Task.detached(priority: .userInitiated) {
            calculateFolderSizeSync(at: folderURL)
        }.value
    }

    private static func calculateFolderSizeSync(at folderURL: URL) -> Int64 {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey]
        guard let enumerator = fm.enumerator(
            at: folderURL,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            return 0
        }

        var total: Int64 = 0
        while let fileURL = enumerator.nextObject() as? URL {
            if Task.isCancelled { break }
            if let rv = try? fileURL.resourceValues(forKeys: Set(keys)),
               rv.isRegularFile == true {
                total += Int64(rv.fileSize ?? rv.totalFileAllocatedSize ?? 0)
            }
        }
        return total
    }

    @discardableResult
    static func createShortcutSymlink(to targetURL: URL, in destinationDir: URL) throws -> URL {
        let baseName = targetURL.lastPathComponent
        let linkCandidate = uniqueDestinationURL(
            for: destinationDir.appendingPathComponent(baseName),
            in: destinationDir
        )
        try FileManager.default.createSymbolicLink(at: linkCandidate, withDestinationURL: targetURL)
        return linkCandidate
    }

    @discardableResult
    static func createFolder(named rawName: String, in directory: URL) throws -> URL {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw FileSystemError.emptyName }
        let target = directory.appendingPathComponent(trimmed, isDirectory: true)
        if FileManager.default.fileExists(atPath: target.path) {
            throw FileSystemError.targetAlreadyExists(trimmed)
        }
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        return target
    }

    @discardableResult
    static func createEmptyFile(named rawName: String, in directory: URL) throws -> URL {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw FileSystemError.emptyName }
        let target = directory.appendingPathComponent(trimmed, isDirectory: false)
        if FileManager.default.fileExists(atPath: target.path) {
            throw FileSystemError.targetAlreadyExists(trimmed)
        }
        FileManager.default.createFile(atPath: target.path, contents: Data())
        return target
    }

    @discardableResult
    static func renameItem(at sourceURL: URL, to rawNewName: String) throws -> URL {
        let trimmed = rawNewName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw FileSystemError.emptyName }
        let parent = sourceURL.deletingLastPathComponent()
        let destination = parent.appendingPathComponent(trimmed)
        if destination.standardizedFileURL == sourceURL.standardizedFileURL {
            return sourceURL
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            throw FileSystemError.targetAlreadyExists(trimmed)
        }
        try FileManager.default.moveItem(at: sourceURL, to: destination)
        return destination
    }

    @discardableResult
    static func copyItems(_ urls: [URL], toDirectory destinationDir: URL) throws -> [URL] {
        let fm = FileManager.default
        var created: [URL] = []
        for src in urls {
            let dst = uniqueDestinationURL(for: src, in: destinationDir)
            try fm.copyItem(at: src, to: dst)
            created.append(dst)
        }
        return created
    }

    @discardableResult
    static func moveItems(_ urls: [URL], toDirectory destinationDir: URL) throws -> [URL] {
        let fm = FileManager.default
        var moved: [URL] = []
        for src in urls {
            if src.deletingLastPathComponent().standardizedFileURL == destinationDir.standardizedFileURL {
                moved.append(src)
                continue
            }
            let dst = uniqueDestinationURL(for: src, in: destinationDir)
            try fm.moveItem(at: src, to: dst)
            moved.append(dst)
        }
        return moved
    }

    static func trashItems(_ urls: [URL]) throws {
        let fm = FileManager.default
        for url in urls {
            try fm.trashItem(at: url, resultingItemURL: nil)
        }
    }

    static func permanentlyDeleteItems(_ urls: [URL]) throws {
        let fm = FileManager.default
        for url in urls {
            try fm.removeItem(at: url)
        }
    }

    static func uniqueDestinationURL(for sourceURL: URL, in destinationDir: URL) -> URL {
        let fm = FileManager.default
        let baseName = sourceURL.lastPathComponent
        let initial = destinationDir.appendingPathComponent(baseName)
        if !fm.fileExists(atPath: initial.path) {
            return initial
        }

        let ext = sourceURL.pathExtension
        let stem = ext.isEmpty ? baseName : String(baseName.dropLast(ext.count + 1))

        var counter = 2
        while true {
            let candidateName = ext.isEmpty
                ? "\(stem) (\(counter))"
                : "\(stem) (\(counter)).\(ext)"
            let candidate = destinationDir.appendingPathComponent(candidateName)
            if !fm.fileExists(atPath: candidate.path) {
                return candidate
            }
            counter += 1
        }
    }

    static func posixPermissionsString(for url: URL) -> String {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let posix = attrs[.posixPermissions] as? Int else {
            return "—"
        }
        let isDir = (attrs[.type] as? FileAttributeType) == .typeDirectory
        var chars = [Character](repeating: "-", count: 10)
        chars[0] = isDir ? "d" : "-"
        let flags: [(Int, Int, Character)] = [
            (0o400, 1, "r"), (0o200, 2, "w"), (0o100, 3, "x"),
            (0o040, 4, "r"), (0o020, 5, "w"), (0o010, 6, "x"),
            (0o004, 7, "r"), (0o002, 8, "w"), (0o001, 9, "x")
        ]
        for (mask, idx, ch) in flags where (posix & mask) != 0 {
            chars[idx] = ch
        }
        return String(chars)
    }

    static func resolveUserPath(_ rawInput: String, relativeTo currentURL: URL) -> URL? {
        var input = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }
        if input.hasPrefix("~") {
            input = NSString(string: input).expandingTildeInPath
        }
        let candidate: URL
        if input.hasPrefix("/") {
            candidate = URL(fileURLWithPath: input).standardizedFileURL
        } else {
            candidate = currentURL.appendingPathComponent(input).standardizedFileURL
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir) else {
            return nil
        }
        return CloudStorageService.resolvePossibleShortcut(at: candidate) ?? candidate
    }
}
