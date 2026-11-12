import AppKit
import QuickLookThumbnailing
import SwiftUI

struct FileGridView: View {
    @Bindable var pane: PaneState
    @Bindable var tab: TabState
    @Bindable var workspace: WorkspaceState

    private let columns = [
        GridItem(.adaptive(minimum: 108, maximum: 132), spacing: 12)
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(tab.displayedItems) { item in
                    let isSelected = tab.selectedURLs.contains(item.url)
                    let isMarked = tab.markedURLs.contains(item.url)
                    let isCut = workspace.isItemCut(item.url)

                    FileGridCell(
                        item: item,
                        isSelected: isSelected,
                        isMarked: isMarked,
                        isCut: isCut
                    )
                    .onTapGesture(count: 2) {
                        workspace.activePaneID = pane.id
                        workspace.openItem(item)
                    }
                    .simultaneousGesture(
                        TapGesture(count: 1).onEnded {
                            workspace.activePaneID = pane.id
                            if NSEvent.modifierFlags.contains(.command) {
                                if tab.selectedURLs.contains(item.url) {
                                    tab.selectedURLs.remove(item.url)
                                } else {
                                    tab.selectedURLs.insert(item.url)
                                }
                            } else {
                                tab.selectedURLs = [item.url]
                            }
                            QuickLookCoordinator.shared.updateSelectionIfVisible(Array(tab.selectedURLs))
                        }
                    )
                    .contextMenu {
                        Button("Åpne") {
                            workspace.activePaneID = pane.id
                            workspace.openItem(item)
                        }
                        Button("Quick Look (Space)") {
                            workspace.activePaneID = pane.id
                            tab.selectedURLs = [item.url]
                            workspace.triggerQuickLook()
                        }
                        Divider()
                        Button("Klipp ut (Cmd+X)") {
                            workspace.activePaneID = pane.id
                            tab.selectedURLs = [item.url]
                            workspace.cutSelected()
                        }
                        Button("Kopier (Cmd+C)") {
                            workspace.activePaneID = pane.id
                            tab.selectedURLs = [item.url]
                            workspace.copySelected()
                        }
                        Button("Gi nytt navn (F2)") {
                            workspace.activePaneID = pane.id
                            tab.selectedURLs = [item.url]
                            workspace.promptRenameSelected()
                        }
                        Divider()
                        Button("Flytt til Papirkurv", role: .destructive) {
                            workspace.activePaneID = pane.id
                            tab.selectedURLs = [item.url]
                            workspace.trashSelected()
                        }
                    }
                }
            }
            .padding(14)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .onTapGesture {
            workspace.activePaneID = pane.id
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard !tab.isInsideArchive, workspace.guardNotInTourSandbox() else { return false }
            let fileURLs = urls.filter(\.isFileURL)
            guard !fileURLs.isEmpty else { return false }
            let targetDir = tab.currentURL
            let op = FileSystemService.preferredDragOperation(
                for: fileURLs,
                to: targetDir,
                modifierFlags: NSEvent.modifierFlags
            )
            workspace.transferQueue.enqueue(operation: op, urls: fileURLs, to: targetDir)
            return true
        }
    }
}

struct FileGridCell: View {
    let item: FileItem
    let isSelected: Bool
    let isMarked: Bool
    let isCut: Bool

    @State private var thumbnail: NSImage? = nil

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    } else {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                            .resizable()
                            .scaledToFit()
                            .padding(8)
                    }
                }
                .frame(width: 68, height: 68)

                if isMarked {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.orange)
                        .background(Circle().fill(.background))
                        .offset(x: 4, y: -4)
                } else if item.cloudState != .none {
                    cloudBadgeView
                        .offset(x: 4, y: -4)
                        .help(item.cloudState.descriptionText)
                }
            }

            Text(item.name)
                .font(.system(size: 11.5, weight: isSelected || isMarked ? .semibold : .regular))
                .foregroundStyle(isMarked ? .orange : .primary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            if !item.isNavigableFolder {
                Text(item.formattedSize())
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .opacity(isCut ? 0.45 : (item.isHidden ? 0.72 : 1.0))
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.20) : Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    isMarked ? Color.orange : (isSelected ? Color.accentColor : Color.clear),
                    lineWidth: 1.5
                )
        )
        .task(id: item.url) {
            await loadThumbnailIfApplicable()
        }
    }

    @ViewBuilder
    private var cloudBadgeView: some View {
        switch item.cloudState {
        case .cloudOnly:
            LucideIcon(kind: .cloudDownload, size: 15)
                .foregroundStyle(.blue)
                .padding(3)
                .background(Circle().fill(.background))
        case .localSynced:
            LucideIcon(kind: .checkCircle, size: 15)
                .foregroundStyle(.green)
                .padding(3)
                .background(Circle().fill(.background))
        case .syncing:
            LucideIcon(kind: .refreshCw, size: 15)
                .foregroundStyle(.blue)
                .padding(3)
                .background(Circle().fill(.background))
        case .none:
            EmptyView()
        }
    }

    private func loadThumbnailIfApplicable() async {
        guard !item.isNavigableFolder, item.cloudState != .cloudOnly else { return }
        let req = QLThumbnailGenerator.Request(
            fileAt: item.url,
            size: CGSize(width: 136, height: 136),
            scale: NSScreen.main?.backingScaleFactor ?? 2.0,
            representationTypes: .thumbnail
        )
        if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req) {
            self.thumbnail = rep.nsImage
        }
    }
}
