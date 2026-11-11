import SwiftUI
import UniformTypeIdentifiers

struct DropShelfAndQueueView: View {
    @Bindable var workspace: WorkspaceState
    @State private var isDropTargeted: Bool = false
    @State private var showBuiltInGuide: Bool = false

    private var queue: TransferQueueManager {
        workspace.transferQueue
    }

    private var isDemo: Bool {
        workspace.tour.isDropShelfDemoActive
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(
                    workspace.tr("Drop-hylle & Fil-kø", "Drop Shelf & Queue"),
                    systemImage: "tray.2.fill"
                )
                .font(.system(size: 13, weight: .semibold))

                Spacer()

                Button {
                    withAnimation(.snappy(duration: 0.18)) {
                        showBuiltInGuide.toggle()
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: showBuiltInGuide ? "questionmark.circle.fill" : "questionmark.circle")
                            .font(.system(size: 12))
                        Text(workspace.tr("Slik brukes den", "How it works"))
                            .font(.system(size: 10.5, weight: .medium))
                    }
                    .foregroundStyle(showBuiltInGuide ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .help(workspace.tr("Vis kort brukerveiledning for Drop-hyllen", "Show quick user guide for the Drop Shelf"))

                Button {
                    workspace.isDropShelfVisible = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            if showBuiltInGuide {
                builtInUserGuideCard
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if isDemo {
                demoDropShelfContent
            } else {
                realDropShelfContent
            }
        }
        .padding(12)
        .frame(width: 295)
        .liquidGlassPanel(cornerRadius: 14)
    }

    // MARK: - Built-in User Guide Card

    private var builtInUserGuideCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(workspace.tr("Brukerveiledning – 3 enkle steg:", "User Guide – 3 Simple Steps:"))
                .font(.system(size: 11.5, weight: .bold))
                .foregroundStyle(Color.accentColor)

            guideRow("1", workspace.tr(
                "Samle filer: Dra filer inn i kurven under, eller marker filer og trykk ⇧⌘D. Filene flyttes ikke ennå.",
                "Collect files: Drag files into the basket below, or select files and press ⇧⌘D. Nothing is moved yet."
            ))
            guideRow("2", workspace.tr(
                "Bla fritt videre til andre mapper og plukk med deg flere filer i samme kurv.",
                "Browse freely into other folders and add more files to the same basket."
            ))
            guideRow("3", workspace.tr(
                "Åpne mål-mappen du vil samle dem i, og klikk «Kopier hit» eller «Flytt hit».",
                "Open your target destination folder and click 'Copy Here' or 'Move Here'."
            ))
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.accentColor.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.28), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func guideRow(_ stepNum: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Text(stepNum)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .frame(width: 16, height: 16)
                .background(Circle().fill(Color.accentColor))

            Text(text)
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Safe Interactive Demo Mode (No real files touched!)

    private var demoDropShelfContent: some View {
        let tour = workspace.tour
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 5) {
                Image(systemName: "checkmark.shield.fill")
                    .foregroundStyle(.green)
                    .font(.system(size: 11))
                Text(workspace.tr("ØVINGSMODUS (DEMOFILER)", "PRACTICE MODE (DEMO FILES)"))
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.green)
            }

            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.accentColor.opacity(0.07))
                    )

                if tour.demoBasketFiles.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: tour.demoTransferCompleted ? "checkmark.circle.fill" : "tray.and.arrow.down")
                            .font(.system(size: 22))
                            .foregroundStyle(tour.demoTransferCompleted ? .green : .secondary)
                        Text(tour.demoTransferCompleted
                             ? workspace.tr("Demofilene ble samlet (ingen ekte filer rørt)!", "Demo files gathered (zero real files touched)!")
                             : workspace.tr("Kurven er tom – klikk knappen under for å legge inn 3 demofiler!", "Basket is empty – click the button below to add 3 demo files!"))
                            .font(.system(size: 11))
                            .foregroundStyle(tour.demoTransferCompleted ? .green : .secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(12)
                } else {
                    VStack(spacing: 5) {
                        ForEach(tour.demoBasketFiles) { demo in
                            HStack(spacing: 7) {
                                Image(systemName: demo.sfSymbol)
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 16)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(demo.name)
                                        .font(.system(size: 11.5, weight: .semibold))
                                    Text("\(demo.sourceFolder) • \(demo.sizeLabel)")
                                        .font(.system(size: 9.5))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("DEMO")
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(Color.green.opacity(0.18)))
                                    .foregroundStyle(.green)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Color.primary.opacity(0.05))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                    .padding(7)
                }
            }
            .frame(minHeight: 110)

            HStack(spacing: 6) {
                Button {
                    withAnimation(.snappy(duration: 0.2)) {
                        tour.loadDemoFilesIntoBasket()
                    }
                } label: {
                    Label(
                        workspace.tr("Legg demofiler i kurven", "Load Demo Files"),
                        systemImage: "plus.circle.fill"
                    )
                    .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.glass)

                Spacer()

                Button {
                    tour.runSimulatedTransfer()
                } label: {
                    Text(workspace.tr("Flytt hit (Demo)", "Move Here (Demo)"))
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(tour.demoBasketFiles.isEmpty || tour.demoTransferRunning)
            }

            Divider()

            // Simulated Transfer Queue
            VStack(alignment: .leading, spacing: 6) {
                Text(workspace.tr("OVERFØRINGSKØ (DEMO)", "TRANSFER QUEUE (DEMO)"))
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(.secondary)

                if tour.demoTransferRunning || tour.demoTransferCompleted {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(workspace.tr("Simulert flytting → \(workspace.activeTab.title)", "Simulated move → \(workspace.activeTab.title)"))
                                .font(.system(size: 11.5, weight: .semibold))
                                .lineLimit(1)
                            Spacer()
                            Text(tour.demoTransferCompleted ? "3/3" : "\(max(1, Int(tour.demoTransferProgress * 3)))/3")
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        ProgressView(value: tour.demoTransferProgress)
                            .tint(tour.demoTransferCompleted ? .green : Color.accentColor)
                            .controlSize(.mini)
                        Text(tour.demoTransferCompleted
                             ? workspace.tr("✓ Simulering ferdig (ingen ekte filer ble endret)", "✓ Simulation complete (no real files changed)")
                             : workspace.tr("Simulerer overføring...", "Simulating transfer..."))
                            .font(.system(size: 10.5))
                            .foregroundStyle(tour.demoTransferCompleted ? .green : .secondary)
                    }
                    .padding(8)
                    .background(Color.primary.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    Text(workspace.tr("Klar for simulert overføring.", "Ready for simulated transfer."))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Real Drop Shelf & Background Queue

    private var realDropShelfContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Section 1: Drop Shelf ("Midlertidig kurv")
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("\(workspace.tr("DROP-HYLLE", "DROP SHELF")) (\(queue.dropShelfItems.count))")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if !queue.dropShelfItems.isEmpty {
                        Button(workspace.tr("Tøm", "Clear")) {
                            queue.clearDropShelf()
                        }
                        .font(.system(size: 11))
                        .buttonStyle(.link)
                    }
                }

                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(
                            isDropTargeted ? Color.accentColor : Color.primary.opacity(0.18),
                            style: StrokeStyle(lineWidth: isDropTargeted ? 2 : 1, dash: [5, 4])
                        )
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(isDropTargeted ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.03))
                        )

                    if queue.dropShelfItems.isEmpty {
                        VStack(spacing: 5) {
                            Image(systemName: "tray.and.arrow.down")
                                .font(.system(size: 20))
                                .foregroundStyle(.secondary)
                            Text(workspace.tr(
                                "Slipp filer her fra ulike mapper, eller trykk ⇧⌘D på valgte filer.",
                                "Drop files here from different folders, or press ⇧⌘D on selected files."
                            ))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        }
                        .padding(14)
                    } else {
                        ScrollView {
                            VStack(spacing: 4) {
                                ForEach(queue.dropShelfItems, id: \.self) { url in
                                    HStack(spacing: 6) {
                                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                                            .resizable()
                                            .frame(width: 15, height: 15)
                                        VStack(alignment: .leading, spacing: 0) {
                                            Text(url.lastPathComponent)
                                                .font(.system(size: 11.5, weight: .medium))
                                                .lineLimit(1)
                                            Text(url.deletingLastPathComponent().lastPathComponent)
                                                .font(.system(size: 9.5))
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                        Spacer()
                                        Button {
                                            queue.removeFromDropShelf(url)
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .font(.system(size: 11))
                                                .foregroundStyle(.secondary)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.primary.opacity(0.04))
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                }
                            }
                            .padding(6)
                        }
                        .frame(maxHeight: 155)
                    }
                }
                .frame(minHeight: 86)
                .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
                    handleDropProviders(providers)
                }

                HStack(spacing: 6) {
                    Button {
                        workspace.addSelectedToDropShelf()
                    } label: {
                        Label(workspace.tr("Legg til valgte", "Add Selected"), systemImage: "plus")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.glass)

                    Spacer()

                    Button(workspace.tr("Kopier hit", "Copy Here")) {
                        workspace.transferDropShelfToActiveFolder(move: false)
                    }
                    .font(.system(size: 11, weight: .medium))
                    .buttonStyle(.glass)
                    .disabled(queue.dropShelfItems.isEmpty || workspace.activeTab.isInsideArchive)

                    Button(workspace.tr("Flytt hit", "Move Here")) {
                        workspace.transferDropShelfToActiveFolder(move: true)
                    }
                    .font(.system(size: 11, weight: .medium))
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(queue.dropShelfItems.isEmpty || workspace.activeTab.isInsideArchive)
                }
            }

            Divider()

            // Section 2: Background Transfer Queue
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("\(workspace.tr("OVERFØRINGSKØ", "TRANSFER QUEUE")) (\(queue.jobs.count))")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if !queue.jobs.isEmpty {
                        Button(workspace.tr("Fjern ferdige", "Clear Done")) {
                            queue.clearCompletedJobs()
                        }
                        .font(.system(size: 11))
                        .buttonStyle(.link)
                    }
                }

                if queue.jobs.isEmpty {
                    Text(workspace.tr("Ingen aktive eller nylige filoverføringer.", "No active or recent file transfers."))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(queue.jobs) { job in
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack {
                                        Text("\(job.operation.rawValue) → \(job.destinationDirectory.lastPathComponent)")
                                            .font(.system(size: 11.5, weight: .semibold))
                                            .lineLimit(1)
                                        Spacer()
                                        Text("\(job.completedItems)/\(job.totalItems)")
                                            .font(.system(size: 10.5, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                    }

                                    ProgressView(value: job.progress)
                                        .controlSize(.mini)

                                    HStack {
                                        Text(job.currentFileName.isEmpty ? job.status.label : job.currentFileName)
                                            .font(.system(size: 10.5))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)

                                        Spacer()

                                        if job.status == .running || job.status == .paused {
                                            Button {
                                                queue.togglePause(job)
                                            } label: {
                                                Image(systemName: job.status == .paused ? "play.fill" : "pause.fill")
                                                    .font(.system(size: 10))
                                            }
                                            .buttonStyle(.plain)
                                            .help(job.status == .paused ? workspace.tr("Fortsett", "Resume") : workspace.tr("Sett på pause", "Pause"))

                                            Button {
                                                queue.cancel(job)
                                            } label: {
                                                Image(systemName: "stop.fill")
                                                    .font(.system(size: 10))
                                                    .foregroundStyle(.red)
                                            }
                                            .buttonStyle(.plain)
                                            .help(workspace.tr("Avbryt overføring", "Cancel transfer"))
                                        }
                                    }
                                }
                                .padding(8)
                                .background(Color.primary.opacity(0.05))
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                        }
                    }
                    .frame(maxHeight: 190)
                }
            }
        }
    }

    private func handleDropProviders(_ providers: [NSItemProvider]) -> Bool {
        guard !workspace.tour.isSandboxActive else { return false }
        var handled = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            handled = true
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let resolvedURL: URL?
                if let data = item as? Data {
                    resolvedURL = URL(dataRepresentation: data, relativeTo: nil)
                } else if let url = item as? URL {
                    resolvedURL = url
                } else {
                    resolvedURL = nil
                }
                if let url = resolvedURL {
                    DispatchQueue.main.async {
                        _ = workspace.transferQueue.addToDropShelf([url])
                    }
                }
            }
        }
        return handled
    }
}
