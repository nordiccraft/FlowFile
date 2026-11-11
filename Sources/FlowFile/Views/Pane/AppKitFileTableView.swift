import AppKit
import SwiftUI

final class FlowNSTableView: NSTableView {
    var onKeyPressHandler: ((NSEvent) -> Bool)?
    var onBuildContextMenu: ((Int) -> NSMenu?)?
    var onBecomeActivePane: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onBecomeActivePane?()
        super.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        onBecomeActivePane?()
        super.rightMouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if let handler = onKeyPressHandler, handler(event) {
            return
        }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let clicked = row(at: point)
        return onBuildContextMenu?(clicked)
    }
}

struct AppKitFileTableView: NSViewRepresentable {
    let pane: PaneState
    let tab: TabState
    let workspace: WorkspaceState

    func makeCoordinator() -> Coordinator {
        Coordinator(pane: pane, tab: tab, workspace: workspace)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .controlBackgroundColor

        let tableView = FlowNSTableView()
        tableView.style = .fullWidth
        tableView.rowHeight = 27
        tableView.intercellSpacing = NSSize(width: 8, height: 1)
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tableView.backgroundColor = .controlBackgroundColor
        tableView.gridStyleMask = []

        // Columns: Navn, Status (Git / Diff / Sky), Endelse, Størrelse, Endret, Type
        let columnsSpec: [(String, String, CGFloat, CGFloat, CGFloat, SortColumn?)] = [
            (SortColumn.name.rawValue, SortColumn.name.title, 260, 140, 2000, .name),
            ("status", "Status", 82, 60, 130, nil),
            (SortColumn.ext.rawValue, SortColumn.ext.title, 66, 50, 140, .ext),
            (SortColumn.size.rawValue, SortColumn.size.title, 94, 75, 180, .size),
            (SortColumn.dateModified.rawValue, SortColumn.dateModified.title, 130, 110, 220, .dateModified),
            (SortColumn.kind.rawValue, SortColumn.kind.title, 125, 80, 280, .kind)
        ]

        for (id, title, width, minW, maxW, sortCol) in columnsSpec {
            let tc = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            tc.title = title
            tc.width = width
            tc.minWidth = minW
            tc.maxWidth = maxW
            if let sortCol {
                tc.sortDescriptorPrototype = NSSortDescriptor(key: sortCol.rawValue, ascending: true)
            }
            tableView.addTableColumn(tc)
        }

        let coordinator = context.coordinator
        coordinator.tableView = tableView

        tableView.delegate = coordinator
        tableView.dataSource = coordinator
        tableView.target = coordinator
        tableView.doubleAction = #selector(Coordinator.handleDoubleClick(_:))

        tableView.registerForDraggedTypes([.fileURL])
        tableView.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        tableView.setDraggingSourceOperationMask([.copy], forLocal: false)

        tableView.onBecomeActivePane = { [weak coordinator] in
            coordinator?.activateThisPane()
        }
        tableView.onKeyPressHandler = { [weak coordinator] event in
            coordinator?.handleKeyDown(event) ?? false
        }
        tableView.onBuildContextMenu = { [weak coordinator] clickedRow in
            coordinator?.buildContextMenu(forClickedRow: clickedRow)
        }

        scrollView.documentView = tableView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.pane = pane
        coordinator.tab = tab
        coordinator.workspace = workspace

        let newItems = tab.displayedItems
        let newMarked = tab.markedURLs
        let newFolderSizes = tab.calculatedFolderSizes
        let newGitBadges = tab.gitBadges
        let newDiffStatuses = tab.diffStatuses
        let cutSet: Set<URL> = workspace.clipboardOperation == .cut ? Set(workspace.clipboardURLs) : []

        let needsReload = coordinator.items != newItems
            || coordinator.lastMarked != newMarked
            || coordinator.lastFolderSizes != newFolderSizes
            || coordinator.lastGitBadges != newGitBadges
            || coordinator.lastDiffStatuses != newDiffStatuses
            || coordinator.lastCutSet != cutSet

        coordinator.items = newItems
        coordinator.lastMarked = newMarked
        coordinator.lastFolderSizes = newFolderSizes
        coordinator.lastGitBadges = newGitBadges
        coordinator.lastDiffStatuses = newDiffStatuses
        coordinator.lastCutSet = cutSet

        guard let tableView = coordinator.tableView else { return }

        coordinator.updateHeaderIndicators(on: tableView)

        if needsReload {
            coordinator.isSyncingSelection = true
            tableView.reloadData()
            coordinator.isSyncingSelection = false
        }

        coordinator.syncSelectionToTable(tableView)

        if workspace.activePaneID == pane.id && coordinator.lastActivePaneID != pane.id {
            coordinator.lastActivePaneID = pane.id
            if !tab.isFilterBarVisible {
                DispatchQueue.main.async {
                    if let window = tableView.window,
                       !(window.firstResponder is NSTextView) {
                        window.makeFirstResponder(tableView)
                    }
                }
            }
        } else {
            coordinator.lastActivePaneID = workspace.activePaneID
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var pane: PaneState
        var tab: TabState
        var workspace: WorkspaceState
        weak var tableView: FlowNSTableView?

        var items: [FileItem] = []
        var lastMarked: Set<URL> = []
        var lastFolderSizes: [URL: Int64] = [:]
        var lastGitBadges: [URL: GitFileBadge] = [:]
        var lastDiffStatuses: [URL: FileDiffStatus] = [:]
        var lastCutSet: Set<URL> = []
        var lastActivePaneID: PaneID? = nil
        var isSyncingSelection: Bool = false

        init(pane: PaneState, tab: TabState, workspace: WorkspaceState) {
            self.pane = pane
            self.tab = tab
            self.workspace = workspace
            self.items = tab.displayedItems
        }

        func activateThisPane() {
            if workspace.activePaneID != pane.id {
                workspace.activePaneID = pane.id
            }
        }

        func updateHeaderIndicators(on tableView: NSTableView) {
            for col in tableView.tableColumns {
                if let sortCol = SortColumn(rawValue: col.identifier.rawValue) {
                    if col.title != sortCol.title {
                        col.title = sortCol.title
                    }
                } else if col.identifier.rawValue == "status" {
                    let desired = tr("Status", "Status")
                    if col.title != desired {
                        col.title = desired
                    }
                }
                if col.identifier.rawValue == tab.sortColumn.rawValue {
                    let indicatorName = tab.sortAscending ? "NSAscendingSortIndicator" : "NSDescendingSortIndicator"
                    tableView.setIndicatorImage(NSImage(named: indicatorName), in: col)
                    tableView.highlightedTableColumn = col
                } else {
                    tableView.setIndicatorImage(nil, in: col)
                }
            }
        }

        func syncSelectionToTable(_ tableView: NSTableView) {
            let desiredIndexes = NSMutableIndexSet()
            for (idx, item) in items.enumerated() where tab.selectedURLs.contains(item.url) {
                desiredIndexes.add(idx)
            }

            if tableView.selectedRowIndexes != (desiredIndexes as IndexSet) {
                isSyncingSelection = true
                tableView.selectRowIndexes(desiredIndexes as IndexSet, byExtendingSelection: false)
                if let firstIdx = desiredIndexes.firstIndex as Int?, firstIdx != NSNotFound, firstIdx < items.count {
                    tableView.scrollRowToVisible(firstIdx)
                }
                isSyncingSelection = false
            }
        }

        // MARK: NSTableViewDataSource

        func numberOfRows(in tableView: NSTableView) -> Int {
            items.count
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard let first = tableView.sortDescriptors.first,
                  let key = first.key,
                  let col = SortColumn(rawValue: key) else {
                return
            }
            activateThisPane()
            if tab.sortColumn == col {
                tab.sortAscending = first.ascending
            } else {
                tab.sortColumn = col
                tab.sortAscending = first.ascending
            }
        }

        // Drag & Drop support
        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
            guard row >= 0 && row < items.count else { return nil }
            return items[row].url as NSURL
        }

        func tableView(
            _ tableView: NSTableView,
            validateDrop info: any NSDraggingInfo,
            proposedRow row: Int,
            proposedDropOperation dropOperation: NSTableView.DropOperation
        ) -> NSDragOperation {
            let moveMask = NSEvent.modifierFlags.contains(.option) ? NSDragOperation.copy : NSDragOperation.move
            if dropOperation == .on, row >= 0 && row < items.count, items[row].isNavigableFolder {
                return moveMask
            }
            tableView.setDropRow(-1, dropOperation: .on)
            return moveMask
        }

        func tableView(
            _ tableView: NSTableView,
            acceptDrop info: any NSDraggingInfo,
            row: Int,
            dropOperation: NSTableView.DropOperation
        ) -> Bool {
            guard workspace.guardNotInTourSandbox() else { return false }
            guard let urls = info.draggingPasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]
            ) as? [URL], !urls.isEmpty else {
                return false
            }

            let targetDirectory: URL
            if dropOperation == .on, row >= 0 && row < items.count, items[row].isNavigableFolder {
                targetDirectory = items[row].url
            } else {
                targetDirectory = tab.currentURL
            }

            let copyInsteadOfMove = NSEvent.modifierFlags.contains(.option)
            do {
                if copyInsteadOfMove {
                    try FileSystemService.copyItems(urls, toDirectory: targetDirectory)
                    workspace.showStatus("Kopierte \(urls.count) element(er) til \(targetDirectory.lastPathComponent)")
                } else {
                    try FileSystemService.moveItems(urls, toDirectory: targetDirectory)
                    workspace.showStatus("Flyttet \(urls.count) element(er) til \(targetDirectory.lastPathComponent)")
                }
                workspace.refreshAllTabs()
                return true
            } catch {
                workspace.alertErrorMessage = error.localizedDescription
                return false
            }
        }

        // MARK: NSTableViewDelegate

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard row >= 0 && row < items.count,
                  let colID = tableColumn?.identifier else {
                return nil
            }
            let item = items[row]
            let isMarked = tab.markedURLs.contains(item.url)
            let isCut = workspace.isItemCut(item.url)

            let cellID = NSUserInterfaceItemIdentifier("Cell_\(colID.rawValue)")
            let cell: NSTableCellView
            if let reused = tableView.makeView(withIdentifier: cellID, owner: nil) as? NSTableCellView {
                cell = reused
            } else {
                cell = makeCell(identifier: cellID, columnID: colID.rawValue)
            }

            configureCell(cell, columnID: colID.rawValue, item: item, isMarked: isMarked, isCut: isCut)
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isSyncingSelection, let tableView else { return }
            activateThisPane()
            let indexes = tableView.selectedRowIndexes
            var urls = Set<URL>()
            for idx in indexes where idx >= 0 && idx < items.count {
                urls.insert(items[idx].url)
            }
            tab.selectedURLs = urls
            QuickLookCoordinator.shared.updateSelectionIfVisible(Array(urls))
        }

        @objc func handleDoubleClick(_ sender: Any?) {
            guard let tableView else { return }
            activateThisPane()
            let clicked = tableView.clickedRow
            guard clicked >= 0 && clicked < items.count else { return }
            workspace.openItem(items[clicked])
        }

        // MARK: Keyboard Handling (Windows Explorer + Total Commander + macOS Quick Look)

        func handleKeyDown(_ event: NSEvent) -> Bool {
            activateThisPane()
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let hasCmd = flags.contains(.command)
            let hasShift = flags.contains(.shift)
            let hasOpt = flags.contains(.option)
            let hasCtrl = flags.contains(.control)

            switch event.keyCode {
            case 36, 76: // Return or Keypad Enter -> Open (NEVER rename!)
                if !hasCmd && !hasOpt && !hasCtrl {
                    workspace.openSelectedItems()
                    return true
                }

            case 51: // Backspace
                if hasCmd {
                    if hasShift {
                        workspace.promptPermanentDeleteSelected()
                    } else {
                        workspace.trashSelected()
                    }
                    return true
                } else if !hasOpt && !hasCtrl {
                    if !tab.filterQuery.isEmpty {
                        tab.filterQuery.removeLast()
                        if tab.filterQuery.isEmpty {
                            tab.isFilterBarVisible = false
                        }
                    } else {
                        tab.goUp(showHidden: workspace.showHiddenFiles)
                        workspace.syncTerminalIfOpen()
                    }
                    return true
                }

            case 117: // Forward Delete key (Windows/PC keyboard Delete!)
                if hasShift {
                    workspace.promptPermanentDeleteSelected()
                } else {
                    workspace.trashSelected()
                }
                return true

            case 49: // Space
                if !hasCmd && !hasOpt && !hasCtrl {
                    if hasShift {
                        workspace.handleShiftSpacePress()
                    } else {
                        workspace.handlePrimarySpacePress()
                    }
                    return true
                }

            case 48: // Tab -> Switch active pane in Dual-Pane
                if workspace.isDualPane && !hasCmd && !hasOpt && !hasCtrl {
                    workspace.switchActivePane()
                    return true
                }

            case 53: // Escape -> Clear filter, exit folder comparison, or clear TC marks
                if !tab.filterQuery.isEmpty || tab.isFilterBarVisible {
                    tab.filterQuery = ""
                    tab.isFilterBarVisible = false
                    return true
                } else if workspace.isCompareActive {
                    workspace.clearDualPaneComparison()
                    return true
                } else if !tab.markedURLs.isEmpty {
                    tab.markedURLs.removeAll()
                    return true
                }

            case 120: // F2 -> Rename
                workspace.promptRenameSelected()
                return true

            case 99: // F3 -> Quick Look
                workspace.triggerQuickLook()
                return true

            case 118: // F4 -> Open in Editor
                workspace.openSelectedInEditor()
                return true

            case 96: // F5 -> Copy to opposite pane
                workspace.copySelectedToOppositePane()
                return true

            case 97: // F6 -> Move to opposite pane
                workspace.moveSelectedToOppositePane()
                return true

            case 98: // F7 -> New Folder
                workspace.promptNewFolder()
                return true

            case 100: // F8 -> Trash (or Shift+F8 permanent delete)
                if hasShift {
                    workspace.promptPermanentDeleteSelected()
                } else {
                    workspace.trashSelected()
                }
                return true

            case 126: // Up Arrow with Option -> Go Up
                if hasOpt && !hasCmd {
                    tab.goUp(showHidden: workspace.showHiddenFiles)
                    return true
                }

            case 125: // Down Arrow with Cmd -> Open (Mac muscle memory bonus)
                if hasCmd && !hasOpt {
                    workspace.openSelectedItems()
                    return true
                }

            case 123: // Left Arrow with Option/Cmd -> Back
                if (hasOpt || hasCmd) && !hasShift {
                    tab.goBack(showHidden: workspace.showHiddenFiles)
                    return true
                }

            case 124: // Right Arrow with Option/Cmd -> Forward
                if (hasOpt || hasCmd) && !hasShift {
                    tab.goForward(showHidden: workspace.showHiddenFiles)
                    return true
                }

            default:
                break
            }

            // Instant Type-to-Filter when typing normal characters!
            if !hasCmd && !hasCtrl && !hasOpt,
               let chars = event.characters,
               chars.count == 1,
               let scalar = chars.unicodeScalars.first,
               CharacterSet.alphanumerics.union(.punctuationCharacters).contains(scalar) {
                tab.isFilterBarVisible = true
                tab.filterQuery.append(chars)
                if let firstMatch = tab.displayedItems.first {
                    tab.selectedURLs = [firstMatch.url]
                }
                return true
            }

            return false
        }

        // MARK: Context Menu

        func buildContextMenu(forClickedRow clickedRow: Int) -> NSMenu {
            if clickedRow >= 0 && clickedRow < items.count {
                let clickedURL = items[clickedRow].url
                if !tab.selectedURLs.contains(clickedURL) {
                    tab.selectedURLs = [clickedURL]
                }
            }

            let menu = NSMenu()
            let clickedItem: FileItem? = (clickedRow >= 0 && clickedRow < items.count) ? items[clickedRow] : nil

            if let item = clickedItem {
                addItem(to: menu, title: "Åpne", action: #selector(ctxOpen))
                if item.isNavigableFolder {
                    addItem(to: menu, title: "Åpne i ny fane", action: #selector(ctxOpenInNewTab))
                    if workspace.isDualPane {
                        addItem(to: menu, title: "Åpne i motsatt panel", action: #selector(ctxOpenInOppositePane))
                    }
                    let pinTitle = workspace.isPinned(item.navigationTargetURL) ? "Fjern fra Hurtigtilgang" : "Fest til Hurtigtilgang"
                    addItem(to: menu, title: pinTitle, action: #selector(ctxTogglePin))
                } else if item.isPackage {
                    addItem(to: menu, title: "Vis pakkeinnhold som mappe", action: #selector(ctxEnterPackage))
                }

                if item.isShortcut {
                    addItem(to: menu, title: "Gå til originalens plassering i FlowFile", action: #selector(ctxRevealShortcutOriginal))
                }

                if !tab.isInsideArchive {
                    addItem(to: menu, title: "Del... (⇧⌘S)", action: #selector(ctxShare))
                }

                addItem(to: menu, title: "Quick Look (Space)", action: #selector(ctxQuickLook))
                addItem(to: menu, title: "Åpne i tekstredigerer (F4)", action: #selector(ctxOpenEditor))
                menu.addItem(.separator())

                if item.cloudState != .none {
                    addItem(to: menu, title: tr("Behold på denne Macen (Last ned lokalt nå)", "Keep on This Mac (Download now)"), action: #selector(ctxCloudDownload))
                    addItem(to: menu, title: tr("Frigjør lokal plass (Behold kun i skyen)", "Free Up Local Space (Online-only)"), action: #selector(ctxCloudEvict))
                    menu.addItem(.separator())
                }

                addItem(to: menu, title: "Marker / Beregn mappestørrelse (Shift+Space)", action: #selector(ctxMarkAndSize))
                if !tab.isInsideArchive {
                    addItem(to: menu, title: "Legg i Drop-hylle (⇧⌘D)", action: #selector(ctxAddToDropShelf))
                    addItem(to: menu, title: "Klipp ut (Cmd+X)", action: #selector(ctxCut))
                }
                addItem(to: menu, title: "Kopier (Cmd+C)", action: #selector(ctxCopy))
                addItem(to: menu, title: "Kopier full sti", action: #selector(ctxCopyPath))

                if workspace.isDualPane {
                    menu.addItem(.separator())
                    addItem(to: menu, title: "Kopier til motsatt panel (F5)", action: #selector(ctxCopyOpposite))
                    if !tab.isInsideArchive {
                        addItem(to: menu, title: "Flytt til motsatt panel (F6)", action: #selector(ctxMoveOpposite))
                        addItem(to: menu, title: "Lag snarvei i motsatt panel", action: #selector(ctxCreateShortcutOpposite))
                    }
                }

                if ArchiveService.isSupportedArchive(item.url) && !tab.isInsideArchive {
                    menu.addItem(.separator())
                    addItem(to: menu, title: "Pakk ut hele arkivet her", action: #selector(ctxExtractArchive))
                } else if !tab.isInsideArchive {
                    menu.addItem(.separator())
                    addItem(to: menu, title: "Komprimer valgte til .zip", action: #selector(ctxCompressZip))
                }

                if !tab.isInsideArchive {
                    menu.addItem(.separator())
                    addItem(to: menu, title: "Gi nytt navn... (F2)", action: #selector(ctxRename))
                    addItem(to: menu, title: "Multi-Rename Tool... (Cmd+M)", action: #selector(ctxMultiRename))
                    addItem(to: menu, title: "Flytt til Papirkurv (Delete)", action: #selector(ctxTrash))
                    addItem(to: menu, title: "Slett permanent... (Shift+Delete)", action: #selector(ctxPermDelete))
                }
                menu.addItem(.separator())
            }

            if tab.isInsideArchive {
                addItem(to: menu, title: "Pakk ut hele arkivet til mappe", action: #selector(ctxExtractArchive))
                addItem(to: menu, title: "Gå ut av arkiv (Backspace)", action: #selector(ctxExitArchive))
            } else {
                addItem(to: menu, title: "Lim inn her (Cmd+V)", action: #selector(ctxPaste))
                addItem(to: menu, title: "Ny mappe... (F7)", action: #selector(ctxNewFolder))
                addItem(to: menu, title: "Ny tom fil...", action: #selector(ctxNewFile))
            }
            menu.addItem(.separator())
            addItem(to: menu, title: "Vis/skjul innebygd Terminal-skuff (Ctrl+`)", action: #selector(ctxToggleEmbeddedTerminal))
            addItem(to: menu, title: "Åpne i macOS Terminal", action: #selector(ctxOpenTerminal))
            addItem(to: menu, title: "Vis i macOS Finder", action: #selector(ctxRevealInFinder))

            return menu
        }

        private func addItem(to menu: NSMenu, title: String, action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }

        @objc private func ctxOpen() { workspace.openSelectedItems() }
        @objc private func ctxOpenInNewTab() {
            if let item = tab.primarySelectedItem {
                pane.addTab(at: item.navigationTargetURL, showHidden: workspace.showHiddenFiles)
            }
        }
        @objc private func ctxOpenInOppositePane() {
            if let item = tab.primarySelectedItem {
                workspace.inactivePane.activeTab.navigate(to: item.navigationTargetURL, showHidden: workspace.showHiddenFiles)
            }
        }
        @objc private func ctxTogglePin() {
            if let item = tab.primarySelectedItem {
                workspace.togglePin(item.navigationTargetURL)
            }
        }
        @objc private func ctxRevealShortcutOriginal() {
            if let item = tab.primarySelectedItem {
                workspace.revealOriginalOfShortcut(item)
            }
        }
        @objc private func ctxShare() { workspace.openShareHub() }
        @objc private func ctxCloudDownload() { workspace.downloadSelectedCloudItems() }
        @objc private func ctxCloudEvict() { workspace.evictSelectedCloudItems() }
        @objc private func ctxCreateShortcutOpposite() { workspace.createShortcutInOppositePane() }
        @objc private func ctxEnterPackage() {
            if let item = tab.primarySelectedItem {
                workspace.openItem(item, forceEnterPackage: true)
            }
        }
        @objc private func ctxQuickLook() { workspace.triggerQuickLook() }
        @objc private func ctxOpenEditor() { workspace.openSelectedInEditor() }
        @objc private func ctxMarkAndSize() { tab.toggleMarkOnSelectedAndAdvance() }
        @objc private func ctxCut() { workspace.cutSelected() }
        @objc private func ctxCopy() { workspace.copySelected() }
        @objc private func ctxPaste() { workspace.pasteIntoActiveFolder() }
        @objc private func ctxCopyPath() { workspace.copyPathOfSelectedOrCurrent() }
        @objc private func ctxCopyOpposite() { workspace.copySelectedToOppositePane() }
        @objc private func ctxMoveOpposite() { workspace.moveSelectedToOppositePane() }
        @objc private func ctxRename() { workspace.promptRenameSelected() }
        @objc private func ctxMultiRename() { workspace.openMultiRenameTool() }
        @objc private func ctxAddToDropShelf() { workspace.addSelectedToDropShelf() }
        @objc private func ctxExtractArchive() { workspace.extractSelectedArchiveHere() }
        @objc private func ctxCompressZip() { workspace.compressSelectedToZip() }
        @objc private func ctxExitArchive() { tab.exitArchive(showHidden: workspace.showHiddenFiles) }
        @objc private func ctxToggleEmbeddedTerminal() { workspace.toggleTerminalDrawer() }
        @objc private func ctxTrash() { workspace.trashSelected() }
        @objc private func ctxPermDelete() { workspace.promptPermanentDeleteSelected() }
        @objc private func ctxNewFolder() { workspace.promptNewFolder() }
        @objc private func ctxNewFile() { workspace.promptNewFile() }
        @objc private func ctxOpenTerminal() { workspace.openTerminalInActiveFolder() }
        @objc private func ctxRevealInFinder() {
            let urls = tab.effectiveActionURLs
            if !urls.isEmpty {
                NSWorkspace.shared.activateFileViewerSelecting(urls)
            } else {
                NSWorkspace.shared.open(tab.currentURL)
            }
        }

        // MARK: Cell Construction

        private func makeCell(identifier: NSUserInterfaceItemIdentifier, columnID: String) -> NSTableCellView {
            let cell = NSTableCellView()
            cell.identifier = identifier

            let textField = NSTextField(labelWithString: "")
            textField.translatesAutoresizingMaskIntoConstraints = false
            textField.lineBreakMode = .byTruncatingMiddle
            textField.maximumNumberOfLines = 1
            cell.textField = textField

            if columnID == SortColumn.name.rawValue {
                cell.addSubview(textField)
                let imageView = NSImageView()
                imageView.translatesAutoresizingMaskIntoConstraints = false
                imageView.imageScaling = .scaleProportionallyUpOrDown
                cell.addSubview(imageView)
                cell.imageView = imageView

                NSLayoutConstraint.activate([
                    imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                    imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    imageView.widthAnchor.constraint(equalToConstant: 18),
                    imageView.heightAnchor.constraint(equalToConstant: 18),

                    textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6),
                    textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                    textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
                ])
            } else if columnID == "status" {
                let imageView = NSImageView()
                imageView.translatesAutoresizingMaskIntoConstraints = false
                imageView.imageScaling = .scaleProportionallyUpOrDown
                cell.imageView = imageView

                let stack = NSStackView(views: [imageView, textField])
                stack.orientation = .horizontal
                stack.alignment = .centerY
                stack.spacing = 5
                stack.detachesHiddenViews = true
                stack.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(stack)

                NSLayoutConstraint.activate([
                    imageView.widthAnchor.constraint(equalToConstant: 19),
                    imageView.heightAnchor.constraint(equalToConstant: 19),
                    stack.centerXAnchor.constraint(equalTo: cell.centerXAnchor),
                    stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    stack.leadingAnchor.constraint(greaterThanOrEqualTo: cell.leadingAnchor, constant: 2),
                    stack.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -2)
                ])
            } else {
                cell.addSubview(textField)
                NSLayoutConstraint.activate([
                    textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                    textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                    textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
                ])
            }

            return cell
        }

        private func configureCell(
            _ cell: NSTableCellView,
            columnID: String,
            item: FileItem,
            isMarked: Bool,
            isCut: Bool
        ) {
            guard let tf = cell.textField else { return }
            cell.alphaValue = isCut ? 0.45 : (item.isHidden ? 0.72 : 1.0)

            let markedColor = NSColor.systemOrange

            switch columnID {
            case SortColumn.name.rawValue:
                let gitBadge = tab.gitBadges[item.url]
                cell.alphaValue = isCut ? 0.45 : (gitBadge == .ignored ? 0.55 : (item.isHidden ? 0.72 : 1.0))
                cell.imageView?.image = FileIconCache.shared.icon(for: item)
                let baseDisplay = item.isShortcut ? "\(item.name) ↪" : item.name
                tf.stringValue = isMarked ? "✓ \(baseDisplay)" : baseDisplay
                tf.font = .systemFont(ofSize: 12.5, weight: isMarked ? .semibold : (item.isNavigableFolder ? .medium : .regular))
                tf.textColor = isMarked ? markedColor : .labelColor
                tf.alignment = .left

            case "status":
                var parts: [String] = []
                var tooltips: [String] = []
                var badgeColor: NSColor = .secondaryLabelColor

                if item.cloudState != .none {
                    tooltips.append(item.cloudState.descriptionText)
                    let baseCfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
                    switch item.cloudState {
                    case .cloudOnly:
                        let cfg = baseCfg.applying(NSImage.SymbolConfiguration(paletteColors: [.systemBlue]))
                        cell.imageView?.image = NSImage(systemSymbolName: "icloud.and.arrow.down", accessibilityDescription: "Kun i skyen")?
                            .withSymbolConfiguration(cfg)
                    case .localSynced:
                        let cfg = baseCfg.applying(NSImage.SymbolConfiguration(paletteColors: [.systemGreen]))
                        cell.imageView?.image = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: "Lagret lokalt")?
                            .withSymbolConfiguration(cfg)
                    case .syncing:
                        let cfg = baseCfg.applying(NSImage.SymbolConfiguration(paletteColors: [.systemBlue]))
                        cell.imageView?.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath.circle", accessibilityDescription: "Synkroniserer")?
                            .withSymbolConfiguration(cfg)
                    case .none:
                        break
                    }
                    cell.imageView?.isHidden = false
                } else {
                    cell.imageView?.image = nil
                    cell.imageView?.isHidden = true
                }

                if let diff = tab.diffStatuses[item.url] {
                    parts.append(diff.badgeText)
                    tooltips.append("Mappe-sammenligning: \(diff.badgeText)")
                    switch diff {
                    case .onlyHere: badgeColor = .systemGreen
                    case .newerHere: badgeColor = .systemBlue
                    case .olderHere: badgeColor = .secondaryLabelColor
                    case .sizeDiffers: badgeColor = .systemOrange
                    case .identical: badgeColor = .tertiaryLabelColor
                    }
                }

                if let git = tab.gitBadges[item.url], git != .ignored {
                    parts.append("Git:\(git.rawValue)")
                    let gitDesc: String = {
                        switch git {
                        case .modified: return "Git: Endret (Modified)"
                        case .staged: return "Git: Klargjort (Staged)"
                        case .untracked: return "Git: Ny fil (Untracked)"
                        case .deleted: return "Git: Slettet"
                        case .conflict: return "Git: Konflikt!"
                        case .ignored: return "Git: Ignorert"
                        }
                    }()
                    tooltips.append(gitDesc)
                    if tab.diffStatuses[item.url] == nil {
                        switch git {
                        case .modified: badgeColor = .systemOrange
                        case .staged, .untracked: badgeColor = .systemGreen
                        case .deleted, .conflict: badgeColor = .systemRed
                        case .ignored: badgeColor = .tertiaryLabelColor
                        }
                    }
                }

                let combinedText = parts.joined(separator: " ")
                tf.stringValue = combinedText
                tf.isHidden = combinedText.isEmpty
                tf.font = .monospacedSystemFont(ofSize: 12, weight: .bold)
                tf.textColor = badgeColor
                tf.alignment = .center
                cell.toolTip = tooltips.isEmpty ? nil : tooltips.joined(separator: " • ")

            case SortColumn.ext.rawValue:
                tf.stringValue = item.fileExtension
                tf.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
                tf.textColor = isMarked ? markedColor : .secondaryLabelColor
                tf.alignment = .left

            case SortColumn.size.rawValue:
                let calcSize = tab.calculatedFolderSizes[item.url]
                tf.stringValue = item.formattedSize(calculatedFolderSize: calcSize)
                tf.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: calcSize != nil ? .semibold : .regular)
                if isMarked {
                    tf.textColor = markedColor
                } else if calcSize != nil {
                    tf.textColor = .controlAccentColor
                } else {
                    tf.textColor = .secondaryLabelColor
                }
                tf.alignment = .right

            case SortColumn.dateModified.rawValue:
                tf.stringValue = item.formattedDate
                tf.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
                tf.textColor = isMarked ? markedColor : .secondaryLabelColor
                tf.alignment = .left

            case SortColumn.kind.rawValue:
                tf.stringValue = item.kindDescription
                tf.font = .systemFont(ofSize: 11.5)
                tf.textColor = isMarked ? markedColor : .tertiaryLabelColor
                tf.alignment = .left

            default:
                break
            }
        }
    }
}
