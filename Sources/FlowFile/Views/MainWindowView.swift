import AppKit
import SwiftUI

struct MainWindowView: View {
    @Bindable var workspace: WorkspaceState

    var body: some View {
        ZStack {
            // Subtle ambient backdrop behind Liquid Glass chrome
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    Color.accentColor.opacity(0.05),
                    Color(nsColor: .underPageBackgroundColor).opacity(0.6)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 8) {
                // Top Liquid Glass Toolbar + Hybrid Address Bar
                TopToolbarView(workspace: workspace)

                // Automatic Update Available Notification Bar
                if let release = workspace.updateService.availableRelease,
                   workspace.updateService.hasVisibleUpdateBanner,
                   !workspace.tour.isActive {
                    HStack(spacing: 10) {
                        LucideIcon(kind: .sparkles, size: 15)
                            .foregroundStyle(Color.accentColor)

                        Text(workspace.tr(
                            "Ny versjon tilgjengelig: FlowFile \(release.version)",
                            "New version available: FlowFile \(release.version)"
                        ))
                        .font(.system(size: 12, weight: .semibold))

                        Spacer()

                        Button(workspace.tr("Se endringer / Oppdater...", "Release Notes / Update...")) {
                            workspace.isUpdateSheetVisible = true
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)

                        Button {
                            workspace.updateService.dismissedBannerForVersion = release.version
                        } label: {
                            LucideIcon(kind: .x, size: 12)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .liquidGlassPanel(cornerRadius: 11)
                    .padding(.horizontal, 10)
                }

                // Middle Workspace: Sidebar + 1 or 2 File Panes + Optional Inspector
                HStack(spacing: 8) {
                    if workspace.isSidebarVisible {
                        SidebarView(workspace: workspace)
                            .tourTarget(.sidebar)
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    }

                    if workspace.isDualPane {
                        HSplitView {
                            FilePaneView(pane: workspace.leftPane, workspace: workspace)
                                .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)

                            FilePaneView(pane: workspace.rightPane, workspace: workspace)
                                .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
                        }
                    } else {
                        FilePaneView(pane: workspace.leftPane, workspace: workspace)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }

                    if workspace.isDropShelfVisible {
                        DropShelfAndQueueView(workspace: workspace)
                            .tourTarget(.dropShelfPanel)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }

                    if workspace.isInspectorVisible {
                        InspectorPaneView(workspace: workspace)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Optional Synchronized Embedded Terminal Drawer (Fase 3: Ctrl+`)
                if workspace.isTerminalDrawerVisible {
                    TerminalDrawerView(workspace: workspace)
                        .padding(.horizontal, 10)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                // Bottom Liquid Glass Status Bar + Total Commander F3–F8 Bar
                StatusAndFKeyBarView(workspace: workspace)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
            }

            // Floating Liquid Glass Command Palette (Cmd+P)
            if workspace.isCommandPaletteVisible {
                CommandPaletteView(workspace: workspace)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    .zIndex(20)
            }
        }
        .overlayPreferenceValue(TourAnchorPreferenceKey.self) { anchors in
            if workspace.tour.isActive {
                InteractiveTourOverlay(workspace: workspace, anchors: anchors)
                    .transition(.opacity)
            }
        }
        .frame(minWidth: 880, minHeight: 560)
        .navigationTitle("FlowFile — \(workspace.activeTab.title)")
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            workspace.refreshPermissionsStatus()
        }
        .sheet(item: $workspace.activePrompt) { prompt in
            PromptDialogSheet(prompt: prompt, workspace: workspace)
        }
        .sheet(isPresented: $workspace.isSettingsVisible) {
            SettingsSheetView(workspace: workspace)
        }
        .sheet(isPresented: $workspace.isUpdateSheetVisible) {
            UpdateSheetView(workspace: workspace)
        }
        .sheet(isPresented: $workspace.isMultiRenameVisible) {
            MultiRenameSheetView(
                workspace: workspace,
                targetItems: workspace.multiRenameTargetItems
            )
        }
        .sheet(isPresented: $workspace.isShareHubVisible) {
            ShareHubSheetView(
                workspace: workspace,
                targetItems: workspace.shareTargetItems
            )
        }
        .alert(
            workspace.tr("Handling kunne ikke utføres", "Action Could Not Be Completed"),
            isPresented: Binding(
                get: { workspace.alertErrorMessage != nil },
                set: { if !$0 { workspace.alertErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                workspace.alertErrorMessage = nil
            }
        } message: {
            Text(workspace.alertErrorMessage ?? "")
        }
    }
}
