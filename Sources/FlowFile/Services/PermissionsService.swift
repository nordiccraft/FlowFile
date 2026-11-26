import AppKit
import Foundation

enum PermissionsService {
    private static let lastVersionDefaultsKey = "flowfile.permissions.lastVersion"
    private static let lastHadFDADefaultsKey = "flowfile.permissions.lastHadFullDiskAccess"

    /// Checks whether the app currently has macOS Full Disk Access (TCC SystemPolicyAllFiles)
    /// without triggering any intrusive system permission dialogs.
    static func hasFullDiskAccess() -> Bool {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path

        // Protected directories under TCC Full Disk Access on modern macOS
        let probePaths = [
            "\(home)/Library/Safari",
            "\(home)/Library/Mail",
            "/Library/Application Support/com.apple.TCC"
        ]

        for path in probePaths where fm.fileExists(atPath: path) {
            if (try? fm.contentsOfDirectory(atPath: path)) != nil {
                UserDefaults.standard.set(true, forKey: lastHadFDADefaultsKey)
                return true
            }
        }
        return false
    }

    /// Detects whether an app update (e.g. ad-hoc `cdhash` change) invalidated a previously granted
    /// Full Disk Access permission. Persists the current version and FDA state in UserDefaults so
    /// the reset alert triggers at most once per version upgrade.
    static func detectPostUpdatePermissionReset(currentVersion: String) -> Bool {
        let defaults = UserDefaults.standard
        let previousVersion = defaults.string(forKey: lastVersionDefaultsKey)
        let previouslyHadFDA = defaults.bool(forKey: lastHadFDADefaultsKey)
        let currentlyHasFDA = hasFullDiskAccess()

        defaults.set(currentVersion, forKey: lastVersionDefaultsKey)
        defaults.set(currentlyHasFDA, forKey: lastHadFDADefaultsKey)

        guard let previousVersion, !previousVersion.isEmpty else {
            return false
        }
        return previousVersion != currentVersion && previouslyHadFDA && !currentlyHasFDA
    }

    /// Opens macOS System Settings directly on Privacy & Security -> Full Disk Access.
    static func openFullDiskAccessSettings() {
        openPrivacySettings(anchor: "Privacy_AllFiles")
    }

    /// Opens macOS System Settings directly on Privacy & Security -> Files & Folders.
    static func openFilesAndFoldersSettings() {
        openPrivacySettings(anchor: "Privacy_FilesAndFolders")
    }

    /// Opens macOS System Settings directly on Privacy & Security -> Local Network.
    static func openLocalNetworkSettings() {
        openPrivacySettings(anchor: "Privacy_LocalNetwork")
    }

    /// Opens macOS System Settings directly on Privacy & Security -> Automation (Apple Events).
    static func openAutomationSettings() {
        openPrivacySettings(anchor: "Privacy_Automation")
    }

    private static func openPrivacySettings(anchor: String) {
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?\(anchor)",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(anchor)"
        ]
        for raw in urls {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    /// Reveals the running FlowFile.app bundle in Finder so the user can drag it into System Settings if needed.
    static func revealRunningAppInFinder() {
        let bundleURL = Bundle.main.bundleURL
        DefaultFileBrowserService.revealExplicitlyInAppleFinder([bundleURL])
    }
}
