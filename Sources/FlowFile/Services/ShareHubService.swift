import AppKit
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct SharePreparationOptions: Equatable {
    var packageAsCleanZip: Bool = false
    var archiveBaseName: String = "Delte-filer"
    var convertHeicAndStripGPS: Bool = false
    var includeHiddenFilesInFolders: Bool = false
}

struct SharePreparedPayload: Equatable {
    let urls: [URL]
    let stagingRoot: URL?
    let totalBytes: Int64
    let cleanedImagesCount: Int
    let uncleanedFiles: [String]
    let excludedHiddenCount: Int
    let skippedSymlinksCount: Int
    let isEncrypted: Bool

    var hasPrivacyWarnings: Bool {
        !uncleanedFiles.isEmpty
    }
}

enum ShareHubError: LocalizedError {
    case emptySelection
    case zipCreationFailed
    case serviceUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .emptySelection:
            return tr("Ingen filer er valgt for deling.", "No files are selected for sharing.")
        case .zipCreationFailed:
            return tr("Kunne ikke opprette komprimert delingsfil.", "Could not create compressed share archive.")
        case .serviceUnavailable(let name):
            return tr(
                "\(name) er ikke tilgjengelig akkurat nå. Sjekk at tjenesten er aktivert på Macen.",
                "\(name) is not available right now. Check that the service is enabled on your Mac."
            )
        }
    }
}

/// Retains itself for the lifetime of an `NSSharingService` handoff so we receive completion/failure callbacks.
@MainActor
private final class ShareServiceDelegateBridge: NSObject, NSSharingServiceDelegate {
    private static var activeBridges: [ObjectIdentifier: ShareServiceDelegateBridge] = [:]
    private let onComplete: (Result<Void, Error>) -> Void

    init(onComplete: @escaping (Result<Void, Error>) -> Void) {
        self.onComplete = onComplete
        super.init()
        Self.activeBridges[ObjectIdentifier(self)] = self
    }

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        let cb = onComplete
        Self.activeBridges.removeValue(forKey: ObjectIdentifier(self))
        cb(.success(()))
    }

    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        let cb = onComplete
        Self.activeBridges.removeValue(forKey: ObjectIdentifier(self))
        cb(.failure(error))
    }
}

enum ShareHubService {
    private static let stagingPrefix = "FlowFileShare_"

    /// Persistent per-user cache directory (survives until 24h grace period expires so AirDrop/Mail/Outlook/pasteboard
    /// never lose staged files while the recipient or mail draft is still reading them).
    static var stagingBaseDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return caches
            .appendingPathComponent("com.flowfile.app", isDirectory: true)
            .appendingPathComponent("ShareStaging", isDirectory: true)
    }

    static func containsImages(_ items: [FileItem]) -> Bool {
        let imageExts: Set<String> = ["heic", "heif", "jpg", "jpeg", "png", "tiff", "tif", "webp", "dng", "cr2", "nef", "arw"]
        return items.contains { imageExts.contains($0.fileExtension.lowercased()) || $0.isNavigableFolder }
    }

    static func containsHeicImages(_ items: [FileItem]) -> Bool {
        let heicExts: Set<String> = ["heic", "heif"]
        return items.contains { heicExts.contains($0.fileExtension.lowercased()) }
    }

    static func containsCloudOnlyItems(_ items: [FileItem]) -> Bool {
        items.contains { $0.cloudState == .cloudOnly || CloudStorageService.isDatalessPlaceholder($0.navigationTargetURL) }
    }

    static func requiresZipForSingleFileTransport(_ items: [FileItem], options: SharePreparationOptions) -> Bool {
        options.packageAsCleanZip
            || items.count > 1
            || items.contains(where: { $0.isNavigableFolder || $0.isDirectory || $0.isPackage })
    }

    static func installedOutlookURL() -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.Outlook")
    }

    static func defaultEmailAppBundleID() -> String? {
        guard let mailto = URL(string: "mailto:"),
              let appURL = NSWorkspace.shared.urlForApplication(toOpen: mailto) else {
            return nil
        }
        return Bundle(url: appURL)?.bundleIdentifier
    }

    static func defaultEmailAppName() -> String {
        guard let mailto = URL(string: "mailto:"),
              let appURL = NSWorkspace.shared.urlForApplication(toOpen: mailto) else {
            return tr("E-post", "Mail")
        }
        return appURL.deletingPathExtension().lastPathComponent
    }

    static func isDefaultEmailAppOutlook() -> Bool {
        defaultEmailAppBundleID()?.lowercased() == "com.microsoft.outlook"
    }

    static func isLikelyBrowserBundleID(_ bundleID: String?) -> Bool {
        guard let id = bundleID?.lowercased() else { return false }
        let browsers = [
            "com.apple.safari", "com.google.chrome", "org.mozilla.firefox",
            "com.microsoft.edgemac", "com.brave.browser", "company.thebrowser.browser",
            "com.operasoftware.opera", "com.vivaldi.vivaldi"
        ]
        return browsers.contains(id)
    }

    /// Returns the real macOS system icon for AirDrop, Messages, Mail, etc.
    @MainActor
    static func systemServiceIcon(named name: NSSharingService.Name) -> NSImage? {
        NSSharingService(named: name)?.image
    }

    @MainActor
    static func openLocalNetworkPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Removes a specific temporary share staging root (or the `FlowFileShare_*` ancestor containing `fileURL`).
    static func cleanupStagingRoot(for fileOrDirURL: URL) {
        let fm = FileManager.default
        let allowedRoots = [
            stagingBaseDirectory.standardizedFileURL.path,
            URL(fileURLWithPath: NSTemporaryDirectory()).standardizedFileURL.path
        ]
        var current = fileOrDirURL.standardizedFileURL
        while let matchingRoot = allowedRoots.first(where: { current.path.hasPrefix($0) && current.path != $0 }) {
            if current.lastPathComponent.hasPrefix(stagingPrefix) {
                try? fm.removeItem(at: current)
                return
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path || parent.path == matchingRoot { break }
            current = parent
        }
    }

    /// Removes expired `FlowFileShare_*` directories (default 24h grace period so active handoffs never break).
    static func cleanupStaleStagingDirectories(maxAgeSeconds: TimeInterval = 86_400) {
        let fm = FileManager.default
        let roots = [
            stagingBaseDirectory,
            URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        ]
        let now = Date()
        for root in roots {
            guard let children = try? fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            for child in children where child.lastPathComponent.hasPrefix(stagingPrefix) {
                if maxAgeSeconds <= 0 {
                    try? fm.removeItem(at: child)
                    continue
                }
                let rv = try? child.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
                let timestamp = rv?.contentModificationDate ?? rv?.creationDate ?? .distantPast
                if now.timeIntervalSince(timestamp) >= maxAgeSeconds {
                    try? fm.removeItem(at: child)
                }
            }
        }
    }

    // MARK: - Async & Sync Preparation

    static func preparePayloadAsync(
        _ items: [FileItem],
        options: SharePreparationOptions
    ) async throws -> SharePreparedPayload {
        try await Task.detached(priority: .userInitiated) {
            try preparePayload(items, options: options)
        }.value
    }

    /// Backwards-compatible wrapper returning prepared URLs directly.
    static func prepareItems(
        _ items: [FileItem],
        options: SharePreparationOptions
    ) throws -> [URL] {
        try preparePayload(items, options: options).urls
    }

    /// Prepares files according to smart options (HEIC→JPG, lossless GPS/EXIF strip, Windows-clean UTF-8 ZIP).
    static func preparePayload(
        _ items: [FileItem],
        options: SharePreparationOptions
    ) throws -> SharePreparedPayload {
        guard !items.isEmpty else { throw ShareHubError.emptySelection }
        cleanupStaleStagingDirectories()

        let fm = FileManager.default
        try fm.createDirectory(at: stagingBaseDirectory, withIntermediateDirectories: true)

        // When no zip AND no image/privacy transformation is requested, share original URLs directly (zero extra disk copy!)
        if !options.packageAsCleanZip && !options.convertHeicAndStripGPS {
            let directURLs = items.map(\.navigationTargetURL)
            let bytes = computeTotalBytes(for: directURLs)
            return SharePreparedPayload(
                urls: directURLs,
                stagingRoot: nil,
                totalBytes: bytes,
                cleanedImagesCount: 0,
                uncleanedFiles: [],
                excludedHiddenCount: 0,
                skippedSymlinksCount: 0,
                isEncrypted: false
            )
        }

        let sessionRoot = stagingBaseDirectory
            .appendingPathComponent("\(stagingPrefix)\(UUID().uuidString.prefix(8))", isDirectory: true)
        let stagingDir = sessionRoot.appendingPathComponent("staged", isDirectory: true)
        try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)

        var stagedURLs: [URL] = []
        var cleanedImages = 0
        var uncleanedFiles: [String] = []
        var excludedHidden = 0
        var skippedSymlinks = 0

        do {
            for item in items {
                let sourceURL = item.navigationTargetURL
                let nfcFileName = sourceURL.lastPathComponent.precomposedStringWithCanonicalMapping
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: sourceURL.path, isDirectory: &isDir) else { continue }

                if isDir.boolValue && !item.isPackage {
                    let dstFolder = uniqueNFCURL(named: nfcFileName, in: stagingDir)
                    try stageFolderRecursively(
                        from: sourceURL,
                        to: dstFolder,
                        options: options,
                        cleanedImages: &cleanedImages,
                        uncleanedFiles: &uncleanedFiles,
                        excludedHidden: &excludedHidden,
                        skippedSymlinks: &skippedSymlinks
                    )
                    stagedURLs.append(dstFolder)
                } else {
                    let staged = try stageSingleFile(
                        from: sourceURL,
                        into: stagingDir,
                        convertAndStrip: options.convertHeicAndStripGPS && !item.isPackage,
                        cleanedImages: &cleanedImages,
                        uncleanedFiles: &uncleanedFiles
                    )
                    stagedURLs.append(staged)
                }
            }
        } catch {
            try? fm.removeItem(at: sessionRoot)
            throw error
        }

        guard options.packageAsCleanZip else {
            let bytes = computeTotalBytes(for: stagedURLs)
            return SharePreparedPayload(
                urls: stagedURLs,
                stagingRoot: sessionRoot,
                totalBytes: bytes,
                cleanedImagesCount: cleanedImages,
                uncleanedFiles: uncleanedFiles,
                excludedHiddenCount: excludedHidden,
                skippedSymlinksCount: skippedSymlinks,
                isEncrypted: false
            )
        }

        let cleanBase = sanitizeArchiveBaseName(options.archiveBaseName)
        let finalZipName = cleanBase.lowercased().hasSuffix(".zip") ? cleanBase : "\(cleanBase).zip"
        let zipOutputURL = sessionRoot.appendingPathComponent(finalZipName)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        proc.currentDirectoryURL = stagingDir

        // -X strips macOS Finder/UID attributes; -y stores symlinks as links; -x removes macOS junk & hidden dotfiles
        var args: [String] = ["-r", "-q", "-X", "-y", zipOutputURL.path]
        for staged in stagedURLs {
            let name = staged.lastPathComponent
            args.append(name.hasPrefix("-") ? "./\(name)" : name)
        }
        var exclusions = ["*.DS_Store", "*__MACOSX*", "*/._*", "._*"]
        if !options.includeHiddenFilesInFolders {
            exclusions.append("*/.*")
        }
        args.append(contentsOf: ["-x"] + exclusions)
        proc.arguments = args

        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            try? fm.removeItem(at: sessionRoot)
            throw error
        }

        guard proc.terminationStatus == 0, fm.fileExists(atPath: zipOutputURL.path) else {
            try? fm.removeItem(at: sessionRoot)
            throw ShareHubError.zipCreationFailed
        }

        // Patch ZIP general-purpose bit 11 (UTF-8 flag) so Norwegian æ/ø/å filenames decode cleanly on Windows!
        _ = try? patchZipUTF8Flags(at: zipOutputURL)

        try? fm.removeItem(at: stagingDir)
        let zipSize = computeTotalBytes(for: [zipOutputURL])
        return SharePreparedPayload(
            urls: [zipOutputURL],
            stagingRoot: sessionRoot,
            totalBytes: zipSize,
            cleanedImagesCount: cleanedImages,
            uncleanedFiles: uncleanedFiles,
            excludedHiddenCount: excludedHidden,
            skippedSymlinksCount: skippedSymlinks,
            isEncrypted: false
        )
    }

    private static func stageFolderRecursively(
        from sourceFolder: URL,
        to destFolder: URL,
        options: SharePreparationOptions,
        cleanedImages: inout Int,
        uncleanedFiles: inout [String],
        excludedHidden: inout Int,
        skippedSymlinks: inout Int
    ) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destFolder, withIntermediateDirectories: true)

        let children = try fm.contentsOfDirectory(
            at: sourceFolder,
            includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isHiddenKey],
            options: []
        )

        for child in children {
            let name = child.lastPathComponent
            // Always exclude macOS Finder junk
            if name == ".DS_Store" || name == "__MACOSX" || name.hasPrefix("._") || name == "Icon\r" {
                excludedHidden += 1
                continue
            }
            let rv = try? child.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isHiddenKey])
            let isHidden = name.hasPrefix(".") || (rv?.isHidden == true)
            if isHidden && !options.includeHiddenFilesInFolders {
                excludedHidden += 1
                continue
            }
            // Never follow symlinks inside shared folders (prevents leaking ~/.ssh or files outside the selection)
            if rv?.isSymbolicLink == true {
                skippedSymlinks += 1
                continue
            }

            let nfcName = name.precomposedStringWithCanonicalMapping
            if rv?.isDirectory == true && rv?.isPackage != true {
                let subDst = destFolder.appendingPathComponent(nfcName, isDirectory: true)
                try stageFolderRecursively(
                    from: child,
                    to: subDst,
                    options: options,
                    cleanedImages: &cleanedImages,
                    uncleanedFiles: &uncleanedFiles,
                    excludedHidden: &excludedHidden,
                    skippedSymlinks: &skippedSymlinks
                )
            } else {
                _ = try stageSingleFile(
                    from: child,
                    into: destFolder,
                    convertAndStrip: options.convertHeicAndStripGPS && rv?.isPackage != true,
                    cleanedImages: &cleanedImages,
                    uncleanedFiles: &uncleanedFiles
                )
            }
        }
    }

    private static func stageSingleFile(
        from sourceURL: URL,
        into destDir: URL,
        convertAndStrip: Bool,
        cleanedImages: inout Int,
        uncleanedFiles: inout [String]
    ) throws -> URL {
        let fm = FileManager.default
        let ext = sourceURL.pathExtension.lowercased()
        let nfcName = sourceURL.lastPathComponent.precomposedStringWithCanonicalMapping

        if convertAndStrip {
            let cleanableImages: Set<String> = ["heic", "heif", "jpg", "jpeg", "png", "tiff", "tif"]
            let uncleanedMetadataTypes: Set<String> = [
                "webp", "gif", "avif", "dng", "cr2", "nef", "arw", "rw2",
                "mov", "mp4", "m4v", "avi", "mkv", "pdf", "docx", "xlsx", "pptx"
            ]
            if cleanableImages.contains(ext) {
                if let sanitized = sanitizeAndConvertImageIfApplicable(sourceURL: sourceURL, into: destDir) {
                    cleanedImages += 1
                    return sanitized
                } else {
                    uncleanedFiles.append(nfcName)
                }
            } else if uncleanedMetadataTypes.contains(ext) {
                uncleanedFiles.append(nfcName)
            }
        }

        let dst = uniqueNFCURL(named: nfcName, in: destDir)
        try fm.copyItem(at: sourceURL, to: dst)
        return dst
    }

    private static func uniqueNFCURL(named nfcName: String, in directory: URL) -> URL {
        let candidate = directory.appendingPathComponent(nfcName)
        return FileSystemService.uniqueDestinationURL(for: candidate, in: directory)
    }

    static func sanitizeArchiveBaseName(_ raw: String) -> String {
        let cleaned = raw
            .precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }
        var str = String(String.UnicodeScalarView(cleaned)).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if str.isEmpty {
            str = tr("Delte-filer", "Shared-files")
        }
        if str.utf8.count > 120 {
            str = String(str.prefix(80))
        }
        return str
    }

    private static func computeTotalBytes(for urls: [URL]) -> Int64 {
        let fm = FileManager.default
        var total: Int64 = 0
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if !isDir.boolValue {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                total += Int64(size)
            } else if let en = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) {
                while let child = en.nextObject() as? URL {
                    let rv = try? child.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                    if rv?.isRegularFile == true {
                        total += Int64(rv?.fileSize ?? 0)
                    }
                }
            }
        }
        return total
    }

    // MARK: - ZIP UTF-8 Flag Patch (Bit 11 / EFS for Windows Compatibility)

    /// Sets ZIP General Purpose Bit 11 (`0x0800`, Language Encoding Flag) on every entry whose filename contains
    /// non-ASCII UTF-8 bytes, in both Local File Headers (`0x04034b50`) and Central Directory Headers (`0x02014b50`).
    /// This guarantees Norwegian `æ/ø/å` filenames display properly in Windows and Android archive tools.
    @discardableResult
    static func patchZipUTF8Flags(at zipURL: URL) throws -> Int {
        var data = try Data(contentsOf: zipURL)
        guard data.count >= 22 else { return 0 }

        func readUInt16(_ offset: Int) -> UInt16 {
            UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
        }
        func readUInt32(_ offset: Int) -> UInt32 {
            UInt32(data[offset])
                | (UInt32(data[offset + 1]) << 8)
                | (UInt32(data[offset + 2]) << 16)
                | (UInt32(data[offset + 3]) << 24)
        }
        func writeUInt16(_ value: UInt16, at offset: Int) {
            data[offset] = UInt8(value & 0xFF)
            data[offset + 1] = UInt8((value >> 8) & 0xFF)
        }

        // Locate End of Central Directory record (0x06054b50) scanning backwards from end (max comment = 65535)
        let minOffset = max(0, data.count - 65_557)
        var eocdOffset: Int? = nil
        var pos = data.count - 22
        while pos >= minOffset {
            if readUInt32(pos) == 0x06054B50 {
                eocdOffset = pos
                break
            }
            pos -= 1
        }
        guard let eocd = eocdOffset else { return 0 }

        let totalEntries = Int(readUInt16(eocd + 10))
        let cdOffset = Int(readUInt32(eocd + 16))
        guard cdOffset >= 0, cdOffset < data.count else { return 0 }

        var patchedCount = 0
        var cursor = cdOffset

        for _ in 0..<totalEntries {
            guard cursor + 46 <= data.count, readUInt32(cursor) == 0x02014B50 else { break }
            let nameLen = Int(readUInt16(cursor + 28))
            let extraLen = Int(readUInt16(cursor + 30))
            let commentLen = Int(readUInt16(cursor + 32))
            let localHeaderOffset = Int(readUInt32(cursor + 42))
            guard cursor + 46 + nameLen <= data.count else { break }

            let nameSlice = data[(cursor + 46)..<(cursor + 46 + nameLen)]
            let hasNonASCII = nameSlice.contains { $0 >= 0x80 }

            if hasNonASCII {
                let cdFlags = readUInt16(cursor + 8)
                if (cdFlags & 0x0800) == 0 {
                    writeUInt16(cdFlags | 0x0800, at: cursor + 8)
                    patchedCount += 1
                }
                if localHeaderOffset >= 0,
                   localHeaderOffset + 30 <= data.count,
                   readUInt32(localHeaderOffset) == 0x04034B50 {
                    let lhFlags = readUInt16(localHeaderOffset + 6)
                    if (lhFlags & 0x0800) == 0 {
                        writeUInt16(lhFlags | 0x0800, at: localHeaderOffset + 6)
                    }
                }
            }

            cursor += 46 + nameLen + extraLen + commentLen
        }

        if patchedCount > 0 {
            try data.write(to: zipURL, options: .atomic)
        }
        return patchedCount
    }

    // MARK: - Delivery Channels

    @MainActor
    static func presentSystemSharePicker(items: [URL], relativeTo anchorView: NSView) {
        let picker = NSSharingServicePicker(items: items)
        picker.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .minY)
    }

    @MainActor
    static func shareViaDefaultEmail(
        _ urls: [URL],
        completion: ((Result<Void, Error>) -> Void)? = nil
    ) -> Bool {
        if let service = NSSharingService(named: .composeEmail), service.canPerform(withItems: urls) {
            if let completion {
                let bridge = ShareServiceDelegateBridge(onComplete: completion)
                service.delegate = bridge
            }
            service.perform(withItems: urls)
            return true
        }
        // Never fall back to opening files in a web browser (e.g. Chrome set as mailto handler)
        if !isLikelyBrowserBundleID(defaultEmailAppBundleID()),
           let mailto = URL(string: "mailto:"),
           let mailAppURL = NSWorkspace.shared.urlForApplication(toOpen: mailto) {
            NSWorkspace.shared.open(urls, withApplicationAt: mailAppURL, configuration: NSWorkspace.OpenConfiguration())
            completion?(.success(()))
            return true
        }
        completion?(.failure(ShareHubError.serviceUnavailable(defaultEmailAppName())))
        return false
    }

    /// File types that Outlook imports (e.g. calendar invite or contact) instead of attaching unless zipped first.
    static func containsOutlookImportableTypes(_ urls: [URL]) -> Bool {
        let importExts: Set<String> = ["eml", "msg", "ics", "vcf", "olm"]
        return urls.contains { importExts.contains($0.pathExtension.lowercased()) }
    }

    @MainActor
    static func shareViaOutlook(
        _ urls: [URL],
        completion: ((Result<Void, Error>) -> Void)? = nil
    ) -> Bool {
        if isDefaultEmailAppOutlook() {
            return shareViaDefaultEmail(urls, completion: completion)
        }
        guard let outlookURL = installedOutlookURL() else {
            return shareViaDefaultEmail(urls, completion: completion)
        }
        NSWorkspace.shared.open(urls, withApplicationAt: outlookURL, configuration: NSWorkspace.OpenConfiguration())
        completion?(.success(()))
        return true
    }

    @MainActor
    static func shareViaAirDrop(
        _ urls: [URL],
        completion: ((Result<Void, Error>) -> Void)? = nil
    ) -> Bool {
        guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) else {
            completion?(.failure(ShareHubError.serviceUnavailable("AirDrop")))
            return false
        }
        if let completion {
            let bridge = ShareServiceDelegateBridge(onComplete: completion)
            service.delegate = bridge
        }
        service.perform(withItems: urls)
        return true
    }

    @MainActor
    static func shareViaMessages(
        _ urls: [URL],
        completion: ((Result<Void, Error>) -> Void)? = nil
    ) -> Bool {
        guard let service = NSSharingService(named: .composeMessage), service.canPerform(withItems: urls) else {
            completion?(.failure(ShareHubError.serviceUnavailable(tr("Meldinger", "Messages"))))
            return false
        }
        if let completion {
            let bridge = ShareServiceDelegateBridge(onComplete: completion)
            service.delegate = bridge
        }
        service.perform(withItems: urls)
        return true
    }

    static func copyPreparedFilesForChatApps(_ urls: [URL]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls as [NSURL])
    }

    /// Uploads a copy into an isolated, per-share subfolder inside the account's writable root
    /// (`FlowFile-delinger/YYYY-MM-DD <navn>/`) so a previously shared folder can never accidentally expose new files.
    static func copyIntoCloudSharedFolder(
        _ urls: [URL],
        account: CloudAccountItem,
        shareLabel: String? = nil
    ) throws -> (folder: URL, copied: [URL]) {
        let fm = FileManager.default
        let uploadRoot = CloudStorageService.writableUploadRootURL(for: account)
        let containerDir = uploadRoot.appendingPathComponent(
            tr("FlowFile-delinger", "FlowFile Shares"),
            isDirectory: true
        )
        try fm.createDirectory(at: containerDir, withIntermediateDirectories: true)

        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        let dateStamp = df.string(from: Date())
        let rawLabel = (shareLabel ?? urls.first?.deletingPathExtension().lastPathComponent ?? tr("Deling", "Share"))
        let safeLabel = sanitizeArchiveBaseName(rawLabel)
        let desiredSubfolder = containerDir.appendingPathComponent("\(dateStamp) \(safeLabel)", isDirectory: true)
        let isolatedFolder = FileSystemService.uniqueDestinationURL(for: desiredSubfolder, in: containerDir)
        try fm.createDirectory(at: isolatedFolder, withIntermediateDirectories: true)

        let copied = try FileSystemService.copyItems(urls, toDirectory: isolatedFolder)
        return (isolatedFolder, copied)
    }

    static func generateQRCodeImage(for string: String) -> NSImage? {
        guard let data = string.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else {
            return nil
        }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let outputImage = filter.outputImage else { return nil }

        let scaled = outputImage.transformed(by: CGAffineTransform(scaleX: 9, y: 9))
        let rep = NSCIImageRep(ciImage: scaled)
        let nsImage = NSImage(size: rep.size)
        nsImage.addRepresentation(rep)
        return nsImage
    }

    // MARK: - Image Conversion & Lossless EXIF/GPS Sanitizer

    static func sanitizeAndConvertImageIfApplicable(sourceURL: URL, into directory: URL) -> URL? {
        let ext = sourceURL.pathExtension.lowercased()
        let supported: Set<String> = ["heic", "heif", "jpg", "jpeg", "png", "tiff", "tif"]
        guard supported.contains(ext) else { return nil }

        guard let imgSource = CGImageSourceCreateWithURL(sourceURL as CFURL, nil) else {
            return nil
        }

        let stem = sourceURL.deletingPathExtension().lastPathComponent.precomposedStringWithCanonicalMapping

        // 1. Lossless metadata stripping for JPEG (preserves original compressed pixels with zero quality loss!)
        if ext == "jpg" || ext == "jpeg" {
            let outURL = uniqueNFCURL(named: "\(stem).jpg", in: directory)
            if let dest = CGImageDestinationCreateWithURL(outURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil) {
                let stripProps: [CFString: Any] = [
                    kCGImageDestinationMergeMetadata: true,
                    kCGImagePropertyGPSDictionary: kCFNull as Any,
                    kCGImagePropertyExifDictionary: kCFNull as Any,
                    kCGImagePropertyExifAuxDictionary: kCFNull as Any,
                    kCGImagePropertyIPTCDictionary: kCFNull as Any,
                    kCGImagePropertyTIFFDictionary: kCFNull as Any,
                    kCGImagePropertyMakerAppleDictionary: kCFNull as Any
                ]
                var cfErr: Unmanaged<CFError>?
                if CGImageDestinationCopyImageSource(dest, imgSource, stripProps as CFDictionary, &cfErr) {
                    return outURL
                }
                try? FileManager.default.removeItem(at: outURL)
            }
        }

        // 2. HEIC/HEIF/TIFF/PNG (or JPEG fallback): bake orientation into pixels via transform so PNG/JPG never
        // appear rotated in Windows or web viewers, and write zero EXIF/GPS/IPTC/TIFF metadata!
        let props = CGImageSourceCopyPropertiesAtIndex(imgSource, 0, nil) as? [CFString: Any]
        let pixelW = (props?[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let pixelH = (props?[kCGImagePropertyPixelHeight] as? Int) ?? 0
        let maxDim = max(pixelW, pixelH)

        let cgImage: CGImage
        if maxDim > 0,
           let oriented = CGImageSourceCreateThumbnailAtIndex(imgSource, 0, [
               kCGImageSourceCreateThumbnailFromImageAlways: true,
               kCGImageSourceCreateThumbnailWithTransform: true,
               kCGImageSourceThumbnailMaxPixelSize: maxDim
           ] as CFDictionary) {
            cgImage = oriented
        } else if let raw = CGImageSourceCreateImageAtIndex(imgSource, 0, nil) {
            cgImage = raw
        } else {
            return nil
        }

        let outputIsPNG = (ext == "png")
        let outExt = outputIsPNG ? "png" : "jpg"
        let outType = outputIsPNG ? UTType.png.identifier : UTType.jpeg.identifier
        let outURL = uniqueNFCURL(named: "\(stem).\(outExt)", in: directory)

        guard let dest = CGImageDestinationCreateWithURL(outURL as CFURL, outType as CFString, 1, nil) else {
            return nil
        }

        var cleanProps: [CFString: Any] = [:]
        if !outputIsPNG {
            cleanProps[kCGImageDestinationLossyCompressionQuality] = 0.92
        }
        CGImageDestinationAddImage(dest, cgImage, cleanProps as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            try? FileManager.default.removeItem(at: outURL)
            return nil
        }
        return outURL
    }
}
