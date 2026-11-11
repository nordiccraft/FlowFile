import SwiftUI

struct TopToolbarView: View {
    @Bindable var workspace: WorkspaceState

    private var activeTab: TabState {
        workspace.activeTab
    }

    private var hasSelection: Bool {
        !activeTab.effectiveActionURLs.isEmpty
    }

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            VStack(spacing: 8) {
                // Row 1: Windows 11 Explorer-inspired Action Bar + Mode Toggles
                HStack(spacing: 8) {
                    // Create group
                    HStack(spacing: 4) {
                        Menu {
                            Button(workspace.tr("Ny mappe (F7)", "New Folder (F7)"), systemImage: "folder.badge.plus") {
                                workspace.promptNewFolder()
                            }
                            Button(workspace.tr("Ny tom fil", "New Empty File"), systemImage: "doc.badge.plus") {
                                workspace.promptNewFile()
                            }
                            Button(workspace.tr("Ny fane (Cmd+T)", "New Tab (Cmd+T)"), systemImage: "plus.rectangle.on.rectangle") {
                                workspace.activePane.addTab(showHidden: workspace.showHiddenFiles)
                            }
                        } label: {
                            Label(workspace.tr("Ny", "New"), systemImage: "plus.circle.fill")
                                .font(.system(size: 12.5, weight: .medium))
                        } primaryAction: {
                            workspace.promptNewFolder()
                        }
                        .menuStyle(.button)
                        .buttonStyle(.glass)
                        .help(workspace.tr("Opprett ny mappe (F7) eller velg fra menyen", "Create new folder (F7) or choose from menu"))
                    }

                    Divider().frame(height: 18)

                    // Clipboard & File actions (Windows 11 ribbon style)
                    HStack(spacing: 4) {
                        toolbarIconButton("scissors", title: workspace.tr("Klipp ut", "Cut"), help: workspace.tr("Klipp ut valgte filer (Cmd+X)", "Cut selected files (Cmd+X)"), disabled: !hasSelection) {
                            workspace.cutSelected()
                        }
                        toolbarIconButton("doc.on.doc", title: workspace.tr("Kopier", "Copy"), help: workspace.tr("Kopier valgte filer (Cmd+C)", "Copy selected files (Cmd+C)"), disabled: !hasSelection) {
                            workspace.copySelected()
                        }
                        toolbarIconButton("doc.on.clipboard", title: workspace.tr("Lim inn", "Paste"), help: workspace.tr("Lim inn i aktiv mappe (Cmd+V)", "Paste into active folder (Cmd+V)"), disabled: false) {
                            workspace.pasteIntoActiveFolder()
                        }
                        toolbarIconButton("pencil", title: workspace.tr("Endre navn", "Rename"), help: workspace.tr("Gi nytt navn (F2)", "Rename (F2)"), disabled: activeTab.primarySelectedItem == nil) {
                            workspace.promptRenameSelected()
                        }
                        toolbarIconButton("character.textbox", title: "Batch", help: workspace.tr("Multi-Rename Tool – masse-omdøping (Cmd+M)", "Multi-Rename Tool (Cmd+M)"), disabled: activeTab.isInsideArchive) {
                            workspace.openMultiRenameTool()
                        }

                        Button {
                            workspace.openShareHub()
                        } label: {
                            Label(workspace.tr("Del", "Share"), systemImage: "square.and.arrow.up")
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.glass)
                        .disabled((!hasSelection && !workspace.tour.isSandboxActive) || activeTab.isInsideArchive)
                        .tourTarget(.shareButton)
                        .help(workspace.tr(
                            "Smart Delingssenter – E-post, Outlook, Teams, Sky og Wi-Fi QR (⇧⌘S)",
                            "Smart Share Hub – Mail, Outlook, Teams, Cloud & Wi-Fi QR (⇧⌘S)"
                        ))

                        toolbarIconButton("trash", title: workspace.tr("Slett", "Delete"), help: workspace.tr("Flytt til Papirkurv (Delete / F8)", "Move to Trash (Delete / F8)"), disabled: !hasSelection) {
                            workspace.trashSelected()
                        }
                    }

                    Spacer(minLength: 8)

                    // View & Power-user toggles
                    HStack(spacing: 6) {
                        Button {
                            workspace.toggleDualPaneComparison()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: workspace.isCompareActive
                                      ? "arrow.left.and.right.righttriangle.left.righttriangle.right.fill"
                                      : "arrow.left.and.right.righttriangle.left.righttriangle.right")
                                if workspace.isCompareActive {
                                    Text(workspace.tr("Avslutt diff", "Exit Diff"))
                                        .font(.system(size: 11.5, weight: .semibold))
                                }
                            }
                            .foregroundStyle(workspace.isCompareActive ? Color.accentColor : .primary)
                        }
                        .buttonStyle(.glass)
                        .tourTarget(.compareButton)
                        .help(workspace.isCompareActive
                              ? workspace.tr("Avslutt mappe-sammenligning (⇧⌘K / Esc)", "Exit folder comparison (⇧⌘K / Esc)")
                              : workspace.tr("Sammenlign venstre og høyre mappe i Dual-Pane (⇧⌘K)", "Compare left and right folders in Dual-Pane (⇧⌘K)"))

                        Button {
                            withAnimation(.snappy(duration: 0.2)) {
                                workspace.isDropShelfVisible.toggle()
                            }
                        } label: {
                            let shelfCount = workspace.transferQueue.dropShelfItems.count
                            let activeJobs = workspace.transferQueue.activeJobsCount
                            HStack(spacing: 4) {
                                Image(systemName: "tray.2.fill")
                                    .foregroundStyle(workspace.isDropShelfVisible || activeJobs > 0 ? Color.accentColor : .primary)
                                if shelfCount > 0 || activeJobs > 0 {
                                    Text("\(shelfCount + activeJobs)")
                                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                        .buttonStyle(.glass)
                        .help(workspace.tr("Vis/skjul Drop-hylle og Filoverføringskø (Cmd+J)", "Show/hide Drop Shelf & Transfer Queue (Cmd+J)"))

                        Button {
                            withAnimation(.snappy(duration: 0.2)) {
                                workspace.toggleTerminalDrawer()
                            }
                        } label: {
                            Image(systemName: "terminal")
                                .foregroundStyle(workspace.isTerminalDrawerVisible ? Color.accentColor : .primary)
                        }
                        .buttonStyle(.glass)
                        .help(workspace.tr("Vis/skjul innebygd synkronisert Terminal-skuff (Ctrl+`)", "Show/hide embedded synchronized Terminal drawer (Ctrl+`)"))

                        Button {
                            workspace.isCommandPaletteVisible = true
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "command")
                                    .font(.system(size: 11, weight: .semibold))
                                Text(workspace.tr("Gå til", "Go to"))
                                    .font(.system(size: 12))
                                Text("⌘P")
                                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.glass)
                        .help(workspace.tr("Åpne Command Palette (Cmd+P)", "Open Command Palette (Cmd+P)"))

                        Picker("", selection: Binding(
                            get: { activeTab.viewMode },
                            set: { activeTab.viewMode = $0 }
                        )) {
                            ForEach(PaneViewMode.allCases) { mode in
                                Image(systemName: mode.systemImage)
                                    .help(mode.title)
                                    .tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 72)
                        .help(workspace.tr("Bytt mellom Detaljert liste og Rutenettvisning", "Switch between Details list and Grid view"))

                        Button {
                            workspace.showHiddenFiles.toggle()
                        } label: {
                            Image(systemName: workspace.showHiddenFiles ? "eye.fill" : "eye.slash")
                                .foregroundStyle(workspace.showHiddenFiles ? Color.accentColor : .primary)
                        }
                        .buttonStyle(.glass)
                        .help(workspace.tr("Vis/skjul skjulte dot-filer (Cmd+Shift+.)", "Show/hide hidden dotfiles (Cmd+Shift+.)"))

                        Button {
                            withAnimation(.snappy(duration: 0.2)) {
                                workspace.toggleDualPane()
                            }
                        } label: {
                            Label(
                                workspace.isDualPane ? "Dual-Pane" : workspace.tr("1-Panel", "1-Pane"),
                                systemImage: workspace.isDualPane ? "rectangle.split.2x1.fill" : "rectangle.split.2x1"
                            )
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(workspace.isDualPane ? Color.accentColor : .primary)
                        }
                        .buttonStyle(.glass)
                        .tourTarget(.dualPaneButton)
                        .help(workspace.tr(
                            "Bytt mellom Windows Explorer 1-panel og Total Commander Dual-Pane (Cmd+D)",
                            "Switch between Windows Explorer 1-Pane and Total Commander Dual-Pane (Cmd+D)"
                        ))

                        Button {
                            withAnimation(.snappy(duration: 0.2)) {
                                workspace.isInspectorVisible.toggle()
                            }
                        } label: {
                            Image(systemName: "sidebar.right")
                                .foregroundStyle(workspace.isInspectorVisible ? Color.accentColor : .primary)
                        }
                        .buttonStyle(.glass)
                        .help(workspace.tr("Vis/skjul høyre Info- og forhåndsvisningspanel (Cmd+I)", "Show/hide right Info & Preview Inspector (Cmd+I)"))

                        Button {
                            workspace.startInteractiveTour()
                        } label: {
                            Image(systemName: "questionmark.circle")
                                .foregroundStyle(workspace.tour.isActive ? Color.accentColor : .primary)
                        }
                        .buttonStyle(.glass)
                        .help(workspace.tr("Start interaktiv brukerveiledning (Øvingsmodus)", "Start interactive walkthrough (Practice Mode)"))
                    }
                }

                // Row 2: Navigation Controls + Hybrid Address Bar + Instant Filter Button
                HStack(spacing: 6) {
                    Button {
                        withAnimation(.snappy(duration: 0.2)) {
                            workspace.isSidebarVisible.toggle()
                        }
                    } label: {
                        Image(systemName: "sidebar.left")
                            .foregroundStyle(workspace.isSidebarVisible ? Color.accentColor : .primary)
                    }
                    .buttonStyle(.glass)
                    .help(workspace.tr("Vis/skjul venstre Explorer-sidepanel (Cmd+B)", "Show/hide left Explorer sidebar (Cmd+B)"))

                    HStack(spacing: 3) {
                        Button {
                            activeTab.goBack(showHidden: workspace.showHiddenFiles)
                        } label: {
                            Image(systemName: "chevron.left")
                        }
                        .buttonStyle(.glass)
                        .disabled(!activeTab.canGoBack)
                        .help(workspace.tr("Tilbake (Opt+Venstre)", "Back (Opt+Left)"))

                        Button {
                            activeTab.goForward(showHidden: workspace.showHiddenFiles)
                        } label: {
                            Image(systemName: "chevron.right")
                        }
                        .buttonStyle(.glass)
                        .disabled(!activeTab.canGoForward)
                        .help(workspace.tr("Frem (Opt+Høyre)", "Forward (Opt+Right)"))

                        Button {
                            activeTab.goUp(showHidden: workspace.showHiddenFiles)
                        } label: {
                            Image(systemName: "arrow.up")
                        }
                        .buttonStyle(.glass)
                        .disabled(!activeTab.canGoUp)
                        .help(workspace.tr("Opp ett mappenivå (Backspace / Opt+Opp)", "Up one folder level (Backspace / Opt+Up)"))

                        Button {
                            workspace.refreshAllTabs()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.glass)
                        .help(workspace.tr("Oppdater mapper (Cmd+R)", "Refresh folders (Cmd+R)"))
                    }

                    AddressBarView(workspace: workspace)

                    Button {
                        activeTab.isFilterBarVisible.toggle()
                        if !activeTab.isFilterBarVisible {
                            activeTab.filterQuery = ""
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "line.3.horizontal.decrease.circle")
                                .foregroundStyle(!activeTab.filterQuery.isEmpty ? Color.accentColor : .primary)
                            if !activeTab.filterQuery.isEmpty {
                                Text(activeTab.filterQuery)
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .lineLimit(1)
                            }
                        }
                    }
                    .buttonStyle(.glass)
                    .help(workspace.tr("Lyn-filter i aktiv mappe (Cmd+F)", "Instant filter in active folder (Cmd+F)"))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
    }

    @ViewBuilder
    private func toolbarIconButton(
        _ systemImage: String,
        title: String,
        help: String,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12))
        }
        .buttonStyle(.glass)
        .disabled(disabled)
        .help(help)
    }
}
