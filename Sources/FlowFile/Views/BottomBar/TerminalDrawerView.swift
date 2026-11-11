import SwiftUI

struct TerminalDrawerView: View {
    @Bindable var workspace: WorkspaceState
    @State private var commandInput: String = ""
    @FocusState private var isInputFocused: Bool

    private var session: TerminalSession {
        workspace.terminalSession
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header bar
            HStack(spacing: 10) {
                Label("Innebygd Terminal (zsh)", systemImage: "terminal.fill")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Color.accentColor)

                Text(session.currentDirectory.path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)

                Spacer()

                Toggle("Synkroniser mappe", isOn: Binding(
                    get: { session.autoSyncDirectory },
                    set: { newVal in
                        session.autoSyncDirectory = newVal
                        if newVal {
                            session.syncDirectory(to: workspace.activeTab.currentURL)
                        }
                    }
                ))
                .toggleStyle(.checkbox)
                .font(.system(size: 11))

                Button("Tøm") {
                    session.clearOutput()
                }
                .font(.system(size: 11))
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Button {
                    workspace.isTerminalDrawerVisible = false
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Skjul terminal-skuff (Ctrl+`)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial)

            Divider()

            // Scrollable Terminal Output
            ScrollViewReader { proxy in
                ScrollView {
                    Text(session.outputText)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .id("terminalBottom")
                }
                .frame(height: 145)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.95))
                .onChange(of: session.outputText) { _, _ in
                    proxy.scrollTo("terminalBottom", anchor: .bottom)
                }
            }

            Divider()

            // Interactive Prompt Input Line
            HStack(spacing: 8) {
                Text("❯")
                    .font(.system(size: 12.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.accentColor)

                TextField("Skriv zsh-kommando (f.eks. git status, ls -la, swift --version)...", text: $commandInput)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5, design: .monospaced))
                    .focused($isInputFocused)
                    .onSubmit {
                        let cmd = commandInput
                        commandInput = ""
                        session.sendCommand(cmd)
                    }
                    .onKeyPress(.upArrow) {
                        guard !session.commandHistory.isEmpty else { return .ignored }
                        session.historyCursor = max(0, session.historyCursor - 1)
                        commandInput = session.commandHistory[session.historyCursor]
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        guard !session.commandHistory.isEmpty else { return .ignored }
                        if session.historyCursor + 1 < session.commandHistory.count {
                            session.historyCursor += 1
                            commandInput = session.commandHistory[session.historyCursor]
                        } else {
                            session.historyCursor = session.commandHistory.count
                            commandInput = ""
                        }
                        return .handled
                    }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1)
        )
        .onAppear {
            session.startIfNeeded(in: workspace.activeTab.currentURL)
            DispatchQueue.main.async {
                isInputFocused = true
            }
        }
    }
}
