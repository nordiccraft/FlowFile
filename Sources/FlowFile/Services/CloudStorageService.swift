import Darwin
import Foundation

enum CloudProviderKind: String, Codable, Hashable {
    case oneDrive = "OneDrive"
    case dropbox = "Dropbox"
    case googleDrive = "Google Drive"
    case box = "Box"
    case iCloudDrive = "iCloud Drive"
    case other = "Skylagring"

    var localizedName: String {
        switch self {
        case .other: return tr("Skylagring", "Cloud Storage")
        default: return rawValue
        }
    }

    var systemImage: String {
        switch self {
        case .oneDrive: return "cloud.fill"
        case .dropbox: return "shippingbox.fill"
        case .googleDrive: return "externaldrive.connected.to.line.below.fill"
        case .box: return "archivebox.fill"
        case .iCloudDrive: return "icloud.fill"
        case .other: return "cloud"
        }
    }
}

struct CloudAccountItem: Identifiable, Hashable {
    var id: String { rootURL.path }
    let provider: CloudProviderKind
    let displayName: String
    let subtitle: String?
    let rootURL: URL

    /// Distinguishes multiple accounts of the same provider (e.g. "OneDrive – Contoso AS" vs "OneDrive – Personal").
    var fullDisplayName: String {
        if let subtitle, !subtitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           subtitle.lowercased() != displayName.lowercased() {
            return "\(displayName) – \(subtitle)"
        }
        return displayName
    }
}

enum CloudSyncState: Equatable, Hashable {
    case none
    case cloudOnly       // Dataless placeholder (0 bytes on disk)
    case localSynced     // Downloaded locally inside a cloud folder
    case syncing         // Actively uploading or downloading

    var badgeSymbol: String {
        switch self {
        case .none: return ""
        case .cloudOnly: return "☁︎"
        case .localSynced: return "✓"
        case .syncing: return "↻"
        }
    }

    var descriptionText: String {
        switch self {
        case .none: return tr("Lokal fil", "Local file")
        case .cloudOnly: return tr("Kun i skyen (tar ikke lokal plass)", "Cloud only (uses zero local disk space)")
        case .localSynced: return tr("Lagret lokalt på Macen + i skyen", "Saved locally on Mac + synced to cloud")
        case .syncing: return tr("Synkroniserer med skyen...", "Syncing with cloud...")
        }
    }
}

enum CloudStorageService {
    /// Discovers all installed/connected cloud drives on macOS:
    /// - ~/Library/CloudStorage/* (OneDrive, Dropbox, Google Drive, Box, etc.)
    /// - ~/Library/Mobile Documents/com~apple~CloudDocs (iCloud Drive)
    /// - Legacy ~/OneDrive, ~/Dropbox, ~/Google Drive, ~/Box folders if not already represented
    static func discoverCloudAccounts() -> [CloudAccountItem] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var accounts: [CloudAccountItem] = []
        var seenResolvedPaths = Set<String>()

        // 1. Modern macOS FileProvider directory: ~/Library/CloudStorage
        let cloudStorageRoot = home.appendingPathComponent("Library/CloudStorage", isDirectory: true)
        if let entries = try? fm.contentsOfDirectory(
            at: cloudStorageRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey],
            options: [.skipsHiddenFiles]
        ) {
            for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue else { continue }
                let folderName = entry.lastPathComponent
                let parsed = classifyCloudFolderName(folderName)
                let resolved = entry.resolvingSymlinksInPath().standardizedFileURL.path
                seenResolvedPaths.insert(resolved)

                accounts.append(CloudAccountItem(
                    provider: parsed.provider,
                    displayName: parsed.title,
                    subtitle: parsed.accountDetail,
                    rootURL: entry.standardizedFileURL
                ))
            }
        }

        // 2. Legacy direct folders in Home (~) if not pointing to an already discovered CloudStorage path
        let legacyCandidates: [(String, CloudProviderKind)] = [
            ("OneDrive", .oneDrive),
            ("Dropbox", .dropbox),
            ("Google Drive", .googleDrive),
            ("Box", .box)
        ]
        for (folderName, kind) in legacyCandidates {
            let candidate = home.appendingPathComponent(folderName)
            guard let target = resolvePossibleShortcut(at: candidate) else { continue }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: target.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let norm = target.standardizedFileURL.path
            if !seenResolvedPaths.contains(norm) {
                seenResolvedPaths.insert(norm)
                accounts.append(CloudAccountItem(
                    provider: kind,
                    displayName: kind.rawValue,
                    subtitle: nil,
                    rootURL: target.standardizedFileURL
                ))
            }
        }

        // 3. Apple iCloud Drive
        let iCloudURL = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        var isICloudDir: ObjCBool = false
        if fm.fileExists(atPath: iCloudURL.path, isDirectory: &isICloudDir), isICloudDir.boolValue {
            accounts.append(CloudAccountItem(
                provider: .iCloudDrive,
                displayName: "iCloud Drive",
                subtitle: "Apple iCloud",
                rootURL: iCloudURL.standardizedFileURL
            ))
        }

        return accounts
    }

    static func cloudAccount(containing url: URL, accounts: [CloudAccountItem]) -> CloudAccountItem? {
        let std = url.standardizedFileURL
        let stdPath = std.path
        let resolvedPath: String
        let directResolved = std.resolvingSymlinksInPath().path
        if directResolved != stdPath {
            resolvedPath = directResolved
        } else {
            // If `url` itself does not exist yet, resolve its parent folder's symlinks too
            let parentResolved = std.deletingLastPathComponent().resolvingSymlinksInPath().path
            resolvedPath = (parentResolved as NSString).appendingPathComponent(std.lastPathComponent)
        }
        return accounts.first { account in
            let rootPath = account.rootURL.standardizedFileURL.path
            let resolvedRoot = account.rootURL.standardizedFileURL.resolvingSymlinksInPath().path
            return stdPath == rootPath
                || stdPath.hasPrefix(rootPath + "/")
                || resolvedPath == resolvedRoot
                || resolvedPath.hasPrefix(resolvedRoot + "/")
        }
    }

    /// Returns the writable root folder for an account.
    /// For Google Drive FileProvider (`GoogleDrive-<email>`), the top level is read-only and holds
    /// "My Drive" / "Min disk" (localized), so we target that writable subfolder automatically.
    static func writableUploadRootURL(for account: CloudAccountItem) -> URL {
        guard account.provider == .googleDrive else {
            return account.rootURL
        }
        let fm = FileManager.default
        let knownMyDriveNames = [
            "My Drive", "Min disk", "Min stasjon", "Mitt drev",
            "Meine Ablage", "Mon Drive", "Mi unidad", "Il mio Drive", "Mijn Drive"
        ]
        for name in knownMyDriveNames {
            let candidate = account.rootURL.appendingPathComponent(name, isDirectory: true)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
                return candidate
            }
        }
        // Fallback: pick first writable child directory if Google Drive uses another locale name
        if let children = try? fm.contentsOfDirectory(
            at: account.rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            if let writable = children.first(where: {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                    && fm.isWritableFile(atPath: $0.path)
            }) {
                return writable
            }
        }
        return account.rootURL
    }

    static func isInsideAnyCloudFolder(_ url: URL) -> Bool {
        let p = url.standardizedFileURL.path
        if p.contains("/Library/CloudStorage/") || p.contains("/Library/Mobile Documents/com~apple~CloudDocs") {
            return true
        }
        return false
    }

    /// True when the file's contents are not stored locally (reading it would trigger a cloud download).
    static func isDatalessPlaceholder(_ url: URL) -> Bool {
        var st = stat()
        if lstat(url.path, &st) == 0 {
            return (st.st_flags & UInt32(SF_DATALESS)) != 0
        }
        return false
    }

    /// Detects cloud sync state without triggering file materialization/download!
    static func detectSyncState(
        for url: URL,
        resourceValues: URLResourceValues?,
        insideCloudRoot: Bool
    ) -> CloudSyncState {
        if resourceValues?.ubiquitousItemIsDownloading == true || resourceValues?.ubiquitousItemIsUploading == true {
            return .syncing
        }

        if let dlStatus = resourceValues?.ubiquitousItemDownloadingStatus {
            if dlStatus == .notDownloaded {
                return .cloudOnly
            } else if dlStatus == .downloaded || dlStatus == .current {
                return .localSynced
            }
        }

        guard insideCloudRoot else { return .none }

        // Check APFS SF_DATALESS flag via lstat() (used by OneDrive, Dropbox, Google Drive & Box FileProvider!)
        var st = stat()
        if lstat(url.path, &st) == 0 {
            if (st.st_flags & UInt32(SF_DATALESS)) != 0 {
                return .cloudOnly
            }
            return .localSynced
        }

        return .none
    }

    /// Evicts local copy to free disk space while keeping item in OneDrive/Dropbox/Google Drive/Box/iCloud!
    static func evictLocalCopy(at urls: [URL]) throws {
        var lastError: Error?
        for url in urls {
            do {
                try FileManager.default.evictUbiquitousItem(at: url)
            } catch {
                // Fallback to macOS fileproviderctl for third-party FileProvider domains
                if !runFileProviderCLI(subcommand: "evict", url: url) {
                    lastError = error
                }
            }
        }
        if let lastError {
            throw lastError
        }
    }

    /// Downloads cloud-only item to local disk ("Behold på denne Macen")
    static func downloadLocalCopy(at urls: [URL]) throws {
        var lastError: Error?
        for url in urls {
            do {
                try FileManager.default.startDownloadingUbiquitousItem(at: url)
            } catch {
                if !runFileProviderCLI(subcommand: "materialize", url: url) {
                    lastError = error
                }
            }
        }
        if let lastError {
            throw lastError
        }
    }

    static func resolvePossibleShortcut(at url: URL) -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return nil }
        if let rv = try? url.resourceValues(forKeys: [.isAliasFileKey, .isSymbolicLinkKey]) {
            if rv.isAliasFile == true,
               let resolved = try? URL(resolvingAliasFileAt: url, options: [.withoutUI, .withoutMounting]) {
                return resolved.standardizedFileURL
            }
            if rv.isSymbolicLink == true {
                return url.resolvingSymlinksInPath().standardizedFileURL
            }
        }
        return url.standardizedFileURL
    }

    // MARK: - Helpers

    private static func classifyCloudFolderName(_ folderName: String) -> (provider: CloudProviderKind, title: String, accountDetail: String?) {
        if folderName.hasPrefix("OneDrive-") {
            let detail = String(folderName.dropFirst("OneDrive-".count))
            return (.oneDrive, "OneDrive", detail.isEmpty ? nil : detail)
        } else if folderName.lowercased().hasPrefix("onedrive") {
            return (.oneDrive, "OneDrive", nil)
        } else if folderName.hasPrefix("GoogleDrive-") {
            let detail = String(folderName.dropFirst("GoogleDrive-".count))
            return (.googleDrive, "Google Drive", detail.isEmpty ? nil : detail)
        } else if folderName.lowercased().hasPrefix("googledrive") || folderName.lowercased().hasPrefix("google drive") {
            return (.googleDrive, "Google Drive", nil)
        } else if folderName.hasPrefix("Dropbox-") {
            let detail = String(folderName.dropFirst("Dropbox-".count))
            return (.dropbox, "Dropbox", detail.isEmpty ? nil : detail)
        } else if folderName.lowercased().hasPrefix("dropbox") {
            return (.dropbox, "Dropbox", nil)
        } else if folderName.hasPrefix("Box-") {
            let detail = String(folderName.dropFirst("Box-".count))
            return (.box, "Box", detail == "Box" ? nil : detail)
        } else if folderName.lowercased() == "box" {
            return (.box, "Box", nil)
        } else {
            return (.other, folderName, nil)
        }
    }

    private static func runFileProviderCLI(subcommand: String, url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: "/usr/bin/fileproviderctl") else { return false }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/fileproviderctl")
        proc.arguments = [subcommand, url.path]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch {
            return false
        }
    }
}
