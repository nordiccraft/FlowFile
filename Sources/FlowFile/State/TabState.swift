import AppKit
import Foundation
import Observation

@Observable
final class TabState: Identifiable {
    let id = UUID()
    var currentURL: URL
    var backStack: [URL] = []
    var forwardStack: [URL] = []

    // Virtual Archive state (Fase 3: browse .zip / .tar.gz like folders)
    var archiveFileURL: URL? = nil
    var archiveSubpath: String = ""

    // Git awareness state (Fase 3)
    var gitBranch: String? = nil
    var gitBadges: [URL: GitFileBadge] = [:]

    // Dual-Pane Folder Comparison state (Fase 2)
    var diffStatuses: [URL: FileDiffStatus] = [:] {
        didSet { cachedDisplayedItems = nil }
    }
    var hideIdenticalInDiff: Bool = false {
        didSet { cachedDisplayedItems = nil }
    }

    var allItems: [FileItem] = [] {
        didSet { cachedDisplayedItems = nil }
    }
    var filterQuery: String = "" {
        didSet { cachedDisplayedItems = nil }
    }
    var isFilterBarVisible: Bool = false

    var sortColumn: SortColumn = .name {
        didSet { cachedDisplayedItems = nil }
    }
    var sortAscending: Bool = true {
        didSet { cachedDisplayedItems = nil }
    }
    var viewMode: PaneViewMode = .details

    var selectedURLs: Set<URL> = []
    var markedURLs: Set<URL> = []
    var calculatedFolderSizes: [URL: Int64] = [:] {
        didSet { cachedDisplayedItems = nil }
    }
    var errorMessage: String? = nil

    private(set) var currentShowHidden: Bool
    @ObservationIgnored private var cachedDisplayedItems: [FileItem]? = nil
    private var watcher: DirectoryWatcher?
    private var gitRefreshGeneration: Int = 0

    var isInsideArchive: Bool {
        archiveFileURL != nil
    }

    var title: String {
        if let archiveURL = archiveFileURL {
            if archiveSubpath.isEmpty {
                return archiveURL.lastPathComponent
            }
            let leaf = URL(fileURLWithPath: archiveSubpath).lastPathComponent
            return leaf
        }
        if currentURL.path == "/" {
            return FileManager.default.displayName(atPath: "/")
        }
        return currentURL.lastPathComponent
    }

    var displayPathString: String {
        if let archiveURL = archiveFileURL {
            return archiveSubpath.isEmpty
                ? "\(archiveURL.path) (Arkiv)"
                : "\(archiveURL.path)/\(archiveSubpath)"
        }
        return currentURL.path
    }

    var canGoBack: Bool { !backStack.isEmpty || isInsideArchive }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var canGoUp: Bool { isInsideArchive || currentURL.path != "/" }

    var displayedItems: [FileItem] {
        // Touch tracked @Observable properties in O(1) so SwiftUI observation remains subscribed on cache hits
        _ = (
            allItems.count,
            filterQuery,
            sortColumn,
            sortAscending,
            hideIdenticalInDiff,
            diffStatuses.count,
            calculatedFolderSizes.count
        )
        if let cached = cachedDisplayedItems {
            return cached
        }

        var candidates = allItems

        if hideIdenticalInDiff && !diffStatuses.isEmpty {
            candidates = candidates.filter { diffStatuses[$0.url] != .identical }
        }

        let trimmed = filterQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            candidates = candidates.filter { item in
                fuzzyMatch(query: trimmed, in: item.name)
            }
        }

        let sorted = FileSystemService.sortItems(
            candidates,
            by: sortColumn,
            ascending: sortAscending,
            folderSizes: calculatedFolderSizes
        )
        cachedDisplayedItems = sorted
        return sorted
    }

    var effectiveActionItems: [FileItem] {
        let items = displayedItems
        if !markedURLs.isEmpty {
            return items.filter { markedURLs.contains($0.url) }
        }
        return items.filter { selectedURLs.contains($0.url) }
    }

    /// Returns marked items if any are marked (Total Commander style), otherwise selected items.
    var effectiveActionURLs: [URL] {
        effectiveActionItems.map(\.url)
    }

    var primarySelectedItem: FileItem? {
        guard let firstURL = selectedURLs.first else { return nil }
        return displayedItems.first(where: { $0.url == firstURL })
            ?? allItems.first(where: { $0.url == firstURL })
    }

    init(initialURL: URL, showHidden: Bool) {
        self.currentURL = initialURL.standardizedFileURL
        self.currentShowHidden = showHidden
        reload(showHidden: showHidden, selectFirstIfEmpty: true)
        setupWatcher()
    }

    // MARK: - Archive Virtual Folder Navigation

    func enterArchive(_ archiveURL: URL, showHidden: Bool) {
        archiveFileURL = archiveURL.standardizedFileURL
        archiveSubpath = ""
        filterQuery = ""
        isFilterBarVisible = false
        markedURLs.removeAll()
        clearDiff()
        watcher?.stop()
        reload(showHidden: showHidden, selectFirstIfEmpty: true)
    }

    func navigateArchiveSubpath(_ subpath: String, showHidden: Bool) {
        guard archiveFileURL != nil else { return }
        archiveSubpath = subpath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        filterQuery = ""
        isFilterBarVisible = false
        markedURLs.removeAll()
        reload(showHidden: showHidden, selectFirstIfEmpty: true)
    }

    func exitArchive(showHidden: Bool) {
        guard let archURL = archiveFileURL else { return }
        archiveFileURL = nil
        archiveSubpath = ""
        filterQuery = ""
        isFilterBarVisible = false
        markedURLs.removeAll()
        reload(showHidden: showHidden, preferredSelection: archURL, selectFirstIfEmpty: true)
        setupWatcher()
    }

    // MARK: - Standard Directory Navigation

    func navigate(
        to targetURL: URL,
        showHidden: Bool,
        recordHistory: Bool = true,
        selecting childToSelect: URL? = nil
    ) {
        let standardized = CloudStorageService.resolvePossibleShortcut(at: targetURL) ?? targetURL.standardizedFileURL

        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: standardized.path, isDirectory: &isDir)

        // Check directory status BEFORE archive suffix so folders named e.g. `project.tar` or `backup.zip` open as folders!
        if exists && !isDir.boolValue && ArchiveService.isSupportedArchive(standardized) {
            currentURL = standardized.deletingLastPathComponent()
            enterArchive(standardized, showHidden: showHidden)
            return
        }

        guard exists && isDir.boolValue else {
            NSWorkspace.shared.open(standardized)
            return
        }

        archiveFileURL = nil
        archiveSubpath = ""

        if standardized != currentURL && recordHistory {
            backStack.append(currentURL)
            forwardStack.removeAll()
        }

        currentURL = standardized
        filterQuery = ""
        isFilterBarVisible = false
        markedURLs.removeAll()
        clearDiff()
        errorMessage = nil

        reload(showHidden: showHidden, preferredSelection: childToSelect, selectFirstIfEmpty: true)
        setupWatcher()
    }

    func goBack(showHidden: Bool) {
        if isInsideArchive {
            goUp(showHidden: showHidden)
            return
        }
        guard let previous = backStack.popLast() else { return }
        let leaving = currentURL
        forwardStack.append(leaving)
        currentURL = previous
        filterQuery = ""
        isFilterBarVisible = false
        markedURLs.removeAll()
        clearDiff()
        reload(showHidden: showHidden, preferredSelection: leaving, selectFirstIfEmpty: true)
        setupWatcher()
    }

    func goForward(showHidden: Bool) {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(currentURL)
        currentURL = next
        archiveFileURL = nil
        archiveSubpath = ""
        filterQuery = ""
        isFilterBarVisible = false
        markedURLs.removeAll()
        clearDiff()
        reload(showHidden: showHidden, selectFirstIfEmpty: true)
        setupWatcher()
    }

    func goUp(showHidden: Bool) {
        if isInsideArchive {
            if archiveSubpath.isEmpty {
                exitArchive(showHidden: showHidden)
            } else {
                let parts = archiveSubpath.split(separator: "/")
                let parentSub = parts.dropLast().joined(separator: "/")
                navigateArchiveSubpath(parentSub, showHidden: showHidden)
            }
            return
        }

        guard canGoUp else { return }
        let childWeLeft = currentURL
        let parent = currentURL.deletingLastPathComponent()
        navigate(to: parent, showHidden: showHidden, recordHistory: true, selecting: childWeLeft)
    }

    func reload(
        showHidden: Bool,
        preferredSelection: URL? = nil,
        selectFirstIfEmpty: Bool = false
    ) {
        currentShowHidden = showHidden
        do {
            let loaded: [FileItem]
            if let archiveURL = archiveFileURL {
                loaded = try ArchiveService.listVirtualDirectory(
                    archiveURL: archiveURL,
                    subpath: archiveSubpath,
                    showHidden: showHidden
                )
                gitBranch = nil
                gitBadges = [:]
            } else {
                loaded = try FileSystemService.listDirectory(at: currentURL, showHidden: showHidden)
                refreshGitStatusAsync(for: currentURL)
            }

            allItems = loaded
            errorMessage = nil

            let validURLs = Set(loaded.map(\.url))
            markedURLs = markedURLs.intersection(validURLs)

            if let preferred = preferredSelection?.standardizedFileURL, validURLs.contains(preferred) {
                selectedURLs = [preferred]
            } else {
                selectedURLs = selectedURLs.intersection(validURLs)
                if selectedURLs.isEmpty && selectFirstIfEmpty, let first = displayedItems.first {
                    selectedURLs = [first.url]
                }
            }

            if !isInsideArchive {
                QuickLookCoordinator.shared.updateSelectionIfVisible(Array(selectedURLs))
            }
        } catch {
            allItems = []
            selectedURLs = []
            errorMessage = error.localizedDescription
        }
    }

    func clearDiff() {
        diffStatuses.removeAll()
        hideIdenticalInDiff = false
    }

    func toggleSort(column: SortColumn) {
        if sortColumn == column {
            sortAscending.toggle()
        } else {
            sortColumn = column
            sortAscending = (column == .size || column == .dateModified) ? false : true
        }
    }

    /// Total Commander mark + calculate folder size + step down one row
    func toggleMarkOnSelectedAndAdvance() {
        let items = displayedItems
        guard !items.isEmpty else { return }

        let targetItem: FileItem
        if let selected = selectedURLs.first,
           let found = items.first(where: { $0.url == selected }) {
            targetItem = found
        } else {
            targetItem = items[0]
        }

        if markedURLs.contains(targetItem.url) {
            markedURLs.remove(targetItem.url)
        } else {
            markedURLs.insert(targetItem.url)
        }

        if !isInsideArchive && targetItem.isNavigableFolder && calculatedFolderSizes[targetItem.url] == nil {
            let folderURL = targetItem.url
            Task { @MainActor [weak self] in
                let bytes = await FileSystemService.calculateFolderSize(at: folderURL)
                self?.calculatedFolderSizes[folderURL] = bytes
            }
        }

        if let currentIndex = items.firstIndex(where: { $0.url == targetItem.url }),
           currentIndex + 1 < items.count {
            let nextURL = items[currentIndex + 1].url
            selectedURLs = [nextURL]
            if !isInsideArchive {
                QuickLookCoordinator.shared.updateSelectionIfVisible([nextURL])
            }
        }
    }

    private func refreshGitStatusAsync(for folderURL: URL) {
        gitRefreshGeneration &+= 1
        let gen = gitRefreshGeneration
        Task { @MainActor [weak self] in
            let snapshot = await GitStatusService.inspectDirectory(folderURL)
            guard let self, self.gitRefreshGeneration == gen, !self.isInsideArchive else { return }
            self.gitBranch = snapshot?.branchName
            self.gitBadges = snapshot?.badgesByURL ?? [:]
        }
    }

    private func setupWatcher() {
        watcher?.stop()
        guard !isInsideArchive else { return }
        let watchedURL = currentURL
        watcher = DirectoryWatcher(url: watchedURL) { [weak self] in
            guard let self, !self.isInsideArchive, self.currentURL == watchedURL else { return }
            self.reload(showHidden: self.currentShowHidden)
        }
    }

    private func fuzzyMatch(query: String, in candidate: String) -> Bool {
        if candidate.localizedCaseInsensitiveContains(query) {
            return true
        }
        let lowerCandidate = candidate.lowercased()
        let lowerQuery = query.lowercased()
        var idx = lowerCandidate.startIndex
        for ch in lowerQuery {
            guard let found = lowerCandidate[idx...].firstIndex(of: ch) else {
                return false
            }
            idx = lowerCandidate.index(after: found)
        }
        return true
    }
}
