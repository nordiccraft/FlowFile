import AppKit
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct SharePreparationOptions {
    var packageAsCleanZip: Bool = false
    var archiveBaseName: String = "Delte-filer"
    var usePassword: Bool = false
    var password: String = ""
    var convertHeicAndStripGPS: Bool = false
}

enum ShareHubError: LocalizedError {
    case emptySelection
    case missingPassword
    case zipCreationFailed

    var errorDescription: String? {
        switch self {
        case .emptySelection:
            return "Ingen filer er valgt for deling."
        case .missingPassword:
            return "Skriv inn et passord for den krypterte ZIP-filen, eller slå av passordbeskyttelse."
        case .zipCreationFailed:
            return "Kunne ikke opprette komprimert delingsfil."
        }
    }
}

enum ShareHubService {
    static func containsImages(_ items: [FileItem]) -> Bool {
        let imageExts: Set<String> = ["heic", "heif", "jpg", "jpeg", "png", "tiff", "tif", "webp"]
        return items.contains { imageExts.contains($0.fileExtension.lowercased()) }
    }

    static func containsHeicImages(_ items: [FileItem]) -> Bool {
        let heicExts: Set<String> = ["heic", "heif"]
        return items.contains { heicExts.contains($0.fileExtension.lowercased()) }
    }

    static func requiresZipForSingleFileTransport(_ items: [FileItem], options: SharePreparationOptions) -> Bool {
        options.packageAsCleanZip
            || options.usePassword
            || items.count > 1
            || items.contains(where: \.isNavigableFolder)
    }

    static func installedOutlookURL() -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.Outlook")
    }

    static func defaultEmailAppName() -> String {
        guard let mailto = URL(string: "mailto:"),
              let appURL = NSWorkspace.shared.urlForApplication(toOpen: mailto) else {
            return "E-post"
        }
        return appURL.deletingPathExtension().lastPathComponent
    }

    /// Prepares files according to user's smart options (HEIC->JPG, strip GPS/EXIF, Windows-clean ZIP, optional password)
    static func prepareItems(
        _ items: [FileItem],
        options: SharePreparationOptions
    ) throws -> [URL] {
        guard !items.isEmpty else { throw ShareHubError.emptySelection }
        if options.usePassword && options.password.trimmingCharacters(in: .whitespaces).isEmpty {
            throw ShareHubError.missingPassword
        }

        let fm = FileManager.default
        let sessionRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FlowFileShare_\(UUID().uuidString.prefix(8))", isDirectory: true)
        let stagingDir = sessionRoot.appendingPathComponent("staged", isDirectory: true)
        try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)

        var stagedURLs: [URL] = []
        for item in items {
            let sourceURL = item.navigationTargetURL
            if options.convertHeicAndStripGPS && !item.isNavigableFolder,
               let sanitized = sanitizeAndConvertImageIfApplicable(sourceURL: sourceURL, into: stagingDir) {
                stagedURLs.append(sanitized)
            } else {
                let dst = FileSystemService.uniqueDestinationURL(for: sourceURL, in: stagingDir)
                try fm.copyItem(at: sourceURL, to: dst)
                stagedURLs.append(dst)
            }
        }

        let shouldZip = options.packageAsCleanZip || options.usePassword
        guard shouldZip else {
            return stagedURLs
        }

        let cleanBase = options.archiveBaseName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
        let finalZipName = cleanBase.lowercased().hasSuffix(".zip")
            ? cleanBase
            : "\(cleanBase.isEmpty ? "Delte-filer" : cleanBase).zip"
        let zipOutputURL = sessionRoot.appendingPathComponent(finalZipName)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        proc.currentDirectoryURL = stagingDir

        // -X strips extra macOS Finder/UID attributes; -x excludes .DS_Store & __MACOSX for 100% clean Windows zips!
        var args: [String] = ["-r", "-q", "-X"]
        if options.usePassword {
            args.append(contentsOf: ["-P", options.password])
        }
        args.append(zipOutputURL.path)
        for staged in stagedURLs {
            args.append(staged.lastPathComponent)
        }
        args.append(contentsOf: ["-x", "*.DS_Store", "*__MACOSX*", "*/._*", "._*"])
        proc.arguments = args

        try proc.run()
        proc.waitUntilExit()

        guard proc.terminationStatus == 0, fm.fileExists(atPath: zipOutputURL.path) else {
            throw ShareHubError.zipCreationFailed
        }

        // Remove uncompressed staging copies once zip is ready
        try? fm.removeItem(at: stagingDir)
        return [zipOutputURL]
    }

    // MARK: - Delivery Channels

    @MainActor
    static func shareViaDefaultEmail(_ urls: [URL]) {
        if let service = NSSharingService(named: .composeEmail), service.canPerform(withItems: urls) {
            service.perform(withItems: urls)
            return
        }
        if let mailto = URL(string: "mailto:"),
           let mailAppURL = NSWorkspace.shared.urlForApplication(toOpen: mailto) {
            NSWorkspace.shared.open(urls, withApplicationAt: mailAppURL, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    @MainActor
    static func shareViaOutlook(_ urls: [URL]) {
        guard let outlookURL = installedOutlookURL() else {
            shareViaDefaultEmail(urls)
            return
        }
        NSWorkspace.shared.open(urls, withApplicationAt: outlookURL, configuration: NSWorkspace.OpenConfiguration())
    }

    @MainActor
    static func shareViaAirDrop(_ urls: [URL]) {
        if let service = NSSharingService(named: .sendViaAirDrop) {
            service.perform(withItems: urls)
        }
    }

    @MainActor
    static func shareViaMessages(_ urls: [URL]) {
        if let service = NSSharingService(named: .composeMessage) {
            service.perform(withItems: urls)
        }
    }

    @MainActor
    static func shareViaCloudService(_ urls: [URL]) -> Bool {
        if let service = NSSharingService(named: .cloudSharing), service.canPerform(withItems: urls) {
            service.perform(withItems: urls)
            return true
        }
        return false
    }

    static func copyPreparedFilesForChatApps(_ urls: [URL]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls as [NSURL])
    }

    static func copyIntoCloudSharedFolder(_ urls: [URL], account: CloudAccountItem) throws -> (folder: URL, copied: [URL]) {
        let sharedDir = account.rootURL.appendingPathComponent("Delt fra FlowFile", isDirectory: true)
        try FileManager.default.createDirectory(at: sharedDir, withIntermediateDirectories: true)
        let copied = try FileSystemService.copyItems(urls, toDirectory: sharedDir)
        return (sharedDir, copied)
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

    // MARK: - Image Conversion & EXIF/GPS Sanitizer

    private static func sanitizeAndConvertImageIfApplicable(sourceURL: URL, into directory: URL) -> URL? {
        let ext = sourceURL.pathExtension.lowercased()
        let supported: Set<String> = ["heic", "heif", "jpg", "jpeg", "png", "tiff", "tif"]
        guard supported.contains(ext) else { return nil }

        guard let imgSource = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imgSource, 0, nil) else {
            return nil
        }

        let outputIsPNG = (ext == "png")
        let outExt = outputIsPNG ? "png" : "jpg"
        let outType = outputIsPNG ? UTType.png.identifier : UTType.jpeg.identifier

        let stem = sourceURL.deletingPathExtension().lastPathComponent
        let outURL = FileSystemService.uniqueDestinationURL(
            for: directory.appendingPathComponent("\(stem).\(outExt)"),
            in: directory
        )

        guard let dest = CGImageDestinationCreateWithURL(outURL as CFURL, outType as CFString, 1, nil) else {
            return nil
        }

        // Preserve orientation if present, while omitting GPS, Exif camera serials, and TIFF user data!
        var cleanProps: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.90
        ]
        if let rawProps = CGImageSourceCopyPropertiesAtIndex(imgSource, 0, nil) as? [CFString: Any],
           let orientation = rawProps[kCGImagePropertyOrientation] {
            cleanProps[kCGImagePropertyOrientation] = orientation
        }

        CGImageDestinationAddImage(dest, cgImage, cleanProps as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return outURL
    }
}
