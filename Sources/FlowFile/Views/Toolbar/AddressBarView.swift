import AppKit
import SwiftUI

struct BreadcrumbSegment: Identifiable {
    let id: String
    let title: String
    let url: URL
    let isRoot: Bool
}

struct AddressBarView: View {
    @Bindable var workspace: WorkspaceState
    @State private var isEditing: Bool = false
    @State private var draftPath: String = ""
    @State private var didJustCopyPath: Bool = false
    @FocusState private var isTextFieldFocused: Bool

    private var currentURL: URL {
        workspace.activeTab.currentURL
    }

    private var fullDisplayPath: String {
        workspace.activeTab.displayPathString
    }

    private var segments: [BreadcrumbSegment] {
        var result: [BreadcrumbSegment] = []
        let rootName = FileManager.default.displayName(atPath: "/")
        result.append(BreadcrumbSegment(id: "/", title: rootName, url: URL(fileURLWithPath: "/"), isRoot: true))

        let components = currentURL.standardizedFileURL.pathComponents
        var runningURL = URL(fileURLWithPath: "/")
        for comp in components where comp != "/" {
            runningURL.appendPathComponent(comp)
            result.append(BreadcrumbSegment(
                id: runningURL.path,
                title: comp,
                url: runningURL,
                isRoot: false
            ))
        }
        return result
    }

    var body: some View {
        HStack(spacing: 6) {
            if isEditing {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 10)

                TextField(workspace.tr("Skriv eller lim inn sti (f.eks. ~/Projects)...", "Type or paste path (e.g. ~/Projects)..."), text: $draftPath)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .focused($isTextFieldFocused)
                    .onSubmit {
                        commitPathEdit()
                    }
                    .onExitCommand {
                        cancelEdit()
                    }

                Button(workspace.tr("Kopier", "Copy")) {
                    copyPathToClipboard(draftPath)
                }
                .font(.system(size: 11, weight: .medium))
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)

                Button {
                    cancelEdit()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 8)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 3) {
                        ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                            if index > 0 {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.tertiary)
                            }

                            Button {
                                workspace.navigateActiveTab(to: segment.url)
                            } label: {
                                HStack(spacing: 4) {
                                    if segment.isRoot {
                                        Image(systemName: "internaldrive")
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                    }
                                    Text(segment.title)
                                        .font(.system(size: 12.5, weight: index == segments.count - 1 ? .semibold : .regular))
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .contentShape(RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.leading, 8)
                }

                // Clicking empty space in the address bar switches to direct path editing with full text selection!
                Color.clear
                    .frame(minWidth: 36, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .help("Klikk her eller trykk Cmd+L for å markere, kopiere eller skrive sti direkte")
                    .onTapGesture {
                        beginEditing()
                    }

                HStack(spacing: 7) {
                    if let archiveURL = workspace.activeTab.archiveFileURL {
                        HStack(spacing: 4) {
                            Image(systemName: "doc.zipper")
                                .font(.system(size: 10.5, weight: .semibold))
                            Text(archiveURL.lastPathComponent)
                                .font(.system(size: 11, weight: .semibold))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.orange.opacity(0.18)))
                        .foregroundStyle(.orange)
                    } else if let branch = workspace.activeTab.gitBranch {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.system(size: 10, weight: .semibold))
                            Text(branch)
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                        .foregroundStyle(Color.accentColor)
                        .help("Aktiv Git-branch i denne mappen")
                    }

                    // Prominent "Kopier sti" pill right in the address bar!
                    Button {
                        copyPathToClipboard(currentURL.path)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: didJustCopyPath ? "checkmark.circle.fill" : "doc.on.doc")
                                .font(.system(size: 11, weight: .semibold))
                            Text(didJustCopyPath
                                 ? workspace.tr("Kopiert!", "Copied!")
                                 : workspace.tr("Kopier sti", "Copy Path"))
                                .font(.system(size: 11.5, weight: .medium))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill(didJustCopyPath ? Color.green.opacity(0.20) : Color.primary.opacity(0.08))
                        )
                        .foregroundStyle(didJustCopyPath ? .green : .primary)
                    }
                    .buttonStyle(.plain)
                    .tourTarget(.copyPathButton)
                    .help(workspace.tr(
                        "Kopier hele mappestien til utklippstavlen (\(currentURL.path))",
                        "Copy full folder path to clipboard (\(currentURL.path))"
                    ))

                    Button {
                        workspace.togglePin(currentURL)
                    } label: {
                        Image(systemName: workspace.isPinned(currentURL) ? "pin.fill" : "pin")
                            .font(.system(size: 11))
                            .foregroundStyle(workspace.isPinned(currentURL) ? Color.accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help(workspace.isPinned(currentURL) ? "Fjern mappe fra Hurtigtilgang" : "Fest mappe til Hurtigtilgang")

                    Button {
                        beginEditing()
                    } label: {
                        Image(systemName: "character.cursor.ibeam")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Rediger mappesti (Cmd+L)")
                }
                .padding(.trailing, 8)
            }
        }
        .frame(height: 32)
        .liquidGlassPanel(cornerRadius: 10, interactive: true)
        .contextMenu {
            Button("Kopier hele mappestien", systemImage: "doc.on.doc") {
                copyPathToClipboard(currentURL.path)
            }
            Button("Kopier sti klar for Terminal (med anførselstegn)", systemImage: "terminal") {
                let escaped = "'" + currentURL.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
                copyPathToClipboard(escaped)
            }
            if let selectedItem = workspace.activeTab.primarySelectedItem {
                Button("Kopier sti til valgt fil (\(selectedItem.name))", systemImage: "doc") {
                    copyPathToClipboard(selectedItem.url.path)
                }
            }
            Divider()
            Button("Lim inn sti og gå dit", systemImage: "arrow.right.circle") {
                if let pasted = NSPasteboard.general.string(forType: .string),
                   let resolved = FileSystemService.resolveUserPath(pasted, relativeTo: currentURL) {
                    workspace.navigateActiveTab(to: resolved)
                } else {
                    workspace.alertErrorMessage = "Utklippstavlen inneholder ikke en gyldig mappesti."
                }
            }
            Button("Rediger adresselinje (Cmd+L)", systemImage: "character.cursor.ibeam") {
                beginEditing()
            }
        }
        .onChange(of: workspace.addressBarFocusTrigger) { _, _ in
            beginEditing()
        }
        .onChange(of: isTextFieldFocused) { _, focused in
            if !focused && isEditing {
                isEditing = false
            }
        }
    }

    private func copyPathToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        didJustCopyPath = true
        workspace.notifyDidCopyPath()
        workspace.showStatus(workspace.tr("Kopierte sti: \(text)", "Copied path: \(text)"))
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            didJustCopyPath = false
        }
    }

    private func beginEditing() {
        draftPath = fullDisplayPath
        isEditing = true
        DispatchQueue.main.async {
            isTextFieldFocused = true
            // Automatically select entire path text just like Windows File Explorer!
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
            }
        }
    }

    private func cancelEdit() {
        isEditing = false
        isTextFieldFocused = false
    }

    private func commitPathEdit() {
        guard let resolved = FileSystemService.resolveUserPath(draftPath, relativeTo: currentURL) else {
            workspace.alertErrorMessage = "Fant ikke stien «\(draftPath)»."
            return
        }
        isEditing = false
        isTextFieldFocused = false
        workspace.navigateActiveTab(to: resolved)
    }
}
