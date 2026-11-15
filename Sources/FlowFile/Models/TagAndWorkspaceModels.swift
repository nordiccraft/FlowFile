import AppKit
import Foundation
import SwiftUI

// MARK: - Feature 3: Native macOS Finder Color Tags

enum FinderColorTag: Int, CaseIterable, Identifiable, Codable {
    case red = 1
    case orange = 2
    case yellow = 3
    case green = 4
    case blue = 5
    case purple = 6
    case gray = 7

    var id: Int { rawValue }

    /// Shortcut number (Ctrl+1 ... Ctrl+7)
    var shortcutDigit: Int { rawValue }

    /// Index inside `NSWorkspace.shared.fileLabels` (macOS labelNumber: 1=Gray, 2=Green, 3=Purple, 4=Blue, 5=Yellow, 6=Red, 7=Orange)
    var macOSFileLabelIndex: Int {
        switch self {
        case .gray: return 1
        case .green: return 2
        case .purple: return 3
        case .blue: return 4
        case .yellow: return 5
        case .red: return 6
        case .orange: return 7
        }
    }

    var title: String {
        switch self {
        case .red: return tr("Rød", "Red")
        case .orange: return tr("Oransje", "Orange")
        case .yellow: return tr("Gul", "Yellow")
        case .green: return tr("Grønn", "Green")
        case .blue: return tr("Blå", "Blue")
        case .purple: return tr("Lilla", "Purple")
        case .gray: return tr("Grå", "Gray")
        }
    }

    /// Exact tag string expected by macOS Finder on the current system locale so Finder renders colored dots natively.
    var systemFinderTagName: String {
        let labels = NSWorkspace.shared.fileLabels
        let idx = macOSFileLabelIndex
        if idx >= 0 && idx < labels.count {
            let candidate = labels[idx].trimmingCharacters(in: .whitespacesAndNewlines)
            if !candidate.isEmpty {
                return candidate
            }
        }
        return fallbackNorwegianName
    }

    var fallbackNorwegianName: String {
        switch self {
        case .red: return "Rød"
        case .orange: return "Oransje"
        case .yellow: return "Gul"
        case .green: return "Grønn"
        case .blue: return "Blå"
        case .purple: return "Lilla"
        case .gray: return "Grå"
        }
    }

    var recognizedNamesLowercased: Set<String> {
        var set: Set<String> = [systemFinderTagName.lowercased()]
        switch self {
        case .red:
            set.formUnion(["rød", "raud", "red"])
        case .orange:
            set.formUnion(["oransje", "orange"])
        case .yellow:
            set.formUnion(["gul", "yellow"])
        case .green:
            set.formUnion(["grønn", "grøn", "green"])
        case .blue:
            set.formUnion(["blå", "blue"])
        case .purple:
            set.formUnion(["lilla", "purple"])
        case .gray:
            set.formUnion(["grå", "gray", "grey"])
        }
        return set
    }

    var swiftUIColor: Color {
        switch self {
        case .red: return Color(nsColor: .systemRed)
        case .orange: return Color(nsColor: .systemOrange)
        case .yellow: return Color(nsColor: .systemYellow)
        case .green: return Color(nsColor: .systemGreen)
        case .blue: return Color(nsColor: .systemBlue)
        case .purple: return Color(nsColor: .systemPurple)
        case .gray: return Color(nsColor: .systemGray)
        }
    }

    var nsColor: NSColor {
        switch self {
        case .red: return .systemRed
        case .orange: return .systemOrange
        case .yellow: return .systemYellow
        case .green: return .systemGreen
        case .blue: return .systemBlue
        case .purple: return .systemPurple
        case .gray: return .systemGray
        }
    }

    static func match(tagName: String) -> FinderColorTag? {
        let normalized = tagName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        return Self.allCases.first { $0.recognizedNamesLowercased.contains(normalized) }
    }

    static func fromMacOSLabelNumber(_ number: Int) -> FinderColorTag? {
        Self.allCases.first { $0.macOSFileLabelIndex == number }
    }

    static func extractColorTags(from tagNames: [String], labelNumber: Int? = nil) -> [FinderColorTag] {
        var seen = Set<FinderColorTag>()
        var ordered: [FinderColorTag] = []
        for raw in tagNames {
            if let matched = match(tagName: raw), !seen.contains(matched) {
                seen.insert(matched)
                ordered.append(matched)
            }
        }
        if ordered.isEmpty, let labelNumber, let fallback = fromMacOSLabelNumber(labelNumber) {
            ordered.append(fallback)
        }
        return ordered
    }
}

enum TagService {
    static func readTagNames(at url: URL) -> [String] {
        var fresh = URL(fileURLWithPath: url.standardizedFileURL.path)
        fresh.removeAllCachedResourceValues()
        let rv = try? fresh.resourceValues(forKeys: [.tagNamesKey])
        return rv?.tagNames ?? []
    }

    static func readColorTags(at url: URL) -> [FinderColorTag] {
        var fresh = URL(fileURLWithPath: url.standardizedFileURL.path)
        fresh.removeAllCachedResourceValues()
        let rv = try? fresh.resourceValues(forKeys: [.tagNamesKey, .labelNumberKey])
        return FinderColorTag.extractColorTags(
            from: rv?.tagNames ?? [],
            labelNumber: rv?.labelNumber
        )
    }

    static func toggleColorTag(_ colorTag: FinderColorTag, on urls: [URL]) throws {
        // If every target URL already has this color tag, remove it; otherwise add it to all targets.
        let allHaveTag = !urls.isEmpty && urls.allSatisfy { readColorTags(at: $0).contains(colorTag) }
        for url in urls {
            var existing = readTagNames(at: url)
            if allHaveTag {
                existing.removeAll { FinderColorTag.match(tagName: $0) == colorTag }
            } else if !existing.contains(where: { FinderColorTag.match(tagName: $0) == colorTag }) {
                existing.append(colorTag.systemFinderTagName)
            }
            try writeTagNames(existing, to: url)
        }
    }

    static func setSingleColorTag(_ colorTag: FinderColorTag?, on urls: [URL]) throws {
        for url in urls {
            // Preserve custom non-color Finder tags while replacing color tags
            var preserved = readTagNames(at: url).filter { FinderColorTag.match(tagName: $0) == nil }
            if let colorTag {
                preserved.append(colorTag.systemFinderTagName)
            }
            try writeTagNames(preserved, to: url)
        }
    }

    static func clearColorTags(on urls: [URL]) throws {
        try setSingleColorTag(nil, on: urls)
    }

    static func writeTagNames(_ tagNames: [String], to url: URL) throws {
        let nsURL = url.standardizedFileURL as NSURL
        try nsURL.setResourceValue(tagNames, forKey: .tagNamesKey)
    }

    /// Recursively finds files and folders carrying `colorTag` under the provided search roots.
    static func findItemsWithColorTag(
        _ colorTag: FinderColorTag,
        inRoots roots: [URL],
        showHidden: Bool,
        maxResults: Int = 400
    ) async -> [FileItem] {
        await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let prefetchKeys: [URLResourceKey] = [
                .isDirectoryKey,
                .isPackageKey,
                .isSymbolicLinkKey,
                .isAliasFileKey,
                .isHiddenKey,
                .fileSizeKey,
                .totalFileAllocatedSizeKey,
                .contentModificationDateKey,
                .creationDateKey,
                .labelNumberKey
            ]
            let keySet = Set(prefetchKeys + [.tagNamesKey])
            var visitedPaths = Set<String>()
            var matches: [FileItem] = []

            var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
            if !showHidden {
                options.insert(.skipsHiddenFiles)
            }

            for rawRoot in roots {
                if Task.isCancelled || matches.count >= maxResults { break }
                let root = rawRoot.standardizedFileURL
                guard fm.fileExists(atPath: root.path) else { continue }

                // Check root children recursively (skipping heavy system/build caches)
                guard let enumerator = fm.enumerator(
                    at: root,
                    includingPropertiesForKeys: prefetchKeys,
                    options: options,
                    errorHandler: { _, _ in true }
                ) else { continue }

                while let itemURL = enumerator.nextObject() as? URL {
                    if Task.isCancelled || matches.count >= maxResults { break }
                    let name = itemURL.lastPathComponent
                    if name == ".git" || name == "node_modules" || name == ".build" || name == "Library" {
                        enumerator.skipDescendants()
                        continue
                    }
                    let stdPath = itemURL.standardizedFileURL.path
                    guard !visitedPaths.contains(stdPath) else { continue }

                    guard let rv = try? itemURL.resourceValues(forKeys: keySet) else { continue }
                    let tags = FinderColorTag.extractColorTags(
                        from: rv.tagNames ?? [],
                        labelNumber: rv.labelNumber
                    )
                    if tags.contains(colorTag) {
                        visitedPaths.insert(stdPath)
                        matches.append(FileItem(url: itemURL, resourceValues: rv))
                    }
                }
            }

            return matches.sorted {
                ($0.modificationDate ?? .distantPast) > ($1.modificationDate ?? .distantPast)
            }
        }.value
    }
}

// MARK: - Feature 2: Tab Session Persistence & Named Saved Workspaces

struct TabSessionSnapshot: Codable, Equatable {
    var isDualPane: Bool
    var activePaneRaw: String
    var leftTabPaths: [String]
    var rightTabPaths: [String]
    var activeLeftIndex: Int
    var activeRightIndex: Int
}

struct SavedWorkspace: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var snapshot: TabSessionSnapshot
    var createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        snapshot: TabSessionSnapshot,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.snapshot = snapshot
        self.createdAt = createdAt
    }

    var summaryLabel: String {
        let totalTabs = snapshot.isDualPane
            ? (snapshot.leftTabPaths.count + snapshot.rightTabPaths.count)
            : snapshot.leftTabPaths.count
        let modeText = snapshot.isDualPane
            ? tr("2-panel", "2-pane")
            : tr("1-panel", "1-pane")
        return "\(modeText) • \(totalTabs) \(totalTabs == 1 ? tr("fane", "tab") : tr("faner", "tabs"))"
    }
}

enum TabSessionPersistence {
    static let lastSessionKey = "flowfile.lastTabSession.v1"
    static let savedWorkspacesKey = "flowfile.savedWorkspaces.v1"

    static func saveLastSession(_ snapshot: TabSessionSnapshot, defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: lastSessionKey)
        }
    }

    static func loadLastSession(defaults: UserDefaults = .standard) -> TabSessionSnapshot? {
        guard let data = defaults.data(forKey: lastSessionKey) else { return nil }
        return try? JSONDecoder().decode(TabSessionSnapshot.self, from: data)
    }

    static func saveWorkspaces(_ workspaces: [SavedWorkspace], defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(workspaces) {
            defaults.set(data, forKey: savedWorkspacesKey)
        }
    }

    static func loadWorkspaces(defaults: UserDefaults = .standard) -> [SavedWorkspace] {
        guard let data = defaults.data(forKey: savedWorkspacesKey),
              let decoded = try? JSONDecoder().decode([SavedWorkspace].self, from: data) else {
            return []
        }
        return decoded
    }

    /// Resolves persisted folder paths, keeping only existing directories and falling back to `fallbackURL` if none remain.
    static func validatedDirectoryURLs(from paths: [String], fallbackURL: URL) -> [URL] {
        let fm = FileManager.default
        var valid: [URL] = []
        for rawPath in paths {
            let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: trimmed, isDirectory: &isDir), isDir.boolValue {
                valid.append(URL(fileURLWithPath: trimmed).standardizedFileURL)
            }
        }
        return valid.isEmpty ? [fallbackURL.standardizedFileURL] : valid
    }
}
