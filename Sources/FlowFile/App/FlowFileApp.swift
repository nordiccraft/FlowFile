import AppKit
import Quartz
import SwiftUI

final class FlowFileAppDelegate: NSObject, NSApplicationDelegate {
    private static let finderSuiteClass = AEEventClass(0x666E6472) // 'fndr'
    private static let miscSuiteClass = AEEventClass(0x6D697363)   // 'misc'
    private static let revealEventID = AEEventID(0x6D766973)       // 'mvis' (kAERevealSelection)

    func applicationWillFinishLaunching(_ notification: Notification) {
        let aeManager = NSAppleEventManager.shared()
        aeManager.setEventHandler(
            self,
            andSelector: #selector(handleRevealAppleEvent(_:withReplyEvent:)),
            forEventClass: Self.finderSuiteClass,
            andEventID: Self.revealEventID
        )
        aeManager.setEventHandler(
            self,
            andSelector: #selector(handleRevealAppleEvent(_:withReplyEvent:)),
            forEventClass: Self.miscSuiteClass,
            andEventID: Self.revealEventID
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        ShareHubService.cleanupStaleStagingDirectories()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            ExternalOpenCoordinator.shared.receive(urls: urls, isRevealEvent: false)
        }
    }

    @objc private func handleRevealAppleEvent(
        _ event: NSAppleEventDescriptor,
        withReplyEvent replyEvent: NSAppleEventDescriptor
    ) {
        let urls = DefaultFileBrowserService.extractURLs(fromAppleEvent: event)
        guard !urls.isEmpty else { return }
        Task { @MainActor in
            ExternalOpenCoordinator.shared.receive(urls: urls, isRevealEvent: true)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        ShareHubService.cleanupStaleStagingDirectories(maxAgeSeconds: 0)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        true
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = QuickLookCoordinator.shared
        panel.delegate = QuickLookCoordinator.shared
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }
}

@main
struct FlowFileApp: App {
    @NSApplicationDelegateAdaptor(FlowFileAppDelegate.self) private var appDelegate
    @State private var workspace = WorkspaceState()

    var body: some Scene {
        WindowGroup("FlowFile") {
            MainWindowView(workspace: workspace)
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
                .onOpenURL { url in
                    ExternalOpenCoordinator.shared.receive(urls: [url], isRevealEvent: false)
                }
        }
        .defaultSize(width: 1220, height: 780)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Ny fane") {
                    workspace.activePane.addTab(showHidden: workspace.showHiddenFiles)
                }
                .keyboardShortcut("t", modifiers: [.command])

                Button("Lukk aktiv fane") {
                    let pane = workspace.activePane
                    if pane.tabs.count > 1 {
                        pane.closeTab(id: pane.activeTabID, showHidden: workspace.showHiddenFiles)
                    }
                }
                .keyboardShortcut("w", modifiers: [.command])
                .disabled(workspace.activePane.tabs.count <= 1)

                Divider()

                Button("Ny mappe...") {
                    workspace.promptNewFolder()
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])

                Button("Ny tom fil...") {
                    workspace.promptNewFile()
                }
                .keyboardShortcut("n", modifiers: [.command, .option])

                Divider()

                Button("Smart Delingssenter (Del valgte)...") {
                    workspace.openShareHub()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            }

            CommandGroup(replacing: .pasteboard) {
                Button(workspace.tr("Klipp ut", "Cut")) {
                    if Self.isTextInputActive {
                        NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil)
                    } else {
                        workspace.cutSelected()
                    }
                }
                .keyboardShortcut("x", modifiers: [.command])

                Button(workspace.tr("Kopier", "Copy")) {
                    if Self.isTextInputActive {
                        NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
                    } else {
                        workspace.copySelected()
                    }
                }
                .keyboardShortcut("c", modifiers: [.command])

                Button(workspace.tr("Lim inn", "Paste")) {
                    if Self.isTextInputActive {
                        NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
                    } else {
                        workspace.pasteIntoActiveFolder()
                    }
                }
                .keyboardShortcut("v", modifiers: [.command])

                Button(workspace.tr("Merk alt", "Select All")) {
                    if Self.isTextInputActive {
                        NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
                    } else {
                        workspace.selectAllInActiveTab()
                    }
                }
                .keyboardShortcut("a", modifiers: [.command])

                Divider()

                Button("Kopier full sti") {
                    workspace.copyPathOfSelectedOrCurrent()
                }
                .keyboardShortcut("c", modifiers: [.command, .option])

                Button("Gi nytt navn...") {
                    workspace.promptRenameSelected()
                }

                Divider()

                Button("Lyn-filter i aktiv mappe") {
                    workspace.activeTab.isFilterBarVisible.toggle()
                }
                .keyboardShortcut("f", modifiers: [.command])
            }

            CommandMenu("Visning") {
                Button(workspace.isDualPane ? "Bytt til 1-Panel (Explorer)" : "Bytt til Dual-Pane (Total Commander)") {
                    withAnimation(.snappy(duration: 0.2)) {
                        workspace.toggleDualPane()
                    }
                }
                .keyboardShortcut("d", modifiers: [.command])

                Button(workspace.isSidebarVisible ? "Skjul venstre sidepanel" : "Vis venstre sidepanel") {
                    withAnimation(.snappy(duration: 0.2)) {
                        workspace.isSidebarVisible.toggle()
                    }
                }
                .keyboardShortcut("b", modifiers: [.command])

                Button(workspace.isInspectorVisible ? "Skjul høyre infopanel" : "Vis høyre infopanel") {
                    withAnimation(.snappy(duration: 0.2)) {
                        workspace.isInspectorVisible.toggle()
                    }
                }
                .keyboardShortcut("i", modifiers: [.command])

                Divider()

                Button(workspace.showHiddenFiles ? "Skjul skjulte dot-filer" : "Vis skjulte dot-filer") {
                    workspace.showHiddenFiles.toggle()
                }
                .keyboardShortcut(".", modifiers: [.command, .shift])

                Divider()

                Button("Detaljert tabellvisning") {
                    workspace.activeTab.viewMode = .details
                }
                .keyboardShortcut("1", modifiers: [.command])

                Button("Rutenettvisning (Miniatyrbilder)") {
                    workspace.activeTab.viewMode = .grid
                }
                .keyboardShortcut("2", modifiers: [.command])

                Divider()

                Button("Oppdater") {
                    workspace.refreshAllTabs()
                }
                .keyboardShortcut("r", modifiers: [.command])
            }

            CommandMenu("Gå til") {
                Button("Command Palette...") {
                    workspace.isCommandPaletteVisible.toggle()
                }
                .keyboardShortcut("p", modifiers: [.command])

                Button("Rediger adresselinje") {
                    workspace.focusAddressBar()
                }
                .keyboardShortcut("l", modifiers: [.command])

                Divider()

                Button("Tilbake") {
                    workspace.activeTab.goBack(showHidden: workspace.showHiddenFiles)
                }
                .keyboardShortcut("[", modifiers: [.command])
                .disabled(!workspace.activeTab.canGoBack)

                Button("Frem") {
                    workspace.activeTab.goForward(showHidden: workspace.showHiddenFiles)
                }
                .keyboardShortcut("]", modifiers: [.command])
                .disabled(!workspace.activeTab.canGoForward)

                Button("Opp ett mappenivå") {
                    workspace.activeTab.goUp(showHidden: workspace.showHiddenFiles)
                }
                .keyboardShortcut(.upArrow, modifiers: [.command])
                .disabled(!workspace.activeTab.canGoUp)

                Divider()

                Button("Hjem") {
                    workspace.navigateActiveTab(to: FileManager.default.homeDirectoryForCurrentUser)
                }
                .keyboardShortcut("h", modifiers: [.command, .shift])

                Button("Nedlastinger") {
                    let dl = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
                    workspace.navigateActiveTab(to: dl)
                }
                .keyboardShortcut("l", modifiers: [.command, .option])
            }

            CommandMenu("Commander") {
                Button("Multi-Rename Tool (Masse-omdøping)...") {
                    workspace.openMultiRenameTool()
                }
                .keyboardShortcut("m", modifiers: [.command])

                Button("Angre siste masse-omdøping") {
                    workspace.undoLastBatchRename()
                }
                .disabled(workspace.lastBatchRename == nil)

                Divider()

                Button(workspace.isDropShelfVisible ? "Skjul Drop-hylle & Fil-kø" : "Vis Drop-hylle & Fil-kø") {
                    withAnimation(.snappy(duration: 0.2)) {
                        workspace.isDropShelfVisible.toggle()
                    }
                }
                .keyboardShortcut("j", modifiers: [.command])

                Button("Legg valgte filer i Drop-hylle") {
                    workspace.addSelectedToDropShelf()
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])

                Divider()

                Button(workspace.isCompareActive
                       ? workspace.tr("Avslutt mappe-sammenligning", "Exit Folder Comparison")
                       : workspace.tr("Sammenlign mapper i Dual-Pane", "Compare Folders in Dual-Pane")) {
                    workspace.toggleDualPaneComparison()
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])

                Divider()

                Button("Komprimer valgte til .zip") {
                    workspace.compressSelectedToZip()
                }

                Button("Pakk ut valgt arkiv her") {
                    workspace.extractSelectedArchiveHere()
                }

                Divider()

                Button("Bytt aktivt panel") {
                    workspace.switchActivePane()
                }
                .disabled(!workspace.isDualPane)

                Button("Quick Look") {
                    workspace.triggerQuickLook()
                }
                .keyboardShortcut("y", modifiers: [.command])

                Divider()

                Button("Kopier til motsatt panel (F5)") {
                    workspace.copySelectedToOppositePane()
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])

                Button("Flytt til motsatt panel (F6)") {
                    workspace.moveSelectedToOppositePane()
                }
                .keyboardShortcut("m", modifiers: [.command, .option])

                Divider()

                Button(workspace.isTerminalDrawerVisible ? "Skjul innebygd Terminal-skuff" : "Vis innebygd Terminal-skuff") {
                    withAnimation(.snappy(duration: 0.2)) {
                        workspace.toggleTerminalDrawer()
                    }
                }
                .keyboardShortcut("`", modifiers: [.control])

                Button("Åpne macOS Terminal i aktiv mappe") {
                    workspace.openTerminalInActiveFolder()
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            }

            CommandGroup(after: .appInfo) {
                Button(workspace.tr("Se etter oppdateringer...", "Check for Updates...")) {
                    workspace.openUpdateChecker()
                }
            }

            CommandGroup(replacing: .appSettings) {
                Button(workspace.tr("Innstillinger...", "Settings...")) {
                    workspace.isSettingsVisible = true
                }
                .keyboardShortcut(",", modifiers: [.command])
            }

            CommandGroup(replacing: .help) {
                Button(workspace.tr("Start interaktiv omvisning (Øvingsmodus)...", "Start Interactive Walkthrough (Practice Mode)...")) {
                    workspace.startInteractiveTour()
                }
            }
        }
    }

    /// True whenever keyboard focus is inside a text field / field editor (address bar, rename sheet, filter bar, etc.)
    private static var isTextInputActive: Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        return responder is NSText || responder is NSTextField
    }
}
