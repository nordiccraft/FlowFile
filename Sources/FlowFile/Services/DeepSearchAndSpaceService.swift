import CryptoKit
import Foundation

// MARK: - Feature 1: Deep Subfolder & File-Content Search (⇧⌘F)

struct DeepSearchQuery: Equatable {
    var rootURL: URL
    var nameQuery: String = ""
    var contentQuery: String = ""
    var minSizeBytes: Int64? = nil
    var modifiedWithinDays: Int? = nil
    var colorTag: FinderColorTag? = nil
    var includeHidden: Bool = false
    var caseSensitiveContent: Bool = false
    var maxResults: Int = 400
}

struct DeepSearchMatch: Identifiable, Equatable {
    var id: URL { item.url }
    let item: FileItem
    let relativeFolder: String
    let matchedLinePreview: String?
}

enum DeepSearchService {
    /// Maximum file size scanned for plain-text content search (15 MB) to keep searches instant and memory-light.
    private static let maxContentInspectBytes: Int64 = 15 * 1024 * 1024

    private static let skippedBinaryExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "gif", "webp", "tiff", "bmp", "ico", "icns",
        "mp4", "mov", "mkv", "avi", "mp3", "m4a", "wav", "flac",
        "zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "dmg", "iso", "pkg",
        "app", "dylib", "so", "o", "a", "pdf", "woff", "woff2", "ttf", "otf", "sqlite", "db"
    ]

    static func search(_ query: DeepSearchQuery) async -> [DeepSearchMatch] {
        await Task.detached(priority: .userInitiated) {
            searchSync(query)
        }.value
    }

    static func searchSync(_ query: DeepSearchQuery) -> [DeepSearchMatch] {
        let fm = FileManager.default
        let root = query.rootURL.standardizedFileURL
        guard fm.fileExists(atPath: root.path) else { return [] }

        let prefetchKeys: [URLResourceKey] = [
            .isDirectoryKey,
            .isPackageKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .isAliasFileKey,
            .isHiddenKey,
            .fileSizeKey,
            .totalFileAllocatedSizeKey,
            .contentModificationDateKey,
            .creationDateKey,
            .labelNumberKey
        ]
        let keySet = Set(prefetchKeys + [.tagNamesKey])

        var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if !query.includeHidden {
            options.insert(.skipsHiddenFiles)
        }

        let trimmedName = query.nameQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedContent = query.contentQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let cutoffDate: Date? = query.modifiedWithinDays.map { days in
            Date().addingTimeInterval(-Double(max(1, days)) * 86_400.0)
        }

        let rootPathPrefix = root.path.hasSuffix("/") ? root.path : (root.path + "/")
        let insideCloud = CloudStorageService.isInsideAnyCloudFolder(root)

        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: prefetchKeys,
            options: options,
            errorHandler: { _, _ in true }
        ) else {
            return []
        }

        var results: [DeepSearchMatch] = []

        while let url = enumerator.nextObject() as? URL {
            if Task.isCancelled || results.count >= query.maxResults {
                break
            }

            let fileName = url.lastPathComponent
            if !query.includeHidden && fileName.hasPrefix(".") {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            if fileName == ".git" || fileName == "node_modules" || fileName == ".build" {
                enumerator.skipDescendants()
                continue
            }

            guard let rv = try? url.resourceValues(forKeys: keySet) else { continue }

            // 1. Filename match
            if !trimmedName.isEmpty && !fileName.localizedCaseInsensitiveContains(trimmedName) {
                continue
            }

            // 2. Minimum size filter
            let logicalSize = Int64(rv.fileSize ?? rv.totalFileAllocatedSize ?? 0)
            if let minBytes = query.minSizeBytes, minBytes > 0 {
                if rv.isDirectory == true && rv.isPackage != true {
                    continue
                }
                if logicalSize < minBytes {
                    continue
                }
            }

            // 3. Modified date filter
            if let cutoff = cutoffDate {
                guard let mod = rv.contentModificationDate, mod >= cutoff else {
                    continue
                }
            }

            // 4. Color tag filter
            if let requiredTag = query.colorTag {
                let tags = FinderColorTag.extractColorTags(from: rv.tagNames ?? [], labelNumber: rv.labelNumber)
                if !tags.contains(requiredTag) {
                    continue
                }
            }

            // 5. Optional file-content substring search
            var matchedSnippet: String? = nil
            if !trimmedContent.isEmpty {
                guard rv.isRegularFile == true,
                      logicalSize > 0,
                      logicalSize <= maxContentInspectBytes,
                      !CloudStorageService.isDatalessPlaceholder(url) else {
                    continue
                }
                let ext = url.pathExtension.lowercased()
                if skippedBinaryExtensions.contains(ext) {
                    continue
                }
                guard let snippet = findMatchingLineSnippet(
                    in: url,
                    needle: trimmedContent,
                    caseSensitive: query.caseSensitiveContent
                ) else {
                    continue
                }
                matchedSnippet = snippet
            }

            let stdURL = url.standardizedFileURL
            let relFull: String
            if stdURL.path.hasPrefix(rootPathPrefix) {
                relFull = String(stdURL.path.dropFirst(rootPathPrefix.count))
            } else {
                relFull = stdURL.lastPathComponent
            }
            let relDir = (relFull as NSString).deletingLastPathComponent

            let item = FileItem(
                url: stdURL,
                resourceValues: rv,
                insideCloudRoot: insideCloud,
                relativeSubpath: relDir.isEmpty ? nil : relDir
            )
            results.append(
                DeepSearchMatch(
                    item: item,
                    relativeFolder: relDir.isEmpty ? "." : relDir,
                    matchedLinePreview: matchedSnippet
                )
            )
        }

        return results
    }

    private static func findMatchingLineSnippet(
        in fileURL: URL,
        needle: String,
        caseSensitive: Bool
    ) -> String? {
        guard let data = try? Data(contentsOf: fileURL, options: [.mappedIfSafe]),
              !data.isEmpty else {
            return nil
        }
        // Quick binary NUL-byte check in first 4 KB
        let sampleCount = min(data.count, 4096)
        if data.prefix(sampleCount).contains(0) {
            return nil
        }
        guard let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else {
            return nil
        }

        let compareOptions: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive, .diacriticInsensitive]
        guard let range = text.range(of: needle, options: compareOptions) else {
            return nil
        }

        let lineRange = text.lineRange(for: range)
        let rawLine = text[lineRange].trimmingCharacters(in: .whitespacesAndNewlines)
        if rawLine.count <= 140 {
            return rawLine
        }
        if let localMatch = rawLine.range(of: needle, options: compareOptions) {
            let matchOffset = rawLine.distance(from: rawLine.startIndex, to: localMatch.lowerBound)
            let matchLength = rawLine.distance(from: localMatch.lowerBound, to: localMatch.upperBound)
            let startOffset = max(0, matchOffset - 50)
            let endOffset = min(rawLine.count, max(startOffset + 140, matchOffset + matchLength + 40))
            let startIdx = rawLine.index(rawLine.startIndex, offsetBy: startOffset)
            let endIdx = rawLine.index(rawLine.startIndex, offsetBy: endOffset)
            let slice = String(rawLine[startIdx..<endIdx])
            let leading = startOffset > 0 ? "…" : ""
            let trailing = endOffset < rawLine.count ? "…" : ""
            return leading + slice + trailing
        }
        return String(rawLine.prefix(140)) + "…"
    }
}

// MARK: - Feature 4: Visual Disk Space Analyzer

struct DiskSpaceEntry: Identifiable, Equatable {
    var id: URL { url }
    let url: URL
    let name: String
    let isDirectory: Bool
    let sizeBytes: Int64
    let itemCount: Int
    let fractionOfRoot: Double
}

struct DiskSpaceReport: Equatable {
    let rootURL: URL
    let totalBytes: Int64
    let scannedFileCount: Int
    let children: [DiskSpaceEntry]
    let largestFiles: [DiskSpaceEntry]
}

enum DiskSpaceAnalyzerService {
    static func analyze(directory rootURL: URL, includeHidden: Bool = true) async -> DiskSpaceReport {
        await Task.detached(priority: .userInitiated) {
            analyzeSync(directory: rootURL, includeHidden: includeHidden)
        }.value
    }

    static func analyzeSync(directory rootURL: URL, includeHidden: Bool = true) -> DiskSpaceReport {
        let fm = FileManager.default
        let root = rootURL.standardizedFileURL
        let rootPrefix = root.path.hasSuffix("/") ? root.path : (root.path + "/")

        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isPackageKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .isHiddenKey,
            .fileSizeKey,
            .totalFileAllocatedSizeKey
        ]
        let keySet = Set(keys)

        // Immediate entries in root so empty or small folders are still represented accurately
        var childMeta: [String: (url: URL, isDir: Bool, bytes: Int64, count: Int)] = [:]
        if let directURLs = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: keys,
            options: includeHidden ? [] : [.skipsHiddenFiles]
        ) {
            for direct in directURLs {
                let std = direct.standardizedFileURL
                let name = std.lastPathComponent
                if !includeHidden && name.hasPrefix(".") { continue }
                let rv = try? std.resourceValues(forKeys: keySet)
                if rv?.isSymbolicLink == true { continue }
                let isDir = (rv?.isDirectory == true)
                let directBytes = isDir ? Int64(0) : Int64(rv?.totalFileAllocatedSize ?? rv?.fileSize ?? 0)
                childMeta[name] = (url: std, isDir: isDir, bytes: directBytes, count: isDir ? 0 : 1)
            }
        }

        var options: FileManager.DirectoryEnumerationOptions = []
        if !includeHidden {
            options.insert(.skipsHiddenFiles)
        }

        var totalBytes: Int64 = 0
        var scannedFiles = 0
        var topFiles: [(url: URL, bytes: Int64)] = []
        let topLimit = 30

        if let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: options,
            errorHandler: { _, _ in true }
        ) {
            while let url = enumerator.nextObject() as? URL {
                if Task.isCancelled { break }
                let std = url.standardizedFileURL
                guard std.path.hasPrefix(rootPrefix) else { continue }
                let rel = String(std.path.dropFirst(rootPrefix.count))
                guard let firstComponent = rel.split(separator: "/", maxSplits: 1).first.map(String.init),
                      !firstComponent.isEmpty else {
                    continue
                }
                if !includeHidden && firstComponent.hasPrefix(".") {
                    enumerator.skipDescendants()
                    continue
                }

                guard let rv = try? std.resourceValues(forKeys: keySet) else { continue }
                if rv.isSymbolicLink == true {
                    enumerator.skipDescendants()
                    continue
                }

                guard rv.isRegularFile == true else { continue }
                let bytes = Int64(rv.totalFileAllocatedSize ?? rv.fileSize ?? 0)
                totalBytes += bytes
                scannedFiles += 1

                if var existing = childMeta[firstComponent] {
                    if existing.isDir {
                        existing.bytes += bytes
                        existing.count += 1
                    } else {
                        existing.bytes = bytes
                        existing.count = 1
                    }
                    childMeta[firstComponent] = existing
                } else {
                    let topChildURL = root.appendingPathComponent(firstComponent)
                    let isSubpath = rel.contains("/")
                    childMeta[firstComponent] = (url: topChildURL, isDir: isSubpath, bytes: bytes, count: 1)
                }

                // Maintain top N largest individual files
                if bytes > 0 {
                    if topFiles.count < topLimit {
                        topFiles.append((url: std, bytes: bytes))
                        if topFiles.count == topLimit {
                            topFiles.sort { $0.bytes > $1.bytes }
                        }
                    } else if let smallestTop = topFiles.last?.bytes, bytes > smallestTop {
                        topFiles[topFiles.count - 1] = (url: std, bytes: bytes)
                        topFiles.sort { $0.bytes > $1.bytes }
                    }
                }
            }
        }

        let safeTotal = max(Int64(1), totalBytes)
        let sortedChildren = childMeta.values
            .sorted {
                if $0.bytes != $1.bytes { return $0.bytes > $1.bytes }
                return $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
            }
            .map { meta in
                DiskSpaceEntry(
                    url: meta.url,
                    name: meta.url.lastPathComponent,
                    isDirectory: meta.isDir,
                    sizeBytes: meta.bytes,
                    itemCount: meta.count,
                    fractionOfRoot: totalBytes > 0 ? min(1.0, Double(meta.bytes) / Double(safeTotal)) : 0.0
                )
            }

        let sortedLargestFiles = topFiles
            .sorted { $0.bytes > $1.bytes }
            .map { file in
                DiskSpaceEntry(
                    url: file.url,
                    name: file.url.lastPathComponent,
                    isDirectory: false,
                    sizeBytes: file.bytes,
                    itemCount: 1,
                    fractionOfRoot: totalBytes > 0 ? min(1.0, Double(file.bytes) / Double(safeTotal)) : 0.0
                )
            }

        return DiskSpaceReport(
            rootURL: root,
            totalBytes: totalBytes,
            scannedFileCount: scannedFiles,
            children: sortedChildren,
            largestFiles: sortedLargestFiles
        )
    }
}

// MARK: - Feature 7: Duplicate File Finder (Size Grouping + Partial Pre-Hash + Full SHA-256)

struct DuplicateFileGroup: Identifiable, Equatable {
    let id: String
    let sha256: String
    let sizeBytes: Int64
    let items: [FileItem]

    var reclaimableBytes: Int64 {
        sizeBytes * Int64(max(0, items.count - 1))
    }
}

enum DuplicateFinderService {
    static func scanForDuplicates(
        inRoots roots: [URL],
        includeHidden: Bool = false,
        minFileSizeBytes: Int64 = 1
    ) async -> [DuplicateFileGroup] {
        await Task.detached(priority: .userInitiated) {
            scanSync(inRoots: roots, includeHidden: includeHidden, minFileSizeBytes: minFileSizeBytes)
        }.value
    }

    static func scanSync(
        inRoots roots: [URL],
        includeHidden: Bool = false,
        minFileSizeBytes: Int64 = 1
    ) -> [DuplicateFileGroup] {
        let fm = FileManager.default
        let prefetchKeys: [URLResourceKey] = [
            .isRegularFileKey,
            .isDirectoryKey,
            .isPackageKey,
            .isSymbolicLinkKey,
            .isHiddenKey,
            .fileSizeKey,
            .totalFileAllocatedSizeKey,
            .contentModificationDateKey,
            .creationDateKey,
            .labelNumberKey
        ]
        let keySet = Set(prefetchKeys + [.tagNamesKey])

        var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if !includeHidden {
            options.insert(.skipsHiddenFiles)
        }

        // Stage 1: Group regular files by exact byte size
        var bySize: [Int64: [FileItem]] = [:]
        var seenPaths = Set<String>()
        // Physical file identity (inode/volume): the same file reached via two path spellings,
        // symlinked roots, firmlinks or hardlinks must never be treated as its own duplicate.
        var seenFileIDs: [NSObject] = []
        func alreadySeen(_ id: NSObject) -> Bool {
            seenFileIDs.contains { $0.isEqual(id) }
        }
        var seenFileIDHashes = Set<Int>()

        for rawRoot in roots {
            if Task.isCancelled { break }
            let root = rawRoot.standardizedFileURL
            guard fm.fileExists(atPath: root.path) else { continue }

            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: prefetchKeys + [.fileResourceIdentifierKey],
                options: options,
                errorHandler: { _, _ in true }
            ) else { continue }

            while let url = enumerator.nextObject() as? URL {
                if Task.isCancelled { break }
                let name = url.lastPathComponent
                if name == ".git" || name == "node_modules" || name == ".build" {
                    enumerator.skipDescendants()
                    continue
                }
                let std = url.standardizedFileURL
                guard !seenPaths.contains(std.path) else { continue }
                guard let rv = try? std.resourceValues(forKeys: keySet.union([.fileResourceIdentifierKey])),
                      rv.isRegularFile == true,
                      rv.isSymbolicLink != true else {
                    continue
                }
                let size = Int64(rv.fileSize ?? 0)
                guard size >= max(1, minFileSizeBytes) else { continue }
                // Never download cloud-only placeholders just to hash them
                if CloudStorageService.isDatalessPlaceholder(std) { continue }

                if let fileID = rv.fileResourceIdentifier as? NSObject {
                    let h = fileID.hash
                    if seenFileIDHashes.contains(h) && alreadySeen(fileID) { continue }
                    seenFileIDHashes.insert(h)
                    seenFileIDs.append(fileID)
                }

                seenPaths.insert(std.path)
                bySize[size, default: []].append(FileItem(url: std, resourceValues: rv))
            }
        }

        var duplicateGroups: [DuplicateFileGroup] = []

        for (size, candidates) in bySize where candidates.count >= 2 {
            if Task.isCancelled { break }

            // Stage 2: Fast head+tail pre-hash for larger files (> 128 KB)
            let preFilteredGroups: [[FileItem]]
            if size > 131_072 {
                var byEdgeHash: [String: [FileItem]] = [:]
                for item in candidates {
                    if Task.isCancelled { break }
                    if let edge = computeEdgeSampleDigest(for: item.url, fileSize: size) {
                        byEdgeHash[edge, default: []].append(item)
                    }
                }
                preFilteredGroups = Array(byEdgeHash.values.filter { $0.count >= 2 })
            } else {
                preFilteredGroups = [candidates]
            }

            // Stage 3: Exact streaming SHA-256 verification
            for group in preFilteredGroups {
                var bySHA: [String: [FileItem]] = [:]
                for item in group {
                    if Task.isCancelled { break }
                    if let digest = try? QuickFileToolsService.computeSHA256Sync(for: item.url) {
                        bySHA[digest, default: []].append(item)
                    }
                }

                for (sha, matchedItems) in bySHA where matchedItems.count >= 2 {
                    let sortedItems = matchedItems.sorted { lhs, rhs in
                        let lDate = lhs.modificationDate ?? .distantPast
                        let rDate = rhs.modificationDate ?? .distantPast
                        if lDate != rDate { return lDate > rDate } // newest first
                        return lhs.url.path < rhs.url.path
                    }
                    duplicateGroups.append(
                        DuplicateFileGroup(
                            id: "\(size)_\(sha)",
                            sha256: sha,
                            sizeBytes: size,
                            items: sortedItems
                        )
                    )
                }
            }
        }

        return duplicateGroups.sorted {
            if $0.reclaimableBytes != $1.reclaimableBytes {
                return $0.reclaimableBytes > $1.reclaimableBytes
            }
            return $0.sizeBytes > $1.sizeBytes
        }
    }

    /// Selects all duplicates EXCEPT the newest copy in every group.
    static func urlsToTrashKeepingNewest(in groups: [DuplicateFileGroup]) -> Set<URL> {
        var result = Set<URL>()
        for group in groups {
            let sortedNewestFirst = group.items.sorted { lhs, rhs in
                let lDate = lhs.modificationDate ?? .distantPast
                let rDate = rhs.modificationDate ?? .distantPast
                if lDate != rDate { return lDate > rDate }
                return lhs.url.path < rhs.url.path
            }
            for item in sortedNewestFirst.dropFirst() {
                result.insert(item.url)
            }
        }
        return result
    }

    /// Selects all duplicates EXCEPT the oldest copy in every group.
    static func urlsToTrashKeepingOldest(in groups: [DuplicateFileGroup]) -> Set<URL> {
        var result = Set<URL>()
        for group in groups {
            let sortedOldestFirst = group.items.sorted { lhs, rhs in
                let lDate = lhs.modificationDate ?? .distantFuture
                let rDate = rhs.modificationDate ?? .distantFuture
                if lDate != rDate { return lDate < rDate }
                return lhs.url.path < rhs.url.path
            }
            for item in sortedOldestFirst.dropFirst() {
                result.insert(item.url)
            }
        }
        return result
    }

    private static func computeEdgeSampleDigest(for url: URL, fileSize: Int64) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let sampleLen = 32_768
        var hasher = SHA256()
        if let head = try? handle.read(upToCount: sampleLen) {
            hasher.update(data: head)
        }
        if fileSize > Int64(sampleLen * 2) {
            let tailOffset = UInt64(max(0, fileSize - Int64(sampleLen)))
            try? handle.seek(toOffset: tailOffset)
            if let tail = try? handle.read(upToCount: sampleLen) {
                hasher.update(data: tail)
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Feature 8: Flat Subfolder View (⌥⌘B)

enum FlatBranchService {
    static func listRecursiveFiles(
        at rootURL: URL,
        showHidden: Bool,
        maxItems: Int = 10_000
    ) throws -> [FileItem] {
        let fm = FileManager.default
        let root = rootURL.standardizedFileURL
        guard fm.fileExists(atPath: root.path) else {
            throw FileSystemError.directoryNotAccessible(root.path)
        }

        let prefetchKeys: [URLResourceKey] = [
            .isDirectoryKey,
            .isPackageKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .isAliasFileKey,
            .isHiddenKey,
            .fileSizeKey,
            .totalFileAllocatedSizeKey,
            .contentModificationDateKey,
            .creationDateKey,
            .labelNumberKey,
            .ubiquitousItemDownloadingStatusKey,
            .ubiquitousItemIsDownloadingKey,
            .ubiquitousItemIsUploadingKey
        ]
        let keySet = Set(prefetchKeys + [.tagNamesKey])

        var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if !showHidden {
            options.insert(.skipsHiddenFiles)
        }

        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: prefetchKeys,
            options: options,
            errorHandler: { _, _ in true }
        ) else {
            throw FileSystemError.directoryNotAccessible(root.path)
        }

        let rootPrefix = root.path.hasSuffix("/") ? root.path : (root.path + "/")
        let insideCloud = CloudStorageService.isInsideAnyCloudFolder(root)
        var items: [FileItem] = []

        while let url = enumerator.nextObject() as? URL {
            if items.count >= maxItems { break }
            let name = url.lastPathComponent
            if !showHidden && name.hasPrefix(".") {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            if name == ".git" || name == "node_modules" || name == ".build" {
                enumerator.skipDescendants()
                continue
            }

            let rv = try? url.resourceValues(forKeys: keySet)
            let isDir = rv?.isDirectory ?? false
            let isPkg = rv?.isPackage ?? false
            // In Flat View, flatten navigable subfolders away so all files & bundles appear in one list
            if isDir && !isPkg {
                continue
            }

            let std = url.standardizedFileURL
            let relFull: String
            if std.path.hasPrefix(rootPrefix) {
                relFull = String(std.path.dropFirst(rootPrefix.count))
            } else {
                relFull = std.lastPathComponent
            }
            let relFolder = (relFull as NSString).deletingLastPathComponent

            items.append(
                FileItem(
                    url: std,
                    resourceValues: rv,
                    insideCloudRoot: insideCloud,
                    relativeSubpath: relFolder.isEmpty ? nil : relFolder
                )
            )
        }

        return items
    }
}
