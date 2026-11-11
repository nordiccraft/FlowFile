import Darwin
import Foundation
import Observation

@Observable
final class TerminalSession {
    var outputText: String = ""
    var currentDirectory: URL
    var autoSyncDirectory: Bool = true
    var commandHistory: [String] = []
    var historyCursor: Int = -1
    var isRunning: Bool = false

    private var masterFD: Int32 = -1
    private var shellProcess: Process?
    private var readSource: DispatchSourceRead?

    init(initialDirectory: URL) {
        self.currentDirectory = initialDirectory.standardizedFileURL
    }

    deinit {
        stop()
    }

    func startIfNeeded(in directory: URL) {
        if isRunning {
            syncDirectory(to: directory)
            return
        }

        currentDirectory = directory.standardizedFileURL
        var master: Int32 = 0
        var slave: Int32 = 0
        var win = winsize(ws_row: 24, ws_col: 110, ws_xpixel: 0, ws_ypixel: 0)

        guard openpty(&master, &slave, nil, nil, &win) == 0 else {
            outputText += "Kunne ikke åpne PTY-terminal.\n"
            return
        }

        self.masterFD = master
        let flags = fcntl(master, F_GETFL)
        _ = fcntl(master, F_SETFL, flags | O_NONBLOCK)

        let slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-f"] // Fast clean startup without noisy prompt escape sequences
        proc.currentDirectoryURL = currentDirectory

        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "dumb"
        env["PS1"] = "%~ %# "
        env["LANG"] = "en_US.UTF-8"
        proc.environment = env

        proc.standardInput = slaveHandle
        proc.standardOutput = slaveHandle
        proc.standardError = slaveHandle

        let source = DispatchSource.makeReadSource(fileDescriptor: master, queue: .main)
        source.setEventHandler { [weak self] in
            self?.readAvailableBytes()
        }
        source.setCancelHandler {
            close(master)
        }
        self.readSource = source
        source.resume()

        do {
            try proc.run()
            self.shellProcess = proc
            self.isRunning = true
            appendOutput("FlowFile Terminal startet i \(currentDirectory.path)\n\(shortPathPrompt())")
        } catch {
            appendOutput("Feil ved oppstart av zsh: \(error.localizedDescription)\n")
        }
    }

    func sendCommand(_ rawCommand: String) {
        let trimmed = rawCommand.trimmingCharacters(in: .newlines)
        if !trimmed.trimmingCharacters(in: .whitespaces).isEmpty {
            commandHistory.append(trimmed)
            historyCursor = commandHistory.count
        }

        if trimmed == "clear" {
            outputText = shortPathPrompt()
            return
        }

        guard isRunning, masterFD >= 0 else {
            startIfNeeded(in: currentDirectory)
            return
        }

        let payload = trimmed + "\n"
        payload.withCString { ptr in
            _ = Darwin.write(masterFD, ptr, strlen(ptr))
        }
    }

    func syncDirectory(to newURL: URL) {
        let standardized = newURL.standardizedFileURL
        guard autoSyncDirectory, standardized != currentDirectory else { return }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: standardized.path, isDirectory: &isDir),
              isDir.boolValue else {
            return
        }
        currentDirectory = standardized
        guard isRunning, masterFD >= 0 else { return }

        let escaped = standardized.path.replacingOccurrences(of: "'", with: "'\\''")
        let cmd = "cd '\(escaped)'\n"
        cmd.withCString { ptr in
            _ = Darwin.write(masterFD, ptr, strlen(ptr))
        }
    }

    func clearOutput() {
        outputText = ""
        sendCommand("")
    }

    func stop() {
        if let proc = shellProcess, proc.isRunning {
            proc.terminate()
        }
        shellProcess = nil
        readSource?.cancel()
        readSource = nil
        masterFD = -1
        isRunning = false
    }

    private func readAvailableBytes() {
        guard masterFD >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = Darwin.read(masterFD, &buffer, buffer.count)
        guard count > 0 else { return }
        if let chunk = String(bytes: buffer[0..<count], encoding: .utf8) {
            let cleaned = stripANSICodes(chunk).replacingOccurrences(of: "\r\n", with: "\n")
            appendOutput(cleaned)
        }
    }

    private func appendOutput(_ text: String) {
        outputText += text
        if outputText.count > 40_000 {
            outputText = String(outputText.suffix(30_000))
        }
    }

    private func shortPathPrompt() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let display = currentDirectory.path.hasPrefix(home)
            ? "~" + currentDirectory.path.dropFirst(home.count)
            : currentDirectory.path
        return "\(display) % "
    }

    private func stripANSICodes(_ input: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "\\x1B\\[[0-9;?]*[A-Za-z]|\\x1B\\][^\\x07]*\\x07") else {
            return input
        }
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        return regex.stringByReplacingMatches(in: input, options: [], range: range, withTemplate: "")
    }
}
