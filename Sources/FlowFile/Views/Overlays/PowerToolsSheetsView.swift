import AppKit
import SwiftUI

// MARK: - Reusable Color Tag Dots View

struct ColorTagDotsView: View {
    let tags: [FinderColorTag]
    var dotSize: CGFloat = 8

    var body: some View {
        if !tags.isEmpty {
            HStack(spacing: -2) {
                ForEach(tags.prefix(3)) { tag in
                    Circle()
                        .fill(tag.swiftUIColor)
                        .frame(width: dotSize, height: dotSize)
                        .overlay(
                            Circle().strokeBorder(Color.black.opacity(0.22), lineWidth: 0.6)
                        )
                }
            }
        }
    }
}

// MARK: - 1. Deep Subfolder & File-Content Search Sheet (⇧⌘F)

struct DeepSearchSheetView: View {
    @Bindable var workspace: WorkspaceState
    @Environment(\.dismiss) private var dismiss

    @State private var nameQuery: String = ""
    @State private var contentQuery: String = ""
    @State private var sizeFilterChoice: Int = 0
    @State private var dateFilterChoice: Int = 0
    @State private var selectedTag: FinderColorTag? = nil
    @State private var caseSensitiveContent: Bool = false
    @State private var searchEntireHome: Bool = false

    @State private var matches: [DeepSearchMatch] = []
    @State private var isSearching: Bool = false
    @State private var hasSearchedOnce: Bool = false
    @State private var accessWarning: String? = nil
    @State private var searchTask: Task<Void, Never>? = nil

    private var rootURL: URL {
        searchEntireHome
            ? FileManager.default.homeDirectoryForCurrentUser
            : workspace.activeTab.currentURL
    }

    private var resolvedMinBytes: Int64? {
        switch sizeFilterChoice {
        case 1: return 1_000_000          // > 1 MB
        case 2: return 10_000_000         // > 10 MB
        case 3: return 100_000_000        // > 100 MB
        case 4: return 1_000_000_000      // > 1 GB
        default: return nil
        }
    }

    private var resolvedModifiedDays: Int? {
        switch dateFilterChoice {
        case 1: return 1
        case 2: return 7
        case 3: return 30
        case 4: return 365
        default: return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(
                    workspace.tr("Dypsøk i undermapper og filinnhold", "Deep Subfolder & Content Search"),
                    systemImage: "magnifyingglass.circle.fill"
                )
                .font(.system(size: 16, weight: .bold))

                Spacer()

                Picker("", selection: $searchEntireHome) {
                    Text(workspace.tr("Gjeldende mappe", "Current Folder")).tag(false)
                    Text(workspace.tr("Hele hjemmemappen", "Entire Home")).tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 260)
                .onChange(of: searchEntireHome) { _, _ in
                    if hasSearchedOnce { triggerSearch() }
                }

                Button(workspace.tr("Lukk", "Close")) {
                    searchTask?.cancel()
                    dismiss()
                }
                .buttonStyle(.glass)
            }

            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(rootURL.path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(workspace.tr("Fil- eller mappenavn (støtter * og ?)", "File or folder name (supports * and ?)"))
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                        TextField(workspace.tr("F.eks. faktura, *.apk, rapport*.pdf ...", "E.g. invoice, *.apk, report*.pdf ..."), text: $nameQuery)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { triggerSearch() }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(workspace.tr("Tekstinnhold inni filen (valgfritt)", "Text inside file (optional)"))
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Toggle(workspace.tr("Skill store/små", "Match case"), isOn: $caseSensitiveContent)
                                .toggleStyle(.checkbox)
                                .font(.system(size: 10.5))
                        }
                        TextField(workspace.tr("Søk i tekst, kode, CSV, JSON, logg ...", "Search inside text, code, CSV, JSON, logs ..."), text: $contentQuery)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { triggerSearch() }
                    }
                }

                HStack(spacing: 12) {
                    Picker(workspace.tr("Størrelse:", "Size:"), selection: $sizeFilterChoice) {
                        Text(workspace.tr("Alle størrelser", "Any size")).tag(0)
                        Text("> 1 MB").tag(1)
                        Text("> 10 MB").tag(2)
                        Text("> 100 MB").tag(3)
                        Text("> 1 GB").tag(4)
                    }
                    .frame(width: 195)

                    Picker(workspace.tr("Endret:", "Modified:"), selection: $dateFilterChoice) {
                        Text(workspace.tr("Når som helst", "Any time")).tag(0)
                        Text(workspace.tr("Siste 24 timer", "Last 24 hours")).tag(1)
                        Text(workspace.tr("Siste 7 dager", "Last 7 days")).tag(2)
                        Text(workspace.tr("Siste 30 dager", "Last 30 days")).tag(3)
                        Text(workspace.tr("Siste år", "Last year")).tag(4)
                    }
                    .frame(width: 205)

                    HStack(spacing: 5) {
                        Text(workspace.tr("Tagg:", "Tag:"))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        ForEach(FinderColorTag.allCases) { tag in
                            let isPicked = selectedTag == tag
                            Button {
                                selectedTag = isPicked ? nil : tag
                            } label: {
                                Circle()
                                    .fill(tag.swiftUIColor)
                                    .frame(width: 14, height: 14)
                                    .overlay(
                                        Circle()
                                            .strokeBorder(isPicked ? Color.primary : Color.clear, lineWidth: 2)
                                    )
                            }
                            .buttonStyle(.plain)
                            .help(tag.title)
                        }
                    }

                    Spacer()

                    if isSearching {
                        Button(workspace.tr("Stopp", "Stop")) {
                            searchTask?.cancel()
                            isSearching = false
                        }
                        .buttonStyle(.glass)
                    }

                    Button {
                        triggerSearch()
                    } label: {
                        Label(workspace.tr("Søk nå", "Search"), systemImage: "magnifyingglass")
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )

            Divider()

            if let accessWarning {
                VStack(spacing: 10) {
                    Image(systemName: "lock.trianglebadge.exclamationmark.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.orange)
                    Text(accessWarning)
                        .font(.system(size: 12.5, weight: .medium))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 480)
                    Button(workspace.tr("Åpne Full disktilgang-innstillinger", "Open Full Disk Access Settings")) {
                        PermissionsService.openFullDiskAccessSettings()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if isSearching {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(workspace.tr("Søker gjennom undermapper...", "Searching subfolders..."))
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if matches.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: hasSearchedOnce ? "doc.text.magnifyingglass" : "magnifyingglass")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text(hasSearchedOnce
                         ? workspace.tr("Ingen treff for disse kriteriene i «\(rootURL.lastPathComponent)».", "No matches found in '\(rootURL.lastPathComponent)'.")
                         : workspace.tr("Skriv inn søkeord eller velg et filter og trykk «Søk nå».", "Enter a search query or pick a filter and click 'Search'."))
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack {
                    Text(workspace.tr("\(matches.count) treff funnet", "\(matches.count) matches found"))
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                }

                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(matches) { match in
                            HStack(spacing: 10) {
                                Image(nsImage: FileIconCache.shared.icon(for: match.item))
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 20, height: 20)

                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(match.item.name)
                                            .font(.system(size: 12.5, weight: .semibold))
                                            .lineLimit(1)
                                        ColorTagDotsView(tags: match.item.colorTags)
                                        Text(match.relativeFolder)
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }

                                    if let snippet = match.matchedLinePreview {
                                        Text(snippet)
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundStyle(Color.accentColor)
                                            .lineLimit(1)
                                    }
                                }

                                Spacer()

                                Text(match.item.formattedSize())
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)

                                Button(workspace.tr("Gå til fil", "Reveal")) {
                                    workspace.revealURLInActiveTab(match.item.url)
                                    dismiss()
                                }
                                .buttonStyle(.glass)
                                .controlSize(.small)

                                Button(workspace.tr("Åpne", "Open")) {
                                    workspace.openItem(match.item)
                                    dismiss()
                                }
                                .buttonStyle(.glass)
                                .controlSize(.small)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.primary.opacity(0.035))
                            )
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 760, height: 540)
        .onDisappear {
            searchTask?.cancel()
        }
    }

    private func triggerSearch() {
        searchTask?.cancel()
        accessWarning = nil
        let targetRoot = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        if (try? FileManager.default.contentsOfDirectory(atPath: targetRoot.path)) == nil {
            matches = []
            isSearching = false
            hasSearchedOnce = true
            accessWarning = workspace.tr(
                "FlowFile mangler lesetilgang til «\(targetRoot.lastPathComponent)». Gi tilgang under Systeminnstillinger → Personvern og sikkerhet → Filer og mapper (eller Full disktilgang).",
                "FlowFile does not have read access to “\(targetRoot.lastPathComponent)”. Grant access in System Settings → Privacy & Security → Files and Folders (or Full Disk Access)."
            )
            return
        }
        isSearching = true
        hasSearchedOnce = true
        let q = DeepSearchQuery(
            rootURL: targetRoot,
            nameQuery: nameQuery,
            contentQuery: contentQuery,
            minSizeBytes: resolvedMinBytes,
            modifiedWithinDays: resolvedModifiedDays,
            colorTag: selectedTag,
            includeHidden: workspace.showHiddenFiles,
            caseSensitiveContent: caseSensitiveContent,
            maxResults: 400
        )
        searchTask = Task { @MainActor in
            let found = await DeepSearchService.search(q)
            if !Task.isCancelled {
                matches = found
                isSearching = false
            }
        }
    }
}

// MARK: - 2. Finder Color Tag Browser Sheet

struct TaggedFilesSheetView: View {
    @Bindable var workspace: WorkspaceState
    @Environment(\.dismiss) private var dismiss

    @State private var items: [FileItem] = []
    @State private var isLoading: Bool = false
    @State private var scanTask: Task<Void, Never>? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(
                    workspace.tr("Fargetagger", "Color Tags"),
                    systemImage: "tag.fill"
                )
                .font(.system(size: 16, weight: .bold))

                Spacer()

                Button(workspace.tr("Filtrer kun aktiv mappe", "Filter Active Folder Only")) {
                    workspace.activeTab.activeColorTagFilter = workspace.selectedSidebarColorTag
                    dismiss()
                }
                .buttonStyle(.glass)
                .controlSize(.small)

                Button(workspace.tr("Lukk", "Close")) {
                    scanTask?.cancel()
                    dismiss()
                }
                .buttonStyle(.glass)
            }

            // Color tag selector bar
            HStack(spacing: 8) {
                ForEach(FinderColorTag.allCases) { tag in
                    let isSelected = workspace.selectedSidebarColorTag == tag
                    Button {
                        workspace.selectedSidebarColorTag = tag
                        reloadTaggedItems()
                    } label: {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(tag.swiftUIColor)
                                .frame(width: 10, height: 10)
                            Text(tag.title)
                                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            Capsule()
                                .fill(isSelected ? tag.swiftUIColor.opacity(0.22) : Color.primary.opacity(0.05))
                        )
                        .overlay(
                            Capsule()
                                .strokeBorder(isSelected ? tag.swiftUIColor : Color.clear, lineWidth: 1.2)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider()

            if isLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(workspace.tr("Leter etter merkede filer...", "Scanning for tagged items..."))
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tag.slash")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text(workspace.tr(
                        "Ingen elementer med taggen «\(workspace.selectedSidebarColorTag.title)» ble funnet i hurtigtilgang eller aktiv mappe.",
                        "No items with the '\(workspace.selectedSidebarColorTag.title)' tag were found in Quick Access or the active folder."
                    ))
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(items) { item in
                            HStack(spacing: 10) {
                                Image(nsImage: FileIconCache.shared.icon(for: item))
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 20, height: 20)

                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(item.name)
                                            .font(.system(size: 12.5, weight: .semibold))
                                        ColorTagDotsView(tags: item.colorTags)
                                    }
                                    Text(item.url.deletingLastPathComponent().path)
                                        .font(.system(size: 10.5, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }

                                Spacer()

                                Button(workspace.tr("Gå til", "Reveal")) {
                                    workspace.revealURLInActiveTab(item.url)
                                    dismiss()
                                }
                                .buttonStyle(.glass)
                                .controlSize(.small)

                                Button(workspace.tr("Åpne", "Open")) {
                                    workspace.openItem(item)
                                    dismiss()
                                }
                                .buttonStyle(.glass)
                                .controlSize(.small)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.primary.opacity(0.035))
                            )
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 680, height: 470)
        .onAppear {
            reloadTaggedItems()
        }
        .onDisappear {
            scanTask?.cancel()
        }
    }

    private func reloadTaggedItems() {
        scanTask?.cancel()
        isLoading = true
        let tag = workspace.selectedSidebarColorTag
        var roots: [URL] = [workspace.activeTab.currentURL]
        if workspace.isDualPane {
            roots.append(workspace.inactivePane.activeTab.currentURL)
        }
        for fav in workspace.favorites where fav.path != "/Applications" {
            roots.append(fav.url)
        }
        let showHidden = workspace.showHiddenFiles
        scanTask = Task { @MainActor in
            let found = await TagService.findItemsWithColorTag(tag, inRoots: roots, showHidden: showHidden)
            if !Task.isCancelled {
                items = found
                isLoading = false
            }
        }
    }
}

// MARK: - 3. Save Named Workspace Sheet

struct SaveWorkspaceSheetView: View {
    @Bindable var workspace: WorkspaceState
    @Environment(\.dismiss) private var dismiss
    @State private var workspaceName: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(
                workspace.tr("Lagre arbeidsområde", "Save Workspace"),
                systemImage: "square.stack.3d.up.fill"
            )
            .font(.system(size: 16, weight: .bold))

            Text(workspace.tr(
                "Lagrer gjeldende oppsett med enkelt-/topanelsvisning og alle åpne faner slik at du kan bytte tilbake med ett klikk i sidepanelet eller via ⌘P.",
                "Saves your current single/dual-pane layout and all open tabs so you can switch back in one click from the sidebar or ⌘P."
            ))
            .font(.system(size: 12))
            .foregroundStyle(.secondary)

            TextField(
                workspace.tr("Navn på arbeidsområde (f.eks. Regnskap, Utvikling, Foto)...", "Workspace name (e.g. Accounting, Dev, Photos)..."),
                text: $workspaceName
            )
            .textFieldStyle(.roundedBorder)
            .onSubmit {
                commitSave()
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(workspace.tr("Inkluderte faner:", "Included tabs:"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("• \(workspace.tr("Venstre", "Left")): \(workspace.leftPane.tabs.map(\.title).joined(separator: ", "))")
                    .font(.system(size: 11.5))
                    .lineLimit(2)
                if workspace.isDualPane {
                    Text("• \(workspace.tr("Høyre", "Right")): \(workspace.rightPane.tabs.map(\.title).joined(separator: ", "))")
                        .font(.system(size: 11.5))
                        .lineLimit(2)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )

            HStack {
                Spacer()
                Button(workspace.tr("Avbryt", "Cancel")) {
                    dismiss()
                }
                .buttonStyle(.glass)

                Button(workspace.tr("Lagre arbeidsområde", "Save Workspace")) {
                    commitSave()
                }
                .buttonStyle(.borderedProminent)
                .disabled(workspaceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            workspaceName = workspace.activeTab.title
        }
    }

    private func commitSave() {
        let trimmed = workspaceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        workspace.saveCurrentWorkspace(named: trimmed)
        dismiss()
    }
}

// MARK: - 4. Visual Disk Space Analyzer Sheet

struct DiskSpaceSheetView: View {
    @Bindable var workspace: WorkspaceState
    @Environment(\.dismiss) private var dismiss

    @State private var inspectedRoot: URL = FileManager.default.homeDirectoryForCurrentUser
    @State private var navigationHistory: [URL] = []
    @State private var report: DiskSpaceReport? = nil
    @State private var isAnalyzing: Bool = false
    @State private var showLargestFilesTab: Bool = false
    @State private var analyzeTask: Task<Void, Never>? = nil
    @State private var pendingTrashEntry: DiskSpaceEntry? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Label(
                    workspace.tr("Diskplass-analyse", "Disk Space Analyzer"),
                    systemImage: "chart.pie.fill"
                )
                .font(.system(size: 16, weight: .bold))

                if !navigationHistory.isEmpty {
                    Button {
                        if let prev = navigationHistory.popLast() {
                            inspectedRoot = prev
                            runAnalysis(for: prev)
                        }
                    } label: {
                        Label(workspace.tr("Tilbake", "Back"), systemImage: "chevron.left")
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                }

                Text(inspectedRoot.path)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)

                Spacer()

                Button {
                    runAnalysis(for: inspectedRoot)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .disabled(isAnalyzing)

                Button(workspace.tr("Lukk", "Close")) {
                    analyzeTask?.cancel()
                    dismiss()
                }
                .buttonStyle(.glass)
            }

            if let report, !isAnalyzing {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(workspace.tr("Totalt målt i mappen", "Total measured in folder"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text(ByteFormatter.string(fromByteCount: report.totalBytes))
                            .font(.system(size: 18, weight: .bold, design: .monospaced))
                    }

                    Divider().frame(height: 28)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(workspace.tr("Antall filer skannet", "Files scanned"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text("\(report.scannedFileCount.formatted())")
                            .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    }

                    Spacer()

                    Picker("", selection: $showLargestFilesTab) {
                        Text(workspace.tr("Undermapper & innhold", "Subfolders & Items")).tag(false)
                        Text(workspace.tr("Største enkeltfiler (Topp 30)", "Largest Files (Top 30)")).tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 340)
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                )

                let entries = showLargestFilesTab ? report.largestFiles : report.children
                if entries.isEmpty {
                    Text(workspace.tr("Mappen er tom.", "This folder is empty."))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(entries) { entry in
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack(spacing: 8) {
                                        Image(systemName: entry.isDirectory ? "folder.fill" : "doc.fill")
                                            .foregroundStyle(entry.isDirectory ? Color.accentColor : .secondary)
                                            .frame(width: 18)

                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(entry.name)
                                                .font(.system(size: 12.5, weight: .semibold))
                                                .lineLimit(1)
                                            if showLargestFilesTab {
                                                Text(entry.url.deletingLastPathComponent().path)
                                                    .font(.system(size: 10.5, design: .monospaced))
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(1)
                                                    .truncationMode(.head)
                                            } else if entry.isDirectory {
                                                Text("\(entry.itemCount) \(workspace.tr("filer", "files"))")
                                                    .font(.system(size: 10.5))
                                                    .foregroundStyle(.secondary)
                                            }
                                        }

                                        Spacer()

                                        Text(String(format: "%.1f %%", entry.fractionOfRoot * 100.0))
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundStyle(.secondary)

                                        Text(ByteFormatter.string(fromByteCount: entry.sizeBytes))
                                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                                            .frame(width: 86, alignment: .trailing)

                                        if entry.isDirectory {
                                            Button(workspace.tr("Utforsk", "Inspect")) {
                                                navigationHistory.append(inspectedRoot)
                                                inspectedRoot = entry.url
                                                runAnalysis(for: entry.url)
                                            }
                                            .buttonStyle(.glass)
                                            .controlSize(.small)
                                        }

                                        Button(workspace.tr("Vis", "Reveal")) {
                                            workspace.revealURLInActiveTab(entry.url)
                                            dismiss()
                                        }
                                        .buttonStyle(.glass)
                                        .controlSize(.small)

                                        Button(role: .destructive) {
                                            pendingTrashEntry = entry
                                        } label: {
                                            Image(systemName: "trash")
                                                .foregroundStyle(DiskSpaceSheetView.isProtected(entry.url) ? Color.secondary : Color.red)
                                        }
                                        .buttonStyle(.glass)
                                        .controlSize(.small)
                                        .disabled(DiskSpaceSheetView.isProtected(entry.url))
                                        .help(DiskSpaceSheetView.isProtected(entry.url)
                                              ? workspace.tr("Beskyttet systemmappe eller hjemmemappe", "Protected system or home folder")
                                              : workspace.tr("Flytt til Papirkurv", "Move to Trash"))
                                        .accessibilityLabel(workspace.tr("Flytt \(entry.name) til Papirkurv", "Move \(entry.name) to Trash"))
                                    }

                                    GeometryReader { geo in
                                        ZStack(alignment: .leading) {
                                            Capsule()
                                                .fill(Color.primary.opacity(0.08))
                                            Capsule()
                                                .fill(barColor(for: entry.fractionOfRoot))
                                                .frame(width: max(4, geo.size.width * CGFloat(entry.fractionOfRoot)))
                                        }
                                    }
                                    .frame(height: 6)
                                }
                                .padding(10)
                                .background(
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .fill(Color.primary.opacity(0.035))
                                )
                            }
                        }
                    }
                }
            } else {
                VStack(spacing: 10) {
                    ProgressView()
                    Text(workspace.tr("Beregner diskbruk i undermapper...", "Calculating disk space across subfolders..."))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(20)
        .frame(width: 740, height: 540)
        .onAppear {
            let start = workspace.activeTab.currentURL
            inspectedRoot = start
            runAnalysis(for: start)
        }
        .onDisappear {
            analyzeTask?.cancel()
        }
        .confirmationDialog(
            workspace.tr(
                "Flytte «\(pendingTrashEntry?.name ?? "")» til Papirkurven?",
                "Move “\(pendingTrashEntry?.name ?? "")” to Trash?"
            ),
            isPresented: Binding(
                get: { pendingTrashEntry != nil },
                set: { if !$0 { pendingTrashEntry = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(workspace.tr("Flytt til Papirkurv", "Move to Trash"), role: .destructive) {
                if let entry = pendingTrashEntry {
                    trashEntry(entry)
                }
                pendingTrashEntry = nil
            }
            Button(workspace.tr("Avbryt", "Cancel"), role: .cancel) {
                pendingTrashEntry = nil
            }
        } message: {
            if let entry = pendingTrashEntry {
                Text(workspace.tr(
                    "\(ByteFormatter.string(fromByteCount: entry.sizeBytes))\(entry.isDirectory ? " • \(entry.itemCount) filer" : "")\n\(entry.url.path)",
                    "\(ByteFormatter.string(fromByteCount: entry.sizeBytes))\(entry.isDirectory ? " • \(entry.itemCount) files" : "")\n\(entry.url.path)"
                ))
            }
        }
    }

    /// Home folder, its standard top-level folders and system locations can never be trashed from the analyzer.
    nonisolated static func isProtected(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.resolvingSymlinksInPath().path
        let protectedHomeChildren = [
            "Library", "Documents", "Desktop", "Downloads", "Pictures", "Movies", "Music",
            "Applications", "Public", ".Trash"
        ]
        if path == "/" || path == home { return true }
        if protectedHomeChildren.contains(where: { path == home + "/" + $0 }) { return true }
        let systemPrefixes = ["/System", "/Library", "/Applications", "/usr", "/bin", "/sbin", "/private", "/etc", "/var", "/Users", "/Volumes", "/cores", "/opt"]
        if systemPrefixes.contains(path) { return true }
        if path.hasPrefix("/System/") || path.hasPrefix("/usr/") || path.hasPrefix("/bin/") || path.hasPrefix("/sbin/") {
            return true
        }
        if path.hasPrefix("/Volumes/"), url.standardizedFileURL.deletingLastPathComponent().path == "/Volumes" {
            return true
        }
        return false
    }

    private func barColor(for fraction: Double) -> Color {
        if fraction >= 0.45 { return .orange }
        if fraction >= 0.20 { return Color.accentColor }
        return .blue.opacity(0.75)
    }

    private func runAnalysis(for target: URL) {
        analyzeTask?.cancel()
        isAnalyzing = true
        let showHidden = workspace.showHiddenFiles
        analyzeTask = Task { @MainActor in
            let res = await DiskSpaceAnalyzerService.analyze(directory: target, includeHidden: showHidden)
            if !Task.isCancelled {
                report = res
                isAnalyzing = false
            }
        }
    }

    private func trashEntry(_ entry: DiskSpaceEntry) {
        guard workspace.guardNotInTourSandbox() else { return }
        guard !DiskSpaceSheetView.isProtected(entry.url) else { return }
        do {
            try FileSystemService.trashItems([entry.url])
            workspace.refreshAllTabs()
            runAnalysis(for: inspectedRoot)
        } catch {
            workspace.alertErrorMessage = error.localizedDescription
        }
    }
}

// MARK: - 5. Folder Synchronization Sheet

struct FolderSyncSheetView: View {
    @Bindable var workspace: WorkspaceState
    @Environment(\.dismiss) private var dismiss

    @State private var mode: FolderSyncMode = .updateLeftToRight
    @State private var plannedItems: [FolderSyncItemPlan] = []
    @State private var selectedIDs: Set<String> = []
    @State private var isScanning: Bool = false
    @State private var isExecuting: Bool = false
    @State private var scanError: String? = nil
    @State private var showTrashConfirmation: Bool = false

    private var leftRoot: URL { workspace.leftPane.activeTab.currentURL }
    private var rightRoot: URL { workspace.rightPane.activeTab.currentURL }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(
                    workspace.tr("Mappe-synkronisering", "Folder Synchronization"),
                    systemImage: "arrow.triangle.2.circlepath.circle.fill"
                )
                .font(.system(size: 16, weight: .bold))

                Spacer()

                Button(workspace.tr("Lukk", "Close")) {
                    dismiss()
                }
                .buttonStyle(.glass)
            }

            // Left & Right folder summary
            HStack(spacing: 10) {
                paneBox(label: workspace.tr("VENSTRE MAPPE", "LEFT FOLDER"), url: leftRoot)
                Image(systemName: mode == .twoWayNewest ? "arrow.left.arrow.right" : "arrow.right")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.accentColor)
                paneBox(label: workspace.tr("HØYRE MAPPE", "RIGHT FOLDER"), url: rightRoot)
            }

            VStack(alignment: .leading, spacing: 6) {
                Picker(workspace.tr("Synkroniseringsmodus:", "Sync Mode:"), selection: $mode) {
                    ForEach(FolderSyncMode.allCases) { m in
                        Text(m.title).tag(m)
                    }
                }
                .onChange(of: mode) { _, _ in
                    refreshPlan()
                }

                Text(mode.descriptionText)
                    .font(.system(size: 11.5))
                    .foregroundStyle(mode == .mirrorLeftToRight ? .orange : .secondary)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )

            if let scanError {
                Text(scanError)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if isScanning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(workspace.tr("Sammenligner mapper og undermapper...", "Comparing folders and subfolders..."))
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if plannedItems.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(.green)
                    Text(workspace.tr("Mappene er allerede synkronisert etter valgt modus!", "Folders are already in sync for the selected mode!"))
                        .font(.system(size: 13, weight: .medium))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack {
                    Text(workspace.tr(
                        "\(selectedIDs.count) av \(plannedItems.count) planlagte filhandlinger valgt",
                        "\(selectedIDs.count) of \(plannedItems.count) planned file operations selected"
                    ))
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.secondary)

                    Spacer()

                    Button(workspace.tr("Velg alle", "Select All")) {
                        selectedIDs = Set(plannedItems.map(\.id))
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 11.5))

                    Button(workspace.tr("Velg ingen", "Select None")) {
                        selectedIDs.removeAll()
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 11.5))
                }

                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(plannedItems) { item in
                            let isChecked = selectedIDs.contains(item.id)
                            HStack(spacing: 10) {
                                Toggle("", isOn: Binding(
                                    get: { isChecked },
                                    set: { val in
                                        if val { selectedIDs.insert(item.id) }
                                        else { selectedIDs.remove(item.id) }
                                    }
                                ))
                                .toggleStyle(.checkbox)
                                .labelsHidden()

                                Text(item.operation.badgeText)
                                    .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(
                                        Capsule().fill(badgeColor(for: item.operation).opacity(0.18))
                                    )
                                    .foregroundStyle(badgeColor(for: item.operation))

                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.relativePath)
                                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Text(item.reason)
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Text(ByteFormatter.string(fromByteCount: item.sizeBytes))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.primary.opacity(0.035))
                            )
                        }
                    }
                }
            }

            Divider()

            HStack {
                Button(workspace.tr("Oppdater forhåndsvisning", "Refresh Preview")) {
                    refreshPlan()
                }
                .buttonStyle(.glass)
                .disabled(isScanning || isExecuting)

                Spacer()

                Button(workspace.tr("Utfør synkronisering", "Run Synchronization")) {
                    if selectedTrashCount > 0 {
                        showTrashConfirmation = true
                    } else {
                        executeSync()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedIDs.isEmpty || isScanning || isExecuting || scanError != nil)
            }
        }
        .padding(20)
        .frame(width: 740, height: 540)
        .onAppear {
            refreshPlan()
        }
        .confirmationDialog(
            workspace.tr(
                "Flytte \(selectedTrashCount) fil(er) i høyre mappe til Papirkurven?",
                "Move \(selectedTrashCount) file(s) in the right folder to Trash?"
            ),
            isPresented: $showTrashConfirmation,
            titleVisibility: .visible
        ) {
            Button(workspace.tr("Synkroniser og flytt til Papirkurv", "Sync and Move to Trash"), role: .destructive) {
                executeSync()
            }
            Button(workspace.tr("Avbryt", "Cancel"), role: .cancel) {}
        } message: {
            Text(workspace.tr(
                "Filene finnes kun i høyre mappe (\(rightRoot.lastPathComponent)). De flyttes til Papirkurven og kan legges tilbake derfra. Hvis disken ikke har papirkurv, stopper synkroniseringen uten å slette noe.",
                "These files exist only in the right folder (\(rightRoot.lastPathComponent)). They are moved to Trash and can be restored from there. If the disk has no Trash, synchronization stops without deleting anything."
            ))
        }
    }

    private var selectedTrashCount: Int {
        plannedItems.filter { $0.operation == .trashInRight && selectedIDs.contains($0.id) }.count
    }

    @ViewBuilder
    private func paneBox(label: String, url: URL) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(url.lastPathComponent)
                .font(.system(size: 12.5, weight: .semibold))
                .lineLimit(1)
            Text(url.path)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }

    private func badgeColor(for op: FolderSyncOperationKind) -> Color {
        switch op {
        case .copyLeftToRight: return .blue
        case .copyRightToLeft: return .green
        case .trashInRight: return .red
        }
    }

    private func refreshPlan() {
        isScanning = true
        scanError = nil
        let lRoot = leftRoot
        let rRoot = rightRoot
        let chosenMode = mode
        let includeHidden = workspace.showHiddenFiles

        Task { @MainActor in
            do {
                let plan = try await FolderSyncService.buildPlan(
                    leftRoot: lRoot,
                    rightRoot: rRoot,
                    mode: chosenMode,
                    includeHidden: includeHidden
                )
                plannedItems = plan
                // Never pre-check destructive rows; the user must opt in to trashing explicitly
                selectedIDs = Set(plan.filter { $0.operation != .trashInRight }.map(\.id))
                isScanning = false
            } catch {
                plannedItems = []
                selectedIDs = []
                scanError = error.localizedDescription
                isScanning = false
            }
        }
    }

    private func executeSync() {
        guard workspace.guardNotInTourSandbox() else { return }
        isExecuting = true
        do {
            let count = try FolderSyncService.execute(plan: plannedItems, selectedIDs: selectedIDs)
            isExecuting = false
            workspace.refreshAllTabs()
            workspace.showStatus(workspace.tr(
                "Synkronisering fullført (\(count) filoperasjoner utført)",
                "Synchronization complete (\(count) file operations executed)"
            ))
            dismiss()
        } catch {
            isExecuting = false
            workspace.refreshAllTabs()
            workspace.alertErrorMessage = error.localizedDescription
            refreshPlan()
        }
    }
}

// MARK: - 6. Duplicate File Finder Sheet

struct DuplicateFinderSheetView: View {
    @Bindable var workspace: WorkspaceState
    @Environment(\.dismiss) private var dismiss

    @State private var scanBothPanes: Bool = false
    @State private var groups: [DuplicateFileGroup] = []
    @State private var selectedForTrash: Set<URL> = []
    @State private var isScanning: Bool = false
    @State private var hasScannedOnce: Bool = false
    @State private var scanTask: Task<Void, Never>? = nil
    @State private var showDuplicateTrashConfirmation: Bool = false

    private var totalReclaimableBytes: Int64 {
        groups.reduce(Int64(0)) { $0 + $1.reclaimableBytes }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(
                    workspace.tr("Duplikat-finner (SHA-256)", "Duplicate File Finder (SHA-256)"),
                    systemImage: "doc.on.doc.fill"
                )
                .font(.system(size: 16, weight: .bold))

                Spacer()

                if workspace.isDualPane {
                    Toggle(
                        workspace.tr("Søk på tvers av begge paneler", "Scan across both panes"),
                        isOn: $scanBothPanes
                    )
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                    .onChange(of: scanBothPanes) { _, _ in
                        startScan()
                    }
                }

                Button {
                    startScan()
                } label: {
                    Label(workspace.tr("Skann på nytt", "Rescan"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .disabled(isScanning)

                Button(workspace.tr("Lukk", "Close")) {
                    scanTask?.cancel()
                    dismiss()
                }
                .buttonStyle(.glass)
            }

            if isScanning {
                VStack(spacing: 10) {
                    ProgressView()
                    Text(workspace.tr(
                        "Sammenligner filstørrelser og verifiserer SHA-256-sjekksummer...",
                        "Comparing file sizes and verifying SHA-256 checksums..."
                    ))
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if groups.isEmpty && hasScannedOnce {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(.green)
                    Text(workspace.tr("Ingen identiske duplikatfiler funnet!", "No identical duplicate files found!"))
                        .font(.system(size: 13, weight: .medium))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 12) {
                    Text(workspace.tr(
                        "\(groups.count) duplikatgrupper • Kan frigjøre \(ByteFormatter.string(fromByteCount: totalReclaimableBytes))",
                        "\(groups.count) duplicate groups • Reclaimable: \(ByteFormatter.string(fromByteCount: totalReclaimableBytes))"
                    ))
                    .font(.system(size: 12, weight: .semibold))

                    Spacer()

                    Button(workspace.tr("Behold kun nyeste", "Keep Newest Only")) {
                        selectedForTrash = DuplicateFinderService.urlsToTrashKeepingNewest(in: groups)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)

                    Button(workspace.tr("Behold kun eldste", "Keep Oldest Only")) {
                        selectedForTrash = DuplicateFinderService.urlsToTrashKeepingOldest(in: groups)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)

                    Button(workspace.tr("Fjern markering", "Clear")) {
                        selectedForTrash.removeAll()
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                }

                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(groups) { group in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("\(group.items.count) \(workspace.tr("identiske kopier", "identical copies")) • \(ByteFormatter.string(fromByteCount: group.sizeBytes)) \(workspace.tr("hver", "each"))")
                                        .font(.system(size: 11.5, weight: .bold))
                                    Spacer()
                                    Text("SHA-256: \(String(group.sha256.prefix(16)))…")
                                        .font(.system(size: 10.5, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }

                                ForEach(group.items) { item in
                                    let markedTrash = selectedForTrash.contains(item.url)
                                    HStack(spacing: 8) {
                                        Toggle("", isOn: Binding(
                                            get: { markedTrash },
                                            set: { val in
                                                if val { selectedForTrash.insert(item.url) }
                                                else { selectedForTrash.remove(item.url) }
                                            }
                                        ))
                                        .toggleStyle(.checkbox)
                                        .labelsHidden()

                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(item.name)
                                                .font(.system(size: 12, weight: .medium))
                                                .strikethrough(markedTrash, color: .red)
                                            Text(item.url.deletingLastPathComponent().path)
                                                .font(.system(size: 10.5, design: .monospaced))
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                        }

                                        Spacer()

                                        Text(item.formattedDate)
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundStyle(.secondary)

                                        Button(workspace.tr("Vis", "Reveal")) {
                                            workspace.revealURLInActiveTab(item.url)
                                            dismiss()
                                        }
                                        .buttonStyle(.glass)
                                        .controlSize(.small)
                                    }
                                    .padding(.vertical, 2)
                                }
                            }
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.primary.opacity(0.04))
                            )
                        }
                    }
                }

                Divider()

                HStack {
                    Text(workspace.tr(
                        "\(selectedForTrash.count) fil(er) valgt for Papirkurven",
                        "\(selectedForTrash.count) file(s) selected for Trash"
                    ))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                    Spacer()

                    Button(role: .destructive) {
                        showDuplicateTrashConfirmation = true
                    } label: {
                        Label(
                            workspace.tr("Flytt valgte til Papirkurv", "Move Selected to Trash"),
                            systemImage: "trash"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(selectedForTrash.isEmpty || !everyGroupKeepsOneCopy)
                }
                if !selectedForTrash.isEmpty && !everyGroupKeepsOneCopy {
                    Text(workspace.tr(
                        "Minst én gruppe har alle kopier valgt. Behold minst én kopi i hver gruppe.",
                        "At least one group has every copy selected. Keep at least one copy in each group."
                    ))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.orange)
                }
            }
        }
        .padding(20)
        .frame(width: 740, height: 540)
        .onAppear {
            startScan()
        }
        .onDisappear {
            scanTask?.cancel()
        }
        .confirmationDialog(
            workspace.tr(
                "Flytte \(selectedForTrash.count) duplikatfil(er) til Papirkurven?",
                "Move \(selectedForTrash.count) duplicate file(s) to Trash?"
            ),
            isPresented: $showDuplicateTrashConfirmation,
            titleVisibility: .visible
        ) {
            Button(workspace.tr("Flytt til Papirkurv", "Move to Trash"), role: .destructive) {
                moveSelectedDuplicatesToTrash()
            }
            Button(workspace.tr("Avbryt", "Cancel"), role: .cancel) {}
        } message: {
            Text(workspace.tr(
                "Totalt \(ByteFormatter.string(fromByteCount: selectedTrashBytes)). Minst én kopi beholdes i hver gruppe, og filene kan legges tilbake fra Papirkurven.",
                "Total \(ByteFormatter.string(fromByteCount: selectedTrashBytes)). At least one copy is kept in each group, and files can be restored from Trash."
            ))
        }
    }

    private var everyGroupKeepsOneCopy: Bool {
        groups.allSatisfy { group in
            group.items.contains { !selectedForTrash.contains($0.url) }
        }
    }

    private var selectedTrashBytes: Int64 {
        groups.reduce(Int64(0)) { sum, group in
            sum + Int64(group.items.filter { selectedForTrash.contains($0.url) }.count) * group.sizeBytes
        }
    }

    private func startScan() {
        scanTask?.cancel()
        isScanning = true
        hasScannedOnce = true
        selectedForTrash.removeAll()

        var roots = [workspace.activeTab.currentURL]
        if workspace.isDualPane && scanBothPanes {
            let opposite = workspace.inactivePane.activeTab.currentURL
            if opposite.standardizedFileURL != roots[0].standardizedFileURL {
                roots.append(opposite)
            }
        }
        let showHidden = workspace.showHiddenFiles

        scanTask = Task { @MainActor in
            let found = await DuplicateFinderService.scanForDuplicates(
                inRoots: roots,
                includeHidden: showHidden
            )
            if !Task.isCancelled {
                groups = found
                // Never auto-select files for deletion; the user picks a rule explicitly
                selectedForTrash = []
                isScanning = false
            }
        }
    }

    private func moveSelectedDuplicatesToTrash() {
        guard workspace.guardNotInTourSandbox() else { return }
        let urls = Array(selectedForTrash)
        guard !urls.isEmpty, everyGroupKeepsOneCopy else { return }
        do {
            try FileSystemService.trashItems(urls)
            workspace.refreshAllTabs()
            workspace.showStatus(workspace.tr(
                "Flyttet \(urls.count) duplikatfil(er) til Papirkurven",
                "Moved \(urls.count) duplicate file(s) to Trash"
            ))
            startScan()
        } catch {
            workspace.alertErrorMessage = error.localizedDescription
        }
    }
}

// MARK: - 7. Batch Image Convert & Resize Sheet

struct ImageConvertSheetView: View {
    @Bindable var workspace: WorkspaceState
    @Environment(\.dismiss) private var dismiss

    @State private var format: ImageOutputFormat = .jpeg
    @State private var jpegQuality: Double = 0.88
    @State private var resizePreset: ImageResizePreset = .original
    @State private var isConverting: Bool = false

    private var targets: [URL] {
        workspace.imageConvertTargetURLs
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(
                workspace.tr("Konverter og skaler bilder", "Convert & Resize Images"),
                systemImage: "photo.stack.fill"
            )
            .font(.system(size: 16, weight: .bold))

            Text(workspace.tr(
                "\(targets.count) bildefil(er) konverteres til nye filer i gjeldende mappe uten å overskrive originalene.",
                "\(targets.count) image file(s) will be converted into new files in the current folder without overwriting originals."
            ))
            .font(.system(size: 12))
            .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                Picker(workspace.tr("Målformat:", "Output format:"), selection: $format) {
                    ForEach(ImageOutputFormat.allCases) { f in
                        Text(f.title).tag(f)
                    }
                }
                .pickerStyle(.segmented)

                if format == .jpeg {
                    HStack {
                        Text(workspace.tr("JPEG-kvalitet:", "JPEG quality:"))
                            .font(.system(size: 12))
                        Slider(value: $jpegQuality, in: 0.50...1.0, step: 0.02)
                        Text("\(Int((jpegQuality * 100).rounded())) %")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .frame(width: 48, alignment: .trailing)
                    }
                }

                Picker(workspace.tr("Oppløsning:", "Dimensions:"), selection: $resizePreset) {
                    ForEach(ImageResizePreset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )

            HStack {
                Spacer()
                Button(workspace.tr("Avbryt", "Cancel")) {
                    dismiss()
                }
                .buttonStyle(.glass)

                Button(workspace.tr("Konverter bilder", "Convert Images")) {
                    runConversion()
                }
                .buttonStyle(.borderedProminent)
                .disabled(targets.isEmpty || isConverting)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func runConversion() {
        guard workspace.guardNotInTourSandbox() else { return }
        isConverting = true
        let dest = workspace.activeTab.currentURL
        do {
            let created = try QuickFileToolsService.convertImages(
                urls: targets,
                inDirectory: dest,
                format: format,
                jpegQuality: jpegQuality,
                resizePreset: resizePreset
            )
            isConverting = false
            workspace.refreshAllTabs()
            workspace.activeTab.selectedURLs = Set(created)
            workspace.showStatus(workspace.tr(
                "Konverterte \(created.count) bilde(r) til .\(format.rawValue)",
                "Converted \(created.count) image(s) to .\(format.rawValue)"
            ))
            dismiss()
        } catch {
            isConverting = false
            workspace.alertErrorMessage = error.localizedDescription
        }
    }
}
