import AppKit
import Foundation
import Observation

struct FavoriteItem: Identifiable, Hashable, Codable {
    var id: String { path }
    var title: String
    let path: String
    let systemImage: String

    var url: URL { URL(fileURLWithPath: path) }
}

struct VolumeInfo: Identifiable, Hashable {
    var id: URL { url }
    let url: URL
    let name: String
    let totalCapacity: Int64
    let availableCapacity: Int64
    let isInternal: Bool
    let isRemovable: Bool
    let isEjectable: Bool

    var usedCapacity: Int64 {
        max(0, totalCapacity - availableCapacity)
    }

    var usedFraction: Double {
        guard totalCapacity > 0 else { return 0 }
        return min(1.0, max(0.0, Double(usedCapacity) / Double(totalCapacity)))
    }

    var systemImage: String {
        if url.path == "/" {
            return "internaldrive.fill"
        } else if isRemovable || isEjectable {
            return "externaldrive.fill"
        } else {
            return "externaldrive.connected.to.line.below.fill"
        }
    }

    var capacitySummary: String {
        let free = ByteFormatter.string(fromByteCount: availableCapacity)
        let total = ByteFormatter.string(fromByteCount: totalCapacity)
        return tr("\(free) ledig av \(total)", "\(free) free of \(total)")
    }
}

@Observable
final class FolderTreeNode: Identifiable, Hashable {
    let url: URL
    let name: String
    var isExpanded: Bool = false
    var children: [FolderTreeNode]? = nil
    var isLoading: Bool = false

    var id: URL { url }

    init(url: URL, name: String? = nil) {
        let standardized = url.standardizedFileURL
        self.url = standardized
        if let name {
            self.name = name
        } else if standardized.path == "/" {
            self.name = FileManager.default.displayName(atPath: "/")
        } else {
            self.name = standardized.lastPathComponent
        }
    }

    func loadChildrenIfNeeded(showHidden: Bool) {
        guard children == nil, !isLoading else { return }
        reloadChildren(showHidden: showHidden)
    }

    func reloadChildren(showHidden: Bool) {
        isLoading = true
        let targetURL = url
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let fm = FileManager.default
            let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isHiddenKey]
            var options: FileManager.DirectoryEnumerationOptions = [.skipsSubdirectoryDescendants]
            if !showHidden {
                options.insert(.skipsHiddenFiles)
            }

            let urls = (try? fm.contentsOfDirectory(
                at: targetURL,
                includingPropertiesForKeys: keys,
                options: options
            )) ?? []

            let subdirs: [FolderTreeNode] = urls.compactMap { childURL in
                guard let rv = try? childURL.resourceValues(forKeys: Set(keys)),
                      rv.isDirectory == true,
                      rv.isPackage != true else {
                    return nil
                }
                if !showHidden && childURL.lastPathComponent.hasPrefix(".") {
                    return nil
                }
                return FolderTreeNode(url: childURL)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

            DispatchQueue.main.async {
                self?.children = subdirs
                self?.isLoading = false
            }
        }
    }

    static func == (lhs: FolderTreeNode, rhs: FolderTreeNode) -> Bool {
        lhs.url == rhs.url
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(url)
    }
}
