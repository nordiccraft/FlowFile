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
    @State private var isCreatingCloudLink: Bool = false
    @State private var feedbackBanner: String? = nil
    @State private var warningBanner: String? = nil
    @State private var createdShareURL: URL? = nil

    // Cloud link options
    @State private var oneDriveOrgOnly: Bool = true
    @State private var googleAnyoneCanView: Bool = true

    // Cached system lookups (avoid querying LaunchServices on every SwiftUI body redraw)
    @State private var defaultEmailName: String = ""
    @State private var outlookInstalled: Bool = false
    @State private var defaultIsOutlook: Bool = false
    @State private var teamsInstalled: Bool = false
    @State private var slackInstalled: Bool = false
    @State private var airDropIcon: NSImage? = nil
    @State private var messagesIcon: NSImage? = nil
    @State private var mailIcon: NSImage? = nil

    // Native macOS share picker anchor
    @State private var pickerAnchorView: NSView? = nil

    // Cloud upload confirmation (local FileProvider copy fallback)
    @State private var pendingCloudUploadAccount: CloudAccountItem? = nil

    // Live countdown ticker for active QR share
    @State private var nowTick: Date = Date()
    private let countdownTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    @Environment(\.dismiss) private var dismiss

    private var wifiServer: LocalWiFiShareServer {
        workspace.wifiShareServer
    }

    private var oauth: CloudShareOAuthService {
        CloudShareOAuthService.shared
    }

    private var hasDirectoriesOrPackages: Bool {
        targetItems.contains(where: { $0.isNavigableFolder || $0.isDirectory || $0.isPackage })
    }

    private var hasDirectoriesOrMultiple: Bool {
        targetItems.count > 1 || hasDirectoriesOrPackages
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

    private var primaryDraggableURL: URL? {
        cachedPayload?.urls.first ?? targetItems.first?.navigationTargetURL
    }

    private var isBusy: Bool {
        isPreparing || isCreatingCloudLink
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                headerSection
                bannersSection
                preparationSection
                directChannelsSection
                cloudLinksSection
                wifiQRSection
                footerSection
            }
            .padding(18)
        }
        .frame(width: 760)
        .frame(maxHeight: 780)
        .onAppear {
            defaultEmailName = ShareHubService.defaultEmailAppName()
            outlookInstalled = ShareHubService.installedOutlookURL() != nil
            defaultIsOutlook = ShareHubService.isDefaultEmailAppOutlook()
            teamsInstalled = ShareHubService.installedTeamsURL() != nil
            slackInstalled = ShareHubService.installedSlackURL() != nil
            airDropIcon = ShareHubService.systemServiceIcon(named: .sendViaAirDrop)
            messagesIcon = ShareHubService.systemServiceIcon(named: .composeMessage)
            mailIcon = ShareHubService.systemServiceIcon(named: .composeEmail)
            wifiServer.refreshInterfaces()

            // Invalidate cached staging payload if the Wi-Fi server stops and deletes its owned staging directory
            wifiServer.onDidStop = {
                cachedPayload = nil
                cachedOptions = nil
            }

            // Only auto-enable ZIP for folders/packages — do NOT force-zip multiple regular files for AirDrop/Messages!
            if hasDirectoriesOrPackages {
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
        .onDisappear {
            wifiServer.onDidStop = nil
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

        if let shareURL = createdShareURL {
            HStack(spacing: 10) {
                Image(systemName: "link.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(workspace.tr("Delingslenke klar og kopiert til utklippstavlen:", "Share link ready and copied to clipboard:"))
                        .font(.system(size: 11, weight: .semibold))
                    Text(shareURL.absoluteString)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button(workspace.tr("Kopier", "Copy")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(shareURL.absoluteString, forType: .string)
                    feedbackBanner = workspace.tr("Delingslenke kopiert!", "Share link copied!")
                }
                .buttonStyle(.glass)
                .controlSize(.small)

                Button(workspace.tr("Åpne", "Open")) {
                    NSWorkspace.shared.open(shareURL)
                }
                .buttonStyle(.glass)
                .controlSize(.small)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.green.opacity(0.12)))
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
                Text(workspace.tr("2. SEND DIREKTE (E-POST, OUTLOOK, AIRDROP, TEAMS & SLACK)", "2. SEND DIRECTLY (MAIL, OUTLOOK, AIRDROP, TEAMS & SLACK)"))
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(.secondary)
                Spacer()
                if exceedsTypicalEmailLimit {
                    Label(
                        workspace.tr(
                            "Over 20 MB – bruk skylenke eller Wi-Fi QR i stedet for e-post",
                            "Over 20 MB – use a cloud link or Wi-Fi QR instead of email"
                        ),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.orange)
                }
            }

            HStack(spacing: 8) {
                // Always show dedicated Outlook button whenever Outlook is installed (even if Outlook is default mail app!)
                if outlookInstalled {
                    shareCardButton(
                        title: "Outlook",
                        subtitle: workspace.tr("Nytt utkast", "New draft"),
                        sfSymbol: "envelope.badge.fill",
                        nsImage: nil
                    ) {
                        runPreparedAction { payload in
                            _ = ShareHubService.shareViaOutlook(payload.urls) { result in
                                handleDeliveryResult(result, channelName: "Microsoft Outlook", dismissOnSuccess: true)
                            }
                        }
                    }
                }

                // Show default mail client when it's NOT Outlook (e.g. Apple Mail, Spark, Thunderbird)
                if !defaultIsOutlook {
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

                // Native macOS Share Menu (Notes, Reminders, Freeform & system share extensions — NOT OneDrive/Google Drive links)
                shareCardButton(
                    title: workspace.tr("macOS Del…", "macOS Share…"),
                    subtitle: workspace.tr("Notater m.fl.", "Notes & extensions"),
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
            }
            .disabled(isBusy)

            // Reliable Teams / Slack handoff bar: draggable file chip + bring app to front + clipboard fallback
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "hand.draw.fill")
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(workspace.tr("Dra til Teams / Slack", "Drag to Teams / Slack"))
                            .font(.system(size: 11.5, weight: .semibold))
                        Text(primaryDraggableURL?.lastPathComponent ?? selectionSummary)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.12)))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .foregroundStyle(Color.accentColor.opacity(0.45))
                )
                .onDrag {
                    if let url = primaryDraggableURL {
                        return NSItemProvider(contentsOf: url) ?? NSItemProvider()
                    }
                    return NSItemProvider()
                }
                .help(workspace.tr(
                    "Dra denne brikken rett inn i en chat i Microsoft Teams eller Slack for 100 % pålitelig filopplasting.",
                    "Drag this chip directly into a Microsoft Teams or Slack chat for reliable file upload."
                ))

                Spacer()

                if teamsInstalled {
                    Button {
                        if !ShareHubService.bringChatAppToFront(bundleID: "com.microsoft.teams2") {
                            _ = ShareHubService.bringChatAppToFront(bundleID: "com.microsoft.teams")
                        }
                    } label: {
                        Label(workspace.tr("Hent Teams til front", "Bring Teams to Front"), systemImage: "bubble.left.and.bubble.right.fill")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                }

                if slackInstalled {
                    Button {
                        _ = ShareHubService.bringChatAppToFront(bundleID: "com.tinyspeck.slackmacgap")
                    } label: {
                        Label(workspace.tr("Hent Slack til front", "Bring Slack to Front"), systemImage: "number")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                }

                Button {
                    runPreparedAction { payload in
                        ShareHubService.copyPreparedFilesForChatApps(payload.urls)
                        warningBanner = nil
                        feedbackBanner = workspace.tr(
                            "Fil kopiert – trykk ⌘V i chat (eller dra brikken til venstre inn i Teams/Slack).",
                            "File copied – press ⌘V in chat (or drag the chip on the left into Teams/Slack)."
                        )
                    }
                } label: {
                    Label(workspace.tr("Kopier (⌘V)", "Copy (⌘V)"), systemImage: "doc.on.clipboard")
                        .font(.system(size: 11))
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .disabled(isBusy)
            }
            .padding(8)
            .background(Color.primary.opacity(0.035))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
    }

    private var cloudLinksSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(workspace.tr(
                    "3. LAG EKTE SKYLENKE (ONEDRIVE, TEAMS & GOOGLE DRIVE)",
                    "3. CREATE REAL CLOUD SHARE LINK (ONEDRIVE, TEAMS & GOOGLE DRIVE)"
                ))
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(.secondary)
                Spacer()
                if isCreatingCloudLink {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.mini)
                        Text(workspace.tr("Oppretter delingslenke…", "Creating share link…"))
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // 3A. OneDrive & Teams 1-click OAuth link bar
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "cloud.fill")
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("OneDrive & Microsoft Teams")
                            .font(.system(size: 12, weight: .semibold))
                        if oauth.isMicrosoftSignedIn {
                            Text(oauth.microsoftAccountEmail ?? workspace.tr("Tilkoblet Microsoft-konto", "Microsoft account connected"))
                                .font(.system(size: 10.5))
                                .foregroundStyle(.green)
                        } else if oauth.microsoftClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text(workspace.tr(
                                "Legg inn Microsoft Client ID i Innstillinger for 1-klikk OneDrive- og Teams-lenker.",
                                "Add Microsoft Client ID in Settings for 1-click OneDrive & Teams links."
                            ))
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                        } else {
                            Text(workspace.tr("Ikke logget inn på Microsoft ennå", "Not signed in to Microsoft yet"))
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    if oauth.isMicrosoftSignedIn {
                        Picker("", selection: $oneDriveOrgOnly) {
                            Text(workspace.tr("Kun org.", "Org only")).tag(true)
                            Text(workspace.tr("Alle med lenke", "Anyone")).tag(false)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .controlSize(.small)
                        .frame(width: 175)

                        Button(workspace.tr("Lag OneDrive-lenke", "Create OneDrive Link")) {
                            createOneDriveLink(openInTeams: false)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(isBusy)

                        Button(workspace.tr("Del lenke i Teams", "Share Link in Teams")) {
                            createOneDriveLink(openInTeams: true)
                        }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                        .disabled(isBusy)
                    } else if oauth.microsoftClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button(workspace.tr("Åpne Innstillinger", "Open Settings")) {
                            dismiss()
                            workspace.isSettingsVisible = true
                        }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                    } else {
                        Button(workspace.tr("Logg inn med Microsoft", "Sign in with Microsoft")) {
                            signInMicrosoftInline()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(isBusy)
                    }
                }
            }
            .padding(10)
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

            // 3B. Google Drive 1-click OAuth link bar
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "externaldrive.connected.to.line.below.fill")
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Google Drive")
                            .font(.system(size: 12, weight: .semibold))
                        if oauth.isGoogleSignedIn {
                            Text(oauth.googleAccountEmail ?? workspace.tr("Tilkoblet Google-konto", "Google account connected"))
                                .font(.system(size: 10.5))
                                .foregroundStyle(.green)
                        } else if oauth.googleClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text(workspace.tr(
                                "Legg inn Google Client ID i Innstillinger for 1-klikk Google Drive-lenker.",
                                "Add Google Client ID in Settings for 1-click Google Drive links."
                            ))
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                        } else {
                            Text(workspace.tr("Ikke logget inn på Google ennå", "Not signed in to Google yet"))
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    if oauth.isGoogleSignedIn {
                        Toggle(workspace.tr("Alle med lenke", "Anyone with link"), isOn: $googleAnyoneCanView)
                            .toggleStyle(.checkbox)
                            .font(.system(size: 11))

                        Button(workspace.tr("Last opp & lag Google Drive-lenke", "Upload & Create Google Drive Link")) {
                            createGoogleDriveLink()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(isBusy)
                    } else if oauth.googleClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button(workspace.tr("Åpne Innstillinger", "Open Settings")) {
                            dismiss()
                            workspace.isSettingsVisible = true
                        }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                    } else {
                        Button(workspace.tr("Logg inn med Google", "Sign in with Google")) {
                            signInGoogleInline()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(isBusy)
                    }
                }
            }
            .padding(10)
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

            // 3C. Honest local FileProvider / Finder fallback (no OAuth required)
            if let activeCloud = sharedCloudAccountForAllItems {
                HStack(spacing: 10) {
                    Image(systemName: activeCloud.provider.systemImage)
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(workspace.tr(
                            "Ligger lokalt i \(activeCloud.fullDisplayName)",
                            "Stored locally in \(activeCloud.fullDisplayName)"
                        ))
                        .font(.system(size: 11.5, weight: .medium))
                        Text(workspace.tr(
                            "Uten OAuth-pålogging må lokal sky-deling gjøres via høyreklikk i Finder (macOS lar ikke tredjepartsapper åpne sky-utvidelsen direkte).",
                            "Without OAuth sign-in, local cloud sharing requires right-clicking in Finder (macOS restricts cloud extensions to Finder)."
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
                    .controlSize(.small)
                }
                .padding(9)
                .background(Color.accentColor.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            } else if !workspace.cloudAccounts.isEmpty {
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
                                        Text(workspace.tr("Kopier til \(account.fullDisplayName)", "Copy to \(account.fullDisplayName)"))
                                            .font(.system(size: 11.5, weight: .medium))
                                        Text(workspace.tr("Lokal mappe (privat)", "Local folder (private)"))
                                            .font(.system(size: 9.5))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                            }
                            .buttonStyle(.glass)
                            .disabled(isBusy)
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
                        .disabled(isBusy)
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
            } else if isCreatingCloudLink {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(workspace.tr("Laster opp og oppretter delingslenke…", "Uploading and creating share link…"))
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

    private func signInMicrosoftInline() {
        isCreatingCloudLink = true
        warningBanner = nil
        feedbackBanner = nil
        Task {
            do {
                try await oauth.signInMicrosoft()
                await MainActor.run {
                    isCreatingCloudLink = false
                    feedbackBanner = workspace.tr("Logget inn på Microsoft OneDrive!", "Signed in to Microsoft OneDrive!")
                }
            } catch {
                await MainActor.run {
                    isCreatingCloudLink = false
                    warningBanner = error.localizedDescription
                }
            }
        }
    }

    private func signInGoogleInline() {
        isCreatingCloudLink = true
        warningBanner = nil
        feedbackBanner = nil
        Task {
            do {
                try await oauth.signInGoogle()
                await MainActor.run {
                    isCreatingCloudLink = false
                    feedbackBanner = workspace.tr("Logget inn på Google Drive!", "Signed in to Google Drive!")
                }
            } catch {
                await MainActor.run {
                    isCreatingCloudLink = false
                    warningBanner = error.localizedDescription
                }
            }
        }
    }

    private func createOneDriveLink(openInTeams: Bool) {
        if workspace.tour.isSandboxActive {
            feedbackBanner = workspace.tr(
                "Øvingsmodus: OneDrive-delingslenke simulert!",
                "Practice Mode: OneDrive share link simulated!"
            )
            return
        }
        var linkOpts = options
        if hasDirectoriesOrMultiple {
            linkOpts.packageAsCleanZip = true
        }
        runPreparedAction(overrideOptions: linkOpts) { payload in
            guard let fileURL = payload.urls.first else { return }
            isCreatingCloudLink = true
            warningBanner = nil
            feedbackBanner = nil
            Task {
                do {
                    let shareURL = try await oauth.createOneDriveShareLink(
                        for: fileURL,
                        organizationOnly: oneDriveOrgOnly
                    )
                    await MainActor.run {
                        isCreatingCloudLink = false
                        createdShareURL = shareURL
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(shareURL.absoluteString, forType: .string)
                        if openInTeams {
                            CloudShareOAuthService.openTeamsChat(
                                withShareURL: shareURL,
                                fileName: fileURL.lastPathComponent
                            )
                            feedbackBanner = workspace.tr(
                                "OneDrive-lenke kopiert og åpnet i Microsoft Teams!",
                                "OneDrive link copied and opened in Microsoft Teams!"
                            )
                        } else {
                            feedbackBanner = workspace.tr(
                                "OneDrive-lenke opprettet og kopiert til utklippstavlen!",
                                "OneDrive link created and copied to clipboard!"
                            )
                        }
                    }
                } catch {
                    await MainActor.run {
                        isCreatingCloudLink = false
                        warningBanner = error.localizedDescription
                    }
                }
            }
        }
    }

    private func createGoogleDriveLink() {
        if workspace.tour.isSandboxActive {
            feedbackBanner = workspace.tr(
                "Øvingsmodus: Google Drive-delingslenke simulert!",
                "Practice Mode: Google Drive share link simulated!"
            )
            return
        }
        var linkOpts = options
        if hasDirectoriesOrMultiple {
            linkOpts.packageAsCleanZip = true
        }
        runPreparedAction(overrideOptions: linkOpts) { payload in
            guard let fileURL = payload.urls.first else { return }
            isCreatingCloudLink = true
            warningBanner = nil
            feedbackBanner = nil
            Task {
                do {
                    let shareURL = try await oauth.uploadAndCreateGoogleDriveLink(
                        for: fileURL,
                        anyoneCanView: googleAnyoneCanView
                    )
                    await MainActor.run {
                        isCreatingCloudLink = false
                        createdShareURL = shareURL
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(shareURL.absoluteString, forType: .string)
                        feedbackBanner = workspace.tr(
                            "Google Drive-lenke opprettet og kopiert til utklippstavlen!",
                            "Google Drive link created and copied to clipboard!"
                        )
                    }
                } catch {
                    await MainActor.run {
                        isCreatingCloudLink = false
                        warningBanner = error.localizedDescription
                    }
                }
            }
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
