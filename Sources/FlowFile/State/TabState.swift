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
    var diffStatuses: [URL: FileDiffStatus] = [:]
    var hideIdenticalInDiff: Bool = false

    var allItems: [FileItem] = []
    var filterQuery: String = ""
    var isFilterBarVisible: Bool = false

    var sortColumn: SortColumn = .name
    var sortAscending: Bool = true
    var viewMode: PaneViewMode = .details

    var selectedURLs: Set<URL> = []
    var markedURLs: Set<URL> = []
    var calculatedFolderSizes: [URL: Int64] = [:]
    var errorMessage: String? = nil

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

        return FileSystemService.sortItems(
            candidates,
            by: sortColumn,
            ascending: sortAscending,
            folderSizes: calculatedFolderSizes
        )
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
        reload(showHidden: showHidden, selectFirstIfEmpty: true)
        setupWatcher(showHidden: showHidden)
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
        setupWatcher(showHidden: showHidden)
    }

    // MARK: - Standard Directory Navigation

    func navigate(
        to targetURL: URL,
        showHidden: Bool,
        recordHistory: Bool = true,
        selecting childToSelect: URL? = nil
    ) {
        let standardized = CloudStorageService.resolvePossibleShortcut(at: targetURL) ?? targetURL.standardizedFileURL

        if ArchiveService.isSupportedArchive(standardized) {
            currentURL = standardized.deletingLastPathComponent()
            enterArchive(standardized, showHidden: showHidden)
            return
        }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: standardized.path, isDirectory: &isDir),
              isDir.boolValue else {
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
        setupWatcher(showHidden: showHidden)
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
        setupWatcher(showHidden: showHidden)
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
        setupWatcher(showHidden: showHidden)
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

    private func setupWatcher(showHidden: Bool) {
        watcher?.stop()
        guard !isInsideArchive else { return }
        let watchedURL = currentURL
        watcher = DirectoryWatcher(url: watchedURL) { [weak self] in
            guard let self, !self.isInsideArchive, self.currentURL == watchedURL else { return }
            self.reload(showHidden: showHidden)
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
