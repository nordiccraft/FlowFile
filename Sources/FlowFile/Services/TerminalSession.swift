import Darwin
import Foundation
import Observation

/// Streaming UTF-8 decoder that buffers trailing incomplete multi-byte sequences across read() chunks.
struct UTF8ChunkDecoder {
    private(set) var pendingBytes = Data()

    mutating func decode(_ incoming: Data) -> String {
        guard !incoming.isEmpty else { return "" }
        pendingBytes.append(incoming)

        let trailingIncomplete = Self.incompleteTrailingByteCount(in: pendingBytes)
        let validCount = pendingBytes.count - trailingIncomplete
        guard validCount > 0 else {
            return ""
        }

        let completeSlice = pendingBytes.prefix(validCount)
        let text = String(decoding: completeSlice, as: UTF8.self)
        pendingBytes = trailingIncomplete > 0 ? Data(pendingBytes.suffix(trailingIncomplete)) : Data()
        return text
    }

    mutating func flushRemainder() -> String {
        guard !pendingBytes.isEmpty else { return "" }
        let text = String(decoding: pendingBytes, as: UTF8.self)
        pendingBytes.removeAll()
        return text
    }

    private static func incompleteTrailingByteCount(in data: Data) -> Int {
        guard !data.isEmpty else { return 0 }
        let maxInspect = min(3, data.count)
        for offset in 1...maxInspect {
            let idx = data.index(data.endIndex, offsetBy: -offset)
            let byte = data[idx]
            if (byte & 0b1100_0000) == 0b1000_0000 {
                // Continuation byte 10xxxxxx: keep walking back to find its leading byte
                continue
            }
            let expectedLength: Int
            if (byte & 0b1000_0000) == 0 {
                expectedLength = 1
            } else if (byte & 0b1110_0000) == 0b1100_0000, byte >= 0xC2 {
                expectedLength = 2
            } else if (byte & 0b1111_0000) == 0b1110_0000 {
                expectedLength = 3
            } else if (byte & 0b1111_1000) == 0b1111_0000, byte <= 0xF4 {
                expectedLength = 4
            } else {
                // Invalid leading byte; let UTF8.self replace it immediately instead of buffering forever
                return 0
            }
            return offset < expectedLength ? offset : 0
        }
        return 0
    }
}

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
    private var utf8Decoder = UTF8ChunkDecoder()

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
        self.utf8Decoder = UTF8ChunkDecoder()
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

        proc.terminationHandler = { [weak self] terminatedProc in
            DispatchQueue.main.async {
                guard let self, self.shellProcess === terminatedProc else { return }
                self.handleShellExit()
            }
        }

        do {
            try proc.run()
            // Close parent's copy of slave FD so masterFD receives EOF promptly when child exits
            try? slaveHandle.close()
            self.shellProcess = proc
            self.isRunning = true
            appendOutput("FlowFile Terminal startet i \(currentDirectory.path)\n\(shortPathPrompt())")
        } catch {
            readSource?.cancel()
            readSource = nil
            masterFD = -1
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
        let proc = shellProcess
        shellProcess = nil
        if let proc, proc.isRunning {
            proc.terminate()
        }
        readSource?.cancel()
        readSource = nil
        masterFD = -1
        isRunning = false
    }

    private func handleShellExit() {
        drainRemainingBytes()
        let flushed = utf8Decoder.flushRemainder()
        if !flushed.isEmpty {
            appendOutput(stripANSICodes(flushed).replacingOccurrences(of: "\r\n", with: "\n"))
        }
        let wasRunning = isRunning
        shellProcess = nil
        readSource?.cancel()
        readSource = nil
        masterFD = -1
        isRunning = false
        if wasRunning {
            appendOutput("\n[Prosessen avsluttet]\n")
        }
    }

    private func drainRemainingBytes() {
        guard masterFD >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(masterFD, &buffer, buffer.count)
            if count > 0 {
                let decoded = utf8Decoder.decode(Data(buffer[0..<count]))
                if !decoded.isEmpty {
                    let cleaned = stripANSICodes(decoded).replacingOccurrences(of: "\r\n", with: "\n")
                    appendOutput(cleaned)
                }
            } else {
                break
            }
        }
    }

    private func readAvailableBytes() {
        guard masterFD >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(masterFD, &buffer, buffer.count)
            if count > 0 {
                let decoded = utf8Decoder.decode(Data(buffer[0..<count]))
                if !decoded.isEmpty {
                    let cleaned = stripANSICodes(decoded).replacingOccurrences(of: "\r\n", with: "\n")
                    appendOutput(cleaned)
                }
            } else if count == 0 {
                handleShellExit()
                return
            } else {
                let err = errno
                if err == EAGAIN || err == EWOULDBLOCK || err == EINTR {
                    return
                }
                handleShellExit()
                return
            }
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
