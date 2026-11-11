import SwiftUI

struct MultiRenameSheetView: View {
    @Bindable var workspace: WorkspaceState
    let targetItems: [FileItem]

    @State private var config = MultiRenameConfig()
    @Environment(\.dismiss) private var dismiss

    private var previewRows: [RenamePreviewRow] {
        MultiRenameService.generatePreview(items: targetItems, config: config)
    }

    private var actionableCount: Int {
        previewRows.filter { $0.status == .ready }.count
    }

    private var hasConflicts: Bool {
        previewRows.contains {
            $0.status == .duplicateConflict || $0.status == .existsOnDisk || $0.status == .invalidEmpty
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header
            HStack {
                Label("Multi-Rename Tool (Masse-omdøping)", systemImage: "character.textbox")
                    .font(.system(size: 16, weight: .semibold))

                Spacer()

                Text("\(targetItems.count) elementer")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            // Configuration Controls
            HStack(alignment: .top, spacing: 16) {
                // Left column: Name Mask & Token buttons
                VStack(alignment: .leading, spacing: 8) {
                    Text("Navnemønster (Stamnavn + Endelse)")
                        .font(.system(size: 12, weight: .semibold))

                    HStack(spacing: 6) {
                        TextField("[N]", text: $config.nameMask)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12.5, design: .monospaced))

                        Text(".")
                            .font(.system(size: 14, weight: .bold))

                        TextField("[E]", text: $config.extensionMask)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12.5, design: .monospaced))
                            .frame(width: 76)
                    }

                    // Quick insert token pills (Total Commander style!)
                    HStack(spacing: 5) {
                        tokenButton("[N]", help: "Opprinnelig filnavn")
                        tokenButton("[N1-5]", help: "Tegn 1 til 5 av navnet")
                        tokenButton("[C]", help: "Teller (001, 002...)")
                        tokenButton("[D]", help: "Dato (YYYY-MM-DD)")
                        tokenButton("[T]", help: "Klokkeslett (HHMMSS)")
                        tokenButton("[P]", help: "Foreldremappe")
                    }

                    Divider().padding(.vertical, 2)

                    Text("Søk & Erstatt")
                        .font(.system(size: 12, weight: .semibold))

                    HStack(spacing: 8) {
                        TextField("Søk etter...", text: $config.searchText)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))
                        Image(systemName: "arrow.right")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        TextField("Erstatt med...", text: $config.replaceText)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))
                    }

                    HStack(spacing: 14) {
                        Toggle("Regulært uttrykk (Regex)", isOn: $config.useRegex)
                            .font(.system(size: 11.5))
                        Toggle("Skill store/små bokstaver", isOn: $config.caseSensitiveSearch)
                            .font(.system(size: 11.5))
                    }
                }
                .frame(maxWidth: .infinity)

                Divider()

                // Right column: Counter & Case Transform
                VStack(alignment: .leading, spacing: 10) {
                    Text("Teller [C]")
                        .font(.system(size: 12, weight: .semibold))

                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Start på").font(.system(size: 10.5)).foregroundStyle(.secondary)
                            Stepper("\(config.counterStart)", value: $config.counterStart, in: 0...99999)
                                .font(.system(size: 12, design: .monospaced))
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Steg").font(.system(size: 10.5)).foregroundStyle(.secondary)
                            Stepper("\(config.counterStep)", value: $config.counterStep, in: 1...1000)
                                .font(.system(size: 12, design: .monospaced))
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Sifre").font(.system(size: 10.5)).foregroundStyle(.secondary)
                            Stepper("\(config.counterDigits)", value: $config.counterDigits, in: 1...8)
                                .font(.system(size: 12, design: .monospaced))
                        }
                    }

                    Divider().padding(.vertical, 2)

                    Text("Store / små bokstaver")
                        .font(.system(size: 12, weight: .semibold))

                    Picker("", selection: $config.caseTransform) {
                        ForEach(RenameCaseTransform.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 210)

                    Button("Tilbakestill felter") {
                        config = MultiRenameConfig()
                    }
                    .font(.system(size: 11.5))
                    .buttonStyle(.glass)
                }
                .frame(width: 260)
            }
            .padding(12)
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            // Live Preview Table
            VStack(spacing: 0) {
                HStack {
                    Text("NÅVÆRENDE NAVN")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("NYTT NAVN (LIVE FORHÅNDSVISNING)")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("STATUS")
                        .frame(width: 110, alignment: .trailing)
                }
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.06))

                Divider()

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(previewRows) { row in
                            HStack(spacing: 8) {
                                Text(row.sourceItem.name)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                Text(row.proposedName.isEmpty ? "—" : row.proposedName)
                                    .font(.system(size: 12, weight: row.status == .ready ? .semibold : .regular, design: .monospaced))
                                    .foregroundStyle(colorForStatus(row.status))
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                statusPill(row.status)
                                    .frame(width: 110, alignment: .trailing)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            Divider().opacity(0.4)
                        }
                    }
                }
                .frame(minHeight: 220, maxHeight: 290)
                .background(Color(nsColor: .controlBackgroundColor))
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            )

            // Footer buttons + Undo
            HStack {
                if let lastUndo = workspace.lastBatchRename {
                    Button {
                        workspace.undoLastBatchRename()
                        dismiss()
                    } label: {
                        Label("Angre forrige masse-omdøping (\(lastUndo.pairs.count) filer)", systemImage: "arrow.uturn.backward")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.glass)
                }

                Spacer()

                Button("Avbryt") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Utfør omdøping (\(actionableCount))") {
                    applyBatchRename()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(actionableCount == 0 || hasConflicts)
            }
        }
        .padding(18)
        .frame(width: 760)
    }

    @ViewBuilder
    private func tokenButton(_ token: String, help: String) -> some View {
        Button {
            if config.nameMask == "[N]" && token == "[C]" {
                config.nameMask = "[N]_[C]"
            } else {
                config.nameMask += token
            }
        } label: {
            Text(token)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
        }
        .buttonStyle(.glass)
        .help(help)
    }

    private func colorForStatus(_ status: RenamePreviewStatus) -> Color {
        switch status {
        case .ready: return .primary
        case .unchanged: return .secondary
        case .invalidEmpty, .duplicateConflict, .existsOnDisk: return .red
        }
    }

    @ViewBuilder
    private func statusPill(_ status: RenamePreviewStatus) -> some View {
        switch status {
        case .ready:
            Text("Klar")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.green)
        case .unchanged:
            Text("Uendret")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        case .invalidEmpty:
            Text("Tomt navn")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.red)
        case .duplicateConflict:
            Text("Duplikat!")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.red)
        case .existsOnDisk:
            Text("Finnes alt!")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.red)
        }
    }

    private func applyBatchRename() {
        do {
            let record = try MultiRenameService.executeBatchRename(rows: previewRows)
            workspace.lastBatchRename = record
            workspace.activeTab.markedURLs.removeAll()
            workspace.refreshAllTabs()
            workspace.showStatus("Omdøpte \(record.pairs.count) element(er) – kan angres fra ⌘M")
            dismiss()
        } catch {
            workspace.alertErrorMessage = error.localizedDescription
        }
    }
}
