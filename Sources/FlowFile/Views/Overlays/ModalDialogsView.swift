import SwiftUI

struct PromptDialogSheet: View {
    let prompt: ActivePrompt
    @Bindable var workspace: WorkspaceState
    @State private var inputText: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch prompt {
            case .newFolder(let directory):
                Label("Opprett ny mappe", systemImage: "folder.badge.plus")
                    .font(.system(size: 15, weight: .semibold))
                Text("I: \(directory.path)")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                TextField("Mappenavn", text: $inputText)
                    .textFieldStyle(.roundedBorder)
                    .focused($isFocused)
                    .onSubmit { submit() }

            case .newFile(let directory):
                Label("Opprett ny tom fil", systemImage: "doc.badge.plus")
                    .font(.system(size: 15, weight: .semibold))
                Text("I: \(directory.path)")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                TextField("Filnavn (f.eks. notat.md)", text: $inputText)
                    .textFieldStyle(.roundedBorder)
                    .focused($isFocused)
                    .onSubmit { submit() }

            case .rename(_, let currentName):
                Label("Gi nytt navn (F2)", systemImage: "pencil")
                    .font(.system(size: 15, weight: .semibold))
                Text("Nåværende navn: \(currentName)")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)

                TextField("Nytt navn", text: $inputText)
                    .textFieldStyle(.roundedBorder)
                    .focused($isFocused)
                    .onSubmit { submit() }

            case .confirmPermanentDelete(let urls):
                Label("Slett permanent?", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.red)

                Text("Er du sikker på at du vil slette \(urls.count) element(er) permanent? Dette går utenom Papirkurven og kan ikke angres.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)

                if let first = urls.first {
                    Text(urls.count == 1 ? first.lastPathComponent : "\(first.lastPathComponent) + \(urls.count - 1) til")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }

            HStack {
                Spacer()
                Button("Avbryt") {
                    workspace.activePrompt = nil
                }
                .keyboardShortcut(.cancelAction)

                Button(confirmTitle, role: isDestructive ? .destructive : nil) {
                    submit()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(isDestructive ? .red : .accentColor)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            switch prompt {
            case .newFolder:
                inputText = "Ny mappe"
            case .newFile:
                inputText = "ny-fil.txt"
            case .rename(_, let currentName):
                inputText = currentName
            case .confirmPermanentDelete:
                break
            }
            DispatchQueue.main.async {
                isFocused = true
            }
        }
    }

    private var isDestructive: Bool {
        if case .confirmPermanentDelete = prompt { return true }
        return false
    }

    private var confirmTitle: String {
        switch prompt {
        case .newFolder, .newFile: return "Opprett"
        case .rename: return "Lagre navn"
        case .confirmPermanentDelete: return "Slett permanent"
        }
    }

    private func submit() {
        do {
            switch prompt {
            case .newFolder(let dir):
                let created = try FileSystemService.createFolder(named: inputText, in: dir)
                workspace.activePrompt = nil
                workspace.activeTab.reload(showHidden: workspace.showHiddenFiles, preferredSelection: created)
                workspace.showStatus("Opprettet mappen «\(created.lastPathComponent)»")

            case .newFile(let dir):
                let created = try FileSystemService.createEmptyFile(named: inputText, in: dir)
                workspace.activePrompt = nil
                workspace.activeTab.reload(showHidden: workspace.showHiddenFiles, preferredSelection: created)
                workspace.showStatus("Opprettet filen «\(created.lastPathComponent)»")

            case .rename(let itemURL, _):
                let renamed = try FileSystemService.renameItem(at: itemURL, to: inputText)
                workspace.activePrompt = nil
                workspace.activeTab.reload(showHidden: workspace.showHiddenFiles, preferredSelection: renamed)
                workspace.showStatus("Endret navn til «\(renamed.lastPathComponent)»")

            case .confirmPermanentDelete(let urls):
                workspace.activePrompt = nil
                workspace.executePermanentDelete(urls)
            }
        } catch {
            workspace.alertErrorMessage = error.localizedDescription
        }
    }
}

struct SettingsSheetView: View {
    @Bindable var workspace: WorkspaceState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(
                    workspace.tr("FlowFile – Innstillinger", "FlowFile – Settings"),
                    systemImage: "slider.horizontal.3"
                )
                .font(.system(size: 16, weight: .semibold))
                Spacer()
                Button(workspace.tr("Ferdig", "Done")) {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }

            Divider()

            // Language & Onboarding
            VStack(alignment: .leading, spacing: 10) {
                Text(workspace.tr("Språk & Brukerveiledning", "Language & User Guide"))
                    .font(.system(size: 13, weight: .semibold))

                HStack {
                    Text(workspace.tr("Språk:", "Language:"))
                        .font(.system(size: 12.5))
                    Picker("", selection: $workspace.appLanguage) {
                        ForEach(AppLanguage.allCases) { lang in
                            Text(lang.displayName(in: workspace.appLanguage)).tag(lang)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                HStack(spacing: 8) {
                    Button {
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            workspace.startInteractiveTour()
                        }
                    } label: {
                        HStack(spacing: 6) {
                            LucideIcon(kind: .mousePointerClick, size: 13)
                            Text(workspace.tr("Start interaktiv omvisning", "Launch Interactive Tour"))
                                .font(.system(size: 12))
                        }
                    }
                    .buttonStyle(.glass)

                    Button {
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            workspace.openUpdateChecker()
                        }
                    } label: {
                        HStack(spacing: 6) {
                            LucideIcon(kind: .refreshCw, size: 13)
                            Text(workspace.tr("Se etter oppdateringer...", "Check for Updates..."))
                                .font(.system(size: 12))
                        }
                    }
                    .buttonStyle(.glass)
                }
            }

            Divider()

            // macOS Permissions
            VStack(alignment: .leading, spacing: 8) {
                Text(workspace.tr("macOS-tillatelser", "macOS Permissions"))
                    .font(.system(size: 13, weight: .semibold))

                HStack(spacing: 8) {
                    Image(systemName: workspace.hasFullDiskAccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(workspace.hasFullDiskAccess ? .green : .orange)
                    Text(workspace.hasFullDiskAccess
                         ? workspace.tr("Full disktilgang: Aktivert", "Full Disk Access: Enabled")
                         : workspace.tr("Full disktilgang: Ikke aktivert", "Full Disk Access: Not enabled"))
                        .font(.system(size: 12.5, weight: .medium))

                    Spacer()

                    Button(workspace.tr("Åpne Systeminnstillinger", "Open System Settings")) {
                        PermissionsService.openFullDiskAccessSettings()
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)

                    Button {
                        workspace.refreshPermissionsStatus()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text(workspace.tr("Tastatur & Total Commander-oppførsel", "Keyboard & Total Commander Behavior"))
                    .font(.system(size: 13, weight: .semibold))

                Toggle(
                    workspace.tr(
                        "Bruk Space til Total Commander-markering + mappestørrelse (og Shift+Space / F3 for Quick Look)",
                        "Use Space for Total Commander mark + folder size (and Shift+Space / F3 for Quick Look)"
                    ),
                    isOn: $workspace.swapSpaceShortcut
                )
                .font(.system(size: 12.5))

                Toggle(
                    workspace.tr(
                        "Vis alltid F3–F8-handlingsraden nederst (også i 1-panel Explorer-modus)",
                        "Always show bottom F3–F8 action bar (even in 1-Pane Explorer mode)"
                    ),
                    isOn: $workspace.showFKeyBarAlways
                )
                .font(.system(size: 12.5))
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text(workspace.tr("Sidepanel & Filvisning", "Sidebar & File View"))
                    .font(.system(size: 13, weight: .semibold))

                Toggle(
                    workspace.tr(
                        "Skjul venstre sidepanel automatisk når du bytter til Dual-Pane (Cmd+D)",
                        "Auto-collapse left sidebar when switching to Dual-Pane (Cmd+D)"
                    ),
                    isOn: $workspace.autoCollapseSidebarInDualPane
                )
                .font(.system(size: 12.5))

                Toggle(
                    workspace.tr("Vis skjulte dot-filer (.dotfiles)", "Show hidden dotfiles (.dotfiles)"),
                    isOn: $workspace.showHiddenFiles
                )
                .font(.system(size: 12.5))
            }

            Spacer(minLength: 4)
        }
        .padding(22)
        .frame(width: 540)
        .onAppear {
            workspace.refreshPermissionsStatus()
        }
    }
}
