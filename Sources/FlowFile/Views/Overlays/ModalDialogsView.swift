import AppKit
import SwiftUI

struct PromptDialogSheet: View {
    let prompt: ActivePrompt
    @Bindable var workspace: WorkspaceState
    @State private var inputText: String = ""
    @FocusState private var isFocused: Bool

    private var validationError: String? {
        switch prompt {
        case .confirmPermanentDelete:
            return nil
        case .newFolder, .newFile, .rename:
            let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return workspace.tr("Navnet kan ikke være tomt.", "The name cannot be empty.")
            }
            if trimmed.contains("/") || trimmed.contains(":") {
                return workspace.tr(
                    "Navnet kan ikke inneholde «/» eller «:».",
                    "The name cannot contain “/” or “:”."
                )
            }
            return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch prompt {
            case .newFolder(let directory):
                Label(workspace.tr("Opprett ny mappe", "Create New Folder"), systemImage: "folder.badge.plus")
                    .font(.system(size: 15, weight: .semibold))
                Text("\(workspace.tr("I", "In")): \(directory.path)")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                TextField(workspace.tr("Mappenavn", "Folder name"), text: $inputText)
                    .textFieldStyle(.roundedBorder)
                    .focused($isFocused)
                    .onSubmit { submit() }

            case .newFile(let directory):
                Label(workspace.tr("Opprett ny tom fil", "Create New Empty File"), systemImage: "doc.badge.plus")
                    .font(.system(size: 15, weight: .semibold))
                Text("\(workspace.tr("I", "In")): \(directory.path)")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                TextField(workspace.tr("Filnavn (f.eks. notat.md)", "File name (e.g. note.md)"), text: $inputText)
                    .textFieldStyle(.roundedBorder)
                    .focused($isFocused)
                    .onSubmit { submit() }

            case .rename(_, let currentName):
                Label(workspace.tr("Gi nytt navn (F2)", "Rename (F2)"), systemImage: "pencil")
                    .font(.system(size: 15, weight: .semibold))
                Text("\(workspace.tr("Nåværende navn", "Current name")): \(currentName)")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)

                TextField(workspace.tr("Nytt navn", "New name"), text: $inputText)
                    .textFieldStyle(.roundedBorder)
                    .focused($isFocused)
                    .onSubmit { submit() }

            case .confirmPermanentDelete(let urls):
                Label(workspace.tr("Slett permanent?", "Delete Permanently?"), systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.red)

                Text(workspace.tr(
                    "Er du sikker på at du vil slette \(urls.count) element(er) permanent? Dette går utenom Papirkurven og kan ikke angres.",
                    "Are you sure you want to permanently delete \(urls.count) item(s)? This bypasses the Trash and cannot be undone."
                ))
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)

                if let first = urls.first {
                    Text(urls.count == 1
                         ? first.lastPathComponent
                         : "\(first.lastPathComponent) + \(urls.count - 1) \(workspace.tr("til", "more"))")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }

            if let error = validationError {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button(workspace.tr("Avbryt", "Cancel")) {
                    workspace.activePrompt = nil
                }
                .keyboardShortcut(.cancelAction)

                Button(confirmTitle, role: isDestructive ? .destructive : nil) {
                    submit()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(isDestructive ? .red : .accentColor)
                .disabled(validationError != nil)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            switch prompt {
            case .newFolder:
                inputText = workspace.tr("Ny mappe", "New Folder")
            case .newFile:
                inputText = workspace.tr("ny-fil.txt", "new-file.txt")
            case .rename(_, let currentName):
                inputText = currentName
            case .confirmPermanentDelete:
                break
            }
            DispatchQueue.main.async {
                isFocused = true
                selectInitialTextRange()
            }
        }
    }

    /// Selects the filename stem (protecting `.ext`) when renaming a file, or the full default name for new folders/files.
    private func selectInitialTextRange() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard let textView = NSApp.keyWindow?.firstResponder as? NSTextView else { return }
            let full = textView.string as NSString
            guard full.length > 0 else { return }

            switch prompt {
            case .rename(let itemURL, _):
                var isDir: ObjCBool = false
                let isFolder = FileManager.default.fileExists(atPath: itemURL.path, isDirectory: &isDir) && isDir.boolValue
                let name = textView.string
                if !isFolder, let dotIdx = name.lastIndex(of: "."), dotIdx != name.startIndex {
                    let stemLength = name.distance(from: name.startIndex, to: dotIdx)
                    let utf16Len = (String(name[..<dotIdx]) as NSString).length
                    if stemLength > 0 && utf16Len <= full.length {
                        textView.setSelectedRange(NSRange(location: 0, length: utf16Len))
                        return
                    }
                }
                textView.setSelectedRange(NSRange(location: 0, length: full.length))

            case .newFile:
                let name = textView.string
                if let dotIdx = name.lastIndex(of: "."), dotIdx != name.startIndex {
                    let utf16Len = (String(name[..<dotIdx]) as NSString).length
                    textView.setSelectedRange(NSRange(location: 0, length: utf16Len))
                } else {
                    textView.setSelectedRange(NSRange(location: 0, length: full.length))
                }

            case .newFolder:
                textView.setSelectedRange(NSRange(location: 0, length: full.length))

            case .confirmPermanentDelete:
                break
            }
        }
    }

    private var isDestructive: Bool {
        if case .confirmPermanentDelete = prompt { return true }
        return false
    }

    private var confirmTitle: String {
        switch prompt {
        case .newFolder, .newFile: return workspace.tr("Opprett", "Create")
        case .rename: return workspace.tr("Lagre navn", "Save Name")
        case .confirmPermanentDelete: return workspace.tr("Slett permanent", "Delete Permanently")
        }
    }

    private func submit() {
        guard validationError == nil else { return }
        do {
            switch prompt {
            case .newFolder(let dir):
                let created = try FileSystemService.createFolder(named: inputText, in: dir)
                workspace.activePrompt = nil
                workspace.activeTab.reload(showHidden: workspace.showHiddenFiles, preferredSelection: created)
                workspace.showStatus(workspace.tr("Opprettet mappen «\(created.lastPathComponent)»", "Created folder “\(created.lastPathComponent)”"))

            case .newFile(let dir):
                let created = try FileSystemService.createEmptyFile(named: inputText, in: dir)
                workspace.activePrompt = nil
                workspace.activeTab.reload(showHidden: workspace.showHiddenFiles, preferredSelection: created)
                workspace.showStatus(workspace.tr("Opprettet filen «\(created.lastPathComponent)»", "Created file “\(created.lastPathComponent)”"))

            case .rename(let itemURL, _):
                let renamed = try FileSystemService.renameItem(at: itemURL, to: inputText)
                workspace.recordRenameUndo(original: itemURL, renamed: renamed)
                workspace.activePrompt = nil
                workspace.activeTab.reload(showHidden: workspace.showHiddenFiles, preferredSelection: renamed)
                workspace.showStatus(workspace.tr("Endret navn til «\(renamed.lastPathComponent)»", "Renamed to “\(renamed.lastPathComponent)”"))

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

    @State private var isSigningInMicrosoft: Bool = false
    @State private var isSigningInGoogle: Bool = false
    @State private var oauthStatusMessage: String? = nil
    @State private var oauthErrorMessage: String? = nil

    private var oauth: CloudShareOAuthService {
        CloudShareOAuthService.shared
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
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
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .frame(maxWidth: 260, alignment: .leading)
                            Spacer()
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

                    // Direct Cloud Sharing (OneDrive & Google Drive OAuth)
                    VStack(alignment: .leading, spacing: 10) {
                        Text(workspace.tr("Direkte skydeling (OneDrive & Google Drive OAuth)", "Direct Cloud Sharing (OneDrive & Google Drive OAuth)"))
                            .font(.system(size: 13, weight: .semibold))

                        // Microsoft OneDrive / Teams
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                Image(systemName: oauth.isMicrosoftSignedIn ? "checkmark.circle.fill" : "cloud")
                                    .foregroundStyle(oauth.isMicrosoftSignedIn ? .green : .secondary)
                                Text("Microsoft OneDrive & Teams")
                                    .font(.system(size: 12.5, weight: .medium))
                                if let email = oauth.microsoftAccountEmail, oauth.isMicrosoftSignedIn {
                                    Text("(\(email))")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                if isSigningInMicrosoft {
                                    ProgressView().controlSize(.small)
                                } else if oauth.isMicrosoftSignedIn {
                                    Button(workspace.tr("Logg ut", "Sign Out")) {
                                        oauth.signOutMicrosoft()
                                        oauthStatusMessage = workspace.tr("Logget ut av Microsoft OneDrive", "Signed out of Microsoft OneDrive")
                                        oauthErrorMessage = nil
                                    }
                                    .buttonStyle(.glass)
                                    .controlSize(.small)
                                } else {
                                    Button(workspace.tr("Logg inn med Microsoft", "Sign In with Microsoft")) {
                                        signInMicrosoft()
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                                    .disabled(oauth.microsoftClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                }
                            }

                            HStack(spacing: 6) {
                                Text("Client ID:")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 64, alignment: .leading)
                                TextField(
                                    workspace.tr("Azure App Client ID (valgfri for direkte lenker)", "Azure App Client ID (optional for direct links)"),
                                    text: Binding(
                                        get: { oauth.microsoftClientID },
                                        set: { oauth.microsoftClientID = $0 }
                                    )
                                )
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11.5, design: .monospaced))
                            }
                        }
                        .padding(9)
                        .background(Color.primary.opacity(0.035))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                        // Google Drive
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                Image(systemName: oauth.isGoogleSignedIn ? "checkmark.circle.fill" : "externaldrive.badge.icloud")
                                    .foregroundStyle(oauth.isGoogleSignedIn ? .green : .secondary)
                                Text("Google Drive")
                                    .font(.system(size: 12.5, weight: .medium))
                                if let email = oauth.googleAccountEmail, oauth.isGoogleSignedIn {
                                    Text("(\(email))")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                if isSigningInGoogle {
                                    ProgressView().controlSize(.small)
                                } else if oauth.isGoogleSignedIn {
                                    Button(workspace.tr("Logg ut", "Sign Out")) {
                                        oauth.signOutGoogle()
                                        oauthStatusMessage = workspace.tr("Logget ut av Google Drive", "Signed out of Google Drive")
                                        oauthErrorMessage = nil
                                    }
                                    .buttonStyle(.glass)
                                    .controlSize(.small)
                                } else {
                                    Button(workspace.tr("Logg inn med Google", "Sign In with Google")) {
                                        signInGoogle()
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                                    .disabled(oauth.googleClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                }
                            }

                            HStack(spacing: 6) {
                                Text("Client ID:")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 64, alignment: .leading)
                                TextField(
                                    workspace.tr("Google OAuth Desktop Client ID", "Google OAuth Desktop Client ID"),
                                    text: Binding(
                                        get: { oauth.googleClientID },
                                        set: { oauth.googleClientID = $0 }
                                    )
                                )
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11.5, design: .monospaced))
                            }
                        }
                        .padding(9)
                        .background(Color.primary.opacity(0.035))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                        if let msg = oauthStatusMessage {
                            Text(msg)
                                .font(.system(size: 11.5))
                                .foregroundStyle(.green)
                        }
                        if let err = oauthErrorMessage {
                            Text(err)
                                .font(.system(size: 11.5))
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Divider()

                    // macOS Permissions
                    VStack(alignment: .leading, spacing: 8) {
                        Text(workspace.tr("macOS-tillatelser", "macOS Permissions"))
                            .font(.system(size: 13, weight: .semibold))

                        if workspace.showPostUpdatePermissionsAlert {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                Text(workspace.tr(
                                    "FlowFile ble oppdatert og macOS tilbakestilte tillatelser. Slå Full disktilgang av og på i Systeminnstillinger for å gjenopprette.",
                                    "FlowFile was updated and macOS reset permissions. Toggle Full Disk Access off and on in System Settings to restore."
                                ))
                                .font(.system(size: 11.5))
                                .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(8)
                            .background(Color.orange.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        }

                        HStack(spacing: 8) {
                            Image(systemName: workspace.hasFullDiskAccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(workspace.hasFullDiskAccess ? .green : .orange)
                            Text(workspace.hasFullDiskAccess
                                 ? workspace.tr("Full disktilgang: Aktivert", "Full Disk Access: Enabled")
                                 : workspace.tr("Full disktilgang: Ikke aktivert", "Full Disk Access: Not enabled"))
                                .font(.system(size: 12.5, weight: .medium))

                            Spacer()

                            Button(workspace.tr("Full disktilgang", "Full Disk Access")) {
                                PermissionsService.openFullDiskAccessSettings()
                            }
                            .buttonStyle(.glass)
                            .controlSize(.small)

                            Button {
                                workspace.refreshPermissionsStatus()
                                if workspace.hasFullDiskAccess {
                                    workspace.showPostUpdatePermissionsAlert = false
                                }
                            } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                            .buttonStyle(.glass)
                            .controlSize(.small)
                        }

                        HStack(spacing: 6) {
                            Button(workspace.tr("Filer og mapper", "Files & Folders")) {
                                PermissionsService.openFilesAndFoldersSettings()
                            }
                            .buttonStyle(.glass)
                            .controlSize(.small)

                            Button(workspace.tr("Lokalt nettverk", "Local Network")) {
                                PermissionsService.openLocalNetworkSettings()
                            }
                            .buttonStyle(.glass)
                            .controlSize(.small)

                            Button(workspace.tr("Automatisering", "Automation")) {
                                PermissionsService.openAutomationSettings()
                            }
                            .buttonStyle(.glass)
                            .controlSize(.small)
                        }
                    }

                    Divider()

                    // Default File Browser in macOS
                    VStack(alignment: .leading, spacing: 9) {
                        Text(workspace.tr("Standard filutforsker i macOS", "Default File Browser in macOS"))
                            .font(.system(size: 13, weight: .semibold))

                        HStack(spacing: 8) {
                            LucideIcon(
                                kind: workspace.isDefaultFileBrowser ? .checkCircle : .settings,
                                size: 16
                            )
                            .foregroundStyle(workspace.isDefaultFileBrowser ? .green : .secondary)

                            Text(workspace.isDefaultFileBrowser
                                 ? workspace.tr("Aktiv standard: FlowFile", "Current default: FlowFile")
                                 : workspace.tr("Aktiv standard: macOS Finder", "Current default: macOS Finder"))
                                .font(.system(size: 12.5, weight: .medium))

                            Spacer()

                            if workspace.isUpdatingDefaultBrowser {
                                ProgressView()
                                    .controlSize(.small)
                            }

                            if workspace.isDefaultFileBrowser {
                                Button(workspace.tr("Oppdater registrering", "Re-apply FlowFile")) {
                                    Task { await workspace.setAsDefaultFileBrowser() }
                                }
                                .buttonStyle(.glass)
                                .controlSize(.small)
                                .disabled(workspace.isUpdatingDefaultBrowser)
                            } else {
                                Button(workspace.tr("Sett FlowFile som standard", "Set FlowFile as Default")) {
                                    Task { await workspace.setAsDefaultFileBrowser() }
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                .disabled(workspace.isUpdatingDefaultBrowser)
                            }

                            Button(workspace.tr("Tilbakestill til Finder", "Restore Finder")) {
                                Task { await workspace.resetDefaultFileBrowserToFinder() }
                            }
                            .buttonStyle(.glass)
                            .controlSize(.small)
                            .disabled(workspace.isUpdatingDefaultBrowser || !workspace.isDefaultFileBrowser)
                        }

                        HStack(spacing: 8) {
                            Text(workspace.tr("Åpne eksterne mapper i:", "Open external folders in:"))
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)

                            Picker("", selection: $workspace.externalOpenTabBehavior) {
                                ForEach(ExternalOpenTabBehavior.allCases) { mode in
                                    Text(mode.displayName(in: workspace.appLanguage)).tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)
                        }

                        Text(workspace.tr(
                            "Gjør at «Vis i Finder» fra nettlesere, Spotlight og Terminal åpner i FlowFile. Apper som allerede kjører kan måtte startes på nytt før byttet trer i kraft. Åpne/Lagre-dialoger (⌘O/⌘S), Skrivebord og Dock tilhører alltid Finder.",
                            "Routes 'Show in Finder' from browsers, Spotlight, and Terminal to FlowFile. Already running apps may need a restart to pick up the change. Open/Save panels (⌘O/⌘S), Desktop, and Dock always remain managed by Finder."
                        ))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 10) {
                        Text(workspace.tr("Tastatur & Hurtighandlinger", "Keyboard & Quick Actions"))
                            .font(.system(size: 13, weight: .semibold))

                        Toggle(
                            workspace.tr(
                                "Bruk Space til hurtigmarkering + mappestørrelse (og Shift+Space / F3 for Quick Look)",
                                "Use Space for quick-mark + folder size (and Shift+Space / F3 for Quick Look)"
                            ),
                            isOn: $workspace.swapSpaceShortcut
                        )
                        .font(.system(size: 12.5))

                        Toggle(
                            workspace.tr(
                                "Vis alltid F3–F8-handlingsraden nederst (også i enkeltpanel-visning)",
                                "Always show bottom F3–F8 action bar (even in single-pane view)"
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
                }
                .padding(.trailing, 6)
            }
        }
        .padding(22)
        .frame(width: 600, height: 640)
        .onAppear {
            workspace.refreshPermissionsStatus()
        }
    }

    private func signInMicrosoft() {
        isSigningInMicrosoft = true
        oauthErrorMessage = nil
        oauthStatusMessage = nil
        Task { @MainActor in
            defer { isSigningInMicrosoft = false }
            do {
                try await oauth.signInMicrosoft()
                oauthStatusMessage = workspace.tr("Logget inn på Microsoft OneDrive!", "Signed in to Microsoft OneDrive!")
            } catch {
                oauthErrorMessage = error.localizedDescription
            }
        }
    }

    private func signInGoogle() {
        isSigningInGoogle = true
        oauthErrorMessage = nil
        oauthStatusMessage = nil
        Task { @MainActor in
            defer { isSigningInGoogle = false }
            do {
                try await oauth.signInGoogle()
                oauthStatusMessage = workspace.tr("Logget inn på Google Drive!", "Signed in to Google Drive!")
            } catch {
                oauthErrorMessage = error.localizedDescription
            }
        }
    }
}
