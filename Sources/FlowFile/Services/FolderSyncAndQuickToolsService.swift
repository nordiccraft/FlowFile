import AppKit
import CryptoKit
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

// MARK: - Feature 5: Folder Synchronization

enum FolderSyncMode: String, CaseIterable, Identifiable {
    case updateLeftToRight = "updateLeftToRight"
    case twoWayNewest = "twoWayNewest"
    case mirrorLeftToRight = "mirrorLeftToRight"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .updateLeftToRight:
            return tr("Oppdater venstre → høyre (kun nye og nyere)", "Update Left → Right (new & newer only)")
        case .twoWayNewest:
            return tr("To-veis synkronisering (nyeste vinner)", "Two-Way Sync (newest wins)")
        case .mirrorLeftToRight:
            return tr("Speil venstre → høyre (flytter ekstra i høyre til Papirkurv)", "Mirror Left → Right (moves extra in right to Trash)")
        }
    }

    var descriptionText: String {
        switch self {
        case .updateLeftToRight:
            return tr(
                "Kopierer manglende og nyere filer fra venstre mappe til høyre mappe. Sletter ingenting.",
                "Copies missing and newer files from the left folder to the right folder. Deletes nothing."
            )
        case .twoWayNewest:
            return tr(
                "Sørger for at begge mapper får alle nye og sist endrede filer fra hverandre. Sletter ingenting.",
                "Ensures both folders receive all missing and most recently modified files from each other. Deletes nothing."
            )
        case .mirrorLeftToRight:
            return tr(
                "Gjør høyre mappe identisk med venstre: kopierer nye/endrede filer over og flytter filer som kun finnes i høyre til Papirkurven.",
                "Makes the right folder match the left: copies new/modified files across and moves right-only files safely to Trash."
            )
        }
    }
}

enum FolderSyncOperationKind: String, Equatable {
    case copyLeftToRight
    case copyRightToLeft
    case trashInRight

    var badgeText: String {
        switch self {
        case .copyLeftToRight: return tr("Kopier →", "Copy →")
        case .copyRightToLeft: return tr("← Kopier", "← Copy")
        case .trashInRight: return tr("Papirkurv (Høyre)", "Trash (Right)")
        }
    }
}

struct FolderSyncItemPlan: Identifiable, Equatable {
    var id: String { "\(operation.rawValue):\(relativePath)" }
    let relativePath: String
    let sourceURL: URL?
    let destinationURL: URL
    let operation: FolderSyncOperationKind
    let sizeBytes: Int64
    let reason: String
}

enum FolderSyncError: LocalizedError {
    case sameFolder
    case nestedFolders

    var errorDescription: String? {
        switch self {
        case .sameFolder:
            return tr("Venstre og høyre panel viser samme mappe.", "Left and right panes point to the same folder.")
        case .nestedFolders:
            return tr(
                "Den ene mappen ligger inne i den andre. Velg to separate mapper før synkronisering.",
                "One folder is nested inside the other. Please select two separate folders to synchronize."
            )
        }
    }
}

enum FolderSyncService {
    private struct ScannedSyncFile {
        let url: URL
        let relativePath: String
        let size: Int64
        let modified: Date
    }

    static func buildPlan(
        leftRoot: URL,
        rightRoot: URL,
        mode: FolderSyncMode,
        includeHidden: Bool = false
    ) async throws -> [FolderSyncItemPlan] {
        try await Task.detached(priority: .userInitiated) {
            try buildPlanSync(
                leftRoot: leftRoot,
                rightRoot: rightRoot,
                mode: mode,
                includeHidden: includeHidden
            )
        }.value
    }

    static func buildPlanSync(
        leftRoot: URL,
        rightRoot: URL,
        mode: FolderSyncMode,
        includeHidden: Bool = false
    ) throws -> [FolderSyncItemPlan] {
        let leftStd = leftRoot.standardizedFileURL
        let rightStd = rightRoot.standardizedFileURL

        if leftStd.path == rightStd.path {
            throw FolderSyncError.sameFolder
        }
        let leftSlash = leftStd.path.hasSuffix("/") ? leftStd.path : (leftStd.path + "/")
        let rightSlash = rightStd.path.hasSuffix("/") ? rightStd.path : (rightStd.path + "/")
        if leftStd.path.hasPrefix(rightSlash) || rightStd.path.hasPrefix(leftSlash) {
            throw FolderSyncError.nestedFolders
        }

        let leftMap = scanRelativeFiles(under: leftStd, includeHidden: includeHidden)
        let rightMap = scanRelativeFiles(under: rightStd, includeHidden: includeHidden)
        let allRelKeys = Set(leftMap.keys).union(rightMap.keys).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }

        var actions: [FolderSyncItemPlan] = []
        let timestampTolerance: TimeInterval = 1.5

        for relKey in allRelKeys {
            let lFile = leftMap[relKey]
            let rFile = rightMap[relKey]

            switch (lFile, rFile) {
            case let (l?, nil):
                let dst = rightStd.appendingPathComponent(l.relativePath)
                actions.append(
                    FolderSyncItemPlan(
                        relativePath: l.relativePath,
                        sourceURL: l.url,
                        destinationURL: dst,
                        operation: .copyLeftToRight,
                        sizeBytes: l.size,
                        reason: tr("Finnes kun i venstre", "Only in left")
                    )
                )

            case let (nil, r?):
                switch mode {
                case .updateLeftToRight:
                    break
                case .twoWayNewest:
                    let dst = leftStd.appendingPathComponent(r.relativePath)
                    actions.append(
                        FolderSyncItemPlan(
                            relativePath: r.relativePath,
                            sourceURL: r.url,
                            destinationURL: dst,
                            operation: .copyRightToLeft,
                            sizeBytes: r.size,
                            reason: tr("Finnes kun i høyre", "Only in right")
                        )
                    )
                case .mirrorLeftToRight:
                    actions.append(
                        FolderSyncItemPlan(
                            relativePath: r.relativePath,
                            sourceURL: nil,
                            destinationURL: r.url,
                            operation: .trashInRight,
                            sizeBytes: r.size,
                            reason: tr("Fjernes i speilmodus (kun i høyre)", "Removed in mirror mode (only in right)")
                        )
                    )
                }

            case let (l?, r?):
                let delta = l.modified.timeIntervalSince(r.modified)
                if delta > timestampTolerance {
                    actions.append(
                        FolderSyncItemPlan(
                            relativePath: l.relativePath,
                            sourceURL: l.url,
                            destinationURL: r.url,
                            operation: .copyLeftToRight,
                            sizeBytes: l.size,
                            reason: tr("Nyere i venstre", "Newer in left")
                        )
                    )
                } else if delta < -timestampTolerance {
                    switch mode {
                    case .updateLeftToRight:
                        break
                    case .twoWayNewest:
                        actions.append(
                            FolderSyncItemPlan(
                                relativePath: r.relativePath,
                                sourceURL: r.url,
                                destinationURL: l.url,
                                operation: .copyRightToLeft,
                                sizeBytes: r.size,
                                reason: tr("Nyere i høyre", "Newer in right")
                            )
                        )
                    case .mirrorLeftToRight:
                        actions.append(
                            FolderSyncItemPlan(
                                relativePath: l.relativePath,
                                sourceURL: l.url,
                                destinationURL: r.url,
                                operation: .copyLeftToRight,
                                sizeBytes: l.size,
                                reason: tr("Avviker fra venstre (speil)", "Differs from left (mirror)")
                            )
                        )
                    }
                } else if l.size != r.size && mode == .mirrorLeftToRight {
                    actions.append(
                        FolderSyncItemPlan(
                            relativePath: l.relativePath,
                            sourceURL: l.url,
                            destinationURL: r.url,
                            operation: .copyLeftToRight,
                            sizeBytes: l.size,
                            reason: tr("Ulik størrelse (speil)", "Size differs (mirror)")
                        )
                    )
                }

            case (nil, nil):
                break
            }
        }

        return actions
    }

    @discardableResult
    static func execute(
        plan: [FolderSyncItemPlan],
        selectedIDs: Set<String>? = nil
    ) throws -> Int {
        let fm = FileManager.default
        var completed = 0

        for step in plan {
            if let selectedIDs, !selectedIDs.contains(step.id) {
                continue
            }

            switch step.operation {
            case .copyLeftToRight, .copyRightToLeft:
                guard let src = step.sourceURL else { continue }
                let dst = step.destinationURL
                let parentDir = dst.deletingLastPathComponent()
                if !fm.fileExists(atPath: parentDir.path) {
                    try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
                }
                if fm.fileExists(atPath: dst.path) {
                    // Move previous version to Trash when possible before copying updated file
                    if (try? fm.trashItem(at: dst, resultingItemURL: nil)) == nil {
                        try fm.removeItem(at: dst)
                    }
                }
                try fm.copyItem(at: src, to: dst)
                completed += 1

            case .trashInRight:
                if fm.fileExists(atPath: step.destinationURL.path) {
                    if (try? fm.trashItem(at: step.destinationURL, resultingItemURL: nil)) == nil {
                        try fm.removeItem(at: step.destinationURL)
                    }
                    completed += 1
                }
            }
        }

        return completed
    }

    private static func scanRelativeFiles(
        under root: URL,
        includeHidden: Bool
    ) -> [String: ScannedSyncFile] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .isDirectoryKey,
            .isPackageKey,
            .isSymbolicLinkKey,
            .isHiddenKey,
            .fileSizeKey,
            .contentModificationDateKey
        ]
        let keySet = Set(keys)

        var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if !includeHidden {
            options.insert(.skipsHiddenFiles)
        }

        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: options,
            errorHandler: { _, _ in true }
        ) else {
            return [:]
        }

        let rootPrefix = root.path.hasSuffix("/") ? root.path : (root.path + "/")
        var map: [String: ScannedSyncFile] = [:]

        while let url = enumerator.nextObject() as? URL {
            let name = url.lastPathComponent
            if !includeHidden && name.hasPrefix(".") {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            if name == ".DS_Store" || name == ".git" {
                enumerator.skipDescendants()
                continue
            }

            let std = url.standardizedFileURL
            guard std.path.hasPrefix(rootPrefix),
                  let rv = try? std.resourceValues(forKeys: keySet),
                  rv.isSymbolicLink != true,
                  rv.isRegularFile == true else {
                continue
            }

            let rel = String(std.path.dropFirst(rootPrefix.count))
            let normalizedKey = rel.lowercased()
            map[normalizedKey] = ScannedSyncFile(
                url: std,
                relativePath: rel,
                size: Int64(rv.fileSize ?? 0),
                modified: rv.contentModificationDate ?? .distantPast
            )
        }

        return map
    }
}

// MARK: - Feature 6: Quick File Actions (Image Convert/Resize, Merge PDF, Streaming SHA-256)

enum ImageOutputFormat: String, CaseIterable, Identifiable {
    case jpeg = "jpg"
    case png = "png"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .jpeg: return "JPEG (.jpg)"
        case .png: return "PNG (.png)"
        }
    }

    var utType: UTType {
        switch self {
        case .jpeg: return .jpeg
        case .png: return .png
        }
    }
}

enum ImageResizePreset: Int, CaseIterable, Identifiable {
    case original = 0
    case max2560 = 2560
    case max1920 = 1920
    case max1280 = 1280
    case max800 = 800

    var id: Int { rawValue }

    var maxPixelSize: Int? {
        rawValue == 0 ? nil : rawValue
    }

    var title: String {
        switch self {
        case .original: return tr("Original størrelse", "Original dimensions")
        case .max2560: return tr("Maks 2560 px (QHD)", "Max 2560 px (QHD)")
        case .max1920: return tr("Maks 1920 px (Full HD)", "Max 1920 px (Full HD)")
        case .max1280: return tr("Maks 1280 px (HD / Web)", "Max 1280 px (HD / Web)")
        case .max800: return tr("Maks 800 px (Kompakt)", "Max 800 px (Compact)")
        }
    }
}

enum QuickToolsError: LocalizedError {
    case noSupportedImages
    case imageDecodeFailed(String)
    case imageEncodeFailed(String)
    case noValidPDFInputs
    case pdfWriteFailed

    var errorDescription: String? {
        switch self {
        case .noSupportedImages:
            return tr("Ingen støttede bildefiler valgt.", "No supported image files selected.")
        case .imageDecodeFailed(let name):
            return tr("Kunne ikke lese bildefilen «\(name)».", "Could not decode image file '\(name)'.")
        case .imageEncodeFailed(let name):
            return tr("Kunne ikke lagre konvertert bilde for «\(name)».", "Could not encode converted image for '\(name)'.")
        case .noValidPDFInputs:
            return tr("Velg minst én PDF- eller bildefil for å slå sammen til PDF.", "Select at least one PDF or image file to merge into a PDF.")
        case .pdfWriteFailed:
            return tr("Kunne ikke skrive den sammenslåtte PDF-filen.", "Failed to write merged PDF file.")
        }
    }
}

enum QuickFileToolsService {
    static let supportedImageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "tiff", "tif", "bmp", "gif", "webp"
    ]

    static func isSupportedImage(_ url: URL) -> Bool {
        supportedImageExtensions.contains(url.pathExtension.lowercased())
    }

    static func isMergeableToPDF(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "pdf" || supportedImageExtensions.contains(ext)
    }

    /// Converts and optionally resizes images into `destinationDirectory` without overwriting existing files.
    static func convertImages(
        urls: [URL],
        inDirectory destinationDirectory: URL,
        format: ImageOutputFormat,
        jpegQuality: Double = 0.88,
        resizePreset: ImageResizePreset = .original
    ) throws -> [URL] {
        let imageURLs = urls.filter { isSupportedImage($0) }
        guard !imageURLs.isEmpty else {
            throw QuickToolsError.noSupportedImages
        }

        var createdURLs: [URL] = []

        for sourceURL in imageURLs {
            guard let src = CGImageSourceCreateWithURL(sourceURL as CFURL, nil) else {
                throw QuickToolsError.imageDecodeFailed(sourceURL.lastPathComponent)
            }

            let cgImage: CGImage
            if let maxPx = resizePreset.maxPixelSize {
                let thumbOpts: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPx
                ]
                guard let scaled = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOpts as CFDictionary) else {
                    throw QuickToolsError.imageDecodeFailed(sourceURL.lastPathComponent)
                }
                cgImage = scaled
            } else {
                let fullOpts: [CFString: Any] = [
                    kCGImageSourceShouldCacheImmediately: true
                ]
                // Apply EXIF orientation via thumbnail transform at native max dimension if present
                let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
                let pw = (props?[kCGImagePropertyPixelWidth] as? Int) ?? 0
                let ph = (props?[kCGImagePropertyPixelHeight] as? Int) ?? 0
                let nativeMax = max(pw, ph)
                if nativeMax > 0,
                   let oriented = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                       kCGImageSourceCreateThumbnailFromImageAlways: true,
                       kCGImageSourceCreateThumbnailWithTransform: true,
                       kCGImageSourceThumbnailMaxPixelSize: nativeMax
                   ] as CFDictionary) {
                    cgImage = oriented
                } else if let raw = CGImageSourceCreateImageAtIndex(src, 0, fullOpts as CFDictionary) {
                    cgImage = raw
                } else {
                    throw QuickToolsError.imageDecodeFailed(sourceURL.lastPathComponent)
                }
            }

            let stem = sourceURL.deletingPathExtension().lastPathComponent
            let suffix = resizePreset.maxPixelSize.map { "_\($0)px" } ?? ""
            let desiredName = "\(stem)\(suffix).\(format.rawValue)"
            let outURL = uniqueOutputURL(named: desiredName, in: destinationDirectory)

            guard let dest = CGImageDestinationCreateWithURL(
                outURL as CFURL,
                format.utType.identifier as CFString,
                1,
                nil
            ) else {
                throw QuickToolsError.imageEncodeFailed(sourceURL.lastPathComponent)
            }

            var encodeProps: [CFString: Any] = [:]
            if format == .jpeg {
                encodeProps[kCGImageDestinationLossyCompressionQuality] = min(1.0, max(0.1, jpegQuality))
            }
            CGImageDestinationAddImage(dest, cgImage, encodeProps as CFDictionary)

            guard CGImageDestinationFinalize(dest) else {
                throw QuickToolsError.imageEncodeFailed(sourceURL.lastPathComponent)
            }
            createdURLs.append(outURL)
        }

        return createdURLs
    }

    /// Merges multiple PDF files and/or images into a single combined PDF document.
    static func mergeIntoPDF(
        urls: [URL],
        inDirectory destinationDirectory: URL,
        preferredBaseName: String? = nil
    ) throws -> URL {
        let validInputs = urls.filter { isMergeableToPDF($0) }
        guard !validInputs.isEmpty else {
            throw QuickToolsError.noValidPDFInputs
        }

        let mergedDoc = PDFDocument()
        var insertIndex = 0

        for url in validInputs {
            let ext = url.pathExtension.lowercased()
            if ext == "pdf" {
                if let srcDoc = PDFDocument(url: url) {
                    for pageIdx in 0..<srcDoc.pageCount {
                        if let page = srcDoc.page(at: pageIdx) {
                            let detachedPage = (page.copy() as? PDFPage) ?? page
                            mergedDoc.insert(detachedPage, at: insertIndex)
                            insertIndex += 1
                        }
                    }
                }
            } else if let nsImage = NSImage(contentsOf: url),
                      let page = PDFPage(image: nsImage) {
                mergedDoc.insert(page, at: insertIndex)
                insertIndex += 1
            }
        }

        guard mergedDoc.pageCount > 0 else {
            throw QuickToolsError.noValidPDFInputs
        }

        let base = (preferredBaseName?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? tr("Sammenslått", "Merged")
        let cleanName = base.lowercased().hasSuffix(".pdf") ? base : "\(base).pdf"
        let outURL = uniqueOutputURL(named: cleanName, in: destinationDirectory)

        guard mergedDoc.write(to: outURL) else {
            throw QuickToolsError.pdfWriteFailed
        }
        return outURL
    }

    /// Computes a streaming lowercase hex SHA-256 digest without loading the entire file into memory.
    static func computeSHA256(for fileURL: URL) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            try computeSHA256Sync(for: fileURL)
        }.value
    }

    static func computeSHA256Sync(for fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var hasher = SHA256()
        let chunkSize = 262_144 // 256 KB chunks

        while true {
            if Task.isCancelled {
                throw CancellationError()
            }
            guard let data = try handle.read(upToCount: chunkSize), !data.isEmpty else {
                break
            }
            hasher.update(data: data)
        }

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func uniqueOutputURL(named desiredFileName: String, in directory: URL) -> URL {
        let fm = FileManager.default
        let candidate = directory.appendingPathComponent(desiredFileName)
        if !fm.fileExists(atPath: candidate.path) {
            return candidate
        }

        let ext = (desiredFileName as NSString).pathExtension
        let stem = ext.isEmpty
            ? desiredFileName
            : String(desiredFileName.dropLast(ext.count + 1))

        var counter = 2
        while true {
            let nextName = ext.isEmpty ? "\(stem) (\(counter))" : "\(stem) (\(counter)).\(ext)"
            let nextURL = directory.appendingPathComponent(nextName)
            if !fm.fileExists(atPath: nextURL.path) {
                return nextURL
            }
            counter += 1
        }
    }
}
