import AppKit
import SwiftUI

struct UpdateSheetView: View {
    @Bindable var workspace: WorkspaceState
    @Environment(\.dismiss) private var dismiss

    private var updater: UpdateService {
        workspace.updateService
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack(spacing: 10) {
                LucideIcon(kind: .refreshCw, size: 22, lineWidth: 1.9)
                    .foregroundStyle(Color.accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(workspace.tr("Programvareoppdatering", "Software Update"))
                        .font(.system(size: 17, weight: .bold))
                    Text(workspace.tr(
                        "Installert versjon: FlowFile \(updater.currentAppVersion)",
                        "Installed version: FlowFile \(updater.currentAppVersion)"
                    ))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                }

                Spacer()
            }

            Divider()

            // Dynamic Status Area
            statusContentView

            Divider()

            // Update Source Configuration (collapsible / clean for friends & dev)
            VStack(alignment: .leading, spacing: 8) {
                Toggle(
                    workspace.tr(
                        "Sjekk automatisk etter nye versjoner ved oppstart",
                        "Automatically check for updates on launch"
                    ),
                    isOn: Binding(
                        get: { updater.checkAutomaticallyOnLaunch },
                        set: { updater.checkAutomaticallyOnLaunch = $0 }
                    )
                )
                .font(.system(size: 12.5))

                HStack(spacing: 8) {
                    Text(workspace.tr("Kilde (GitHub-repo):", "Update Source (GitHub repo):"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    TextField(
                        "nordiccraft/FlowFile",
                        text: Binding(
                            get: { updater.updateSourceRepoOrURL },
                            set: { updater.updateSourceRepoOrURL = $0 }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))

                    Button {
                        Task {
                            await updater.checkForUpdates(silent: false)
                        }
                    } label: {
                        HStack(spacing: 5) {
                            LucideIcon(kind: .refreshCw, size: 12.5)
                            Text(workspace.tr("Sjekk nå", "Check Now"))
                                .font(.system(size: 12, weight: .medium))
                        }
                    }
                    .buttonStyle(.glass)
                }
            }

            // Footer
            HStack {
                Spacer()
                Button(workspace.tr("Lukk", "Close")) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(22)
        .frame(width: 540)
        .task {
            if case .idle = updater.state {
                await updater.checkForUpdates(silent: false)
            }
        }
    }

    @ViewBuilder
    private var statusContentView: some View {
        switch updater.state {
        case .idle, .checking:
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text(workspace.tr("Ser etter nye versjoner av FlowFile...", "Checking for FlowFile updates..."))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 90, alignment: .center)

        case .upToDate(let current):
            HStack(spacing: 12) {
                LucideIcon(kind: .checkCircle, size: 24)
                    .foregroundStyle(.green)

                VStack(alignment: .leading, spacing: 3) {
                    Text(workspace.tr("FlowFile er oppdatert!", "FlowFile is up to date!"))
                        .font(.system(size: 14, weight: .semibold))
                    Text(workspace.tr(
                        "Du kjører siste tilgjengelige versjon (\(current)).",
                        "You are running the latest available version (\(current))."
                    ))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.green.opacity(0.08)))

        case .updateAvailable(let release):
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    HStack(spacing: 8) {
                        LucideIcon(kind: .sparkles, size: 18)
                            .foregroundStyle(Color.accentColor)
                        Text(workspace.tr(
                            "Ny versjon tilgjengelig: \(release.version)",
                            "New version available: \(release.version)"
                        ))
                        .font(.system(size: 14.5, weight: .bold))
                    }

                    Spacer()

                    Button {
                        Task {
                            await updater.downloadAndInstall(release)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            LucideIcon(kind: .cloudDownload, size: 14)
                            Text(workspace.tr("Installer og start på nytt", "Install & Relaunch"))
                                .font(.system(size: 12.5, weight: .semibold))
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }

                if !release.releaseNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ScrollView {
                        Text(release.releaseNotes)
                            .font(.system(size: 12))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                    .frame(maxHeight: 140)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 11).fill(Color.accentColor.opacity(0.09)))

        case .downloading(let progress):
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(workspace.tr("Laster ned oppdatering...", "Downloading update..."))
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("\(Int(progress * 100)) %")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: progress)
                Text(workspace.tr(
                    "Verifiserer SHA-256-sjekksum og kodesignatur før oppdatering.",
                    "Verifying SHA-256 checksum and code signature before updating."
                ))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))

        case .installing:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(workspace.tr(
                    "Installerer ny versjon og starter FlowFile på nytt...",
                    "Installing update and relaunching FlowFile..."
                ))
                .font(.system(size: 13, weight: .medium))
            }
            .padding(14)

        case .unconfigured:
            VStack(alignment: .leading, spacing: 6) {
                Text(workspace.tr(
                    "Oppdateringskilde er ikke satt ennå",
                    "Update source is not configured yet"
                ))
                .font(.system(size: 13, weight: .semibold))
                Text(workspace.tr(
                    "Skriv inn GitHub-repoet ditt under (f.eks. dittnavn/flowfile-releases) – eller sett FLOWFILE_REPO i scripts/release-config.env når du bygger pakker til venner og kollegaer, så følger adressen automatisk med i appen!",
                    "Enter your GitHub repo below (e.g. yourname/flowfile-releases) – or set FLOWFILE_REPO in scripts/release-config.env when building packages so it is pre-configured for friends and colleagues!"
                ))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))

        case .error(let msg):
            HStack(spacing: 10) {
                LucideIcon(kind: .xCircle, size: 20)
                    .foregroundStyle(.orange)
                Text(msg)
                    .font(.system(size: 12.5))
                Spacer()
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.10)))
        }
    }
}
