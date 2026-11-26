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
    let tagNames: [String]
    let labelNumber: Int?
    let relativeSubpath: String?

    var id: URL { url }

    var colorTags: [FinderColorTag] {
        FinderColorTag.extractColorTags(from: tagNames, labelNumber: labelNumber)
    }

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
        self.tagNames = []
        self.labelNumber = nil
        self.relativeSubpath = nil

        if isDirectory {
            self.stemName = name
            self.fileExtension = ""
            self.rawFileExtension = ""
            self.kindDescription = tr("Arkivmappe", "Archive Folder")
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
            self.kindDescription = ext.isEmpty
                ? tr("Arkivfil", "Archive File")
                : "\(ext.uppercased())-\(tr("arkivfil", "archive file"))"
        }
    }

    init(
        url: URL,
        resourceValues: URLResourceValues? = nil,
        insideCloudRoot: Bool = false,
        relativeSubpath: String? = nil
    ) {
        let standardized = url.standardizedFileURL
        self.url = standardized
        self.archiveEntryPath = nil
        if let providedTags = resourceValues?.tagNames {
            self.tagNames = providedTags
        } else {
            self.tagNames = (try? standardized.resourceValues(forKeys: [.tagNamesKey]))?.tagNames ?? []
        }
        self.labelNumber = resourceValues?.labelNumber
        self.relativeSubpath = relativeSubpath

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
            self.kindDescription = "\(tr("Snarvei", "Shortcut")) → \(resolved.lastPathComponent)"
        } else if let desc = resourceValues?.localizedTypeDescription {
            self.kindDescription = desc
        } else if let desc = (try? standardized.resourceValues(forKeys: [.localizedTypeDescriptionKey]))?.localizedTypeDescription {
            self.kindDescription = desc
        } else {
            let ext = standardized.pathExtension
            self.kindDescription = isDir
                ? tr("Mappe", "Folder")
                : (ext.isEmpty ? tr("Fil", "File") : "\(ext.uppercased())-\(tr("fil", "file"))")
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
            return isShortcut ? tr("<SNARVEI>", "<SHORTCUT>") : tr("<MAPPE>", "<FOLDER>")
        }
        return ByteFormatter.string(fromByteCount: size)
    }

    var formattedDate: String {
        guard let modificationDate else { return "—" }
        return DateFormatterCache.compactString(from: modificationDate)
    }

    static func == (lhs: FileItem, rhs: FileItem) -> Bool {
        lhs.url == rhs.url &&
        lhs.modificationDate == rhs.modificationDate &&
        lhs.size == rhs.size &&
        lhs.cloudState == rhs.cloudState &&
        lhs.tagNames == rhs.tagNames &&
        lhs.labelNumber == rhs.labelNumber &&
        lhs.relativeSubpath == rhs.relativeSubpath &&
        lhs.kindDescription == rhs.kindDescription
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(url)
    }
}

enum ByteFormatter {
    private static let lock = NSLock()
    private static let formatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useBytes, .useKB, .useMB, .useGB, .useTB]
        f.countStyle = .file
        f.includesUnit = true
        f.isAdaptive = true
        return f
    }()

    static func string(fromByteCount bytes: Int64) -> String {
        lock.lock()
        defer { lock.unlock() }
        return formatter.string(fromByteCount: bytes)
    }
}

enum DateFormatterCache {
    private static let lock = NSLock()
    private static var compactCache: [String: DateFormatter] = [:]
    private static var fullCache: [String: DateFormatter] = [:]

    static var compact: DateFormatter {
        let loc = LocalizationCenter.shared.currentLanguage.locale
        lock.lock()
        defer { lock.unlock() }
        if let existing = compactCache[loc.identifier] {
            return existing
        }
        let df = DateFormatter()
        df.locale = loc
        df.dateStyle = .short
        df.timeStyle = .short
        compactCache[loc.identifier] = df
        return df
    }

    static var full: DateFormatter {
        let loc = LocalizationCenter.shared.currentLanguage.locale
        lock.lock()
        defer { lock.unlock() }
        if let existing = fullCache[loc.identifier] {
            return existing
        }
        let df = DateFormatter()
        df.locale = loc
        df.dateStyle = .medium
        df.timeStyle = .medium
        fullCache[loc.identifier] = df
        return df
    }

    static func compactString(from date: Date) -> String {
        let loc = LocalizationCenter.shared.currentLanguage.locale
        lock.lock()
        defer { lock.unlock() }
        let df: DateFormatter
        if let existing = compactCache[loc.identifier] {
            df = existing
        } else {
            let created = DateFormatter()
            created.locale = loc
            created.dateStyle = .short
            created.timeStyle = .short
            compactCache[loc.identifier] = created
            df = created
        }
        return df.string(from: date)
    }

    static func fullString(from date: Date) -> String {
        let loc = LocalizationCenter.shared.currentLanguage.locale
        lock.lock()
        defer { lock.unlock() }
        let df: DateFormatter
        if let existing = fullCache[loc.identifier] {
            df = existing
        } else {
            let created = DateFormatter()
            created.locale = loc
            created.dateStyle = .medium
            created.timeStyle = .medium
            fullCache[loc.identifier] = created
            df = created
        }
        return df.string(from: date)
    }
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
