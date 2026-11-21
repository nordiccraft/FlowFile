import AppKit
import SwiftUI

/// Tiny invisible AppKit anchor so `NSSharingServicePicker` opens cleanly right beneath a SwiftUI button.
private struct SharePickerAnchorView: NSViewRepresentable {
    let onViewReady: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { onViewReady(view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onViewReady(nsView) }
    }
}

struct ShareHubSheetView: View {
    @Bindable var workspace: WorkspaceState
    let targetItems: [FileItem]

    @State private var options = SharePreparationOptions()
    @State private var cachedOptions: SharePreparationOptions? = nil
    @State private var cachedPayload: SharePreparedPayload? = nil
    @State private var isPreparing: Bool = false
    @State private var feedbackBanner: String? = nil
    @State private var warningBanner: String? = nil

    // Cached system lookups (avoid querying LaunchServices on every SwiftUI body redraw)
    @State private var defaultEmailName: String = ""
    @State private var outlookInstalled: Bool = false
    @State private var defaultIsOutlook: Bool = false
    @State private var airDropIcon: NSImage? = nil
    @State private var messagesIcon: NSImage? = nil
    @State private var mailIcon: NSImage? = nil

    // Native macOS share picker anchor
    @State private var pickerAnchorView: NSView? = nil

    // Cloud upload confirmation
    @State private var pendingCloudUploadAccount: CloudAccountItem? = nil

    // Live countdown ticker for active QR share
    @State private var nowTick: Date = Date()
    private let countdownTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    @Environment(\.dismiss) private var dismiss

    private var wifiServer: LocalWiFiShareServer {
        workspace.wifiShareServer
    }

    private var hasDirectoriesOrMultiple: Bool {
        targetItems.count > 1 || targetItems.contains(where: { $0.isNavigableFolder || $0.isDirectory || $0.isPackage })
    }

    private var hasImages: Bool {
        ShareHubService.containsImages(targetItems)
    }

    private var hasCloudOnlyItems: Bool {
        ShareHubService.containsCloudOnlyItems(targetItems)
    }

    /// Only returns a cloud account when EVERY selected item resides inside that SAME cloud account.
    private var sharedCloudAccountForAllItems: CloudAccountItem? {
        guard !targetItems.isEmpty else { return nil }
        let matched = targetItems.compactMap {
            CloudStorageService.cloudAccount(containing: $0.url, accounts: workspace.cloudAccounts)
        }
        guard matched.count == targetItems.count, let first = matched.first else { return nil }
        return matched.allSatisfy({ $0.id == first.id }) ? first : nil
    }

    private var estimatedSelectionBytes: Int64 {
        cachedPayload?.totalBytes ?? targetItems.reduce(Int64(0)) { $0 + $1.size }
    }

    private var exceedsTypicalEmailLimit: Bool {
        estimatedSelectionBytes > 20 * 1_048_576
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                headerSection
                bannersSection
                preparationSection
                directChannelsSection
                cloudSection
                wifiQRSection
                footerSection
            }
            .padding(18)
        }
        .frame(width: 740)
        .frame(maxHeight: 740)
        .onAppear {
            defaultEmailName = ShareHubService.defaultEmailAppName()
            outlookInstalled = ShareHubService.installedOutlookURL() != nil
            defaultIsOutlook = ShareHubService.isDefaultEmailAppOutlook()
            airDropIcon = ShareHubService.systemServiceIcon(named: .sendViaAirDrop)
            messagesIcon = ShareHubService.systemServiceIcon(named: .composeMessage)
            mailIcon = ShareHubService.systemServiceIcon(named: .composeEmail)
            wifiServer.refreshInterfaces()

            if hasDirectoriesOrMultiple {
                options.packageAsCleanZip = true
            }
            if let first = targetItems.first {
                options.archiveBaseName = targetItems.count == 1
                    ? first.stemName
                    : workspace.tr(
                        "\(first.stemName)-med-\(targetItems.count - 1)-til",
                        "\(first.stemName)-and-\(targetItems.count - 1)-more"
                    )
            }
            if ShareHubService.containsHeicImages(targetItems) {
                options.convertHeicAndStripGPS = true
            }
        }
        .onChange(of: options) { _, _ in
            cachedPayload = nil
            cachedOptions = nil
        }
        .onReceive(countdownTimer) { date in
            if wifiServer.isRunning {
                nowTick = date
            }
        }
        .confirmationDialog(
            workspace.tr(
                "Last opp kopi til \(pendingCloudUploadAccount?.fullDisplayName ?? "")?",
                "Upload copy to \(pendingCloudUploadAccount?.fullDisplayName ?? "")?"
            ),
            isPresented: Binding(
                get: { pendingCloudUploadAccount != nil },
                set: { if !$0 { pendingCloudUploadAccount = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(workspace.tr("Last opp kopi (kun deg)", "Upload Copy (Private)")) {
                if let account = pendingCloudUploadAccount {
                    performCloudUpload(to: account)
                }
                pendingCloudUploadAccount = nil
            }
            Button(workspace.tr("Avbryt", "Cancel"), role: .cancel) {
                pendingCloudUploadAccount = nil
            }
        } message: {
            if let account = pendingCloudUploadAccount {
                Text(workspace.tr(
                    "Lager en ny egen undermappe i «FlowFile-delinger» på \(account.fullDisplayName). Ingenting deles med andre før du selv velger Del i \(account.displayName).",
                    "Creates a new isolated subfolder in “FlowFile Shares” on \(account.fullDisplayName). Nothing is shared with anyone until you explicitly share it in \(account.displayName)."
                ))
            }
        }
    }

    // MARK: - Sections

    private var headerSection: some View {
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
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    @ViewBuilder
    private var bannersSection: some View {
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

        if hasCloudOnlyItems {
            HStack(spacing: 8) {
                Image(systemName: "icloud.and.arrow.down")
                    .foregroundStyle(.orange)
                Text(workspace.tr(
                    "Én eller flere valgte filer ligger kun i skyen og vil lastes ned før klargjøring.",
                    "One or more selected files are cloud-only and will be downloaded during preparation."
                ))
                .font(.system(size: 11.5))
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
        }

        if let payload = cachedPayload {
            privacySummaryBanner(for: payload)
        }
    }

    private func privacySummaryParts(for payload: SharePreparedPayload) -> [String] {
        var parts: [String] = []
        if payload.cleanedImagesCount > 0 {
            parts.append(workspace.tr(
                "\(payload.cleanedImagesCount) bilde(r) renset for GPS/EXIF",
                "\(payload.cleanedImagesCount) image(s) stripped of GPS/EXIF"
            ))
        }
        if payload.excludedHiddenCount > 0 {
            parts.append(workspace.tr(
                "\(payload.excludedHiddenCount) skjulte filer utelatt",
                "\(payload.excludedHiddenCount) hidden file(s) excluded"
            ))
        }
        if payload.skippedSymlinksCount > 0 {
            parts.append(workspace.tr(
                "\(payload.skippedSymlinksCount) snarvei(er) utelatt",
                "\(payload.skippedSymlinksCount) symlink(s) skipped"
            ))
        }
        return parts
    }

    @ViewBuilder
    private func privacySummaryBanner(for payload: SharePreparedPayload) -> some View {
        let parts = privacySummaryParts(for: payload)

        if !parts.isEmpty || !payload.uncleanedFiles.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                if !parts.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "shield.checkmark.fill")
                            .foregroundStyle(.green)
                        Text(parts.joined(separator: " • "))
                            .font(.system(size: 11.5, weight: .medium))
                    }
                }
                if !payload.uncleanedFiles.isEmpty {
                    let previewNames = payload.uncleanedFiles.prefix(3).joined(separator: ", ")
                    let more = payload.uncleanedFiles.count > 3 ? " (+\(payload.uncleanedFiles.count - 3))" : ""
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(workspace.tr(
                            "Metadata kunne ikke fjernes automatisk fra: \(previewNames)\(more)",
                            "Metadata could not be stripped automatically from: \(previewNames)\(more)"
                        ))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        }
    }

    private var preparationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(workspace.tr("1. SMART KLARGJØRING FØR DELING", "1. SMART PREPARATION BEFORE SHARING"))
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(workspace.tr("Ikke kryptert", "Not encrypted"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
            }

            HStack(spacing: 14) {
                Toggle(
                    workspace.tr(
                        "Pakk som ren .zip med UTF-8 (æøå-sikker på Windows, uten .git/.env/.DS_Store)",
                        "Package as clean UTF-8 .zip (Windows-safe, excludes .git/.env/.DS_Store)"
                    ),
                    isOn: $options.packageAsCleanZip
                )
                .font(.system(size: 12))

                if options.packageAsCleanZip {
                    HStack(spacing: 4) {
                        Text(workspace.tr("Navn:", "Name:"))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                        TextField(workspace.tr("Arkivnavn", "Archive name"), text: $options.archiveBaseName)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(width: 155)
                        Text(".zip")
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if hasImages {
                Toggle(
                    ShareHubService.containsHeicImages(targetItems)
                        ? workspace.tr(
                            "Konverter .HEIC til .JPG og fjern GPS/kamera-metadata (tapsfri på .JPG)",
                            "Convert .HEIC to .JPG and strip GPS/camera metadata (lossless for .JPG)"
                        )
                        : workspace.tr(
                            "Fjern GPS- og kamera-metadata fra bilder før deling (tapsfri på .JPG)",
                            "Strip GPS and camera metadata from images before sharing (lossless for .JPG)"
                        ),
                    isOn: $options.convertHeicAndStripGPS
                )
                .font(.system(size: 12))
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var directChannelsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(workspace.tr("2. SEND DIREKTE ELLER VIA MACOS DEL-MENY", "2. SEND DIRECTLY OR VIA MACOS SHARE MENU"))
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(.secondary)
                Spacer()
                if exceedsTypicalEmailLimit {
                    Label(
                        workspace.tr(
                            "Over 20 MB – e-post kan avvise vedlegget; bruk QR eller sky i stedet",
                            "Over 20 MB – email may reject attachment; use QR or cloud instead"
                        ),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.orange)
                }
            }

            HStack(spacing: 8) {
                // Native macOS Share Menu (covers Mail, AirDrop, Messages, Notes, iCloud, Outlook/Dropbox/OneDrive extensions)
                shareCardButton(
                    title: workspace.tr("macOS Del…", "macOS Share…"),
                    subtitle: workspace.tr("Alle delingsutvidelser", "All share extensions"),
                    sfSymbol: "square.and.arrow.up",
                    nsImage: nil
                ) {
                    runPreparedAction { payload in
                        if let anchor = pickerAnchorView {
                            ShareHubService.presentSystemSharePicker(items: payload.urls, relativeTo: anchor)
                        }
                    }
                }
                .background(
                    SharePickerAnchorView { view in
                        pickerAnchorView = view
                    }
                )

                shareCardButton(
                    title: workspace.tr("E-post", "Mail") + (defaultEmailName.isEmpty ? "" : " (\(defaultEmailName))"),
                    subtitle: workspace.tr("Ekte filvedlegg", "Real attachment"),
                    sfSymbol: "envelope.fill",
                    nsImage: mailIcon
                ) {
                    runPreparedAction { payload in
                        _ = ShareHubService.shareViaDefaultEmail(payload.urls) { result in
                            handleDeliveryResult(result, channelName: defaultEmailName, dismissOnSuccess: true)
                        }
                    }
                }

                if outlookInstalled && !defaultIsOutlook {
                    shareCardButton(
                        title: "Outlook",
                        subtitle: workspace.tr("Nytt utkast", "New draft"),
                        sfSymbol: "tray.full.fill",
                        nsImage: nil
                    ) {
                        var outlookOpts = options
                        if ShareHubService.containsOutlookImportableTypes(targetItems.map(\.navigationTargetURL)) {
                            outlookOpts.packageAsCleanZip = true
                        }
                        runPreparedAction(overrideOptions: outlookOpts) { payload in
                            _ = ShareHubService.shareViaOutlook(payload.urls) { result in
                                handleDeliveryResult(result, channelName: "Microsoft Outlook", dismissOnSuccess: true)
                            }
                        }
                    }
                }

                shareCardButton(
                    title: "AirDrop",
                    subtitle: "Mac / iPhone / iPad",
                    sfSymbol: "dot.radiowaves.left.and.right",
                    nsImage: airDropIcon
                ) {
                    runPreparedAction { payload in
                        _ = ShareHubService.shareViaAirDrop(payload.urls) { result in
                            handleDeliveryResult(result, channelName: "AirDrop", dismissOnSuccess: false)
                        }
                    }
                }

                shareCardButton(
                    title: workspace.tr("Meldinger", "Messages"),
                    subtitle: "iMessage",
                    sfSymbol: "message.fill",
                    nsImage: messagesIcon
                ) {
                    runPreparedAction { payload in
                        _ = ShareHubService.shareViaMessages(payload.urls) { result in
                            handleDeliveryResult(result, channelName: workspace.tr("Meldinger", "Messages"), dismissOnSuccess: false)
                        }
                    }
                }

                shareCardButton(
                    title: "Teams / Slack",
                    subtitle: workspace.tr("Kopier (⌘V)", "Copy (⌘V)"),
                    sfSymbol: "bubble.left.and.bubble.right.fill",
                    nsImage: nil
                ) {
                    runPreparedAction { payload in
                        ShareHubService.copyPreparedFilesForChatApps(payload.urls)
                        warningBanner = nil
                        feedbackBanner = workspace.tr(
                            "Klargjort fil er kopiert – gå til Slack/Teams og trykk ⌘V (eller dra filen direkte).",
                            "Prepared file copied – switch to Slack/Teams and press ⌘V (or drag the file directly)."
                        )
                    }
                }
            }
            .disabled(isPreparing)
        }
    }

    private var cloudSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(workspace.tr(
                "3. SKYLAGRING (ONEDRIVE, DROPBOX, GOOGLE DRIVE, BOX & ICLOUD)",
                "3. CLOUD STORAGE (ONEDRIVE, DROPBOX, GOOGLE DRIVE, BOX & ICLOUD)"
            ))
            .font(.system(size: 10.5, weight: .bold))
            .foregroundStyle(.secondary)

            if let activeCloud = sharedCloudAccountForAllItems {
                HStack(spacing: 10) {
                    Image(systemName: activeCloud.provider.systemImage)
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(workspace.tr(
                            "Ligger allerede i \(activeCloud.fullDisplayName)",
                            "Already stored in \(activeCloud.fullDisplayName)"
                        ))
                        .font(.system(size: 12.5, weight: .medium))
                        Text(workspace.tr(
                            "Bruk «macOS Del…» eller høyreklikk i Finder for å opprette delingslenke i \(activeCloud.displayName).",
                            "Use “macOS Share…” or right-click in Finder to create a share link in \(activeCloud.displayName)."
                        ))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button(workspace.tr("Vis i Finder → Del", "Reveal in Finder → Share")) {
                        if workspace.tour.isSandboxActive {
                            feedbackBanner = workspace.tr("Øvingsmodus: Visning i Finder simulert.", "Practice Mode: Finder reveal simulated.")
                            return
                        }
                        DefaultFileBrowserService.revealExplicitlyInAppleFinder(targetItems.map(\.url))
                    }
                    .buttonStyle(.glass)

                    Button(workspace.tr("Kopier filsti", "Copy Path")) {
                        if workspace.tour.isSandboxActive {
                            feedbackBanner = workspace.tr("Øvingsmodus: Filsti kopiert (simulert).", "Practice Mode: Path copied (simulated).")
                            return
                        }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(targetItems.map(\.url.path).joined(separator: "\n"), forType: .string)
                        feedbackBanner = workspace.tr(
                            "Kopierte sti i \(activeCloud.fullDisplayName)",
                            "Copied path in \(activeCloud.fullDisplayName)"
                        )
                    }
                    .buttonStyle(.glass)
                }
                .padding(10)
                .background(Color.accentColor.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            } else if workspace.cloudAccounts.isEmpty {
                Text(workspace.tr(
                    "Ingen lokale skykontoer (OneDrive, Dropbox, Google Drive, Box) ble funnet på denne Macen ennå.",
                    "No local cloud accounts (OneDrive, Dropbox, Google Drive, Box) were found on this Mac yet."
                ))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(workspace.cloudAccounts) { account in
                            Button {
                                if workspace.tour.isSandboxActive {
                                    feedbackBanner = workspace.tr(
                                        "Øvingsmodus: Opplasting til \(account.fullDisplayName) simulert!",
                                        "Practice Mode: Upload to \(account.fullDisplayName) simulated!"
                                    )
                                    return
                                }
                                pendingCloudUploadAccount = account
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: account.provider.systemImage)
                                        .foregroundStyle(Color.accentColor)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(workspace.tr("Last opp til \(account.fullDisplayName)", "Upload to \(account.fullDisplayName)"))
                                            .font(.system(size: 12, weight: .medium))
                                        Text(workspace.tr("Ny privat mappe (kun deg)", "New private folder (only you)"))
                                            .font(.system(size: 10))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                            }
                            .buttonStyle(.glass)
                            .disabled(isPreparing)
                        }
                    }
                }
            }
        }
    }

    private var wifiQRSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(workspace.tr(
                    "4. LYN-DELING MED QR-KODE PÅ WI-FI (TIL WINDOWS, ANDROID & IPHONE)",
                    "4. INSTANT QR SHARE OVER WI-FI (TO WINDOWS, ANDROID & IPHONE)"
                ))
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(.secondary)
                Spacer()
                if wifiServer.isRunning {
                    Text(workspace.tr("Ikke kryptert (lokalt nettverk)", "Unencrypted (local network)"))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.orange)
                }
            }

            if wifiServer.isRunning {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 16) {
                        if let qrImage = ShareHubService.generateQRCodeImage(for: wifiServer.shareURLString) {
                            Image(nsImage: qrImage)
                                .interpolation(.none)
                                .resizable()
                                .frame(width: 122, height: 122)
                                .padding(6)
                                .background(Color.white)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            // Self-test status + interface selector
                            HStack(spacing: 8) {
                                selfTestBadge
                                Spacer()
                                if wifiServer.availableInterfaces.count > 1 {
                                    Picker("", selection: Binding(
                                        get: { wifiServer.selectedInterfaceID ?? "" },
                                        set: { wifiServer.switchInterface(to: $0) }
                                    )) {
                                        ForEach(wifiServer.availableInterfaces) { iface in
                                            Text(iface.label).tag(iface.id)
                                        }
                                    }
                                    .labelsHidden()
                                    .controlSize(.small)
                                    .frame(maxWidth: 210)
                                }
                            }

                            HStack(spacing: 8) {
                                Text(wifiServer.shareURLString)
                                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                                    .textSelection(.enabled)
                                    .lineLimit(1)
                                    .truncationMode(.middle)

                                Button(workspace.tr("Kopier lenke", "Copy Link")) {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(wifiServer.shareURLString, forType: .string)
                                    feedbackBanner = workspace.tr("Kopierte lokal Wi-Fi-lenke!", "Copied local Wi-Fi link!")
                                }
                                .font(.system(size: 11))
                                .buttonStyle(.glass)
                            }

                            if wifiServer.requirePIN && !wifiServer.accessPIN.isEmpty {
                                HStack(spacing: 6) {
                                    Image(systemName: "lock.fill")
                                        .foregroundStyle(Color.accentColor)
                                    Text(workspace.tr("PIN-kode for mottaker:", "Recipient PIN:"))
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(.secondary)
                                    Text(wifiServer.accessPIN)
                                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 2)
                                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.15)))
                                }
                            }

                            // Countdown & Extend
                            HStack(spacing: 10) {
                                Text(remainingTimeLabel)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)

                                Button(workspace.tr("+10 min", "+10 min")) {
                                    wifiServer.extendExpiration(bySeconds: 600)
                                }
                                .font(.system(size: 10.5))
                                .buttonStyle(.glass)
                                .controlSize(.mini)

                                Spacer()

                                Text(wifiServer.downloadCount > 0
                                     ? workspace.tr("Lastet ned \(wifiServer.downloadCount) gang(er)", "Downloaded \(wifiServer.downloadCount) time(s)")
                                     : workspace.tr("Venter på mottaker…", "Waiting for recipient…"))
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(wifiServer.downloadCount > 0 ? .green : Color.accentColor)
                            }

                            HStack {
                                Text(workspace.tr(
                                    "Delingen fortsetter i bakgrunnen selv om du lukker dette vinduet.",
                                    "Sharing stays active in the background even if you close this sheet."
                                ))
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)

                                Spacer()

                                Button(workspace.tr("Stopp Wi-Fi-deling", "Stop Wi-Fi Sharing"), role: .destructive) {
                                    wifiServer.stop()
                                }
                                .font(.system(size: 11.5))
                                .buttonStyle(.glass)
                            }
                        }
                    }

                    // Actionable Local Network permission guidance if self-test failed
                    if wifiServer.selfTestState == .blockedByLocalNetwork {
                        HStack(spacing: 10) {
                            Image(systemName: "wifi.exclamationmark")
                                .foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(workspace.tr(
                                    "macOS blokkerer lokalt nettverk for FlowFile",
                                    "macOS is blocking Local Network access for FlowFile"
                                ))
                                .font(.system(size: 11.5, weight: .semibold))
                                Text(workspace.tr(
                                    "Slå på FlowFile under Systeminnstillinger → Personvern og sikkerhet → Lokalt nettverk, og prøv på nytt.",
                                    "Enable FlowFile in System Settings → Privacy & Security → Local Network, then try again."
                                ))
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(workspace.tr("Åpne innstillinger", "Open Settings")) {
                                ShareHubService.openLocalNetworkPrivacySettings()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                        .padding(9)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.14)))
                    } else if wifiServer.showNetworkHintAfterWait {
                        HStack(spacing: 8) {
                            Image(systemName: "info.circle.fill")
                                .foregroundStyle(Color.accentColor)
                            Text(workspace.tr(
                                "Ingen tilkobling ennå? Sjekk at enhetene er på samme Wi-Fi. Bedrifts- og gjestenett blokkerer ofte direkte deling – prøv Personlig hotspot fra mobilen, det fungerer nesten alltid.",
                                "No connection yet? Check both devices are on the same Wi-Fi. Office and guest networks often block direct sharing – try Personal Hotspot from your phone, which almost always works."
                            ))
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.08)))
                    }

                    // Live download log
                    if !wifiServer.downloadEvents.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(wifiServer.downloadEvents.prefix(3)) { ev in
                                Text(workspace.tr(
                                    "Lastet ned av \(ev.clientAddress) kl. \(ev.timestamp.formatted(date: .omitted, time: .standard))",
                                    "Downloaded by \(ev.clientAddress) at \(ev.timestamp.formatted(date: .omitted, time: .standard))"
                                ))
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(12)
                .background(Color.primary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(workspace.tr(
                                "Del direkte over lokalnettet uten sky og uten størrelsesgrense",
                                "Share directly over local Wi-Fi with no cloud and no size limit"
                            ))
                            .font(.system(size: 12, weight: .medium))
                            Text(workspace.tr(
                                "Perfekt til mobil, nettbrett eller PC på samme Wi-Fi (eller Personlig hotspot).",
                                "Great for phones, tablets or PCs on the same Wi-Fi (or Personal Hotspot)."
                            ))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            startWiFiQRShare()
                        } label: {
                            Label(workspace.tr("Vis QR-kode & lenke", "Show QR Code & Link"), systemImage: "qrcode")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isPreparing)
                    }

                    HStack(spacing: 14) {
                        Toggle(
                            workspace.tr("Krev 4-sifret PIN-kode på delte nettverk", "Require 4-digit PIN on shared networks"),
                            isOn: Binding(
                                get: { wifiServer.requirePIN },
                                set: { wifiServer.requirePIN = $0 }
                            )
                        )
                        .font(.system(size: 11))

                        Spacer()

                        if wifiServer.availableInterfaces.count > 1 {
                            Picker(workspace.tr("Nettverk:", "Network:"), selection: Binding(
                                get: { wifiServer.selectedInterfaceID ?? "" },
                                set: { wifiServer.selectedInterfaceID = $0 }
                            )) {
                                ForEach(wifiServer.availableInterfaces) { iface in
                                    Text(iface.label).tag(iface.id)
                                }
                            }
                            .controlSize(.small)
                            .frame(maxWidth: 230)
                        }
                    }
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
    }

    @ViewBuilder
    private var selfTestBadge: some View {
        switch wifiServer.selfTestState {
        case .idle, .testing:
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text(workspace.tr("Tester lokalt nettverk…", "Testing local network…"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        case .reachable:
            Label(workspace.tr("Klar på lokalt nettverk", "Reachable on local network"), systemImage: "checkmark.circle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.green)
        case .blockedByLocalNetwork:
            Label(workspace.tr("Blokkert av Lokalt nettverk", "Blocked by Local Network"), systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.orange)
        }
    }

    private var remainingTimeLabel: String {
        guard let expiresAt = wifiServer.expiresAt else { return "" }
        let secs = max(0, Int(expiresAt.timeIntervalSince(nowTick)))
        let m = secs / 60
        let s = secs % 60
        return workspace.tr(
            String(format: "Utløper om %d:%02d", m, s),
            String(format: "Expires in %d:%02d", m, s)
        )
    }

    private var footerSection: some View {
        HStack {
            if isPreparing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(workspace.tr("Klargjør filer i bakgrunnen…", "Preparing files in background…"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            } else if let warningBanner {
                Text(warningBanner)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.orange)
            } else if let feedbackBanner {
                Text(feedbackBanner)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.green)
            }
            Spacer()
            Button(workspace.tr("Lukk", "Close")) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
        }
    }

    private var selectionSummary: String {
        let sizeStr = ByteFormatter.string(fromByteCount: estimatedSelectionBytes)
        if targetItems.count == 1, let single = targetItems.first {
            return "\(single.name) (\(sizeStr))"
        }
        return workspace.tr(
            "\(targetItems.count) valgte elementer (\(sizeStr))",
            "\(targetItems.count) selected items (\(sizeStr))"
        )
    }

    @ViewBuilder
    private func shareCardButton(
        title: String,
        subtitle: String,
        sfSymbol: String,
        nsImage: NSImage?,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                if let nsImage {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 18, height: 18)
                } else {
                    Image(systemName: sfSymbol)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(height: 18)
                }
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
        .buttonStyle(.glass)
    }

    // MARK: - Async Preparation & Actions

    private func runPreparedAction(
        overrideOptions: SharePreparationOptions? = nil,
        _ completion: @escaping @MainActor (SharePreparedPayload) -> Void
    ) {
        if workspace.tour.isSandboxActive {
            feedbackBanner = workspace.tr(
                "Øvingsmodus: Deling simulert – ingen ekte filer ble sendt!",
                "Practice Mode: Sharing simulated – no real files were sent!"
            )
            return
        }

        let effectiveOptions = overrideOptions ?? options
        if let cachedPayload, cachedOptions == effectiveOptions {
            completion(cachedPayload)
            return
        }

        isPreparing = true
        feedbackBanner = nil
        warningBanner = nil
        let items = targetItems

        Task {
            do {
                let payload = try await ShareHubService.preparePayloadAsync(items, options: effectiveOptions)
                await MainActor.run {
                    isPreparing = false
                    if overrideOptions == nil {
                        cachedPayload = payload
                        cachedOptions = effectiveOptions
                    }
                    completion(payload)
                }
            } catch {
                await MainActor.run {
                    isPreparing = false
                    workspace.alertErrorMessage = error.localizedDescription
                }
            }
        }
    }

    @MainActor
    private func handleDeliveryResult(_ result: Result<Void, Error>, channelName: String, dismissOnSuccess: Bool) {
        switch result {
        case .success:
            warningBanner = nil
            feedbackBanner = workspace.tr(
                "Sendt til \(channelName)",
                "Handed off to \(channelName)"
            )
            if dismissOnSuccess {
                dismiss()
            }
        case .failure(let error):
            warningBanner = error.localizedDescription
        }
    }

    private func performCloudUpload(to account: CloudAccountItem) {
        let label = options.archiveBaseName
        runPreparedAction { payload in
            isPreparing = true
            Task {
                do {
                    let res = try await Task.detached(priority: .userInitiated) {
                        try ShareHubService.copyIntoCloudSharedFolder(payload.urls, account: account, shareLabel: label)
                    }.value
                    await MainActor.run {
                        isPreparing = false
                        workspace.navigateActiveTab(to: res.folder)
                        workspace.activeTab.selectedURLs = Set(res.copied)
                        workspace.showStatus(workspace.tr(
                            "Lastet opp privat kopi i \(account.fullDisplayName) – synkroniserer…",
                            "Uploaded private copy to \(account.fullDisplayName) – syncing…"
                        ))
                        dismiss()
                    }
                } catch {
                    await MainActor.run {
                        isPreparing = false
                        workspace.alertErrorMessage = error.localizedDescription
                    }
                }
            }
        }
    }

    private func startWiFiQRShare() {
        if workspace.tour.isSandboxActive {
            feedbackBanner = workspace.tr(
                "Øvingsmodus: Lokal Wi-Fi QR-server simulert!",
                "Practice Mode: Local Wi-Fi QR server simulated!"
            )
            return
        }
        var qrOptions = options
        if hasDirectoriesOrMultiple {
            qrOptions.packageAsCleanZip = true
        }
        runPreparedAction(overrideOptions: qrOptions) { payload in
            if let singleFile = payload.urls.first {
                wifiServer.startSharing(fileURL: singleFile, ownedStagingURL: payload.stagingRoot)
            }
        }
    }
}
