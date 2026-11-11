import AppKit
import Foundation
import Observation
import SwiftUI

enum PaneID: String, CaseIterable {
    case left
    case right

    var opposite: PaneID {
        self == .left ? .right : .left
    }
}

enum ClipboardOperation {
    case copy
    case cut
}

enum ActivePrompt: Identifiable {
    case newFolder(inDirectory: URL)
    case newFile(inDirectory: URL)
    case rename(itemURL: URL, currentName: String)
    case confirmPermanentDelete(urls: [URL])

    var id: String {
        switch self {
        case .newFolder(let url): return "newFolder:\(url.path)"
        case .newFile(let url): return "newFile:\(url.path)"
        case .rename(let url, _): return "rename:\(url.path)"
        case .confirmPermanentDelete(let urls): return "permDelete:\(urls.count)"
        }
    }
}

@Observable
final class PaneState: Identifiable {
    let id: PaneID
    var tabs: [TabState]
    var activeTabID: UUID

    var activeTab: TabState {
        if let found = tabs.first(where: { $0.id == activeTabID }) {
            return found
        }
        return tabs[0]
    }

    init(id: PaneID, initialURL: URL, showHidden: Bool) {
        self.id = id
        let firstTab = TabState(initialURL: initialURL, showHidden: showHidden)
        self.tabs = [firstTab]
        self.activeTabID = firstTab.id
    }

    func addTab(at url: URL? = nil, showHidden: Bool) {
        let target = url ?? activeTab.currentURL
        let tab = TabState(initialURL: target, showHidden: showHidden)
        tabs.append(tab)
        activeTabID = tab.id
    }

    func closeTab(id tabID: UUID, showHidden: Bool) {
        guard tabs.count > 1 else { return }
        guard let idx = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs.remove(at: idx)
        if activeTabID == tabID {
            let safeIdx = min(idx, tabs.count - 1)
            activeTabID = tabs[safeIdx].id
        }
    }
}

@Observable
final class WorkspaceState {
    var leftPane: PaneState
    var rightPane: PaneState

    var isDualPane: Bool = false
    var activePaneID: PaneID = .left

    var isSidebarVisible: Bool = true
    var autoCollapseSidebarInDualPane: Bool {
        didSet { UserDefaults.standard.set(autoCollapseSidebarInDualPane, forKey: "autoCollapseSidebarInDualPane") }
    }
    private var sidebarVisibleBeforeDualPane: Bool = true

    var isInspectorVisible: Bool = false
    var isDropShelfVisible: Bool = false
    var isTerminalDrawerVisible: Bool = false

    var showHiddenFiles: Bool {
        didSet {
            UserDefaults.standard.set(showHiddenFiles, forKey: "showHiddenFiles")
            refreshAllTabs()
            for node in rootTreeNodes where node.isExpanded {
                node.reloadChildren(showHidden: showHiddenFiles)
            }
        }
    }

    /// false = Space opens Quick Look & Shift+Space marks + calculates folder size
    /// true = Space marks + calculates folder size & F3 opens Quick Look
    var swapSpaceShortcut: Bool {
        didSet { UserDefaults.standard.set(swapSpaceShortcut, forKey: "swapSpaceShortcut") }
    }

    var showFKeyBarAlways: Bool {
        didSet { UserDefaults.standard.set(showFKeyBarAlways, forKey: "showFKeyBarAlways") }
    }

    var appLanguage: AppLanguage {
        didSet {
            UserDefaults.standard.set(appLanguage.rawValue, forKey: "appLanguage")
            LocalizationCenter.shared.currentLanguage = appLanguage
            refreshStandardFavoriteTitles()
            refreshAllTabs()
        }
    }

    var isOnboardingVisible: Bool {
        get { tour.isActive }
        set {
            if newValue {
                startInteractiveTour()
            } else {
                finishInteractiveTour()
            }
        }
    }
    let tour = InteractiveTourState()
    let updateService = UpdateService()
    var isUpdateSheetVisible: Bool = false
    var hasFullDiskAccess: Bool = false
    var dismissedFDABanner: Bool = false
    private var dualPaneOpenedByCompare: Bool = false

    private static var onboardingDefaultsKey: String {
        let bundlePath = Bundle.main.bundleURL.standardizedFileURL.path
        return "hasCompletedOnboarding_v2_\(bundlePath)"
    }

    // Fase 2 & 3 Subsystems
    let transferQueue = TransferQueueManager()
    let terminalSession: TerminalSession
    var isMultiRenameVisible: Bool = false
    var multiRenameTargetItems: [FileItem] = []
    var lastBatchRename: RenameUndoRecord? = nil
    var isCompareActive: Bool = false

    // Cloud Storage & Smart Share Hub
    var cloudAccounts: [CloudAccountItem] = []
    var isShareHubVisible: Bool = false
    var shareTargetItems: [FileItem] = []

    var clipboardURLs: [URL] = []
    var clipboardOperation: ClipboardOperation? = nil

    var favorites: [FavoriteItem] = [] {
        didSet { saveFavorites() }
    }
    var volumes: [VolumeInfo] = []
    var rootTreeNodes: [FolderTreeNode] = []
    var recentFolders: [URL] = []

    var activePrompt: ActivePrompt? = nil
    var isCommandPaletteVisible: Bool = false
    var isSettingsVisible: Bool = false
    var addressBarFocusTrigger: Int = 0

    var statusBanner: String? = nil
    var alertErrorMessage: String? = nil

    var activePane: PaneState {
        activePaneID == .left ? leftPane : rightPane
    }

    var inactivePane: PaneState {
        activePaneID == .left ? rightPane : leftPane
    }

    var activeTab: TabState {
        activePane.activeTab
    }

    init() {
        let hidden = UserDefaults.standard.bool(forKey: "showHiddenFiles")
        let swapSpace = UserDefaults.standard.bool(forKey: "swapSpaceShortcut")
        let autoCollapse = UserDefaults.standard.object(forKey: "autoCollapseSidebarInDualPane") as? Bool ?? false
        let fKeyAlways = UserDefaults.standard.bool(forKey: "showFKeyBarAlways")
        let langRaw = UserDefaults.standard.string(forKey: "appLanguage") ?? AppLanguage.system.rawValue
        let resolvedLang = AppLanguage(rawValue: langRaw) ?? .system
        LocalizationCenter.shared.currentLanguage = resolvedLang

        self.showHiddenFiles = hidden
        self.swapSpaceShortcut = swapSpace
        self.autoCollapseSidebarInDualPane = autoCollapse
        self.showFKeyBarAlways = fKeyAlways
        self.appLanguage = resolvedLang
        self.hasFullDiskAccess = PermissionsService.hasFullDiskAccess()

        let homeURL = FileManager.default.homeDirectoryForCurrentUser

        // Start both panes in homeURL so macOS TCC never prompts for ~/Downloads before the user sees the Welcome & Full Disk Access setup!
        self.leftPane = PaneState(id: .left, initialURL: homeURL, showHidden: hidden)
        self.rightPane = PaneState(id: .right, initialURL: homeURL, showHidden: hidden)
        self.terminalSession = TerminalSession(initialDirectory: homeURL)

        loadFavorites()
        refreshStandardFavoriteTitles()
        refreshVolumesAndTree()
        recordRecentFolder(homeURL)

        if !UserDefaults.standard.bool(forKey: Self.onboardingDefaultsKey) {
            self.tour.isActive = true
            self.tour.currentStep = .welcomeSetup
        }

        if updateService.checkAutomaticallyOnLaunch {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await self?.updateService.checkForUpdates(silent: true)
            }
        }

        transferQueue.onJobFinished = { [weak self] createdURLs, destDir in
            guard let self else { return }
            self.refreshAllTabs()
            if self.activeTab.currentURL.standardizedFileURL == destDir.standardizedFileURL {
                self.activeTab.selectedURLs = Set(createdURLs)
            } else if self.isDualPane && self.inactivePane.activeTab.currentURL.standardizedFileURL == destDir.standardizedFileURL {
                self.inactivePane.activeTab.selectedURLs = Set(createdURLs)
            }
            self.showStatus("Overføring fullført (\(createdURLs.count) elementer)")
        }
    }

    // MARK: - Layout & Navigation

    func toggleDualPane() {
        if !isDualPane {
            sidebarVisibleBeforeDualPane = isSidebarVisible
            isDualPane = true
            if autoCollapseSidebarInDualPane && !tour.isActive {
                isSidebarVisible = false
            }
            if tour.isActive && tour.currentStep == .dualPaneToggle {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    if self?.tour.isActive == true && self?.tour.currentStep == .dualPaneToggle {
                        self?.goToTourStep(.folderCompareStart)
                    }
                }
            }
        } else {
            dualPaneOpenedByCompare = false
            isDualPane = false
            activePaneID = .left
            if isCompareActive {
                leftPane.activeTab.clearDiff()
                rightPane.activeTab.clearDiff()
                leftPane.activeTab.markedURLs.removeAll()
                rightPane.activeTab.markedURLs.removeAll()
                isCompareActive = false
            }
            if autoCollapseSidebarInDualPane {
                isSidebarVisible = sidebarVisibleBeforeDualPane
            }
        }
    }

    func tr(_ nb: String, _ en: String) -> String {
        appLanguage.resolvedIsNorwegian ? nb : en
    }

    func openOnboardingGuide() {
        startInteractiveTour()
    }

    func completeOnboarding() {
        finishInteractiveTour()
    }

    func startInteractiveTour() {
        refreshPermissionsStatus()
        clearDualPaneComparisonSilent()
        if isDualPane {
            isDualPane = false
            activePaneID = .left
        }
        isSidebarVisible = true
        isDropShelfVisible = false
        tour.resetDemoState()
        tour.currentStep = .welcomeSetup
        tour.isActive = true
    }

    func goToTourStep(_ step: TourStep) {
        withAnimation(.snappy(duration: 0.22)) {
            switch step {
            case .welcomeSetup:
                clearDualPaneComparisonSilent()
                isDualPane = false
                isSidebarVisible = true
                isDropShelfVisible = false
            case .copyPath:
                clearDualPaneComparisonSilent()
                isDualPane = false
                isSidebarVisible = true
                isDropShelfVisible = false
            case .sidebarAndCloud:
                isSidebarVisible = true
                isDropShelfVisible = false
            case .dualPaneToggle:
                clearDualPaneComparisonSilent()
                isDualPane = false
                isSidebarVisible = true
                isDropShelfVisible = false
            case .folderCompareStart:
                clearDualPaneComparisonSilent()
                if !isDualPane {
                    isDualPane = true
                }
                isDropShelfVisible = false
            case .folderCompareExit:
                if !isCompareActive {
                    runDualPaneComparison(silent: true)
                }
                isDropShelfVisible = false
            case .dropShelfPractice:
                clearDualPaneComparisonSilent()
                isDualPane = false
                activePaneID = .left
                isDropShelfVisible = true
            case .smartShareFinish:
                clearDualPaneComparisonSilent()
                isDualPane = false
                isDropShelfVisible = false
            }
            tour.currentStep = step
        }
    }

    func finishInteractiveTour() {
        UserDefaults.standard.set(true, forKey: Self.onboardingDefaultsKey)
        clearDualPaneComparisonSilent()
        isDropShelfVisible = false
        if isDualPane {
            isDualPane = false
            activePaneID = .left
        }
        isSidebarVisible = true
        tour.resetDemoState()
        tour.isActive = false
        showStatus(tr(
            "Omvisning fullført – FlowFile er klar til vanlig bruk!",
            "Tour complete – FlowFile is ready for normal use!"
        ))
    }

    func notifyDidCopyPath() {
        if tour.isActive && tour.currentStep == .copyPath {
            tour.didClickCopyPath = true
        }
    }

    private func clearDualPaneComparisonSilent() {
        leftPane.activeTab.clearDiff()
        rightPane.activeTab.clearDiff()
        leftPane.activeTab.markedURLs.removeAll()
        rightPane.activeTab.markedURLs.removeAll()
        dualPaneOpenedByCompare = false
        isCompareActive = false
    }

    @discardableResult
    func guardNotInTourSandbox() -> Bool {
        if tour.isSandboxActive {
            showStatus(tr(
                "Øvingsmodus aktiv: Ingen ekte filer flyttes, kopieres eller slettes",
                "Practice Mode active: No real files are moved, copied, or deleted"
            ))
            return false
        }
        return true
    }

    func refreshPermissionsStatus() {
        hasFullDiskAccess = PermissionsService.hasFullDiskAccess()
    }

    func openUpdateChecker() {
        isUpdateSheetVisible = true
        Task { @MainActor [weak self] in
            await self?.updateService.checkForUpdates(silent: false)
        }
    }

    func switchActivePane() {
        guard isDualPane else { return }
        activePaneID = activePaneID.opposite
        syncTerminalIfOpen()
        if !activeTab.isInsideArchive {
            QuickLookCoordinator.shared.updateSelectionIfVisible(Array(activeTab.selectedURLs))
        }
    }

    func navigateActiveTab(to url: URL) {
        activeTab.navigate(to: url, showHidden: showHiddenFiles)
        isCompareActive = false
        if !activeTab.isInsideArchive {
            recordRecentFolder(activeTab.currentURL)
            syncTerminalIfOpen()
        }
    }

    func openItem(_ item: FileItem, forceEnterPackage: Bool = false) {
        // Virtual archive browsing!
        if let entryPath = item.archiveEntryPath, let archiveURL = activeTab.archiveFileURL {
            if item.isDirectory {
                activeTab.navigateArchiveSubpath(entryPath, showHidden: showHiddenFiles)
            } else {
                do {
                    let tempFile = try ArchiveService.extractForPreview(archiveURL: archiveURL, entryPath: entryPath)
                    NSWorkspace.shared.open(tempFile)
                } catch {
                    alertErrorMessage = error.localizedDescription
                }
            }
            return
        }

        let destinationURL = item.navigationTargetURL

        // Entering .zip / .tar.gz archives (including via shortcuts!) directly as virtual folders!
        if !item.isNavigableFolder && ArchiveService.isSupportedArchive(destinationURL) {
            activeTab.enterArchive(destinationURL, showHidden: showHiddenFiles)
            showStatus("Åpnet arkiv som virtuell mappe – Backspace går ut igjen")
            return
        }

        if item.isNavigableFolder || (item.isDirectory && forceEnterPackage) {
            navigateActiveTab(to: destinationURL)
        } else {
            NSWorkspace.shared.open(destinationURL)
        }
    }

    func openSelectedItems() {
        let tab = activeTab
        let selected = tab.displayedItems.filter { tab.selectedURLs.contains($0.url) }
        guard !selected.isEmpty else { return }

        if selected.count == 1, let single = selected.first {
            openItem(single)
        } else {
            for item in selected where !item.isVirtualArchiveEntry {
                if item.isNavigableFolder {
                    activePane.addTab(at: item.navigationTargetURL, showHidden: showHiddenFiles)
                } else {
                    NSWorkspace.shared.open(item.navigationTargetURL)
                }
            }
        }
    }

    func focusAddressBar() {
        addressBarFocusTrigger &+= 1
    }

    func refreshAllTabs() {
        for tab in leftPane.tabs {
            tab.reload(showHidden: showHiddenFiles)
        }
        for tab in rightPane.tabs {
            tab.reload(showHidden: showHiddenFiles)
        }
        if isCompareActive && isDualPane {
            runDualPaneComparison(silent: true)
        }
        volumes = FileSystemService.mountedVolumes()
        cloudAccounts = CloudStorageService.discoverCloudAccounts()
    }

    func recordRecentFolder(_ url: URL) {
        let standardized = url.standardizedFileURL
        recentFolders.removeAll(where: { $0 == standardized })
        recentFolders.insert(standardized, at: 0)
        if recentFolders.count > 20 {
            recentFolders = Array(recentFolders.prefix(20))
        }
    }

    // MARK: - Fase 2: Multi-Rename Tool, Drop Shelf & Folder Compare

    func openMultiRenameTool() {
        guard !activeTab.isInsideArchive else {
            showStatus("Pakk ut filene først før masse-omdøping")
            return
        }
        let targets = activeTab.effectiveActionItems
        if targets.isEmpty {
            multiRenameTargetItems = activeTab.displayedItems
        } else {
            multiRenameTargetItems = targets
        }
        guard !multiRenameTargetItems.isEmpty else {
            showStatus("Ingen filer i mappen å gi nytt navn til")
            return
        }
        isMultiRenameVisible = true
    }

    func undoLastBatchRename() {
        guard let record = lastBatchRename else { return }
        do {
            try MultiRenameService.undoBatchRename(record)
            lastBatchRename = nil
            refreshAllTabs()
            showStatus("Angret masse-omdøping (\(record.pairs.count) filer tilbakeført)")
        } catch {
            alertErrorMessage = error.localizedDescription
        }
    }

    func addSelectedToDropShelf() {
        guard !activeTab.isInsideArchive else { return }
        let urls = activeTab.effectiveActionURLs
        guard !urls.isEmpty else { return }
        let added = transferQueue.addToDropShelf(urls)
        isDropShelfVisible = true
        showStatus("La \(added) element(er) i Drop-hyllen")
    }

    func transferDropShelfToActiveFolder(move: Bool) {
        guard guardNotInTourSandbox() else { return }
        guard !activeTab.isInsideArchive else { return }
        let items = transferQueue.dropShelfItems
        guard !items.isEmpty else { return }
        let dest = activeTab.currentURL
        transferQueue.enqueue(
            operation: move ? .move : .copy,
            urls: items,
            to: dest
        )
        if move {
            transferQueue.clearDropShelf()
        }
        showStatus("\(move ? "Flytter" : "Kopierer") \(items.count) element(er) fra Drop-hyllen...")
    }

    func toggleDualPaneComparison() {
        if isCompareActive {
            clearDualPaneComparison()
        } else {
            runDualPaneComparison()
        }
    }

    func runDualPaneComparison(silent: Bool = false) {
        if !isDualPane {
            dualPaneOpenedByCompare = true
            toggleDualPane()
        }
        let lTab = leftPane.activeTab
        let rTab = rightPane.activeTab

        if tour.isSandboxActive {
            // Safe simulated comparison badges without marking real files for action!
            var demoLeft: [URL: FileDiffStatus] = [:]
            for (idx, item) in lTab.displayedItems.prefix(4).enumerated() {
                switch idx {
                case 0: demoLeft[item.url] = .onlyHere
                case 1: demoLeft[item.url] = .newerHere
                default: demoLeft[item.url] = .identical
                }
            }
            if demoLeft.isEmpty {
                let dummy = URL(fileURLWithPath: "/tmp/demo-compare")
                demoLeft[dummy] = .onlyHere
            }
            var demoRight: [URL: FileDiffStatus] = [:]
            for (idx, item) in rTab.displayedItems.prefix(3).enumerated() {
                demoRight[item.url] = idx == 0 ? .olderHere : .identical
            }
            lTab.diffStatuses = demoLeft
            rTab.diffStatuses = demoRight
            isCompareActive = true
            if tour.currentStep == .folderCompareStart {
                withAnimation(.snappy(duration: 0.22)) {
                    tour.currentStep = .folderCompareExit
                }
            }
            return
        }

        let result = FolderCompareService.compare(
            leftItems: lTab.allItems,
            rightItems: rTab.allItems
        )
        lTab.diffStatuses = result.leftStatuses
        rTab.diffStatuses = result.rightStatuses

        // Auto-mark missing and newer items (Total Commander Shift+F2 ergonomics!)
        lTab.markedURLs = Set(result.leftStatuses.compactMap { url, status in
            (status == .onlyHere || status == .newerHere) ? url : nil
        })
        rTab.markedURLs = Set(result.rightStatuses.compactMap { url, status in
            (status == .onlyHere || status == .newerHere) ? url : nil
        })

        isCompareActive = true
        if !silent {
            showStatus(tr(
                "Mappe-sammenligning: \(result.differencesCount) ulikheter funnet (trykk Esc eller ⇧⌘K for å avslutte)",
                "Folder Compare: \(result.differencesCount) differences found (press Esc or ⇧⌘K to exit)"
            ))
        }
    }

    func toggleHideIdenticalInDiff() {
        let next = !leftPane.activeTab.hideIdenticalInDiff
        leftPane.activeTab.hideIdenticalInDiff = next
        rightPane.activeTab.hideIdenticalInDiff = next
    }

    func clearDualPaneComparison() {
        let wasExitTourStep = tour.isActive && tour.currentStep == .folderCompareExit
        leftPane.activeTab.clearDiff()
        rightPane.activeTab.clearDiff()
        leftPane.activeTab.markedURLs.removeAll()
        rightPane.activeTab.markedURLs.removeAll()
        let shouldReturnToSinglePane = dualPaneOpenedByCompare
        dualPaneOpenedByCompare = false
        isCompareActive = false
        if shouldReturnToSinglePane && isDualPane {
            toggleDualPane()
        }
        showStatus(tr("Mappe-sammenligning avsluttet", "Folder comparison closed"))
        if wasExitTourStep {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 250_000_000)
                self?.goToTourStep(.dropShelfPractice)
            }
        }
    }

    // MARK: - Fase 3: Archive Helpers & Synchronized Terminal

    func extractSelectedArchiveHere() {
        guard guardNotInTourSandbox() else { return }
        let tab = activeTab
        if let archURL = tab.archiveFileURL {
            let parentDir = archURL.deletingLastPathComponent()
            do {
                let folder = try ArchiveService.extractEntireArchive(archURL, in: parentDir)
                tab.exitArchive(showHidden: showHiddenFiles)
                tab.selectedURLs = [folder]
                showStatus("Pakket ut til «\(folder.lastPathComponent)»")
            } catch {
                alertErrorMessage = error.localizedDescription
            }
            return
        }

        guard let item = tab.primarySelectedItem, ArchiveService.isSupportedArchive(item.url) else { return }
        do {
            let folder = try ArchiveService.extractEntireArchive(item.url, in: tab.currentURL)
            refreshAllTabs()
            tab.selectedURLs = [folder]
            showStatus("Pakket ut til «\(folder.lastPathComponent)»")
        } catch {
            alertErrorMessage = error.localizedDescription
        }
    }

    func compressSelectedToZip() {
        guard guardNotInTourSandbox() else { return }
        guard !activeTab.isInsideArchive else { return }
        let urls = activeTab.effectiveActionURLs
        guard !urls.isEmpty else { return }
        do {
            let zipURL = try ArchiveService.compressToZip(urls: urls, in: activeTab.currentURL)
            activeTab.markedURLs.removeAll()
            refreshAllTabs()
            activeTab.selectedURLs = [zipURL]
            showStatus("Opprettet arkivet «\(zipURL.lastPathComponent)»")
        } catch {
            alertErrorMessage = error.localizedDescription
        }
    }

    func toggleTerminalDrawer() {
        isTerminalDrawerVisible.toggle()
        if isTerminalDrawerVisible {
            terminalSession.startIfNeeded(in: activeTab.currentURL)
        }
    }

    func syncTerminalIfOpen() {
        if isTerminalDrawerVisible && !activeTab.isInsideArchive {
            terminalSession.syncDirectory(to: activeTab.currentURL)
        }
    }

    // MARK: - Quick Look & Space Key

    func handlePrimarySpacePress() {
        if swapSpaceShortcut {
            activeTab.toggleMarkOnSelectedAndAdvance()
        } else {
            triggerQuickLook()
        }
    }

    func handleShiftSpacePress() {
        if swapSpaceShortcut {
            triggerQuickLook()
        } else {
            activeTab.toggleMarkOnSelectedAndAdvance()
        }
    }

    func triggerQuickLook() {
        if let archiveURL = activeTab.archiveFileURL {
            guard let item = activeTab.primarySelectedItem,
                  !item.isDirectory,
                  let entryPath = item.archiveEntryPath else {
                return
            }
            do {
                let previewURL = try ArchiveService.extractForPreview(archiveURL: archiveURL, entryPath: entryPath)
                QuickLookCoordinator.shared.togglePreview(for: [previewURL])
            } catch {
                alertErrorMessage = error.localizedDescription
            }
            return
        }

        let urls = activeTab.effectiveActionURLs
        guard !urls.isEmpty else { return }
        QuickLookCoordinator.shared.togglePreview(for: urls)
    }

    func openSelectedInEditor() {
        guard !activeTab.isInsideArchive else {
            triggerQuickLook()
            return
        }
        let urls = activeTab.effectiveActionURLs
        guard !urls.isEmpty else { return }
        for url in urls {
            if let textAppURL = NSWorkspace.shared.urlForApplication(toOpen: URL(fileURLWithPath: "/tmp/sample.txt")) {
                NSWorkspace.shared.open(
                    [url],
                    withApplicationAt: textAppURL,
                    configuration: NSWorkspace.OpenConfiguration()
                )
            } else {
                NSWorkspace.shared.open(url)
            }
        }
    }

    // MARK: - Clipboard & Queued File Operations

    func isItemCut(_ url: URL) -> Bool {
        clipboardOperation == .cut && clipboardURLs.contains(url.standardizedFileURL)
    }

    func copySelected() {
        if let archiveURL = activeTab.archiveFileURL {
            let entryPaths = activeTab.effectiveActionItems.compactMap(\.archiveEntryPath)
            guard !entryPaths.isEmpty else { return }
            let tempClipDir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("FlowFileArchiveClipboard", isDirectory: true)
            try? FileManager.default.removeItem(at: tempClipDir)
            try? FileManager.default.createDirectory(at: tempClipDir, withIntermediateDirectories: true)
            if let extracted = try? ArchiveService.extractEntries(
                from: archiveURL,
                entryPaths: entryPaths,
                currentSubpath: activeTab.archiveSubpath,
                to: tempClipDir
            ), !extracted.isEmpty {
                clipboardURLs = extracted
                clipboardOperation = .copy
                writeToSystemPasteboard(extracted)
                showStatus("Pakket ut og kopierte \(extracted.count) arkiv-element(er) til utklippstavlen")
            }
            return
        }

        let urls = activeTab.effectiveActionURLs.map(\.standardizedFileURL)
        guard !urls.isEmpty else { return }
        clipboardURLs = urls
        clipboardOperation = .copy
        writeToSystemPasteboard(urls)
        showStatus("Kopierte \(urls.count) element(er) til utklippstavlen")
    }

    func cutSelected() {
        guard !activeTab.isInsideArchive else { return }
        let urls = activeTab.effectiveActionURLs.map(\.standardizedFileURL)
        guard !urls.isEmpty else { return }
        clipboardURLs = urls
        clipboardOperation = .cut
        writeToSystemPasteboard(urls)
        showStatus("Klippet ut \(urls.count) element(er) – trykk Cmd+V for å flytte")
    }

    func pasteIntoActiveFolder() {
        guard guardNotInTourSandbox() else { return }
        guard !activeTab.isInsideArchive else {
            showStatus("Kan ikke lime inn direkte i et arkiv")
            return
        }
        let targetDir = activeTab.currentURL
        var urlsToProcess = clipboardURLs
        let op = clipboardOperation ?? .copy

        if urlsToProcess.isEmpty {
            if let pbURLs = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [
                .urlReadingFileURLsOnly: true
            ]) as? [URL], !pbURLs.isEmpty {
                urlsToProcess = pbURLs
            }
        }

        guard !urlsToProcess.isEmpty else { return }

        if op == .cut {
            transferQueue.enqueue(operation: .move, urls: urlsToProcess, to: targetDir)
            clipboardURLs.removeAll()
            clipboardOperation = nil
        } else {
            transferQueue.enqueue(operation: .copy, urls: urlsToProcess, to: targetDir)
        }
    }

    /// Total Commander F5: Copy selected/marked items (or archive entries!) directly to opposite pane
    func copySelectedToOppositePane() {
        guard guardNotInTourSandbox() else { return }
        guard isDualPane else {
            showStatus("Slå på Dual-Pane (Cmd+D) for å kopiere til motsatt panel")
            return
        }
        guard !inactivePane.activeTab.isInsideArchive else {
            showStatus("Motsatt panel viser et arkiv – velg en vanlig mappe som mål")
            return
        }
        let dest = inactivePane.activeTab.currentURL

        // Extracting directly out of a virtual archive to the opposite pane via F5!
        if let archiveURL = activeTab.archiveFileURL {
            let entryPaths = activeTab.effectiveActionItems.compactMap(\.archiveEntryPath)
            guard !entryPaths.isEmpty else { return }
            do {
                let extracted = try ArchiveService.extractEntries(
                    from: archiveURL,
                    entryPaths: entryPaths,
                    currentSubpath: activeTab.archiveSubpath,
                    to: dest
                )
                activeTab.markedURLs.removeAll()
                refreshAllTabs()
                inactivePane.activeTab.selectedURLs = Set(extracted)
                showStatus("Pakket ut \(extracted.count) element(er) direkte til \(dest.lastPathComponent)")
            } catch {
                alertErrorMessage = error.localizedDescription
            }
            return
        }

        let urls = activeTab.effectiveActionURLs
        guard !urls.isEmpty else { return }
        activeTab.markedURLs.removeAll()
        transferQueue.enqueue(operation: .copy, urls: urls, to: dest)
    }

    /// Total Commander F6: Move selected/marked items directly to opposite pane
    func moveSelectedToOppositePane() {
        guard guardNotInTourSandbox() else { return }
        guard isDualPane else {
            showStatus("Slå på Dual-Pane (Cmd+D) for å flytte til motsatt panel")
            return
        }
        guard !activeTab.isInsideArchive && !inactivePane.activeTab.isInsideArchive else {
            showStatus("Kan ikke flytte til/fra et komprimert arkiv – bruk F5 for å kopiere ut")
            return
        }
        let urls = activeTab.effectiveActionURLs
        guard !urls.isEmpty else { return }
        let dest = inactivePane.activeTab.currentURL
        activeTab.markedURLs.removeAll()
        transferQueue.enqueue(operation: .move, urls: urls, to: dest)
    }

    func promptNewFolder() {
        guard guardNotInTourSandbox() else { return }
        guard !activeTab.isInsideArchive else { return }
        activePrompt = .newFolder(inDirectory: activeTab.currentURL)
    }

    func promptNewFile() {
        guard guardNotInTourSandbox() else { return }
        guard !activeTab.isInsideArchive else { return }
        activePrompt = .newFile(inDirectory: activeTab.currentURL)
    }

    func promptRenameSelected() {
        guard guardNotInTourSandbox() else { return }
        guard !activeTab.isInsideArchive else { return }
        let targets = activeTab.effectiveActionItems
        if targets.count > 1 {
            openMultiRenameTool()
            return
        }
        guard let item = activeTab.primarySelectedItem else { return }
        activePrompt = .rename(itemURL: item.url, currentName: item.name)
    }

    func trashSelected() {
        guard guardNotInTourSandbox() else { return }
        guard !activeTab.isInsideArchive else { return }
        let urls = activeTab.effectiveActionURLs
        guard !urls.isEmpty else { return }
        do {
            try FileSystemService.trashItems(urls)
            activeTab.markedURLs.removeAll()
            refreshAllTabs()
            showStatus(tr("La \(urls.count) element(er) i Papirkurven", "Moved \(urls.count) item(s) to Trash"))
        } catch {
            alertErrorMessage = error.localizedDescription
        }
    }

    func promptPermanentDeleteSelected() {
        guard guardNotInTourSandbox() else { return }
        guard !activeTab.isInsideArchive else { return }
        let urls = activeTab.effectiveActionURLs
        guard !urls.isEmpty else { return }
        activePrompt = .confirmPermanentDelete(urls: urls)
    }

    func executePermanentDelete(_ urls: [URL]) {
        guard guardNotInTourSandbox() else { return }
        do {
            try FileSystemService.permanentlyDeleteItems(urls)
            activeTab.markedURLs.removeAll()
            refreshAllTabs()
            showStatus("Slettet \(urls.count) element(er) permanent")
        } catch {
            alertErrorMessage = error.localizedDescription
        }
    }

    func copyPathOfSelectedOrCurrent() {
        let path: String
        if let item = activeTab.primarySelectedItem, !item.isVirtualArchiveEntry {
            path = item.url.path
        } else {
            path = activeTab.currentURL.path
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
        showStatus("Kopierte sti: \(path)")
    }

    func openTerminalInActiveFolder() {
        let folderPath = activeTab.currentURL.path
        if let terminalURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
            let config = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([URL(fileURLWithPath: folderPath)], withApplicationAt: terminalURL, configuration: config)
        }
    }

    // MARK: - Favorites & Sidebar

    func isPinned(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return favorites.contains(where: { $0.path == path })
    }

    func togglePin(_ url: URL) {
        let standardized = url.standardizedFileURL
        if let idx = favorites.firstIndex(where: { $0.path == standardized.path }) {
            favorites.remove(at: idx)
            showStatus("Fjernet «\(standardized.lastPathComponent)» fra Hurtigtilgang")
        } else {
            let fav = FavoriteItem(
                title: standardized.lastPathComponent,
                path: standardized.path,
                systemImage: "folder.fill"
            )
            favorites.append(fav)
            showStatus("Festet «\(standardized.lastPathComponent)» til Hurtigtilgang")
        }
    }

    func refreshVolumesAndTree() {
        volumes = FileSystemService.mountedVolumes()
        cloudAccounts = CloudStorageService.discoverCloudAccounts()
        let homeURL = FileManager.default.homeDirectoryForCurrentUser
        let homeNode = FolderTreeNode(url: homeURL, name: "\(homeURL.lastPathComponent) (Hjem)")
        homeNode.isExpanded = true
        homeNode.loadChildrenIfNeeded(showHidden: showHiddenFiles)

        let rootNode = FolderTreeNode(url: URL(fileURLWithPath: "/"))
        var nodes = [homeNode, rootNode]

        for account in cloudAccounts {
            nodes.append(FolderTreeNode(url: account.rootURL, name: account.displayName))
        }

        for vol in volumes where vol.url.path != "/" {
            nodes.append(FolderTreeNode(url: vol.url, name: vol.name))
        }
        rootTreeNodes = nodes
    }

    // MARK: - Smart Sharing, Cloud Actions & Shortcut Helpers

    func openShareHub() {
        if tour.isSandboxActive {
            tour.didPreviewShareHub = true
            let demoItems = [
                FileItem(
                    virtualArchiveURL: URL(fileURLWithPath: "/tmp/Budsjett_2026.xlsx"),
                    name: "Budsjett_2026.xlsx",
                    isDirectory: false,
                    size: 1_420_000,
                    modificationDate: Date(),
                    archiveEntryPath: "demo"
                ),
                FileItem(
                    virtualArchiveURL: URL(fileURLWithPath: "/tmp/Prosjektbilde.heic"),
                    name: "Prosjektbilde.heic",
                    isDirectory: false,
                    size: 3_200_000,
                    modificationDate: Date(),
                    archiveEntryPath: "demo"
                )
            ]
            shareTargetItems = demoItems
            isShareHubVisible = true
            return
        }
        guard !activeTab.isInsideArchive else {
            showStatus(tr("Pakk ut filen først før deling", "Extract the file first before sharing"))
            return
        }
        let targets = activeTab.effectiveActionItems
        guard !targets.isEmpty else {
            showStatus(tr("Velg minst én fil eller mappe å dele", "Select at least one file or folder to share"))
            return
        }
        shareTargetItems = targets
        isShareHubVisible = true
    }

    func revealOriginalOfShortcut(_ item: FileItem) {
        guard let target = item.resolvedTargetURL else { return }
        let parentDir = target.deletingLastPathComponent()
        activeTab.navigate(to: parentDir, showHidden: showHiddenFiles, selecting: target)
        showStatus("Gikk til originalplasseringen: \(parentDir.path)")
    }

    func createShortcutInOppositePane() {
        guard guardNotInTourSandbox() else { return }
        guard isDualPane else {
            showStatus("Slå på Dual-Pane (Cmd+D) for å opprette snarvei i motsatt panel")
            return
        }
        guard !activeTab.isInsideArchive && !inactivePane.activeTab.isInsideArchive else { return }
        let items = activeTab.effectiveActionItems
        guard !items.isEmpty else { return }
        let dest = inactivePane.activeTab.currentURL

        do {
            var created: [URL] = []
            for item in items {
                let link = try FileSystemService.createShortcutSymlink(to: item.navigationTargetURL, in: dest)
                created.append(link)
            }
            refreshAllTabs()
            inactivePane.activeTab.selectedURLs = Set(created)
            showStatus("Opprettet \(created.count) snarvei(er) i \(dest.lastPathComponent)")
        } catch {
            alertErrorMessage = error.localizedDescription
        }
    }

    func evictSelectedCloudItems() {
        guard guardNotInTourSandbox() else { return }
        let urls = activeTab.effectiveActionURLs
        guard !urls.isEmpty else { return }
        do {
            try CloudStorageService.evictLocalCopy(at: urls)
            refreshAllTabs()
            showStatus("Frigjorde lokal plass for \(urls.count) element(er) – ligger trygt i skyen")
        } catch {
            alertErrorMessage = "Kunne ikke frigjøre lokal kopi: \(error.localizedDescription)"
        }
    }

    func downloadSelectedCloudItems() {
        guard guardNotInTourSandbox() else { return }
        let urls = activeTab.effectiveActionURLs
        guard !urls.isEmpty else { return }
        do {
            try CloudStorageService.downloadLocalCopy(at: urls)
            refreshAllTabs()
            showStatus("Startet nedlasting til Macen for \(urls.count) sky-element(er)")
        } catch {
            alertErrorMessage = "Kunne ikke starte nedlasting: \(error.localizedDescription)"
        }
    }

    private func loadFavorites() {
        if let data = UserDefaults.standard.data(forKey: "flowfile.favorites"),
           let decoded = try? JSONDecoder().decode([FavoriteItem].self, from: data),
           !decoded.isEmpty {
            favorites = decoded
            return
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
        var defaults: [FavoriteItem] = [
            FavoriteItem(title: "Hjem", path: home.path, systemImage: "house.fill"),
            FavoriteItem(title: "Skrivebord", path: home.appendingPathComponent("Desktop").path, systemImage: "menubar.dock.rectangle"),
            FavoriteItem(title: "Nedlastinger", path: home.appendingPathComponent("Downloads").path, systemImage: "arrow.down.circle.fill"),
            FavoriteItem(title: "Dokumenter", path: home.appendingPathComponent("Documents").path, systemImage: "doc.fill"),
            FavoriteItem(title: "Programmer", path: "/Applications", systemImage: "app.badge.fill")
        ]
        let projectsPath = home.appendingPathComponent("Projects").path
        if FileManager.default.fileExists(atPath: projectsPath) {
            defaults.append(FavoriteItem(title: "Projects", path: projectsPath, systemImage: "hammer.fill"))
        }
        favorites = defaults
    }

    private func refreshStandardFavoriteTitles() {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let mapping: [String: (String, String)] = [
            home: ("Hjem", "Home"),
            "\(home)/Desktop": ("Skrivebord", "Desktop"),
            "\(home)/Downloads": ("Nedlastinger", "Downloads"),
            "\(home)/Documents": ("Dokumenter", "Documents"),
            "/Applications": ("Programmer", "Applications")
        ]
        var updated = favorites
        var changed = false
        for i in updated.indices {
            if let pair = mapping[URL(fileURLWithPath: updated[i].path).standardizedFileURL.path] {
                let desired = tr(pair.0, pair.1)
                if updated[i].title != desired {
                    updated[i].title = desired
                    changed = true
                }
            }
        }
        if changed {
            favorites = updated
        }
    }

    private func saveFavorites() {
        if let data = try? JSONEncoder().encode(favorites) {
            UserDefaults.standard.set(data, forKey: "flowfile.favorites")
        }
    }

    private func writeToSystemPasteboard(_ urls: [URL]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls as [NSURL])
    }

    func showStatus(_ text: String) {
        statusBanner = text
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_200_000_000)
            if self?.statusBanner == text {
                self?.statusBanner = nil
            }
        }
    }
}
