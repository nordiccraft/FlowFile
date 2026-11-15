import SwiftUI

struct PaletteEntry: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let icon: String
    let shortcut: String?
    let action: () -> Void
}

struct CommandPaletteView: View {
    @Bindable var workspace: WorkspaceState
    @State private var query: String = ""
    @State private var selectedIndex: Int = 0
    @FocusState private var isSearchFocused: Bool

    private var entries: [PaletteEntry] {
        var list: [PaletteEntry] = []

        // Actions
        list.append(PaletteEntry(
            id: "cmd.deepsearch",
            title: workspace.tr("Dypsøk i undermapper og filinnhold", "Deep Subfolder & File-Content Search"),
            subtitle: workspace.tr("Søk på navn, tekst inni filer, størrelse, dato og fargetagg", "Search by name, text content, size, date & color tag"),
            icon: "doc.text.magnifyingglass",
            shortcut: "⇧⌘F"
        ) {
            workspace.openDeepSearch()
        })

        list.append(PaletteEntry(
            id: "cmd.flatview",
            title: workspace.activeTab.isFlatBranchView
                ? workspace.tr("Avslutt flat undermappe-visning", "Exit Flat Subfolder View")
                : workspace.tr("Flat visning – samle alle filer fra undermapper", "Flat Subfolder View – flatten all nested files"),
            subtitle: workspace.activeTab.currentURL.path,
            icon: "square.stack.3d.down.right.fill",
            shortcut: "⌥⌘B"
        ) {
            workspace.toggleFlatViewInActiveTab()
        })

        list.append(PaletteEntry(
            id: "cmd.diskspace",
            title: workspace.tr("Diskplass-analyse i aktiv mappe", "Disk Space Analyzer in Active Folder"),
            subtitle: workspace.tr("Se hvilke undermapper og store filer som bruker mest plass", "Inspect which subfolders and large files consume the most space"),
            icon: "chart.pie.fill",
            shortcut: "⌥⌘D"
        ) {
            workspace.openDiskSpaceAnalyzer()
        })

        list.append(PaletteEntry(
            id: "cmd.duplicates",
            title: workspace.tr("Finn duplikatfiler (SHA-256)", "Find Duplicate Files (SHA-256)"),
            subtitle: workspace.tr("Skann og fjern identiske kopier trygt til Papirkurven", "Scan and safely move identical copies to Trash"),
            icon: "doc.on.doc.fill",
            shortcut: nil
        ) {
            workspace.openDuplicateFinder()
        })

        list.append(PaletteEntry(
            id: "cmd.foldersync",
            title: workspace.tr("Synkroniser venstre og høyre mappe", "Synchronize Left and Right Folders"),
            subtitle: workspace.tr("Oppdater én vei, to-veis eller speil med forhåndsvisning", "One-way update, two-way newest, or mirror with preview"),
            icon: "arrow.triangle.2.circlepath.circle.fill",
            shortcut: "⌥⇧⌘K"
        ) {
            workspace.openFolderSync()
        })

        list.append(PaletteEntry(
            id: "cmd.convertimages",
            title: workspace.tr("Konverter / skaler valgte bilder", "Convert / Resize Selected Images"),
            subtitle: workspace.tr("Konverter HEIC, PNG, TIFF, JPG til JPEG/PNG med valgfri skalering", "Convert HEIC, PNG, TIFF, JPG to JPEG/PNG with optional resize"),
            icon: "photo.stack.fill",
            shortcut: nil
        ) {
            workspace.openImageConverter()
        })

        list.append(PaletteEntry(
            id: "cmd.mergepdf",
            title: workspace.tr("Slå sammen valgte PDF-er og bilder til én PDF", "Merge Selected PDFs & Images into Single PDF"),
            subtitle: workspace.activeTab.currentURL.path,
            icon: "doc.richtext.fill",
            shortcut: nil
        ) {
            workspace.mergeSelectedToPDF()
        })

        list.append(PaletteEntry(
            id: "cmd.saveworkspace",
            title: workspace.tr("Lagre gjeldende arbeidsområde", "Save Current Workspace"),
            subtitle: workspace.tr("Lagre åpne faner og paneloppsett under eget navn", "Save open tabs and pane layout under a custom name"),
            icon: "square.stack.3d.up.fill",
            shortcut: "⌥⌘S"
        ) {
            workspace.isSaveWorkspaceSheetVisible = true
        })

        for saved in workspace.savedWorkspaces {
            list.append(PaletteEntry(
                id: "ws.\(saved.id.uuidString)",
                title: "\(workspace.tr("Arbeidsområde", "Workspace")): \(saved.name)",
                subtitle: saved.summaryLabel,
                icon: saved.snapshot.isDualPane ? "rectangle.split.2x1.fill" : "rectangle.fill",
                shortcut: nil
            ) {
                workspace.applySavedWorkspace(saved)
            })
        }

        list.append(PaletteEntry(
            id: "cmd.sharehub",
            title: "Smart Delingssenter – Del valgte filer/mapper",
            subtitle: "E-post/Outlook, passord-ZIP, Teams/Slack, OneDrive/Dropbox & Wi-Fi QR-kode",
            icon: "square.and.arrow.up.circle.fill",
            shortcut: "⇧⌘S"
        ) {
            workspace.openShareHub()
        })

        for account in workspace.cloudAccounts {
            list.append(PaletteEntry(
                id: "cloud.\(account.id)",
                title: "Skylagring: \(account.displayName)",
                subtitle: account.rootURL.path,
                icon: account.provider.systemImage,
                shortcut: nil
            ) {
                workspace.navigateActiveTab(to: account.rootURL)
            })
        }

        list.append(PaletteEntry(
            id: "cmd.multirename",
            title: "Multi-Rename Tool – Masse-omdøping",
            subtitle: "Mønster ([N], [C], [D]), søk/erstatt, regex og forhåndsvisning",
            icon: "character.textbox",
            shortcut: "⌘M"
        ) {
            workspace.openMultiRenameTool()
        })

        list.append(PaletteEntry(
            id: "cmd.dropshelf",
            title: workspace.isDropShelfVisible ? "Skjul Drop-hylle & Filoverføringskø" : "Åpne Drop-hylle & Filoverføringskø",
            subtitle: "Samle filer fra ulike mapper og se aktive overføringer",
            icon: "tray.2.fill",
            shortcut: "⌘J"
        ) {
            workspace.isDropShelfVisible.toggle()
        })

        list.append(PaletteEntry(
            id: "cmd.compare",
            title: "Sammenlign venstre og høyre mappe (Dual-Pane Diff)",
            subtitle: "Marker nye og endrede filer mellom panelene",
            icon: "arrow.left.and.right.righttriangle.left.righttriangle.right",
            shortcut: "⇧⌘K"
        ) {
            workspace.runDualPaneComparison()
        })

        list.append(PaletteEntry(
            id: "cmd.embeddedterminal",
            title: workspace.isTerminalDrawerVisible ? "Skjul innebygd Terminal-skuff" : "Åpne innebygd synkronisert Terminal-skuff",
            subtitle: "zsh-terminal nederst som følger aktiv mappe",
            icon: "terminal",
            shortcut: "⌃`"
        ) {
            workspace.toggleTerminalDrawer()
        })

        list.append(PaletteEntry(
            id: "cmd.zip",
            title: "Komprimer valgte filer til .zip-arkiv",
            subtitle: workspace.activeTab.currentURL.path,
            icon: "doc.zipper",
            shortcut: nil
        ) {
            workspace.compressSelectedToZip()
        })

        list.append(PaletteEntry(
            id: "cmd.dualpane",
            title: workspace.isDualPane
                ? workspace.tr("Bytt til enkeltpanel", "Switch to Single Pane")
                : workspace.tr("Bytt til topanelsvisning", "Switch to Dual-Pane"),
            subtitle: workspace.tr("Veksle mellom ett og to filpaneler", "Toggle between one and two file panes"),
            icon: "rectangle.split.2x1",
            shortcut: "⌘D"
        ) {
            workspace.toggleDualPane()
        })

        list.append(PaletteEntry(
            id: "cmd.hidden",
            title: workspace.showHiddenFiles ? "Skjul skjulte dot-filer" : "Vis skjulte dot-filer (.dotfiles)",
            subtitle: "Vis eller skjul filer som starter med punktum",
            icon: "eye",
            shortcut: "⇧⌘."
        ) {
            workspace.showHiddenFiles.toggle()
        })

        list.append(PaletteEntry(
            id: "cmd.newfolder",
            title: "Opprett ny mappe i aktivt panel",
            subtitle: workspace.activeTab.currentURL.path,
            icon: "folder.badge.plus",
            shortcut: "F7"
        ) {
            workspace.promptNewFolder()
        })

        list.append(PaletteEntry(
            id: "cmd.terminal",
            title: "Åpne Terminal i aktiv mappe",
            subtitle: workspace.activeTab.currentURL.path,
            icon: "terminal.fill",
            shortcut: nil
        ) {
            workspace.openTerminalInActiveFolder()
        })

        list.append(PaletteEntry(
            id: "cmd.copypath",
            title: "Kopier full sti til utklippstavle",
            subtitle: workspace.activeTab.primarySelectedItem?.url.path ?? workspace.activeTab.currentURL.path,
            icon: "doc.on.doc",
            shortcut: nil
        ) {
            workspace.copyPathOfSelectedOrCurrent()
        })

        list.append(PaletteEntry(
            id: "cmd.settings",
            title: "Åpne FlowFile-innstillinger",
            subtitle: "Tilpass Space-tast, sidepanel og F-tast-rad",
            icon: "gearshape.fill",
            shortcut: "⌘,"
        ) {
            workspace.isSettingsVisible = true
        })

        // Favorites & Recent Folders
        for fav in workspace.favorites {
            list.append(PaletteEntry(
                id: "fav.\(fav.path)",
                title: "Gå til: \(fav.title)",
                subtitle: fav.path,
                icon: fav.systemImage,
                shortcut: nil
            ) {
                workspace.navigateActiveTab(to: fav.url)
            })
        }

        for recent in workspace.recentFolders {
            if !workspace.favorites.contains(where: { $0.path == recent.path }) {
                list.append(PaletteEntry(
                    id: "recent.\(recent.path)",
                    title: "Nylig mappe: \(recent.lastPathComponent)",
                    subtitle: recent.path,
                    icon: "clock.arrow.circlepath",
                    shortcut: nil
                ) {
                    workspace.navigateActiveTab(to: recent)
                })
            }
        }

        // Subdirectories in current folder
        for sub in workspace.activeTab.allItems where sub.isNavigableFolder {
            list.append(PaletteEntry(
                id: "sub.\(sub.url.path)",
                title: "Undermappe: \(sub.name)",
                subtitle: sub.url.path,
                icon: "folder",
                shortcut: nil
            ) {
                workspace.navigateActiveTab(to: sub.url)
            })
        }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Array(list.prefix(16)) }

        return list.filter {
            $0.title.localizedCaseInsensitiveContains(trimmed) ||
            $0.subtitle.localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.25)
                .ignoresSafeArea()
                .onTapGesture {
                    close()
                }

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "command")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.accentColor)

                    TextField("Hopp til mappe eller kjør kommando...", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .focused($isSearchFocused)
                        .onSubmit {
                            runSelected()
                        }
                        .onExitCommand {
                            close()
                        }

                    Button("Esc") {
                        close()
                    }
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .buttonStyle(.glass)
                }
                .padding(14)

                Divider()

                ScrollView {
                    VStack(spacing: 3) {
                        let visible = entries
                        if visible.isEmpty {
                            Text("Ingen treff for «\(query)»")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                                .padding(24)
                        } else {
                            ForEach(Array(visible.enumerated()), id: \.element.id) { idx, entry in
                                let isHighlighted = idx == selectedIndex
                                Button {
                                    selectedIndex = idx
                                    runSelected()
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: entry.icon)
                                            .font(.system(size: 14))
                                            .foregroundStyle(isHighlighted ? .white : Color.accentColor)
                                            .frame(width: 22)

                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(entry.title)
                                                .font(.system(size: 13, weight: .medium))
                                                .foregroundStyle(isHighlighted ? .white : .primary)
                                            Text(entry.subtitle)
                                                .font(.system(size: 11, design: .monospaced))
                                                .foregroundStyle(isHighlighted ? .white.opacity(0.8) : .secondary)
                                                .lineLimit(1)
                                        }

                                        Spacer()

                                        if let shortcut = entry.shortcut {
                                            Text(shortcut)
                                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                                .foregroundStyle(isHighlighted ? .white : .secondary)
                                        }
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 7)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .fill(isHighlighted ? Color.accentColor : Color.clear)
                                    )
                                    .contentShape(RoundedRectangle(cornerRadius: 8))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: 330)
            }
            .frame(width: 560)
            .liquidGlassPanel(cornerRadius: 16)
            .shadow(color: .black.opacity(0.28), radius: 24, y: 10)
            .padding(.top, 50)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .onAppear {
            selectedIndex = 0
            DispatchQueue.main.async {
                isSearchFocused = true
            }
        }
        .onChange(of: query) { _, _ in
            selectedIndex = 0
        }
        .onKeyPress(.downArrow) {
            let count = entries.count
            if count > 0 {
                selectedIndex = (selectedIndex + 1) % count
            }
            return .handled
        }
        .onKeyPress(.upArrow) {
            let count = entries.count
            if count > 0 {
                selectedIndex = (selectedIndex - 1 + count) % count
            }
            return .handled
        }
    }

    private func runSelected() {
        let visible = entries
        if let directURL = FileSystemService.resolveUserPath(query, relativeTo: workspace.activeTab.currentURL),
           visible.isEmpty {
            close()
            workspace.navigateActiveTab(to: directURL)
            return
        }
        guard selectedIndex >= 0 && selectedIndex < visible.count else { return }
        let chosen = visible[selectedIndex]
        close()
        chosen.action()
    }

    private func close() {
        workspace.isCommandPaletteVisible = false
    }
}
