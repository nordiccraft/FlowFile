import AppKit
import SwiftUI

struct SidebarView: View {
    @Bindable var workspace: WorkspaceState

    private var activePath: String {
        workspace.activeTab.currentURL.standardizedFileURL.path
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Section 1: Hurtigtilgang (Pinned Favorites)
                VStack(alignment: .leading, spacing: 4) {
                    sectionHeader(workspace.tr("Hurtigtilgang", "Quick Access"), icon: "star.fill")

                    ForEach(workspace.favorites) { fav in
                        let isSelected = activePath == fav.path
                        Button {
                            workspace.navigateActiveTab(to: fav.url)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: fav.systemImage)
                                    .font(.system(size: 13))
                                    .foregroundStyle(isSelected ? Color.white : Color.accentColor)
                                    .frame(width: 18)

                                Text(fav.title)
                                    .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                                    .lineLimit(1)

                                Spacer()
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(isSelected ? Color.accentColor : Color.clear)
                            )
                            .contentShape(RoundedRectangle(cornerRadius: 7))
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Åpne i ny fane") {
                                workspace.activePane.addTab(at: fav.url, showHidden: workspace.showHiddenFiles)
                            }
                            if workspace.isDualPane {
                                Button("Åpne i motsatt panel") {
                                    workspace.inactivePane.activeTab.navigate(to: fav.url, showHidden: workspace.showHiddenFiles)
                                }
                            }
                            Divider()
                            Button("Fjern fra Hurtigtilgang", role: .destructive) {
                                workspace.togglePin(fav.url)
                            }
                        }
                    }
                }

                // Section 1B: Lagrede arbeidsområder (Saved Workspaces)
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        sectionHeader(workspace.tr("Arbeidsområder", "Workspaces"), icon: "square.stack.3d.up.fill")
                        Spacer()
                        Button {
                            workspace.isSaveWorkspaceSheetVisible = true
                        } label: {
                            Image(systemName: "plus.circle")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                        }
                        .buttonStyle(.plain)
                        .help(workspace.tr("Lagre gjeldende fane- og paneloppsett (⌥⌘S)", "Save current tab & pane layout (⌥⌘S)"))
                    }

                    if workspace.savedWorkspaces.isEmpty {
                        Button {
                            workspace.isSaveWorkspaceSheetVisible = true
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "plus")
                                    .font(.system(size: 10, weight: .bold))
                                Text(workspace.tr("Lagre nåværende oppsett...", "Save current layout..."))
                                    .font(.system(size: 11.5))
                            }
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                    } else {
                        ForEach(workspace.savedWorkspaces) { saved in
                            Button {
                                workspace.applySavedWorkspace(saved)
                            } label: {
                                HStack(spacing: 7) {
                                    Image(systemName: saved.snapshot.isDualPane ? "rectangle.split.2x1.fill" : "rectangle")
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(Color.accentColor)
                                        .frame(width: 18)

                                    VStack(alignment: .leading, spacing: 0) {
                                        Text(saved.name)
                                            .font(.system(size: 12, weight: .medium))
                                            .lineLimit(1)
                                        Text(saved.summaryLabel)
                                            .font(.system(size: 10))
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .fill(Color.primary.opacity(0.035))
                                )
                                .contentShape(RoundedRectangle(cornerRadius: 7))
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(workspace.tr("Åpne arbeidsområde", "Open Workspace")) {
                                    workspace.applySavedWorkspace(saved)
                                }
                                Divider()
                                Button(workspace.tr("Slett arbeidsområde", "Delete Workspace"), role: .destructive) {
                                    workspace.deleteSavedWorkspace(id: saved.id)
                                }
                            }
                        }
                    }
                }

                // Section 1C: macOS Fargetagger (Color Tags)
                VStack(alignment: .leading, spacing: 6) {
                    sectionHeader(workspace.tr("Fargetagger", "Color Tags"), icon: "tag.fill")

                    HStack(spacing: 7) {
                        ForEach(FinderColorTag.allCases) { tag in
                            let isFilteredInTab = workspace.activeTab.activeColorTagFilter == tag
                            Button {
                                workspace.openTaggedFilesBrowser(for: tag)
                            } label: {
                                Circle()
                                    .fill(tag.swiftUIColor)
                                    .frame(width: 16, height: 16)
                                    .overlay(
                                        Circle()
                                            .strokeBorder(isFilteredInTab ? Color.primary : Color.black.opacity(0.18), lineWidth: isFilteredInTab ? 2 : 0.8)
                                    )
                            }
                            .buttonStyle(.plain)
                            .help(workspace.tr(
                                "\(tag.title) – klikk for å finne merkede filer (høyreklikk for å filtrere aktiv mappe)",
                                "\(tag.title) – click to browse tagged files (right-click to filter active folder)"
                            ))
                            .contextMenu {
                                Button(workspace.tr("Finn alle filer med taggen «\(tag.title)»...", "Browse all '\(tag.title)' items...")) {
                                    workspace.openTaggedFilesBrowser(for: tag)
                                }
                                Button(workspace.tr("Filtrer kun aktiv mappe på «\(tag.title)»", "Filter active folder by '\(tag.title)'")) {
                                    workspace.activeTab.activeColorTagFilter = (workspace.activeTab.activeColorTagFilter == tag) ? nil : tag
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                }

                // Section 2: Skylagring (OneDrive, Dropbox, Google Drive, Box & iCloud Drive!)
                if !workspace.cloudAccounts.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        sectionHeader(workspace.tr("Skylagring", "Cloud Storage"), icon: "icloud.fill")

                        ForEach(workspace.cloudAccounts) { account in
                            let isSelected = activePath == account.rootURL.path || activePath.hasPrefix(account.rootURL.path + "/")
                            Button {
                                workspace.navigateActiveTab(to: account.rootURL)
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: account.provider.systemImage)
                                        .font(.system(size: 13))
                                        .foregroundStyle(isSelected ? Color.white : Color.accentColor)
                                        .frame(width: 18)

                                    VStack(alignment: .leading, spacing: 0) {
                                        Text(account.displayName)
                                            .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                                            .foregroundStyle(isSelected ? Color.white : Color.primary)
                                            .lineLimit(1)

                                        if let subtitle = account.subtitle, !subtitle.isEmpty {
                                            Text(subtitle)
                                                .font(.system(size: 10))
                                                .foregroundStyle(isSelected ? Color.white.opacity(0.85) : .secondary)
                                                .lineLimit(1)
                                        }
                                    }

                                    Spacer()
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .fill(isSelected ? Color.accentColor : Color.clear)
                                )
                                .contentShape(RoundedRectangle(cornerRadius: 7))
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Åpne i ny fane") {
                                    workspace.activePane.addTab(at: account.rootURL, showHidden: workspace.showHiddenFiles)
                                }
                                if workspace.isDualPane {
                                    Button("Åpne i motsatt panel") {
                                        workspace.inactivePane.activeTab.navigate(to: account.rootURL, showHidden: workspace.showHiddenFiles)
                                    }
                                }
                                Button(workspace.isPinned(account.rootURL) ? "Fjern fra Hurtigtilgang" : "Fest til Hurtigtilgang") {
                                    workspace.togglePin(account.rootURL)
                                }
                            }
                        }
                    }
                }

                // Section 3: Denne maskinen (Disks & Volumes with storage meter!)
                VStack(alignment: .leading, spacing: 6) {
                    sectionHeader(workspace.tr("Denne maskinen", "This Mac"), icon: "desktopcomputer")

                    ForEach(workspace.volumes) { vol in
                        let isSelected = activePath == vol.url.standardizedFileURL.path
                        Button {
                            workspace.navigateActiveTab(to: vol.url)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 7) {
                                    Image(systemName: vol.systemImage)
                                        .font(.system(size: 13))
                                        .foregroundStyle(vol.usedFraction > 0.9 ? .orange : Color.accentColor)
                                        .frame(width: 18)

                                    Text(vol.name)
                                        .font(.system(size: 12.5, weight: .medium))
                                        .lineLimit(1)

                                    Spacer()

                                    if vol.isEjectable {
                                        Button {
                                            try? NSWorkspace.shared.unmountAndEjectDevice(at: vol.url)
                                            workspace.refreshVolumesAndTree()
                                        } label: {
                                            Image(systemName: "eject.fill")
                                                .font(.system(size: 10))
                                                .foregroundStyle(.secondary)
                                        }
                                        .buttonStyle(.plain)
                                        .help("Løs ut disk")
                                    }
                                }

                                ProgressView(value: vol.usedFraction)
                                    .tint(vol.usedFraction > 0.9 ? .red : Color.accentColor)
                                    .controlSize(.mini)

                                Text(vol.capacitySummary)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .padding(8)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.04))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.6) : Color.clear, lineWidth: 1)
                            )
                            .contentShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Section 4: Utvidbart mappetre
                VStack(alignment: .leading, spacing: 4) {
                    sectionHeader(workspace.tr("Mappetre", "Folder Tree"), icon: "list.bullet.indent")

                    ForEach(workspace.rootTreeNodes) { node in
                        FolderTreeRowView(
                            node: node,
                            depth: 0,
                            workspace: workspace
                        )
                    }
                }
            }
            .padding(10)
        }
        .frame(minWidth: 210, idealWidth: 235, maxWidth: 300)
        .liquidGlassPanel(cornerRadius: 14)
    }

    @ViewBuilder
    private func sectionHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(.secondary)
                .tracking(0.5)
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 2)
    }
}

struct FolderTreeRowView: View {
    @Bindable var node: FolderTreeNode
    let depth: Int
    @Bindable var workspace: WorkspaceState

    private var isCurrentFolder: Bool {
        workspace.activeTab.currentURL.standardizedFileURL == node.url.standardizedFileURL
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Button {
                    node.isExpanded.toggle()
                    if node.isExpanded {
                        node.loadChildrenIfNeeded(showHidden: workspace.showHiddenFiles)
                    }
                } label: {
                    Image(systemName: node.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 14, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    workspace.navigateActiveTab(to: node.url)
                    if !node.isExpanded {
                        node.isExpanded = true
                        node.loadChildrenIfNeeded(showHidden: workspace.showHiddenFiles)
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: node.isExpanded ? "folder.fill" : "folder")
                            .font(.system(size: 12))
                            .foregroundStyle(isCurrentFolder ? Color.white : Color.accentColor)

                        Text(node.name)
                            .font(.system(size: 12, weight: isCurrentFolder ? .semibold : .regular))
                            .foregroundStyle(isCurrentFolder ? Color.white : Color.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 3)
                    .padding(.horizontal, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(isCurrentFolder ? Color.accentColor : Color.clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Åpne i ny fane") {
                        workspace.activePane.addTab(at: node.url, showHidden: workspace.showHiddenFiles)
                    }
                    Button(workspace.isPinned(node.url) ? "Fjern fra Hurtigtilgang" : "Fest til Hurtigtilgang") {
                        workspace.togglePin(node.url)
                    }
                    Button("Oppdater undermapper") {
                        node.reloadChildren(showHidden: workspace.showHiddenFiles)
                    }
                }
            }
            .padding(.leading, CGFloat(depth) * 12)

            if node.isExpanded {
                if node.isLoading && (node.children ?? []).isEmpty {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Laster...")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.leading, CGFloat(depth + 2) * 12)
                    .padding(.vertical, 2)
                } else if let children = node.children {
                    ForEach(children) { child in
                        FolderTreeRowView(
                            node: child,
                            depth: depth + 1,
                            workspace: workspace
                        )
                    }
                }
            }
        }
    }
}
