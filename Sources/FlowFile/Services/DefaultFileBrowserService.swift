import AppKit
import CoreServices
import Foundation
import UniformTypeIdentifiers

enum ExternalOpenTabBehavior: String, CaseIterable, Identifiable {
    case smartNewTab = "smartNewTab"
    case activeTab = "activeTab"

    var id: String { rawValue }

    func displayName(in language: AppLanguage) -> String {
        let nb = language.resolvedIsNorwegian
        switch self {
        case .smartNewTab:
            return nb
                ? "Ny fane (gjenbruk hvis åpen)"
                : "New Tab (reuse if open)"
        case .activeTab:
            return nb
                ? "Aktiv fane"
                : "Active Tab"
        }
    }
}

enum DefaultFileBrowserService {
    static let flowFileBundleID = "com.flowfile.app"
    static let finderBundleID = "com.apple.finder"
    static let finderAppURL = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")

    private static let nsFileViewerKey = "NSFileViewer" as CFString
    private static let launchServicesDomain = "com.apple.LaunchServices/com.apple.launchservices.secure" as CFString
    private static let lsHandlersKey = "LSHandlers" as CFString

    /// Returns true if FlowFile is currently configured as the default folder handler or NSFileViewer.
    static func isFlowFileDefault() -> Bool {
        if let viewer = currentNSFileViewer(),
           viewer.caseInsensitiveCompare(flowFileBundleID) == .orderedSame {
            return true
        }
        if let appURL = NSWorkspace.shared.urlForApplication(toOpen: .folder),
           let bundleID = Bundle(url: appURL)?.bundleIdentifier,
           bundleID.caseInsensitiveCompare(flowFileBundleID) == .orderedSame {
            return true
        }
        return false
    }

    static func currentNSFileViewer() -> String? {
        CFPreferencesSynchronize(
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        return CFPreferencesCopyValue(
            nsFileViewerKey,
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        ) as? String
    }

    /// Registers FlowFile as the default macOS file viewer (`NSFileViewer`) and LaunchServices `public.folder` handler.
    @MainActor
    static func setFlowFileAsDefault() async throws {
        guard let targetAppURL = resolveFlowFileAppBundleURL() else {
            throw NSError(
                domain: "DefaultFileBrowserService",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: tr(
                        "Fant ikke FlowFile.app. Legg FlowFile.app i /Applications først.",
                        "Could not locate FlowFile.app. Move FlowFile.app to /Applications first."
                    )
                ]
            )
        }

        // 1. Set global NSFileViewer for Cocoa "Show in Finder" / activateFileViewerSelecting
        CFPreferencesSetValue(
            nsFileViewerKey,
            flowFileBundleID as CFString,
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        _ = CFPreferencesSynchronize(
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )

        // 2. Cleanly update LaunchServices secure LSHandlers without accumulating duplicate entries
        updateLaunchServicesFolderHandlerPreference(bundleID: flowFileBundleID)

        // 3. Notify LaunchServices daemon in-memory immediately via official NSWorkspace API
        try await NSWorkspace.shared.setDefaultApplication(at: targetAppURL, toOpen: .folder)
    }

    /// Restores macOS Finder (`com.apple.finder`) as the default file viewer and folder handler.
    @MainActor
    static func resetToFinder() async throws {
        // 1. Delete global NSFileViewer override
        CFPreferencesSetValue(
            nsFileViewerKey,
            nil,
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        _ = CFPreferencesSynchronize(
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )

        // 2. Point LSHandlers cleanly back to com.apple.finder without duplicates
        updateLaunchServicesFolderHandlerPreference(bundleID: finderBundleID)

        // 3. Notify LaunchServices daemon immediately via official NSWorkspace API
        if FileManager.default.fileExists(atPath: finderAppURL.path) {
            try await NSWorkspace.shared.setDefaultApplication(at: finderAppURL, toOpen: .folder)
        }
    }

    /// Deduplicates and updates `public.folder` inside LaunchServices `LSHandlers`.
    static func upsertLaunchServicesFolderHandler(
        in existingHandlers: [[String: Any]],
        bundleID: String
    ) -> [[String: Any]] {
        var filtered = existingHandlers.filter { entry in
            guard let contentType = entry["LSHandlerContentType"] as? String else {
                return true
            }
            return contentType.caseInsensitiveCompare("public.folder") != .orderedSame
        }
        filtered.append([
            "LSHandlerContentType": "public.folder",
            "LSHandlerRoleAll": bundleID
        ])
        return filtered
    }

    /// Resolves whether an externally opened/revealed URL should open a directory directly or open its parent and select the item.
    static func resolveExternalTarget(
        for rawURL: URL,
        isRevealEvent: Bool
    ) -> (folderURL: URL, itemToSelect: URL?) {
        let standardized = (CloudStorageService.resolvePossibleShortcut(at: rawURL) ?? rawURL).standardizedFileURL
        let resourceValues = try? standardized.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        let isDir = resourceValues?.isDirectory ?? false
        let ext = standardized.pathExtension.lowercased()
        let isPackage = (resourceValues?.isPackage ?? false)
            || ["app", "bundle", "pkg", "mpkg", "framework", "plugin", "xcodeproj", "xcworkspace"].contains(ext)

        if isDir && !isPackage {
            if isRevealEvent && standardized.path != "/" {
                return (standardized.deletingLastPathComponent().standardizedFileURL, standardized)
            }
            return (standardized, nil)
        }

        let parent = standardized.deletingLastPathComponent().standardizedFileURL
        return (parent, standardized)
    }

    /// Extracts file URLs from a Finder / Cocoa `kAERevealSelection` (`'mvis'`) or `odoc` Apple Event.
    static func extractURLs(fromAppleEvent event: NSAppleEventDescriptor) -> [URL] {
        guard let directObj = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)) else {
            return []
        }

        var results: [URL] = []
        if directObj.descriptorType == DescType(typeAEList) {
            let count = directObj.numberOfItems
            if count >= 1 {
                for idx in 1...count {
                    if let item = directObj.atIndex(idx),
                       let url = extractSingleURL(from: item) {
                        results.append(url)
                    }
                }
            }
        } else if let url = extractSingleURL(from: directObj) {
            results.append(url)
        }
        return results
    }

    /// Explicitly reveals items in Apple's macOS Finder (`com.apple.finder`), even when FlowFile itself is `NSFileViewer`.
    static func revealExplicitlyInAppleFinder(_ urls: [URL]) {
        let validURLs = urls.map(\.standardizedFileURL).filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !validURLs.isEmpty else { return }

        if !isFlowFileDefault() {
            NSWorkspace.shared.activateFileViewerSelecting(validURLs)
            return
        }

        let script = """
        on run argv
            set posixFiles to {}
            repeat with p in argv
                try
                    set end of posixFiles to (POSIX file (contents of p) as alias)
                end try
            end repeat
            if (count of posixFiles) > 0 then
                tell application id "com.apple.finder"
                    reveal posixFiles
                    activate
                end tell
            end if
        end run
        """

        DispatchQueue.global(qos: .userInitiated).async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            proc.arguments = ["-e", script, "--"] + validURLs.map(\.path)
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            try? proc.run()
            proc.waitUntilExit()
        }
    }

    // MARK: - Private Helpers

    private static func resolveFlowFileAppBundleURL() -> URL? {
        let running = Bundle.main.bundleURL.standardizedFileURL
        if running.pathExtension.lowercased() == "app" && FileManager.default.fileExists(atPath: running.path) {
            return running
        }
        let standardApps = URL(fileURLWithPath: "/Applications/FlowFile.app")
        if FileManager.default.fileExists(atPath: standardApps.path) {
            return standardApps
        }
        let userApps = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/FlowFile.app")
        if FileManager.default.fileExists(atPath: userApps.path) {
            return userApps
        }
        return nil
    }

    private static func updateLaunchServicesFolderHandlerPreference(bundleID: String) {
        let existingRaw = CFPreferencesCopyValue(
            lsHandlersKey,
            launchServicesDomain,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        ) as? [[String: Any]] ?? []

        let updated = upsertLaunchServicesFolderHandler(in: existingRaw, bundleID: bundleID)
        CFPreferencesSetValue(
            lsHandlersKey,
            updated as CFArray,
            launchServicesDomain,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        _ = CFPreferencesSynchronize(
            launchServicesDomain,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
    }

    private static func extractSingleURL(from descriptor: NSAppleEventDescriptor) -> URL? {
        if let direct = descriptor.fileURLValue {
            return direct
        }
        if let coerced = descriptor.coerce(toDescriptorType: DescType(typeFileURL)) {
            if let url = coerced.fileURLValue {
                return url
            }
            if let str = coerced.stringValue, let url = URL(string: str), url.isFileURL {
                return url
            }
        }
        if let str = descriptor.stringValue {
            if str.hasPrefix("file://"), let url = URL(string: str) {
                return url
            }
            if str.hasPrefix("/") {
                return URL(fileURLWithPath: str)
            }
        }
        return nil
    }
}

@MainActor
final class ExternalOpenCoordinator {
    static let shared = ExternalOpenCoordinator()

    private weak var workspace: WorkspaceState?
    private var pendingEvents: [(urls: [URL], isRevealEvent: Bool)] = []

    private init() {}

    func attach(workspace: WorkspaceState) {
        self.workspace = workspace
        guard !pendingEvents.isEmpty else { return }
        let queued = pendingEvents
        pendingEvents.removeAll()
        for entry in queued {
            workspace.handleExternalOpenOrReveal(urls: entry.urls, isRevealEvent: entry.isRevealEvent)
        }
    }

    func receive(urls: [URL], isRevealEvent: Bool) {
        let fileURLs = urls.filter(\.isFileURL)
        guard !fileURLs.isEmpty else { return }

        if let workspace {
            workspace.handleExternalOpenOrReveal(urls: fileURLs, isRevealEvent: isRevealEvent)
            bringMainWindowToFront()
        } else {
            pendingEvents.append((fileURLs, isRevealEvent))
        }
    }

    private func bringMainWindowToFront() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.isMiniaturized {
            window.deminiaturize(nil)
        }
    }
}
