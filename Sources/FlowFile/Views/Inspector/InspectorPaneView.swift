import AppKit
import QuickLookThumbnailing
import SwiftUI

struct InspectorPaneView: View {
    @Bindable var workspace: WorkspaceState
    @State private var previewImage: NSImage? = nil
    @State private var isCalculatingSize: Bool = false
    @State private var computedSHA256: String? = nil
    @State private var isComputingSHA256: Bool = false
    @State private var didCopySHA256: Bool = false

    private var activeTab: TabState {
        workspace.activeTab
    }

    private var inspectedItem: FileItem? {
        activeTab.primarySelectedItem
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("Detaljer & Forhåndsvisning", systemImage: "info.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        workspace.isInspectorVisible = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                if let item = inspectedItem {
                    // Large Preview Card
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.primary.opacity(0.05))
                            .frame(height: 170)

                        if let previewImage {
                            Image(nsImage: previewImage)
                                .resizable()
                                .scaledToFit()
                                .frame(maxHeight: 154)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .padding(8)
                        } else {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                                .resizable()
                                .scaledToFit()
                                .frame(width: 72, height: 72)
                        }
                    }
                    .onTapGesture(count: 2) {
                        workspace.triggerQuickLook()
                    }
                    .task(id: item.url) {
                        computedSHA256 = nil
                        isComputingSHA256 = false
                        didCopySHA256 = false
                        await loadLargePreview(for: item)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.name)
                            .font(.system(size: 14, weight: .semibold))
                            .textSelection(.enabled)
                        Text(item.kindDescription)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        metadataRow("Størrelse") {
                            if item.isNavigableFolder {
                                if let calc = activeTab.calculatedFolderSizes[item.url] {
                                    Text(ByteFormatter.string(fromByteCount: calc))
                                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                } else if isCalculatingSize {
                                    ProgressView().controlSize(.mini)
                                } else {
                                    Button("Beregn størrelse") {
                                        calculateSize(for: item.url)
                                    }
                                    .buttonStyle(.link)
                                    .font(.system(size: 12))
                                }
                            } else {
                                Text("\(ByteFormatter.string(fromByteCount: item.size)) (\(item.size.formatted()) B)")
                                    .font(.system(size: 11.5, design: .monospaced))
                            }
                        }

                        if let mod = item.modificationDate {
                            metadataRow("Endret") {
                                Text(DateFormatterCache.full.string(from: mod))
                                    .font(.system(size: 11.5))
                            }
                        }

                        if let created = item.creationDate {
                            metadataRow("Opprettet") {
                                Text(DateFormatterCache.full.string(from: created))
                                    .font(.system(size: 11.5))
                            }
                        }

                        metadataRow("Rettigheter") {
                            Text(FileSystemService.posixPermissionsString(for: item.url))
                                .font(.system(size: 11.5, design: .monospaced))
                        }

                        if item.cloudState != .none {
                            metadataRow("Skystatus") {
                                Text("\(item.cloudState.badgeSymbol) \(item.cloudState.descriptionText)")
                                    .font(.system(size: 11.5, weight: .medium))
                            }
                        }

                        if let resolved = item.resolvedTargetURL {
                            metadataRow("Snarvei til") {
                                Text(resolved.path)
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .lineLimit(2)
                                    .textSelection(.enabled)
                            }
                        }

                        if !activeTab.isInsideArchive {
                            metadataRow(workspace.tr("Fargetagg", "Color Tag")) {
                                HStack(spacing: 5) {
                                    let activeTags = Set(item.colorTags)
                                    ForEach(FinderColorTag.allCases) { tag in
                                        Button {
                                            workspace.toggleColorTagOnSelection(tag)
                                        } label: {
                                            Circle()
                                                .fill(tag.swiftUIColor)
                                                .frame(width: 13, height: 13)
                                                .overlay(
                                                    Circle()
                                                        .strokeBorder(activeTags.contains(tag) ? Color.primary : Color.black.opacity(0.2), lineWidth: activeTags.contains(tag) ? 1.8 : 0.6)
                                                )
                                        }
                                        .buttonStyle(.plain)
                                        .help("\(tag.title) (⌃\(tag.shortcutDigit))")
                                    }
                                    if !item.colorTags.isEmpty {
                                        Button {
                                            workspace.clearColorTagsOnSelection()
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .font(.system(size: 12))
                                                .foregroundStyle(.secondary)
                                        }
                                        .buttonStyle(.plain)
                                        .help(workspace.tr("Fjern fargetagger", "Clear color tags"))
                                    }
                                }
                            }
                        }

                        if !item.isNavigableFolder && !activeTab.isInsideArchive {
                            metadataRow("SHA-256") {
                                if let sha = computedSHA256 {
                                    VStack(alignment: .trailing, spacing: 4) {
                                        Text(sha)
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                            .multilineTextAlignment(.trailing)
                                            .textSelection(.enabled)
                                        Button {
                                            NSPasteboard.general.clearContents()
                                            NSPasteboard.general.setString(sha, forType: .string)
                                            didCopySHA256 = true
                                        } label: {
                                            Label(
                                                didCopySHA256 ? workspace.tr("Kopiert", "Copied") : workspace.tr("Kopier hash", "Copy Hash"),
                                                systemImage: didCopySHA256 ? "checkmark" : "doc.on.doc"
                                            )
                                            .font(.system(size: 10.5, weight: .medium))
                                        }
                                        .buttonStyle(.link)
                                    }
                                } else if isComputingSHA256 {
                                    ProgressView().controlSize(.mini)
                                } else {
                                    Button(workspace.tr("Beregn SHA-256", "Compute SHA-256")) {
                                        computeSHA256(for: item.url)
                                    }
                                    .buttonStyle(.link)
                                    .font(.system(size: 11.5))
                                }
                            }
                        }
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 4) {
                        Text("FULL STI")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary)
                        Text(item.url.path)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }

                    HStack(spacing: 6) {
                        Button {
                            workspace.triggerQuickLook()
                        } label: {
                            Label("Quick Look", systemImage: "eye")
                                .font(.system(size: 12))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass)

                        Button {
                            workspace.openShareHub()
                        } label: {
                            Label("Del...", systemImage: "square.and.arrow.up")
                                .font(.system(size: 12))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass)
                    }
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "folder.badge.questionmark")
                            .font(.system(size: 28))
                            .foregroundStyle(.tertiary)
                        Text("Velg en fil eller mappe for å se detaljer og forhåndsvisning.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                }
            }
            .padding(12)
        }
        .frame(minWidth: 230, idealWidth: 260, maxWidth: 310)
        .liquidGlassPanel(cornerRadius: 14)
    }

    @ViewBuilder
    private func metadataRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .leading)
            Spacer(minLength: 4)
            content()
        }
    }

    private func loadLargePreview(for item: FileItem) async {
        previewImage = nil
        guard !item.isNavigableFolder else { return }
        let req = QLThumbnailGenerator.Request(
            fileAt: item.url,
            size: CGSize(width: 360, height: 320),
            scale: NSScreen.main?.backingScaleFactor ?? 2.0,
            representationTypes: .all
        )
        if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req) {
            previewImage = rep.nsImage
        }
    }

    private func calculateSize(for folderURL: URL) {
        isCalculatingSize = true
        Task { @MainActor in
            let size = await FileSystemService.calculateFolderSize(at: folderURL)
            activeTab.calculatedFolderSizes[folderURL] = size
            isCalculatingSize = false
        }
    }

    private func computeSHA256(for fileURL: URL) {
        isComputingSHA256 = true
        didCopySHA256 = false
        Task { @MainActor in
            if let digest = try? await QuickFileToolsService.computeSHA256(for: fileURL),
               inspectedItem?.url == fileURL {
                computedSHA256 = digest
            }
            isComputingSHA256 = false
        }
    }
}
