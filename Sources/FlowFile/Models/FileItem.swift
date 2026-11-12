import AppKit
import Foundation
import UniformTypeIdentifiers

enum SortColumn: String, CaseIterable, Identifiable {
    case name = "name"
    case ext = "ext"
    case size = "size"
    case dateModified = "dateModified"
    case kind = "kind"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: return tr("Navn", "Name")
        case .ext: return tr("Endelse", "Ext")
        case .size: return tr("Størrelse", "Size")
        case .dateModified: return tr("Endret", "Modified")
        case .kind: return tr("Type", "Kind")
        }
    }
}

enum PaneViewMode: String, CaseIterable, Identifiable {
    case details
    case grid

    var id: String { rawValue }

    var title: String {
        switch self {
        case .details: return tr("Detaljer", "Details")
        case .grid: return tr("Rutenett", "Grid")
        }
    }

    var systemImage: String {
        switch self {
        case .details: return "list.bullet.rectangle"
        case .grid: return "square.grid.2x2"
        }
    }
}

struct FileItem: Identifiable, Hashable {
    let url: URL
    let name: String
    let stemName: String
    let fileExtension: String
    let rawFileExtension: String
    let isDirectory: Bool
    let isPackage: Bool
    let isSymbolicLink: Bool
    let isAliasFile: Bool
    let resolvedTargetURL: URL?
    let targetIsNavigableFolder: Bool
    let isHidden: Bool
    let size: Int64
    let modificationDate: Date?
    let creationDate: Date?
    let kindDescription: String
    let cloudState: CloudSyncState
    let archiveEntryPath: String?

    var id: URL { url }

    var isVirtualArchiveEntry: Bool {
        archiveEntryPath != nil
    }

    var isShortcut: Bool {
        isSymbolicLink || isAliasFile
    }

    /// True folder (or shortcut pointing to a folder!) for sorting at top and navigating inside FlowFile.
    var isNavigableFolder: Bool {
        (isDirectory && !isPackage) || targetIsNavigableFolder
    }

    /// Destination URL to open when navigating into a folder or shortcut.
    var navigationTargetURL: URL {
        if let resolvedTargetURL {
            return resolvedTargetURL
        }
        return url
    }

    init(
        virtualArchiveURL: URL,
        name: String,
        isDirectory: Bool,
        size: Int64,
        modificationDate: Date?,
        archiveEntryPath: String
    ) {
        self.url = virtualArchiveURL
        self.name = name
        self.isDirectory = isDirectory
        self.isPackage = false
        self.isSymbolicLink = false
        self.isAliasFile = false
        self.resolvedTargetURL = nil
        self.targetIsNavigableFolder = false
        self.isHidden = name.hasPrefix(".")
        self.size = size
        self.modificationDate = modificationDate
        self.creationDate = nil
        self.cloudState = .none
        self.archiveEntryPath = archiveEntryPath

        if isDirectory {
            self.stemName = name
            self.fileExtension = ""
            self.rawFileExtension = ""
            self.kindDescription = "Arkivmappe"
        } else {
            let ext = (name as NSString).pathExtension
            if name.hasPrefix(".") && !name.dropFirst().contains(".") {
                self.stemName = name
                self.fileExtension = ""
                self.rawFileExtension = ""
            } else if ext.isEmpty {
                self.stemName = name
                self.fileExtension = ""
                self.rawFileExtension = ""
            } else {
                self.stemName = String(name.dropLast(ext.count + 1))
                self.fileExtension = ext.lowercased()
                self.rawFileExtension = ext
            }
            self.kindDescription = ext.isEmpty ? "Arkivfil" : "\(ext.uppercased())-arkivfil"
        }
    }

    init(
        url: URL,
        resourceValues: URLResourceValues? = nil,
        insideCloudRoot: Bool = false
    ) {
        let standardized = url.standardizedFileURL
        self.url = standardized
        self.archiveEntryPath = nil

        let fullName = standardized.lastPathComponent
        self.name = fullName

        let isDir = resourceValues?.isDirectory ?? false
        let isPkg = resourceValues?.isPackage ?? false
        let isSym = resourceValues?.isSymbolicLink ?? false
        let isAlias = (resourceValues?.isAliasFile ?? false) && !isSym

        self.isDirectory = isDir
        self.isPackage = isPkg
        self.isSymbolicLink = isSym
        self.isAliasFile = isAlias
        self.isHidden = (resourceValues?.isHidden ?? false) || fullName.hasPrefix(".")

        // Resolve Finder Aliases and Symlinks so double-clicking shortcuts NEVER launches Finder!
        var resolved: URL? = nil
        var targetFolder = false
        if isAlias {
            if let aliasTarget = try? URL(resolvingAliasFileAt: standardized, options: [.withoutUI, .withoutMounting]) {
                let norm = aliasTarget.standardizedFileURL
                resolved = norm
                if let targetRV = try? norm.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]),
                   targetRV.isDirectory == true, targetRV.isPackage != true {
                    targetFolder = true
                }
            }
        } else if isSym {
            let symTarget = standardized.resolvingSymlinksInPath().standardizedFileURL
            if symTarget != standardized {
                resolved = symTarget
                if let targetRV = try? symTarget.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]),
                   targetRV.isDirectory == true, targetRV.isPackage != true {
                    targetFolder = true
                }
            }
        }
        self.resolvedTargetURL = resolved
        self.targetIsNavigableFolder = targetFolder

        if (isDir && !isPkg) || targetFolder {
            self.stemName = fullName
            self.fileExtension = ""
            self.rawFileExtension = ""
        } else {
            let ext = standardized.pathExtension
            if fullName.hasPrefix(".") && !fullName.dropFirst().contains(".") {
                self.stemName = fullName
                self.fileExtension = ""
                self.rawFileExtension = ""
            } else if ext.isEmpty {
                self.stemName = fullName
                self.fileExtension = ""
                self.rawFileExtension = ""
            } else {
                self.stemName = String(fullName.dropLast(ext.count + 1))
                self.fileExtension = ext.lowercased()
                self.rawFileExtension = ext
            }
        }

        // Use logical fileSize first when dataless/cloud so cloud-only files show their real size instead of 0 B!
        let logicalBytes = resourceValues?.fileSize.map { Int64($0) }
        let allocatedBytes = resourceValues?.totalFileAllocatedSize.map { Int64($0) }
        self.size = logicalBytes ?? allocatedBytes ?? 0

        self.modificationDate = resourceValues?.contentModificationDate
        self.creationDate = resourceValues?.creationDate

        if targetFolder, let resolved {
            self.kindDescription = "Snarvei → \(resolved.lastPathComponent)"
        } else {
            self.kindDescription = resourceValues?.localizedTypeDescription ?? (isDir ? "Mappe" : "Fil")
        }

        self.cloudState = CloudStorageService.detectSyncState(
            for: standardized,
            resourceValues: resourceValues,
            insideCloudRoot: insideCloudRoot
        )
    }

    func formattedSize(calculatedFolderSize: Int64? = nil) -> String {
        if isNavigableFolder {
            if let folderBytes = calculatedFolderSize {
                return ByteFormatter.string(fromByteCount: folderBytes)
            }
            return isShortcut ? "<SNARVEI>" : "<MAPPE>"
        }
        return ByteFormatter.string(fromByteCount: size)
    }

    var formattedDate: String {
        guard let modificationDate else { return "—" }
        return DateFormatterCache.compact.string(from: modificationDate)
    }

    static func == (lhs: FileItem, rhs: FileItem) -> Bool {
        lhs.url == rhs.url &&
        lhs.modificationDate == rhs.modificationDate &&
        lhs.size == rhs.size &&
        lhs.cloudState == rhs.cloudState
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(url)
    }
}

enum ByteFormatter {
    private static let formatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useBytes, .useKB, .useMB, .useGB, .useTB]
        f.countStyle = .file
        f.includesUnit = true
        f.isAdaptive = true
        return f
    }()

    static func string(fromByteCount bytes: Int64) -> String {
        formatter.string(fromByteCount: bytes)
    }
}

enum DateFormatterCache {
    static let compact: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "nb_NO")
        df.dateFormat = "dd.MM.yyyy HH:mm"
        return df
    }()

    static let full: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "nb_NO")
        df.dateStyle = .medium
        df.timeStyle = .medium
        return df
    }()
}

final class FileIconCache {
    static let shared = FileIconCache()
    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = 1000
    }

    func icon(for item: FileItem) -> NSImage {
        if item.isVirtualArchiveEntry {
            let vKey = item.isDirectory ? "varch:folder" : "varch:ext:\(item.fileExtension)"
            if let cached = cache.object(forKey: vKey as NSString) {
                return cached
            }
            let img: NSImage
            if item.isDirectory {
                img = NSWorkspace.shared.icon(for: .folder)
            } else if !item.fileExtension.isEmpty, let ut = UTType(filenameExtension: item.fileExtension) {
                img = NSWorkspace.shared.icon(for: ut)
            } else {
                img = NSWorkspace.shared.icon(for: .data)
            }
            img.size = NSSize(width: 18, height: 18)
            cache.setObject(img, forKey: vKey as NSString)
            return img
        }

        let key: String
        if item.isShortcut || item.isNavigableFolder || item.isPackage || item.fileExtension == "app" {
            key = "path:\(item.url.path)"
        } else if !item.fileExtension.isEmpty {
            key = "ext:\(item.fileExtension)"
        } else {
            key = "path:\(item.url.path)"
        }

        if let cached = cache.object(forKey: key as NSString) {
            return cached
        }

        let img = NSWorkspace.shared.icon(forFile: item.url.path)
        img.size = NSSize(width: 18, height: 18)
        cache.setObject(img, forKey: key as NSString)
        return img
    }
}
