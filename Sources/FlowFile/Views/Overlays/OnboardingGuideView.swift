import AppKit
import SwiftUI

struct InteractiveTourOverlay: View {
    @Bindable var workspace: WorkspaceState
    let anchors: [TourTargetID: Anchor<CGRect>]

    private var tour: InteractiveTourState {
        workspace.tour
    }

    var body: some View {
        GeometryReader { proxy in
            let winSize = proxy.size
            ZStack(alignment: .topLeading) {
                if tour.currentStep == .welcomeSetup {
                    Color.black.opacity(0.48)
                        .ignoresSafeArea()
                        .onTapGesture {}

                    welcomeSetupCard
                        .position(x: winSize.width / 2, y: winSize.height / 2)
                } else if let targetID = tour.currentStep.targetID,
                          let anchor = anchors[targetID] {
                    let rawRect = proxy[anchor]
                    let hole = clampedSpotlightRect(rawRect.insetBy(dx: -6, dy: -6), in: winSize)

                    // 4-piece dimmed surround: lets real mouse clicks pass straight through the highlighted hole!
                    spotlightMaskSurround(hole: hole, in: winSize)

                    // Clean spotlight ring around target (hit-testing off)
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 2.5)
                        .shadow(color: Color.accentColor.opacity(0.55), radius: 8)
                        .frame(width: hole.width, height: hole.height)
                        .position(x: hole.midX, y: hole.midY)
                        .allowsHitTesting(false)

                    // Coach-Mark Card with integrated Practice Mode status bar — guaranteed never to cover the target!
                    let cardPos = computeCoachCardCenter(for: tour.currentStep, hole: hole, in: winSize)
                    coachMarkCard(for: tour.currentStep)
                        .position(x: cardPos.x, y: cardPos.y)
                } else {
                    Color.black.opacity(0.40)
                        .ignoresSafeArea()

                    coachMarkCard(for: tour.currentStep)
                        .position(x: winSize.width / 2, y: winSize.height / 2)
                }
            }
        }
        .onAppear {
            workspace.refreshPermissionsStatus()
        }
    }

    // MARK: - Step 0: Welcome, Language & Permissions Card

    private var welcomeSetupCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Integrated Practice Mode top strip
            HStack(spacing: 7) {
                LucideIcon(kind: .shieldCheck, size: 15)
                    .foregroundStyle(.green)
                Text(workspace.tr(
                    "Øvingsmodus – ingen ekte filer flyttes eller endres",
                    "Practice Mode – no real files are moved or changed"
                ))
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)

                Spacer()

                Button {
                    workspace.finishInteractiveTour()
                } label: {
                    LucideIcon(kind: .x, size: 14)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 12) {
                LucideIcon(kind: .sparkles, size: 28, lineWidth: 1.9)
                    .foregroundStyle(Color.accentColor)

                VStack(alignment: .leading, spacing: 3) {
                    Text(workspace.tr("Velkommen til FlowFile", "Welcome to FlowFile"))
                        .font(.system(size: 20, weight: .bold))
                    Text(workspace.tr(
                        "Bli kjent med programmet gjennom en kort, interaktiv rundtur direkte i grensesnittet.",
                        "Explore the app through a short, interactive walkthrough directly in the interface."
                    ))
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                }
            }

            Divider()

            // Language choice
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    LucideIcon(kind: .globe, size: 15)
                        .foregroundStyle(Color.accentColor)
                    Text(workspace.tr("1. Språk / Language", "1. Language / Språk"))
                        .font(.system(size: 13, weight: .semibold))
                }

                Picker("", selection: $workspace.appLanguage) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.displayName(in: workspace.appLanguage)).tag(lang)
                    }
                }
                .pickerStyle(.segmented)
            }

            // Optional permissions helper
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    LucideIcon(kind: .shieldCheck, size: 15)
                        .foregroundStyle(workspace.hasFullDiskAccess ? .green : Color.accentColor)
                    Text(workspace.tr("2. Valgfritt: Full disktilgang", "2. Optional: Full Disk Access"))
                        .font(.system(size: 13, weight: .semibold))
                }

                HStack(spacing: 9) {
                    LucideIcon(kind: workspace.hasFullDiskAccess ? .checkCircle : .settings, size: 16)
                        .foregroundStyle(workspace.hasFullDiskAccess ? .green : .secondary)

                    Text(workspace.hasFullDiskAccess
                         ? workspace.tr("Full disktilgang er aktivert på denne Macen.", "Full Disk Access is active on this Mac.")
                         : workspace.tr("Helt valgfritt. Uten dette spør macOS bare om tillatelse enkeltvis første gang du åpner Skrivebord, Dokumenter eller Nedlastinger.", "Completely optional. Without this, macOS simply asks permission per folder when you first open Desktop, Documents, or Downloads."))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    Spacer()
                }

                HStack(spacing: 8) {
                    Button {
                        PermissionsService.openFullDiskAccessSettings()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            PermissionsService.revealRunningAppInFinder()
                        }
                    } label: {
                        HStack(spacing: 6) {
                            LucideIcon(kind: .settings, size: 13)
                            Text(workspace.tr("Åpne Systeminnstillinger (valgfritt)", "Open System Settings (optional)"))
                                .font(.system(size: 12))
                        }
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)

                    Button {
                        workspace.refreshPermissionsStatus()
                    } label: {
                        HStack(spacing: 5) {
                            LucideIcon(kind: .refreshCw, size: 13)
                            Text(workspace.tr("Sjekk status", "Re-check"))
                                .font(.system(size: 12))
                        }
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                }

                if !workspace.hasFullDiskAccess {
                    Text(workspace.tr(
                        "Tips: Slå på bryteren for FlowFile i listen som åpnes – eller dra FlowFile.app rett over i listen én gang, så slipper du at macOS spør om lov på hver mappe.",
                        "Tip: Toggle on FlowFile in the list that opens – or drag FlowFile.app straight into the list once, and macOS will never prompt per folder again."
                    ))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )

            // Optional Default File Browser choice
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    LucideIcon(kind: workspace.isDefaultFileBrowser ? .checkCircle : .columns2, size: 15)
                        .foregroundStyle(workspace.isDefaultFileBrowser ? .green : Color.accentColor)
                    Text(workspace.tr(
                        "3. Valgfritt: Standard filutforsker i macOS",
                        "3. Optional: Default File Browser in macOS"
                    ))
                    .font(.system(size: 13, weight: .semibold))
                }

                Text(workspace.isDefaultFileBrowser
                     ? workspace.tr(
                         "FlowFile er satt som standard for mapper og «Vis i Finder». Du kan bytte tilbake til Finder når som helst.",
                         "FlowFile is set as the default for folders and 'Show in Finder'. You can switch back to Finder anytime."
                     )
                     : workspace.tr(
                         "Vil du at «Vis i Finder» fra nettlesere og Spotlight skal åpne i FlowFile i stedet for Finder? Kan endres når som helst under Innstillinger (⌘,).",
                         "Want 'Show in Finder' from browsers and Spotlight to open in FlowFile instead of Finder? You can change this anytime in Settings (⌘,)."
                     ))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    if !workspace.isDefaultFileBrowser {
                        Button {
                            Task { await workspace.setAsDefaultFileBrowser() }
                        } label: {
                            HStack(spacing: 6) {
                                LucideIcon(kind: .sparkles, size: 13)
                                Text(workspace.tr("Sett FlowFile som standard (valgfritt)", "Set FlowFile as Default (optional)"))
                                    .font(.system(size: 12))
                            }
                        }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                        .disabled(workspace.isUpdatingDefaultBrowser)
                    } else {
                        Button {
                            Task { await workspace.resetDefaultFileBrowserToFinder() }
                        } label: {
                            HStack(spacing: 6) {
                                LucideIcon(kind: .refreshCw, size: 13)
                                Text(workspace.tr("Tilbakestill til macOS Finder", "Restore macOS Finder"))
                                    .font(.system(size: 12))
                            }
                        }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                        .disabled(workspace.isUpdatingDefaultBrowser)
                    }
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )

            HStack {
                Button(workspace.tr("Hopp over omvisning", "Skip Tour")) {
                    workspace.finishInteractiveTour()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

                Spacer()

                Button {
                    workspace.goToTourStep(.copyPath)
                } label: {
                    HStack(spacing: 6) {
                        Text(workspace.tr("Start interaktiv rundtur", "Start Interactive Tour"))
                        LucideIcon(kind: .arrowRight, size: 14)
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 540)
        .liquidGlassPanel(cornerRadius: 16)
        .shadow(color: .black.opacity(0.30), radius: 22, y: 8)
    }

    // MARK: - Interactive Coach-Mark Card (Steps 1–7)

    @ViewBuilder
    private func coachMarkCard(for step: TourStep) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            // Compact Practice Mode header INSIDE the card — never floating over toolbar controls!
            HStack(spacing: 6) {
                LucideIcon(kind: .shieldCheck, size: 13.5)
                    .foregroundStyle(.green)

                Text(workspace.tr("Øvingsmodus (rører ingen filer)", "Practice Mode (safe sandbox)"))
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                Text("\(step.rawValue)/\(TourStep.allCases.count - 1)")
                    .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.accentColor)

                Button {
                    workspace.finishInteractiveTour()
                } label: {
                    HStack(spacing: 3) {
                        Text(workspace.tr("Avslutt", "Exit"))
                            .font(.system(size: 10.5, weight: .medium))
                        LucideIcon(kind: .x, size: 11.5)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Divider()

            switch step {
            case .copyPath:
                coachHeader(
                    icon: .copy,
                    title: workspace.tr("Kopier full mappesti på ett klikk", "Copy Full Folder Path in One Click")
                )
                Text(workspace.tr(
                    "Klikk på den opplyste «Kopier sti»-knappen i adresselinjen. Du kan også klikke i adresselinjen eller trykke ⌘L når som helst for å lime inn en sti direkte.",
                    "Click the highlighted 'Copy Path' button in the address bar. You can also click the address bar or press ⌘L anytime to paste a path directly."
                ))
                .font(.system(size: 12))

                actionHintPill(
                    done: tour.didClickCopyPath,
                    promptText: workspace.tr("Klikk på «Kopier sti» i det opplyste feltet for å prøve", "Click 'Copy Path' in the highlighted area to try it"),
                    doneText: workspace.tr("Stien er kopiert til utklippstavlen", "Path copied to clipboard")
                )

            case .sidebarAndCloud:
                coachHeader(
                    icon: .cloud,
                    title: workspace.tr("Sidepanel, Skylagring & Status-symboler", "Sidebar, Cloud Drives & Status Icons")
                )
                Text(workspace.tr(
                    "Til venstre finner du Hurtigtilgang, skytjenester (OneDrive, Dropbox, Google Drive, Box og iCloud), disker med plassmåler og ekte mappetre.",
                    "On the left you have Quick Access, cloud drives (OneDrive, Dropbox, Google Drive, Box & iCloud), disks with usage meters, and a real folder tree."
                ))
                .font(.system(size: 12))

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        LucideIcon(kind: .checkCircle, size: 15)
                            .foregroundStyle(.green)
                        Text(workspace.tr("Grønt sjekk-ikon = lagret lokalt på Macen", "Green check icon = saved locally on Mac"))
                            .font(.system(size: 11.5, weight: .medium))
                    }
                    HStack(spacing: 8) {
                        LucideIcon(kind: .cloudDownload, size: 15)
                            .foregroundStyle(.blue)
                        Text(workspace.tr("Blått sky-ikon = kun i skyen (sparer plass)", "Blue cloud icon = online-only (saves space)"))
                            .font(.system(size: 11.5, weight: .medium))
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))

            case .dualPaneToggle:
                coachHeader(
                    icon: .columns2,
                    title: workspace.tr("Bytt mellom 1-Panel og Dual-Pane (⌘D)", "Switch Between 1-Pane and Dual-Pane (⌘D)")
                )
                Text(workspace.tr(
                    "Bruk ett ryddig panel til vanlig som i Windows Explorer, og del vinduet i to side-om-side paneler som i Total Commander når du vil flytte og organisere mapper.",
                    "Use 1 clean pane like Windows Explorer for everyday work, and split into 2 side-by-side panes like Total Commander whenever organizing folders."
                ))
                .font(.system(size: 12))

                actionHintPill(
                    done: workspace.isDualPane,
                    promptText: workspace.tr("Klikk på den opplyste «1-Panel»-knappen øverst til høyre", "Click the highlighted '1-Pane' button in the top-right"),
                    doneText: workspace.tr("To-panel aktivert", "Dual-Pane activated")
                )

            case .folderCompareStart:
                coachHeader(
                    icon: .compareArrows,
                    title: workspace.tr("Sammenlign to mapper (⇧⌘K)", "Compare Two Folders (⇧⌘K)")
                )
                Text(workspace.tr(
                    "Lurer du på hvilke filer som mangler eller er nyere i den ene mappen? Klikk på Sammenlign-knappen for å vise tydelige NY / NYERE-merker.",
                    "Wondering which files are missing or newer between left and right? Click the Compare button to highlight NEW / NEWER differences."
                ))
                .font(.system(size: 12))

                actionHintPill(
                    done: workspace.isCompareActive,
                    promptText: workspace.tr("Klikk på den opplyste Sammenlign-knappen", "Click the highlighted Compare button"),
                    doneText: workspace.tr("Sammenligning startet", "Comparison started")
                )

            case .folderCompareExit:
                coachHeader(
                    icon: .xCircle,
                    title: workspace.tr("Slik går du ut av sammenligningen", "How to Exit Folder Comparison")
                )
                Text(workspace.tr(
                    "Se de simulerte NY / NYERE-merkene i listen. For å avslutte sammenligningen klikker du «Avslutt sammenligning» i den opplyste linjen, trykker ⇧⌘K på nytt, eller trykker Esc.",
                    "Notice the simulated NEW / NEWER badges. To exit comparison anytime, click 'Exit Comparison' in the highlighted bar, press ⇧⌘K again, or press Esc."
                ))
                .font(.system(size: 12))

                actionHintPill(
                    done: !workspace.isCompareActive,
                    promptText: workspace.tr("Klikk på «Avslutt sammenligning» i det opplyste feltet", "Click 'Exit Comparison' in the highlighted bar"),
                    doneText: workspace.tr("Sammenligning avsluttet", "Comparison closed")
                )

            case .dropShelfPractice:
                coachHeader(
                    icon: .inbox,
                    title: workspace.tr("Prøv Drop-hyllen i praksis (⌘J) – med demofiler", "Try the Drop Shelf Hands-On (⌘J) – with Demo Files")
                )
                Text(workspace.tr(
                    "Samle filer fra flere ulike mapper i én kurv før du legger dem i mål-mappen:\n1. Klikk «Legg demofiler i kurven» i panelet til høyre.\n2. Klikk «Flytt hit (Demo)» for å teste køen uten å røre ekte filer.",
                    "Gather files from different folders into one basket before dropping them into your target folder:\n1. Click 'Load Demo Files' in the right panel.\n2. Click 'Move Here (Demo)' to test the queue without touching real files."
                ))
                .font(.system(size: 12))

                actionHintPill(
                    done: tour.demoTransferCompleted,
                    promptText: tour.demoShelfLoaded
                        ? workspace.tr("Klikk nå «Flytt hit (Demo)» i Drop-hyllen til høyre", "Now click 'Move Here (Demo)' in the Drop Shelf")
                        : workspace.tr("Klikk «Legg demofiler i kurven» i Drop-hyllen til høyre", "Click 'Load Demo Files' in the Drop Shelf"),
                    doneText: workspace.tr("Simulering fullført – så enkelt samler du filer", "Simulation complete – gathering files is that easy")
                )

            case .smartShareFinish:
                coachHeader(
                    icon: .share,
                    title: workspace.tr("Smart Delingssenter (Del / ⇧⌘S)", "Smart Share Hub (Share / ⇧⌘S)")
                )
                Text(workspace.tr(
                    "Klikk på den opplyste «Del»-knappen for å se Windows-vennlig .zip (uten skjulte Mac-filer), passord-beskyttet .zip, .HEIC → .JPG, Outlook/Teams og lokal Wi-Fi QR-deling.",
                    "Click the highlighted 'Share' button to preview Windows-clean .zip packing, password .zip, .HEIC → .JPG conversion, Outlook/Teams, and local Wi-Fi QR sharing."
                ))
                .font(.system(size: 12))

                actionHintPill(
                    done: tour.didPreviewShareHub,
                    promptText: workspace.tr("Klikk på «Del» øverst for å titte inn (eller fullfør under)", "Click 'Share' above to take a peek (or finish below)"),
                    doneText: workspace.tr("Du har sett Smart Delingssenter", "You previewed the Smart Share Hub")
                )

            case .welcomeSetup:
                EmptyView()
            }

            Divider()

            // Coach card navigation buttons
            HStack {
                if let prev = TourStep(rawValue: step.rawValue - 1) {
                    Button {
                        workspace.goToTourStep(prev)
                    } label: {
                        HStack(spacing: 5) {
                            LucideIcon(kind: .arrowLeft, size: 12.5)
                            Text(workspace.tr("Tilbake", "Back"))
                        }
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                }

                Spacer()

                if let next = TourStep(rawValue: step.rawValue + 1) {
                    Button {
                        workspace.goToTourStep(next)
                    } label: {
                        HStack(spacing: 5) {
                            Text(workspace.tr("Neste steg", "Next Step"))
                            LucideIcon(kind: .arrowRight, size: 12.5)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                } else {
                    Button {
                        workspace.finishInteractiveTour()
                    } label: {
                        HStack(spacing: 5) {
                            LucideIcon(kind: .checkCircle, size: 13)
                            Text(workspace.tr("Fullfør omvisning", "Finish Tour"))
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
        }
        .padding(16)
        .frame(width: 392)
        .liquidGlassPanel(cornerRadius: 15)
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 1.5)
        )
        .shadow(color: .black.opacity(0.32), radius: 18, y: 8)
    }

    @ViewBuilder
    private func coachHeader(icon: LucideIconKind, title: String) -> some View {
        HStack(spacing: 8) {
            LucideIcon(kind: icon, size: 18, lineWidth: 1.9)
                .foregroundStyle(Color.accentColor)
            Text(title)
                .font(.system(size: 14, weight: .bold))
        }
    }

    @ViewBuilder
    private func actionHintPill(done: Bool, promptText: String, doneText: String) -> some View {
        HStack(spacing: 8) {
            LucideIcon(kind: done ? .checkCircle : .mousePointerClick, size: 15, lineWidth: 1.9)
                .foregroundStyle(done ? .green : Color.accentColor)

            Text(done ? doneText : promptText)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(done ? .green : Color.accentColor)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill((done ? Color.green : Color.accentColor).opacity(0.12))
        )
    }

    // MARK: - 4-Piece Click-Blocking Dimmed Surround Around the Spotlight Hole

    @ViewBuilder
    private func spotlightMaskSurround(hole: CGRect, in size: CGSize) -> some View {
        let dim = Color.black.opacity(0.46)

        if hole.minY > 0 {
            dim
                .frame(width: size.width, height: hole.minY)
                .position(x: size.width / 2, y: hole.minY / 2)
                .contentShape(Rectangle())
                .onTapGesture {}
        }

        if hole.maxY < size.height {
            let h = size.height - hole.maxY
            dim
                .frame(width: size.width, height: h)
                .position(x: size.width / 2, y: hole.maxY + h / 2)
                .contentShape(Rectangle())
                .onTapGesture {}
        }

        if hole.minX > 0 {
            dim
                .frame(width: hole.minX, height: hole.height)
                .position(x: hole.minX / 2, y: hole.midY)
                .contentShape(Rectangle())
                .onTapGesture {}
        }

        if hole.maxX < size.width {
            let w = size.width - hole.maxX
            dim
                .frame(width: w, height: hole.height)
                .position(x: hole.maxX + w / 2, y: hole.midY)
                .contentShape(Rectangle())
                .onTapGesture {}
        }
    }

    private func clampedSpotlightRect(_ rect: CGRect, in size: CGSize) -> CGRect {
        let minX = max(2, rect.minX)
        let minY = max(2, rect.minY)
        let maxX = min(size.width - 2, rect.maxX)
        let maxY = min(size.height - 2, rect.maxY)
        return CGRect(x: minX, y: minY, width: max(24, maxX - minX), height: max(24, maxY - minY))
    }

    /// Computes a card center guaranteed never to overlap the highlighted spotlight `hole` or clip off-screen.
    private func computeCoachCardCenter(for step: TourStep, hole: CGRect, in size: CGSize) -> CGPoint {
        let cardW: CGFloat = 392
        let cardH: CGFloat = 290
        let gap: CGFloat = 20

        func clampPoint(_ pt: CGPoint) -> CGPoint {
            CGPoint(
                x: max(cardW / 2 + 14, min(size.width - cardW / 2 - 14, pt.x)),
                y: max(cardH / 2 + 14, min(size.height - cardH / 2 - 14, pt.y))
            )
        }

        switch step {
        case .sidebarAndCloud:
            return clampPoint(CGPoint(x: hole.maxX + cardW / 2 + gap, y: hole.midY))
        case .dropShelfPractice:
            return clampPoint(CGPoint(x: hole.minX - cardW / 2 - gap, y: hole.midY))
        default:
            // Prefer placing clearly below toolbar/banner controls; if near bottom, place above
            let belowY = hole.maxY + cardH / 2 + gap
            if belowY + cardH / 2 <= size.height - 12 {
                return clampPoint(CGPoint(x: hole.midX, y: belowY))
            } else {
                let aboveY = hole.minY - cardH / 2 - gap
                return clampPoint(CGPoint(x: hole.midX, y: aboveY))
            }
        }
    }
}
