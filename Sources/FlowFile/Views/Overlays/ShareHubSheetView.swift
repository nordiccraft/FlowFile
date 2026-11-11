import AppKit
import SwiftUI

struct ShareHubSheetView: View {
    @Bindable var workspace: WorkspaceState
    let targetItems: [FileItem]

    @State private var options = SharePreparationOptions()
    @State private var wifiServer = LocalWiFiShareServer()
    @State private var feedbackBanner: String? = nil
    @Environment(\.dismiss) private var dismiss

    private var hasDirectoriesOrMultiple: Bool {
        targetItems.count > 1 || targetItems.contains(where: \.isNavigableFolder)
    }

    private var hasImages: Bool {
        ShareHubService.containsImages(targetItems)
    }

    private var currentCloudAccount: CloudAccountItem? {
        guard let first = targetItems.first else { return nil }
        return CloudStorageService.cloudAccount(containing: first.url, accounts: workspace.cloudAccounts)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header
            HStack {
                Label(
                    workspace.tr("FlowFile Smart Delingssenter", "FlowFile Smart Share Hub"),
                    systemImage: "square.and.arrow.up.circle.fill"
                )
                .font(.system(size: 16, weight: .semibold))
                Spacer()
                Text(selectionSummary)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            if workspace.tour.isSandboxActive {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.shield.fill")
                        .foregroundStyle(.green)
                    Text(workspace.tr(
                        "Øvingsmodus aktiv: Klikk gjerne på valgene for å teste – ingen ekte filer sendes eller opprettes.",
                        "Practice Mode active: Feel free to click options to test – no real files are sent or created."
                    ))
                    .font(.system(size: 11.5, weight: .medium))
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.green.opacity(0.12)))
            }

            // 1. Smart Preparation Options (Pilar 1)
            VStack(alignment: .leading, spacing: 10) {
                Text("1. SMART KLARGJØRING FØR DELING")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(.secondary)

                HStack(spacing: 16) {
                    Toggle("Pakk som Windows-ren .zip (uten .DS_Store / __MACOSX)", isOn: $options.packageAsCleanZip)
                        .font(.system(size: 12.5))
                        .disabled(options.usePassword)

                    if options.packageAsCleanZip || options.usePassword {
                        HStack(spacing: 4) {
                            Text("Navn:")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                            TextField("Arkivnavn", text: $options.archiveBaseName)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12, design: .monospaced))
                                .frame(width: 165)
                            Text(".zip")
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                HStack(spacing: 14) {
                    Toggle("Beskytt med passord (kryptert ZIP)", isOn: Binding(
                        get: { options.usePassword },
                        set: { enabled in
                            options.usePassword = enabled
                            if enabled {
                                options.packageAsCleanZip = true
                            }
                        }
                    ))
                    .font(.system(size: 12.5))

                    if options.usePassword {
                        SecureField("Skriv passord...", text: $options.password)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 200)
                    }
                }

                if hasImages {
                    Toggle(
                        ShareHubService.containsHeicImages(targetItems)
                            ? "Konverter .HEIC til vanlig .JPG og fjern GPS/posisjons-metadata"
                            : "Fjern GPS- og kamera-metadata fra bilder før deling",
                        isOn: $options.convertHeicAndStripGPS
                    )
                    .font(.system(size: 12.5))
                }
            }
            .padding(12)
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            // 2. Direct App & Chat Channels (Pilar 2)
            VStack(alignment: .leading, spacing: 8) {
                Text("2. SEND DIREKTE SOM VEDLEGG ELLER TIL CHAT")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    shareCardButton(
                        title: "E-post (\(ShareHubService.defaultEmailAppName()))",
                        subtitle: "Ekte filvedlegg",
                        icon: "envelope.fill"
                    ) {
                        runPreparedAction { urls in
                            ShareHubService.shareViaDefaultEmail(urls)
                            dismiss()
                        }
                    }

                    if ShareHubService.installedOutlookURL() != nil && ShareHubService.defaultEmailAppName() != "Microsoft Outlook" {
                        shareCardButton(
                            title: "Microsoft Outlook",
                            subtitle: "Nytt utkast med vedlegg",
                            icon: "tray.full.fill"
                        ) {
                            runPreparedAction { urls in
                                ShareHubService.shareViaOutlook(urls)
                                dismiss()
                            }
                        }
                    }

                    shareCardButton(
                        title: "AirDrop",
                        subtitle: "Til Mac / iPhone / iPad",
                        icon: "airplayaudio"
                    ) {
                        runPreparedAction { urls in
                            ShareHubService.shareViaAirDrop(urls)
                        }
                    }

                    shareCardButton(
                        title: "Meldinger",
                        subtitle: "Send i iMessage",
                        icon: "message.fill"
                    ) {
                        runPreparedAction { urls in
                            ShareHubService.shareViaMessages(urls)
                        }
                    }

                    shareCardButton(
                        title: "Teams / Slack",
                        subtitle: "Kopier klar for ⌘V i chat",
                        icon: "bubble.left.and.bubble.right.fill"
                    ) {
                        runPreparedAction { urls in
                            ShareHubService.copyPreparedFilesForChatApps(urls)
                            feedbackBanner = "✓ Klargjort fil er kopiert! Gå til Teams/Slack og trykk ⌘V."
                        }
                    }
                }
            }

            // 3. Cloud Bridge: OneDrive, Dropbox, Google Drive, Box, iCloud (Pilar 3)
            VStack(alignment: .leading, spacing: 8) {
                Text("3. SKYLAGRING (ONEDRIVE, DROPBOX, GOOGLE DRIVE, BOX & ICLOUD)")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(.secondary)

                if let activeCloud = currentCloudAccount {
                    HStack(spacing: 10) {
                        Image(systemName: activeCloud.provider.systemImage)
                            .foregroundStyle(Color.accentColor)
                        Text("Ligger allerede i \(activeCloud.displayName)")
                            .font(.system(size: 12.5, weight: .medium))

                        Spacer()

                        Button("Åpne skydeling") {
                            let rawURLs = targetItems.map(\.url)
                            if !ShareHubService.shareViaCloudService(rawURLs) {
                                NSWorkspace.shared.activateFileViewerSelecting(rawURLs)
                            }
                        }
                        .buttonStyle(.glass)

                        Button("Kopier filsti") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(targetItems.map(\.url.path).joined(separator: "\n"), forType: .string)
                            feedbackBanner = "✓ Kopierte sti i \(activeCloud.displayName)"
                        }
                        .buttonStyle(.glass)
                    }
                    .padding(10)
                    .background(Color.accentColor.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                } else if workspace.cloudAccounts.isEmpty {
                    Text("Ingen lokale skykontoer (OneDrive, Dropbox, Google Drive, Box) ble funnet på denne Macen ennå – bruk gjerne E-post, Teams/Slack eller QR-deling under.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(workspace.cloudAccounts) { account in
                                Button {
                                    runPreparedAction { urls in
                                        do {
                                            let res = try ShareHubService.copyIntoCloudSharedFolder(urls, account: account)
                                            workspace.navigateActiveTab(to: res.folder)
                                            workspace.activeTab.selectedURLs = Set(res.copied)
                                            workspace.showStatus("Lagt i «Delt fra FlowFile» i \(account.displayName)!")
                                            dismiss()
                                        } catch {
                                            workspace.alertErrorMessage = error.localizedDescription
                                        }
                                    }
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: account.provider.systemImage)
                                            .foregroundStyle(Color.accentColor)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text("Legg i \(account.displayName)")
                                                .font(.system(size: 12, weight: .medium))
                                            Text("Kopierer til «Delt fra FlowFile»")
                                                .font(.system(size: 10))
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                }
                                .buttonStyle(.glass)
                            }
                        }
                    }
                }
            }

            // 4. Local Wi-Fi QR Drop to Windows / Android / iPhone (Pilar 4)
            VStack(alignment: .leading, spacing: 8) {
                Text("4. LYN-DELING MED QR-KODE PÅ WI-FI (TIL WINDOWS, ANDROID & IPHONE)")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(.secondary)

                if wifiServer.isRunning {
                    HStack(spacing: 16) {
                        if let qrImage = ShareHubService.generateQRCodeImage(for: wifiServer.shareURLString) {
                            Image(nsImage: qrImage)
                                .interpolation(.none)
                                .resizable()
                                .frame(width: 116, height: 116)
                                .padding(6)
                                .background(Color.white)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Skann med mobilkamera eller åpne lenken på en PC på samme Wi-Fi:")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)

                            HStack(spacing: 8) {
                                Text(wifiServer.shareURLString)
                                    .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                                    .textSelection(.enabled)

                                Button("Kopier lenke") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(wifiServer.shareURLString, forType: .string)
                                    feedbackBanner = "✓ Kopierte lokal Wi-Fi-lenke!"
                                }
                                .font(.system(size: 11))
                                .buttonStyle(.glass)
                            }

                            Toggle("Stopp lenken automatisk etter første nedlasting", isOn: $wifiServer.autoStopAfterFirstDownload)
                                .font(.system(size: 11.5))

                            HStack {
                                Text(wifiServer.downloadCount > 0 ? "✓ Lastet ned \(wifiServer.downloadCount) gang(er)" : "Venter på mottaker...")
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(wifiServer.downloadCount > 0 ? .green : Color.accentColor)

                                Spacer()

                                Button("Stopp Wi-Fi-deling", role: .destructive) {
                                    wifiServer.stop()
                                }
                                .font(.system(size: 11.5))
                                .buttonStyle(.glass)
                            }
                        }
                    }
                    .padding(12)
                    .background(Color.primary.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Del direkte over lokalnettet uten sky og uten størrelsesgrense")
                                .font(.system(size: 12, weight: .medium))
                            Text("Perfekt når mottakeren sitter på en Windows-PC, Android eller telefon i nærheten.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            startWiFiQRShare()
                        } label: {
                            Label("Vis QR-kode & Wi-Fi-lenke", systemImage: "qrcode")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(10)
                    .background(Color.primary.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                if let err = wifiServer.errorMessage {
                    Text(err)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.red)
                }
            }

            // Footer
            HStack {
                if let feedbackBanner {
                    Text(feedbackBanner)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.green)
                }
                Spacer()
                Button("Lukk") {
                    wifiServer.stop()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(18)
        .frame(width: 720)
        .onAppear {
            if hasDirectoriesOrMultiple {
                options.packageAsCleanZip = true
            }
            if let first = targetItems.first {
                options.archiveBaseName = targetItems.count == 1
                    ? first.stemName
                    : "\(first.stemName)-med-\(targetItems.count - 1)-til"
            }
            if ShareHubService.containsHeicImages(targetItems) {
                options.convertHeicAndStripGPS = true
            }
        }
        .onDisappear {
            wifiServer.stop()
        }
    }

    private var selectionSummary: String {
        if targetItems.count == 1, let single = targetItems.first {
            return single.name
        }
        return "\(targetItems.count) valgte elementer"
    }

    @ViewBuilder
    private func shareCardButton(
        title: String,
        subtitle: String,
        icon: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(9)
        }
        .buttonStyle(.glass)
    }

    private func runPreparedAction(_ completion: ([URL]) -> Void) {
        if workspace.tour.isSandboxActive {
            feedbackBanner = workspace.tr(
                "✓ Øvingsmodus: Deling simulert – ingen ekte filer ble sendt!",
                "✓ Practice Mode: Sharing simulated – no real files were sent!"
            )
            return
        }
        do {
            let prepared = try ShareHubService.prepareItems(targetItems, options: options)
            completion(prepared)
        } catch {
            workspace.alertErrorMessage = error.localizedDescription
        }
    }

    private func startWiFiQRShare() {
        if workspace.tour.isSandboxActive {
            feedbackBanner = workspace.tr(
                "✓ Øvingsmodus: Lokal Wi-Fi QR-server simulert!",
                "✓ Practice Mode: Local Wi-Fi QR server simulated!"
            )
            return
        }
        var qrOptions = options
        if hasDirectoriesOrMultiple {
            qrOptions.packageAsCleanZip = true
        }
        do {
            let prepared = try ShareHubService.prepareItems(targetItems, options: qrOptions)
            if let singleFile = prepared.first {
                wifiServer.startSharing(fileURL: singleFile)
            }
        } catch {
            workspace.alertErrorMessage = error.localizedDescription
        }
    }
}
