import AppKit
import Foundation

enum PermissionsService {
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
                return true
            }
        }
        return false
    }

    /// Opens macOS System Settings directly on Privacy & Security -> Full Disk Access.
    static func openFullDiskAccessSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles"
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
