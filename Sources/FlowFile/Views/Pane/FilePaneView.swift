import SwiftUI

struct FilePaneView: View {
    @Bindable var pane: PaneState
    @Bindable var workspace: WorkspaceState
    @State private var didCopyPanePath: Bool = false
    @FocusState private var isFilterFieldFocused: Bool

    private var activeTab: TabState {
        pane.activeTab
    }

    private var isActivePane: Bool {
        !workspace.isDualPane || workspace.activePaneID == pane.id
    }

    var body: some View {
        VStack(spacing: 0) {
            // Pane Header: Tabs + New Tab + Dual-Pane Path Pill
            VStack(spacing: 4) {
                HStack(spacing: 4) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(pane.tabs) { tab in
                                let isSelectedTab = tab.id == pane.activeTabID
                                HStack(spacing: 5) {
                                    if tab.isInsideArchive {
                                        LucideIcon(kind: .archive, size: 12)
                                            .foregroundStyle(isSelectedTab ? Color.accentColor : .secondary)
                                    } else {
                                        Image(systemName: "folder")
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundStyle(isSelectedTab ? Color.accentColor : .secondary)
                                    }

                                    Text(tab.title)
                                        .font(.system(size: 12, weight: isSelectedTab ? .semibold : .regular))
                                        .lineLimit(1)

                                    if pane.tabs.count > 1 {
                                        Button {
                                            pane.closeTab(id: tab.id, showHidden: workspace.showHiddenFiles)
                                        } label: {
                                            Image(systemName: "xmark")
                                                .font(.system(size: 9, weight: .bold))
                                                .foregroundStyle(.secondary)
                                                .frame(width: 14, height: 14)
                                                .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .fill(isSelectedTab ? Color.primary.opacity(0.10) : Color.clear)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .strokeBorder(isSelectedTab ? Color.accentColor.opacity(0.45) : Color.clear, lineWidth: 1)
                                )
                                .contentShape(RoundedRectangle(cornerRadius: 7))
                                .onTapGesture {
                                    workspace.activePaneID = pane.id
                                    pane.activeTabID = tab.id
                                }
                            }
                        }
                    }

                    Button {
                        workspace.activePaneID = pane.id
                        pane.addTab(showHidden: workspace.showHiddenFiles)
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .help("Åpne ny fane i dette panelet (Cmd+T)")

                    Spacer()

                    if workspace.isDualPane {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(isActivePane ? Color.accentColor : Color.secondary.opacity(0.35))
                                .frame(width: 7, height: 7)
                            Text(pane.id == .left ? workspace.tr("VENSTRE", "LEFT") : workspace.tr("HØYRE", "RIGHT"))
                                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                .foregroundStyle(isActivePane ? Color.accentColor : .secondary)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .onTapGesture {
                            workspace.activePaneID = pane.id
                        }
                    }
                }

                // In Dual-Pane mode, show each pane's full path right under its tabs (Total Commander style!)
                if workspace.isDualPane {
                    HStack(spacing: 6) {
                        Button {
                            workspace.activePaneID = pane.id
                            activeTab.goUp(showHidden: workspace.showHiddenFiles)
                        } label: {
                            Image(systemName: "arrow.turn.left.up")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .disabled(!activeTab.canGoUp)

                        Text(activeTab.displayPathString)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(isActivePane ? .primary : .secondary)
                            .lineLimit(1)
                            .truncationMode(.head)

                        Spacer()

                        if let branch = activeTab.gitBranch {
                            HStack(spacing: 3) {
                                LucideIcon(kind: .gitBranch, size: 11)
                                Text(branch)
                                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                            }
                            .foregroundStyle(Color.accentColor)
                        }

                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(activeTab.currentURL.path, forType: .string)
                            didCopyPanePath = true
                            workspace.notifyDidCopyPath()
                            workspace.showStatus(workspace.tr("Kopierte sti: \(activeTab.currentURL.path)", "Copied path: \(activeTab.currentURL.path)"))
                            Task { @MainActor in
                                try? await Task.sleep(nanoseconds: 1_600_000_000)
                                didCopyPanePath = false
                            }
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: didCopyPanePath ? "checkmark" : "doc.on.doc")
                                    .font(.system(size: 9.5, weight: .semibold))
                                Text(didCopyPanePath ? workspace.tr("Kopiert", "Copied") : workspace.tr("Kopier sti", "Copy Path"))
                                    .font(.system(size: 10, weight: .medium))
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(didCopyPanePath ? Color.green.opacity(0.2) : Color.primary.opacity(0.08)))
                            .foregroundStyle(didCopyPanePath ? .green : .secondary)
                        }
                        .buttonStyle(.plain)
                        .help(workspace.tr("Kopier mappestien for dette panelet", "Copy folder path for this pane"))

                        Text("\(activeTab.displayedItems.count) \(workspace.tr("elem.", "items"))")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 2)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        workspace.activePaneID = pane.id
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial)

            // Archive virtual folder banner
            if let archiveURL = activeTab.archiveFileURL {
                HStack(spacing: 8) {
                    Image(systemName: "doc.zipper")
                        .foregroundStyle(.orange)
                    Text("Arkiv: \(archiveURL.lastPathComponent)\(activeTab.archiveSubpath.isEmpty ? "" : "/\(activeTab.archiveSubpath)")")
                        .font(.system(size: 11.5, weight: .semibold))
                        .lineLimit(1)

                    Spacer()

                    Button("Pakk ut alt her") {
                        workspace.activePaneID = pane.id
                        workspace.extractSelectedArchiveHere()
                    }
                    .font(.system(size: 11))
                    .buttonStyle(.glass)

                    Button("Lukk arkiv") {
                        activeTab.exitArchive(showHidden: workspace.showHiddenFiles)
                    }
                    .font(.system(size: 11))
                    .buttonStyle(.glass)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.orange.opacity(0.12))
            }

            // Dual-Pane Folder Compare banner
            if workspace.isCompareActive || !activeTab.diffStatuses.isEmpty {
                let banner = HStack(spacing: 8) {
                    Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right.fill")
                        .foregroundStyle(Color.accentColor)
                    Text(workspace.tr("Mappe-sammenligning aktiv", "Folder Comparison Active"))
                        .font(.system(size: 11.5, weight: .semibold))

                    Toggle(workspace.tr("Skjul identiske", "Hide identical"), isOn: Binding(
                        get: { activeTab.hideIdenticalInDiff },
                        set: { _ in workspace.toggleHideIdenticalInDiff() }
                    ))
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))

                    Spacer()

                    Button {
                        workspace.clearDualPaneComparison()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11, weight: .bold))
                            Text(workspace.tr("Avslutt sammenligning", "Exit Comparison"))
                                .font(.system(size: 11.5, weight: .semibold))
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.accentColor.opacity(0.20)))
                        .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .help(workspace.tr("Lukk mappe-sammenligning (Esc / ⇧⌘K)", "Close folder comparison (Esc / ⇧⌘K)"))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.accentColor.opacity(0.11))

                if pane.id == .left {
                    banner.tourTarget(.exitCompareBanner)
                } else {
                    banner
                }
            }

            // Instant Filter Bar (appears when typing or pressing Cmd+F)
            if activeTab.isFilterBarVisible || !activeTab.filterQuery.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Color.accentColor)

                    TextField("Lyn-filter i «\(activeTab.title)» (fuzzy søk)...", text: Binding(
                        get: { activeTab.filterQuery },
                        set: { newVal in
                            activeTab.filterQuery = newVal
                            if let first = activeTab.displayedItems.first {
                                activeTab.selectedURLs = [first.url]
                            }
                        }
                    ))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .focused($isFilterFieldFocused)
                    .onExitCommand {
                        activeTab.filterQuery = ""
                        activeTab.isFilterBarVisible = false
                    }

                    Text("\(activeTab.displayedItems.count) av \(activeTab.allItems.count)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)

                    Button {
                        activeTab.filterQuery = ""
                        activeTab.isFilterBarVisible = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.accentColor.opacity(0.10))
            }

            Divider()

            // Main File List / Grid Content (High-contrast readable surface!)
            if let errorMessage = activeTab.errorMessage {
                VStack(spacing: 10) {
                    Image(systemName: "lock.trianglebadge.exclamationmark.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(.orange)
                    Text(errorMessage)
                        .font(.system(size: 13, weight: .medium))
                        .multilineTextAlignment(.center)
                    Button("Gå opp ett nivå") {
                        activeTab.goUp(showHidden: workspace.showHiddenFiles)
                    }
                    .buttonStyle(.glass)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
                .background(Color(nsColor: .controlBackgroundColor))
            } else {
                switch activeTab.viewMode {
                case .details:
                    AppKitFileTableView(
                        pane: pane,
                        tab: activeTab,
                        workspace: workspace
                    )
                case .grid:
                    FileGridView(
                        pane: pane,
                        tab: activeTab,
                        workspace: workspace
                    )
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    workspace.isDualPane && isActivePane
                        ? Color.accentColor.opacity(0.85)
                        : Color.primary.opacity(0.12),
                    lineWidth: workspace.isDualPane && isActivePane ? 2.0 : 1.0
                )
        )
    }
}
