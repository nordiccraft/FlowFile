import SwiftUI

struct StatusAndFKeyBarView: View {
    @Bindable var workspace: WorkspaceState

    private var activeTab: TabState {
        workspace.activeTab
    }

    private var summaryText: String {
        let items = activeTab.displayedItems
        let foldersCount = items.filter(\.isNavigableFolder).count
        let filesCount = items.count - foldersCount

        if !activeTab.markedURLs.isEmpty {
            let markedItems = items.filter { activeTab.markedURLs.contains($0.url) }
            let bytes = markedItems.reduce(Int64(0)) { acc, item in
                acc + (item.isNavigableFolder ? (activeTab.calculatedFolderSizes[item.url] ?? 0) : item.size)
            }
            return workspace.tr(
                "✓ \(markedItems.count) markert (\(ByteFormatter.string(fromByteCount: bytes)))  •  \(foldersCount) mapper, \(filesCount) filer",
                "✓ \(markedItems.count) marked (\(ByteFormatter.string(fromByteCount: bytes)))  •  \(foldersCount) folders, \(filesCount) files"
            )
        }

        let selected = items.filter { activeTab.selectedURLs.contains($0.url) }
        if !selected.isEmpty {
            let bytes = selected.reduce(Int64(0)) { acc, item in
                acc + (item.isNavigableFolder ? (activeTab.calculatedFolderSizes[item.url] ?? 0) : item.size)
            }
            return workspace.tr(
                "\(selected.count) valgt (\(ByteFormatter.string(fromByteCount: bytes)))  •  \(foldersCount) mapper, \(filesCount) filer",
                "\(selected.count) selected (\(ByteFormatter.string(fromByteCount: bytes)))  •  \(foldersCount) folders, \(filesCount) files"
            )
        }

        return workspace.tr("\(foldersCount) mapper, \(filesCount) filer", "\(foldersCount) folders, \(filesCount) files")
    }

    var body: some View {
        GlassEffectContainer(spacing: 6) {
            VStack(spacing: 6) {
                // Total Commander F3–F8 Bar (shown automatically in Dual-Pane, or always if enabled in Settings)
                if workspace.isDualPane || workspace.showFKeyBarAlways {
                    HStack(spacing: 6) {
                        fKeyButton("F3", title: "Quick Look") {
                            workspace.triggerQuickLook()
                        }
                        fKeyButton("F4", title: workspace.tr("Rediger", "Edit")) {
                            workspace.openSelectedInEditor()
                        }
                        fKeyButton("F5", title: workspace.isDualPane ? workspace.tr("Kopier →", "Copy →") : workspace.tr("Kopier (2-panel)", "Copy (2-pane)")) {
                            workspace.copySelectedToOppositePane()
                        }
                        fKeyButton("F6", title: workspace.isDualPane ? workspace.tr("Flytt →", "Move →") : workspace.tr("Flytt (2-panel)", "Move (2-pane)")) {
                            workspace.moveSelectedToOppositePane()
                        }
                        fKeyButton("F7", title: workspace.tr("Ny mappe", "New Folder")) {
                            workspace.promptNewFolder()
                        }
                        fKeyButton("F8", title: workspace.tr("Papirkurv", "Trash"), destructive: true) {
                            workspace.trashSelected()
                        }
                    }
                }

                // Bottom Status Row
                HStack(spacing: 12) {
                    Text(summaryText)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(.secondary)

                    if !workspace.clipboardURLs.isEmpty, let op = workspace.clipboardOperation {
                        HStack(spacing: 4) {
                            Image(systemName: op == .cut ? "scissors" : "doc.on.doc")
                                .font(.system(size: 10))
                            Text("\(workspace.clipboardURLs.count) i utklippstavle (\(op == .cut ? "klipp ut" : "kopi"))")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(op == .cut ? .orange : Color.accentColor)
                    }

                    Spacer()

                    if let statusBanner = workspace.statusBanner {
                        Text(statusBanner)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                            .transition(.opacity)
                    }

                    HStack(spacing: 10) {
                        if workspace.transferQueue.activeJobsCount > 0 {
                            Button {
                                workspace.isDropShelfVisible = true
                            } label: {
                                HStack(spacing: 4) {
                                    ProgressView().controlSize(.mini)
                                    Text("\(workspace.transferQueue.activeJobsCount) i kø")
                                        .font(.system(size: 11, weight: .semibold))
                                }
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.accentColor)
                        }

                        Button {
                            withAnimation(.snappy(duration: 0.2)) {
                                workspace.toggleTerminalDrawer()
                            }
                        } label: {
                            Label(
                                workspace.isTerminalDrawerVisible ? "Skjul Terminal" : "Terminal-skuff",
                                systemImage: "terminal"
                            )
                            .font(.system(size: 11, weight: workspace.isTerminalDrawerVisible ? .semibold : .regular))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(workspace.isTerminalDrawerVisible ? Color.accentColor : .secondary)
                        .help("Vis/skjul innebygd synkronisert Terminal-skuff (Ctrl+`)")

                        Button {
                            workspace.isSettingsVisible = true
                        } label: {
                            Image(systemName: "gearshape")
                                .font(.system(size: 11.5))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("FlowFile-innstillinger (Cmd+,)")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .liquidGlassPanel(cornerRadius: 10)
            }
        }
    }

    @ViewBuilder
    private func fKeyButton(
        _ key: String,
        title: String,
        destructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(key)
                    .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.primary.opacity(0.10))
                    )
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(destructive ? Color.red : Color.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
        .buttonStyle(.glass)
    }
}
