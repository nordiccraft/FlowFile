import Darwin
import Foundation
import Network
import Observation
import Security

struct LocalNetworkInterface: Identifiable, Hashable {
    var id: String { "\(name)-\(ipAddress)" }
    let name: String
    let ipAddress: String
    let label: String
}

enum LocalShareSelfTestState: Equatable {
    case idle
    case testing
    case reachable
    case blockedByLocalNetwork
}

struct LocalShareDownloadEvent: Identifiable, Equatable {
    let id = UUID()
    let timestamp: Date
    let clientAddress: String
}

@Observable
final class LocalWiFiShareServer {
    var isRunning: Bool = false
    var shareURLString: String = ""
    var sharedFileName: String = ""
    var sharedFileSize: Int64 = 0
    var downloadCount: Int = 0
    /// Time-window mode is default so mobile browsers (which often issue 2 requests) never get cut off mid-download.
    var autoStopAfterFirstDownload: Bool = false
    var autoExpireNanoseconds: UInt64 = 600_000_000_000
    var expiresAt: Date? = nil
    var errorMessage: String? = nil

    // Diagnostics, network selection, PIN & activity log
    var availableInterfaces: [LocalNetworkInterface] = []
    var selectedInterfaceID: String? = nil
    var selfTestState: LocalShareSelfTestState = .idle
    var showNetworkHintAfterWait: Bool = false
    var requirePIN: Bool = false
    var accessPIN: String = ""
    var downloadEvents: [LocalShareDownloadEvent] = []

    /// Optional staging file owned by this active Wi-Fi share (cleaned up when `stop()` is called).
    var ownedStagingFileURL: URL? = nil

    private var listener: NWListener?
    private var servedFileURL: URL?
    private(set) var securityToken: String = ""
    private var autoExpireTask: Task<Void, Never>?
    private var waitingHintTask: Task<Void, Never>?
    private var currentSessionID = UUID()
    private let connectionLock = NSLock()
    private var activeConnections: Int = 0
    private let maxConcurrentConnections: Int = 6
    private let serverQueue = DispatchQueue(label: "com.flowfile.lan-share", qos: .userInitiated)

    private struct SessionSnapshot {
        let sessionID: UUID
        let fileURL: URL
        let fileName: String
        let fileSize: Int64
        let token: String
        let pin: String?
    }

    private var activeSnapshot: SessionSnapshot?

    deinit {
        stop()
    }

    func refreshInterfaces() {
        let detected = Self.discoverNetworkInterfaces()
        availableInterfaces = detected
        if let current = selectedInterfaceID, detected.contains(where: { $0.id == current }) {
            return
        }
        selectedInterfaceID = detected.first?.id
    }

    func startSharing(fileURL: URL, ownedStagingURL: URL? = nil) {
        stop()
        errorMessage = nil
        downloadCount = 0
        downloadEvents = []
        showNetworkHintAfterWait = false
        selfTestState = .idle
        ownedStagingFileURL = ownedStagingURL

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            errorMessage = tr("Fant ikke filen som skal deles.", "Could not find the file to share.")
            return
        }

        refreshInterfaces()
        guard let chosenInterface = chosenNetworkInterface() else {
            errorMessage = tr(
                "Fant ingen aktiv Wi-Fi- eller kabeltilkobling. Koble til et lokalt nettverk eller Personlig hotspot og prøv igjen.",
                "No active Wi-Fi or Ethernet connection found. Connect to a local network or Personal Hotspot and try again."
            )
            return
        }

        let sessionID = UUID()
        let token = Self.generateSecurityToken()
        let pin: String?
        if requirePIN {
            let trimmed = accessPIN.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count == 4, trimmed.allSatisfy(\.isNumber) {
                pin = trimmed
            } else {
                let generated = Self.generateFourDigitPIN()
                accessPIN = generated
                pin = generated
            }
        } else {
            pin = nil
        }

        let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = (attrs?[.size] as? Int64) ?? 0
        let fileName = fileURL.lastPathComponent.precomposedStringWithCanonicalMapping

        self.currentSessionID = sessionID
        self.servedFileURL = fileURL
        self.sharedFileName = fileName
        self.sharedFileSize = size
        self.securityToken = token

        let snapshot = SessionSnapshot(
            sessionID: sessionID,
            fileURL: fileURL,
            fileName: fileName,
            fileSize: size,
            token: token,
            pin: pin
        )
        self.activeSnapshot = snapshot

        do {
            let params = NWParameters.tcp
            params.acceptLocalOnly = true
            params.prohibitedInterfaceTypes = [.cellular]
            let nwListener = try NWListener(using: params, on: .any)
            self.listener = nwListener

            nwListener.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async {
                    guard let self, self.currentSessionID == sessionID else { return }
                    switch state {
                    case .ready:
                        if let port = nwListener.port?.rawValue {
                            let ip = chosenInterface.ipAddress
                            self.shareURLString = "http://\(ip):\(port)/s/\(token)"
                            self.isRunning = true
                            self.scheduleExpiry(nanoseconds: self.autoExpireNanoseconds, sessionID: sessionID)
                            self.runSelfTest(ip: ip, port: port, token: token, sessionID: sessionID)
                            self.scheduleWaitingHint(sessionID: sessionID)
                        }
                    case .failed(let err):
                        self.errorMessage = tr(
                            "Kunne ikke starte lokal Wi-Fi-deling: \(err.localizedDescription)",
                            "Could not start local Wi-Fi sharing: \(err.localizedDescription)"
                        )
                        self.stop()
                    default:
                        break
                    }
                }
            }

            nwListener.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection, snapshot: snapshot)
            }

            nwListener.start(queue: serverQueue)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func switchInterface(to interfaceID: String) {
        selectedInterfaceID = interfaceID
        guard isRunning, let fileURL = servedFileURL else { return }
        let staged = ownedStagingFileURL
        ownedStagingFileURL = nil // Preserve staging across interface restart
        startSharing(fileURL: fileURL, ownedStagingURL: staged)
    }

    func extendExpiration(bySeconds extraSeconds: TimeInterval = 600) {
        guard isRunning else { return }
        let sessionID = currentSessionID
        let baseRemaining = max(0, (expiresAt ?? Date()).timeIntervalSinceNow)
        let newDuration = min(3600, baseRemaining + extraSeconds)
        scheduleExpiry(nanoseconds: UInt64(newDuration * 1_000_000_000), sessionID: sessionID)
    }

    func stop() {
        currentSessionID = UUID()
        autoExpireTask?.cancel()
        autoExpireTask = nil
        waitingHintTask?.cancel()
        waitingHintTask = nil
        listener?.cancel()
        listener = nil
        servedFileURL = nil
        activeSnapshot = nil
        isRunning = false
        shareURLString = ""
        expiresAt = nil
        selfTestState = .idle
        showNetworkHintAfterWait = false
        if let staged = ownedStagingFileURL {
            ownedStagingFileURL = nil
            ShareHubService.cleanupStagingRoot(for: staged)
        }
    }

    private func chosenNetworkInterface() -> LocalNetworkInterface? {
        if let selectedInterfaceID,
           let match = availableInterfaces.first(where: { $0.id == selectedInterfaceID }) {
            return match
        }
        return availableInterfaces.first
    }

    private func scheduleExpiry(nanoseconds: UInt64, sessionID: UUID) {
        autoExpireTask?.cancel()
        expiresAt = Date().addingTimeInterval(Double(nanoseconds) / 1_000_000_000.0)
        autoExpireTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
            guard let self, !Task.isCancelled, self.currentSessionID == sessionID else { return }
            self.stop()
        }
    }

    private func scheduleWaitingHint(sessionID: UUID) {
        waitingHintTask?.cancel()
        waitingHintTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 20_000_000_000)
            } catch {
                return
            }
            guard let self, !Task.isCancelled,
                  self.currentSessionID == sessionID,
                  self.isRunning,
                  self.downloadCount == 0 else { return }
            self.showNetworkHintAfterWait = true
        }
    }

    /// Probes our own LAN IP/port right after startup. If macOS Local Network privacy blocks traffic,
    /// the probe times out instead of returning 200 OK, so we can guide the user immediately.
    private func runSelfTest(ip: String, port: UInt16, token: String, sessionID: UUID) {
        selfTestState = .testing
        guard let probeURL = URL(string: "http://\(ip):\(port)/ping/\(token)") else {
            selfTestState = .blockedByLocalNetwork
            return
        }
        Task {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 2.5
            config.timeoutIntervalForResource = 3.0
            config.connectionProxyDictionary = [:] // Never route local LAN probe through corporate proxy
            let session = URLSession(configuration: config)
            defer { session.invalidateAndCancel() }
            do {
                let (_, response) = try await session.data(from: probeURL)
                let ok = (response as? HTTPURLResponse)?.statusCode == 200
                await MainActor.run {
                    guard self.currentSessionID == sessionID, self.isRunning else { return }
                    self.selfTestState = ok ? .reachable : .blockedByLocalNetwork
                }
            } catch {
                await MainActor.run {
                    guard self.currentSessionID == sessionID, self.isRunning else { return }
                    self.selfTestState = .blockedByLocalNetwork
                }
            }
        }
    }

    // MARK: - HTTP Connection Handling

    private func handleConnection(_ connection: NWConnection, snapshot: SessionSnapshot) {
        connectionLock.lock()
        if activeConnections >= maxConcurrentConnections {
            connectionLock.unlock()
            connection.cancel()
            return
        }
        activeConnections += 1
        connectionLock.unlock()

        var released = false
        let finishConnection: () -> Void = { [weak self] in
            connection.cancel()
            guard let self else { return }
            self.connectionLock.lock()
            if !released {
                released = true
                self.activeConnections = max(0, self.activeConnections - 1)
            }
            self.connectionLock.unlock()
        }

        // 10-second header timeout protects against slow/stalled clients
        let timeoutItem = DispatchWorkItem {
            finishConnection()
        }
        serverQueue.asyncAfter(deadline: .now() + 10.0, execute: timeoutItem)

        connection.start(queue: serverQueue)
        readHTTPRequestHeaders(
            from: connection,
            accumulated: Data(),
            timeoutItem: timeoutItem,
            snapshot: snapshot,
            finish: finishConnection
        )
    }

    private func readHTTPRequestHeaders(
        from connection: NWConnection,
        accumulated: Data,
        timeoutItem: DispatchWorkItem,
        snapshot: SessionSnapshot,
        finish: @escaping () -> Void
    ) {
        let maxHeaderBytes = 16_384
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self, error == nil else {
                timeoutItem.cancel()
                finish()
                return
            }

            var buffer = accumulated
            if let data {
                buffer.append(data)
            }

            let delimiter = Data("\r\n\r\n".utf8)
            if buffer.range(of: delimiter) != nil || isComplete || buffer.count >= maxHeaderBytes {
                timeoutItem.cancel()
                guard buffer.count <= maxHeaderBytes,
                      let requestText = String(data: buffer, encoding: .utf8) ?? String(data: buffer, encoding: .isoLatin1) else {
                    self.sendSimpleResponse(status: "400 Bad Request", body: "Bad Request", over: connection, finish: finish)
                    return
                }
                self.routeRequest(requestText, over: connection, snapshot: snapshot, finish: finish)
                return
            }

            self.readHTTPRequestHeaders(
                from: connection,
                accumulated: buffer,
                timeoutItem: timeoutItem,
                snapshot: snapshot,
                finish: finish
            )
        }
    }

    private func routeRequest(
        _ request: String,
        over connection: NWConnection,
        snapshot: SessionSnapshot,
        finish: @escaping () -> Void
    ) {
        let lines = request.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else {
            finish()
            return
        }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else {
            sendSimpleResponse(status: "400 Bad Request", body: "Bad Request", over: connection, finish: finish)
            return
        }

        let method = String(parts[0]).uppercased()
        guard method == "GET" || method == "HEAD" else {
            sendSimpleResponse(status: "405 Method Not Allowed", body: "Method Not Allowed", over: connection, finish: finish)
            return
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.isEmpty { break }
            if let colon = line.firstIndex(of: ":") {
                let k = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let v = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                headers[k] = v
            }
        }

        let rawTarget = String(parts[1])
        let targetParts = rawTarget.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let pathOnly = String(targetParts[0])
        let queryParams = Self.parseQueryParameters(targetParts.count > 1 ? String(targetParts[1]) : "")
        let prefersNorwegian = (headers["accept-language"] ?? "nb").lowercased().contains("nb")
            || (headers["accept-language"] ?? "nb").lowercased().contains("no")
            || (headers["accept-language"] ?? "nb").lowercased().contains("nn")

        // 1. Internal self-test probe
        if pathOnly.hasPrefix("/ping/") {
            let candidate = String(pathOnly.dropFirst("/ping/".count))
            if Self.constantTimeEquals(candidate, snapshot.token) {
                sendSimpleResponse(status: "200 OK", body: "ok", over: connection, finish: finish)
                return
            }
        }

        // 2. Landing page: exact match `/s/<token>`
        if pathOnly.hasPrefix("/s/") {
            let candidate = String(pathOnly.dropFirst("/s/".count))
            if Self.constantTimeEquals(candidate, snapshot.token) {
                if let requiredPIN = snapshot.pin {
                    let providedPIN = queryParams["pin"] ?? ""
                    if !Self.constantTimeEquals(providedPIN, requiredPIN) {
                        sendPINPromptPage(
                            over: connection,
                            snapshot: snapshot,
                            headOnly: method == "HEAD",
                            wrongAttempt: !providedPIN.isEmpty,
                            norwegian: prefersNorwegian,
                            finish: finish
                        )
                        return
                    }
                }
                sendLandingPage(
                    over: connection,
                    snapshot: snapshot,
                    headOnly: method == "HEAD",
                    pinQuery: snapshot.pin,
                    norwegian: prefersNorwegian,
                    finish: finish
                )
                return
            }
        }

        // 3. File download: exact `/d/<token>` or `/d/<token>/<filename>`
        if pathOnly.hasPrefix("/d/") {
            let rest = String(pathOnly.dropFirst("/d/".count))
            let candidateToken = rest.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
            if Self.constantTimeEquals(candidateToken, snapshot.token) {
                if let requiredPIN = snapshot.pin {
                    let providedPIN = queryParams["pin"] ?? ""
                    guard Self.constantTimeEquals(providedPIN, requiredPIN) else {
                        sendSimpleResponse(status: "403 Forbidden", body: "PIN required", over: connection, finish: finish)
                        return
                    }
                }
                let rangeHeader = headers["range"]
                let clientIP = Self.extractClientIP(from: connection)
                streamServedFile(
                    over: connection,
                    snapshot: snapshot,
                    headOnly: method == "HEAD",
                    rangeHeader: rangeHeader,
                    clientIP: clientIP,
                    finish: finish
                )
                return
            }
        }

        sendSimpleResponse(status: "404 Not Found", body: "Not Found", over: connection, finish: finish)
    }

    private func sendSimpleResponse(
        status: String,
        body: String,
        over connection: NWConnection,
        finish: @escaping () -> Void
    ) {
        let bodyData = Data(body.utf8)
        let header = [
            "HTTP/1.1 \(status)",
            "Content-Type: text/plain; charset=utf-8",
            "Content-Length: \(bodyData.count)",
            "X-Content-Type-Options: nosniff",
            "Cache-Control: no-store",
            "Referrer-Policy: no-referrer",
            "Connection: close",
            "",
            ""
        ].joined(separator: "\r\n")
        var response = Data(header.utf8)
        response.append(bodyData)
        connection.send(content: response, completion: .contentProcessed { _ in
            finish()
        })
    }

    private func sendPINPromptPage(
        over connection: NWConnection,
        snapshot: SessionSnapshot,
        headOnly: Bool,
        wrongAttempt: Bool,
        norwegian: Bool,
        finish: @escaping () -> Void
    ) {
        let escapedName = Self.escapeHTML(snapshot.fileName)
        let title = norwegian ? "PIN-kode kreves" : "PIN Code Required"
        let prompt = norwegian
            ? "Skriv inn den 4-sifrede PIN-koden fra FlowFile på Macen for å laste ned «\(escapedName)»."
            : "Enter the 4-digit PIN shown in FlowFile on the Mac to download “\(escapedName)”."
        let wrongMsg = wrongAttempt
            ? (norwegian ? "<p class=\"err\">Feil PIN-kode – prøv igjen.</p>" : "<p class=\"err\">Incorrect PIN – please try again.</p>")
            : ""
        let btnLabel = norwegian ? "Lås opp nedlasting" : "Unlock Download"

        let html = """
        <!DOCTYPE html>
        <html lang="\(norwegian ? "no" : "en")">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>FlowFile – \(title)</title>
        <style>
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; background: #0f172a; color: #f8fafc; display: flex; align-items: center; justify-content: center; min-height: 100vh; margin: 0; padding: 20px; box-sizing: border-box; }
        .card { background: rgba(30, 41, 59, 0.92); border: 1px solid rgba(148, 163, 184, 0.25); border-radius: 18px; padding: 28px; max-width: 420px; width: 100%; text-align: center; box-shadow: 0 20px 40px rgba(0,0,0,0.4); }
        h2 { margin: 0 0 10px 0; font-size: 19px; }
        p { color: #94a3b8; font-size: 14px; margin: 0 0 18px 0; }
        p.err { color: #f87171; font-weight: 600; }
        input { font-size: 24px; letter-spacing: 8px; text-align: center; width: 160px; padding: 10px; border-radius: 10px; border: 1px solid #475569; background: #0f172a; color: #fff; margin-bottom: 16px; }
        button { display: block; width: 100%; background: #2563eb; color: #fff; border: none; font-weight: 600; padding: 13px 20px; border-radius: 10px; font-size: 15px; cursor: pointer; }
        </style>
        </head>
        <body>
        <div class="card">
            <h2>\(title)</h2>
            <p>\(prompt)</p>
            \(wrongMsg)
            <form method="GET" action="/s/\(snapshot.token)">
                <input name="pin" type="tel" inputmode="numeric" maxlength="4" pattern="[0-9]{4}" placeholder="••••" autofocus required>
                <button type="submit">\(btnLabel)</button>
            </form>
        </div>
        </body>
        </html>
        """

        let bodyData = Data(html.utf8)
        let header = [
            "HTTP/1.1 200 OK",
            "Content-Type: text/html; charset=utf-8",
            "Content-Length: \(bodyData.count)",
            "Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; form-action 'self'",
            "X-Content-Type-Options: nosniff",
            "Cache-Control: no-store",
            "Referrer-Policy: no-referrer",
            "Connection: close",
            "",
            ""
        ].joined(separator: "\r\n")
        var response = Data(header.utf8)
        if !headOnly {
            response.append(bodyData)
        }
        connection.send(content: response, completion: .contentProcessed { _ in
            finish()
        })
    }

    private func sendLandingPage(
        over connection: NWConnection,
        snapshot: SessionSnapshot,
        headOnly: Bool,
        pinQuery: String?,
        norwegian: Bool,
        finish: @escaping () -> Void
    ) {
        let sizeStr = ByteFormatter.string(fromByteCount: snapshot.fileSize)
        let html = Self.buildLandingPageHTML(
            fileName: snapshot.fileName,
            sizeString: sizeStr,
            securityToken: snapshot.token,
            pinQuery: pinQuery,
            norwegian: norwegian
        )

        let bodyData = Data(html.utf8)
        let header = [
            "HTTP/1.1 200 OK",
            "Content-Type: text/html; charset=utf-8",
            "Content-Length: \(bodyData.count)",
            "Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'",
            "X-Content-Type-Options: nosniff",
            "Cache-Control: no-store",
            "Referrer-Policy: no-referrer",
            "Connection: close",
            "",
            ""
        ].joined(separator: "\r\n")
        var response = Data(header.utf8)
        if !headOnly {
            response.append(bodyData)
        }

        connection.send(content: response, completion: .contentProcessed { _ in
            finish()
        })
    }

    private func streamServedFile(
        over connection: NWConnection,
        snapshot: SessionSnapshot,
        headOnly: Bool,
        rangeHeader: String?,
        clientIP: String,
        finish: @escaping () -> Void
    ) {
        guard let fileHandle = try? FileHandle(forReadingFrom: snapshot.fileURL) else {
            sendSimpleResponse(status: "404 Not Found", body: "Not Found", over: connection, finish: finish)
            return
        }

        let totalSize = snapshot.fileSize
        var startByte: Int64 = 0
        var endByte: Int64 = max(0, totalSize - 1)
        var isPartial = false

        if let rangeHeader, totalSize > 0 {
            if let parsed = Self.parseByteRange(rangeHeader, totalSize: totalSize) {
                startByte = parsed.lowerBound
                endByte = parsed.upperBound
                isPartial = true
            } else {
                try? fileHandle.close()
                let header = [
                    "HTTP/1.1 416 Range Not Satisfiable",
                    "Content-Range: bytes */\(totalSize)",
                    "Content-Length: 0",
                    "Connection: close",
                    "",
                    ""
                ].joined(separator: "\r\n")
                connection.send(content: Data(header.utf8), completion: .contentProcessed { _ in finish() })
                return
            }
        }

        let bytesToSend: Int64 = totalSize == 0 ? 0 : (endByte - startByte + 1)
        let disposition = Self.contentDispositionHeaderValue(for: snapshot.fileName)
        var headerLines = [
            isPartial ? "HTTP/1.1 206 Partial Content" : "HTTP/1.1 200 OK",
            "Content-Type: application/octet-stream",
            "Accept-Ranges: bytes",
            "Content-Length: \(bytesToSend)",
            "Content-Disposition: \(disposition)",
            "X-Content-Type-Options: nosniff",
            "Cache-Control: no-store",
            "Referrer-Policy: no-referrer",
            "Connection: close"
        ]
        if isPartial {
            headerLines.append("Content-Range: bytes \(startByte)-\(endByte)/\(totalSize)")
        }
        headerLines.append(contentsOf: ["", ""])
        let headerData = Data(headerLines.joined(separator: "\r\n").utf8)

        if headOnly || bytesToSend == 0 {
            try? fileHandle.close()
            connection.send(content: headerData, completion: .contentProcessed { _ in finish() })
            return
        }

        do {
            try fileHandle.seek(toOffset: UInt64(startByte))
        } catch {
            try? fileHandle.close()
            finish()
            return
        }

        connection.send(content: headerData, completion: .contentProcessed { [weak self] err in
            guard err == nil, let self else {
                try? fileHandle.close()
                finish()
                return
            }
            self.sendNextChunk(
                fileHandle: fileHandle,
                remaining: bytesToSend,
                reachedEOF: endByte >= totalSize - 1,
                over: connection,
                snapshot: snapshot,
                clientIP: clientIP,
                finish: finish
            )
        })
    }

    private func sendNextChunk(
        fileHandle: FileHandle,
        remaining: Int64,
        reachedEOF: Bool,
        over connection: NWConnection,
        snapshot: SessionSnapshot,
        clientIP: String,
        finish: @escaping () -> Void
    ) {
        if remaining <= 0 {
            try? fileHandle.close()
            finish()
            if reachedEOF {
                recordCompletedDownload(sessionID: snapshot.sessionID, clientIP: clientIP)
            }
            return
        }

        let toRead = Int(min(Int64(65_536), remaining))
        let chunk = (try? fileHandle.read(upToCount: toRead)) ?? Data()
        if chunk.isEmpty {
            try? fileHandle.close()
            finish()
            if reachedEOF {
                recordCompletedDownload(sessionID: snapshot.sessionID, clientIP: clientIP)
            }
            return
        }

        let nextRemaining = remaining - Int64(chunk.count)
        connection.send(content: chunk, completion: .contentProcessed { [weak self] err in
            if err != nil {
                try? fileHandle.close()
                finish()
                return
            }
            self?.sendNextChunk(
                fileHandle: fileHandle,
                remaining: nextRemaining,
                reachedEOF: reachedEOF,
                over: connection,
                snapshot: snapshot,
                clientIP: clientIP,
                finish: finish
            )
        })
    }

    private func recordCompletedDownload(sessionID: UUID, clientIP: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.currentSessionID == sessionID else { return }
            self.downloadCount += 1
            self.showNetworkHintAfterWait = false
            self.downloadEvents.insert(
                LocalShareDownloadEvent(timestamp: Date(), clientAddress: clientIP),
                at: 0
            )
            if self.downloadEvents.count > 20 {
                self.downloadEvents.removeLast(self.downloadEvents.count - 20)
            }
            if self.autoStopAfterFirstDownload {
                // 20-second grace window so mobile download managers making a follow-up request succeed cleanly
                self.scheduleExpiry(nanoseconds: 20_000_000_000, sessionID: sessionID)
            }
        }
    }

    // MARK: - Static Helpers & Parsing

    static func generateSecurityToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess {
            return bytes.map { String(format: "%02x", $0) }.joined()
        }
        return (UUID().uuidString + UUID().uuidString)
            .replacingOccurrences(of: "-", with: "")
            .prefix(32)
            .lowercased()
    }

    static func generateFourDigitPIN() -> String {
        var val: UInt32 = 0
        if SecRandomCopyBytes(kSecRandomDefault, MemoryLayout<UInt32>.size, &val) == errSecSuccess {
            return String(format: "%04u", val % 10_000)
        }
        return String(format: "%04u", UInt32.random(in: 0..<10_000))
    }

    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let aBytes = Array(a.utf8)
        let bBytes = Array(b.utf8)
        guard aBytes.count == bBytes.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<aBytes.count {
            diff |= aBytes[i] ^ bBytes[i]
        }
        return diff == 0
    }

    static func parseByteRange(_ header: String, totalSize: Int64) -> ClosedRange<Int64>? {
        let trimmed = header.trimmingCharacters(in: .whitespaces).lowercased()
        guard trimmed.hasPrefix("bytes="), totalSize > 0 else { return nil }
        let spec = String(trimmed.dropFirst("bytes=".count))
        // Reject multi-range specs for simplicity; handle single range cleanly
        guard !spec.contains(",") else { return nil }
        let bounds = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard bounds.count == 2 else { return nil }

        let startStr = String(bounds[0]).trimmingCharacters(in: .whitespaces)
        let endStr = String(bounds[1]).trimmingCharacters(in: .whitespaces)

        if startStr.isEmpty {
            // Suffix range: bytes=-500
            guard let suffixLen = Int64(endStr), suffixLen > 0 else { return nil }
            let start = max(0, totalSize - suffixLen)
            return start...(totalSize - 1)
        }
        guard let start = Int64(startStr), start >= 0, start < totalSize else { return nil }
        if endStr.isEmpty {
            return start...(totalSize - 1)
        }
        guard let rawEnd = Int64(endStr), rawEnd >= start else { return nil }
        return start...min(rawEnd, totalSize - 1)
    }

    private static func parseQueryParameters(_ query: String) -> [String: String] {
        var result: [String: String] = [:]
        guard !query.isEmpty else { return result }
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            let k = String(kv[0]).removingPercentEncoding ?? String(kv[0])
            let v = kv.count > 1 ? (String(kv[1]).removingPercentEncoding ?? String(kv[1])) : ""
            result[k] = v
        }
        return result
    }

    private static func extractClientIP(from connection: NWConnection) -> String {
        if case .hostPort(let host, _) = connection.endpoint {
            let raw = "\(host)"
            if let pct = raw.firstIndex(of: "%") {
                return String(raw[..<pct])
            }
            return raw
        }
        return tr("Ukjent enhet", "Unknown device")
    }

    static func escapeHTML(_ raw: String) -> String {
        var out = ""
        out.reserveCapacity(raw.count)
        for ch in raw {
            switch ch {
            case "&": out.append("&amp;")
            case "<": out.append("&lt;")
            case ">": out.append("&gt;")
            case "\"": out.append("&quot;")
            case "'": out.append("&#39;")
            default: out.append(ch)
            }
        }
        return out
    }

    /// Produces an RFC 6266 + RFC 5987 Content-Disposition header with clean NFC UTF-8 and readable ASCII fallback.
    static func contentDispositionHeaderValue(for fileName: String) -> String {
        let nfcName = fileName.precomposedStringWithCanonicalMapping
        let strippedControls = String(nfcName.unicodeScalars.filter { scalar in
            scalar.value >= 0x20 && scalar.value != 0x7F && scalar != "\"" && scalar != "\\"
        })
        let transliterated = strippedControls
            .replacingOccurrences(of: "æ", with: "ae")
            .replacingOccurrences(of: "Æ", with: "AE")
            .replacingOccurrences(of: "ø", with: "o")
            .replacingOccurrences(of: "Ø", with: "O")
            .replacingOccurrences(of: "å", with: "a")
            .replacingOccurrences(of: "Å", with: "A")
        let asciiFallback = String(transliterated.unicodeScalars.map { $0.isASCII ? Character($0) : "_" })
        let cleanFallback = asciiFallback.isEmpty ? "download" : asciiFallback

        var rfc5987Allowed = CharacterSet.alphanumerics
        rfc5987Allowed.insert(charactersIn: "-._~")
        let encodedUTF8 = strippedControls.addingPercentEncoding(withAllowedCharacters: rfc5987Allowed) ?? cleanFallback
        return "attachment; filename=\"\(cleanFallback)\"; filename*=UTF-8''\(encodedUTF8)"
    }

    static func buildLandingPageHTML(
        fileName: String,
        sizeString: String,
        securityToken: String,
        pinQuery: String? = nil,
        norwegian: Bool = true
    ) -> String {
        let nfcName = fileName.precomposedStringWithCanonicalMapping
        let escapedName = escapeHTML(nfcName)
        let escapedSize = escapeHTML(sizeString)
        let encodedPathName = nfcName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "fil"
        let pinSuffix = pinQuery.map { "?pin=\($0)" } ?? ""
        let downloadHref = "/d/\(securityToken)/\(encodedPathName)\(pinSuffix)"
        let titleSuffix = norwegian ? "FlowFile Deling" : "FlowFile Share"
        let subtitle = norwegian ? "Delt direkte fra FlowFile" : "Shared directly from FlowFile"
        let buttonText = norwegian ? "Last ned fil" : "Download File"

        return """
        <!DOCTYPE html>
        <html lang="\(norwegian ? "no" : "en")">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(titleSuffix) – \(escapedName)</title>
        <style>
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; background: #0f172a; color: #f8fafc; display: flex; align-items: center; justify-content: center; min-height: 100vh; margin: 0; padding: 20px; box-sizing: border-box; }
        .card { background: rgba(30, 41, 59, 0.9); border: 1px solid rgba(148, 163, 184, 0.25); border-radius: 18px; padding: 28px; max-width: 420px; width: 100%; text-align: center; box-shadow: 0 20px 40px rgba(0,0,0,0.4); }
        h2 { margin: 0 0 8px 0; font-size: 19px; word-break: break-all; }
        p { color: #94a3b8; font-size: 14px; margin: 0 0 22px 0; }
        a.btn { display: inline-block; background: #2563eb; color: #fff; text-decoration: none; font-weight: 600; padding: 13px 24px; border-radius: 10px; font-size: 15px; }
        </style>
        </head>
        <body>
        <div class="card">
            <h2>\(escapedName)</h2>
            <p>\(escapedSize) • \(subtitle)</p>
            <a class="btn" href="\(downloadHref)">\(buttonText)</a>
        </div>
        </body>
        </html>
        """
    }

    static func discoverNetworkInterfaces() -> [LocalNetworkInterface] {
        var ifaddr: UnsafeMutablePointer<ifaddrs>? = nil
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }

        var found: [LocalNetworkInterface] = []
        var seenIPs = Set<String>()
        var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr

        while let current = ptr {
            let interface = current.pointee
            ptr = interface.ifa_next
            let flags = Int32(interface.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_RUNNING) != 0, (flags & IFF_LOOPBACK) == 0 else { continue }
            guard let sockAddr = interface.ifa_addr, sockAddr.pointee.sa_family == UInt8(AF_INET) else { continue }

            let name = String(cString: interface.ifa_name)
            if name == "lo0" || name.hasPrefix("utun") || name.hasPrefix("bridge")
                || name.hasPrefix("awdl") || name.hasPrefix("llw") || name.hasPrefix("anpi") || name.hasPrefix("ap") {
                continue
            }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                sockAddr,
                socklen_t(sockAddr.pointee.sa_len),
                &hostname,
                socklen_t(hostname.count),
                nil,
                socklen_t(0),
                NI_NUMERICHOST
            ) == 0 else { continue }

            let ip = String(cString: hostname)
            if ip.hasPrefix("169.254.") || ip.hasPrefix("127.") || seenIPs.contains(ip) { continue }
            seenIPs.insert(ip)

            let label: String
            if name == "en0" {
                label = "Wi-Fi (\(name)) – \(ip)"
            } else if name.hasPrefix("en") {
                label = "\(tr("Kabel / Nettverk", "Ethernet / Network")) (\(name)) – \(ip)"
            } else {
                label = "\(name) – \(ip)"
            }
            found.append(LocalNetworkInterface(name: name, ipAddress: ip, label: label))
        }

        // Prioritize en0 (Wi-Fi) first, then other en* interfaces
        return found.sorted { lhs, rhs in
            if lhs.name == "en0" && rhs.name != "en0" { return true }
            if rhs.name == "en0" && lhs.name != "en0" { return false }
            if lhs.name.hasPrefix("en") && !rhs.name.hasPrefix("en") { return true }
            if rhs.name.hasPrefix("en") && !lhs.name.hasPrefix("en") { return false }
            return lhs.name < rhs.name
        }
    }

    static func localIPv4Address() -> String? {
        discoverNetworkInterfaces().first?.ipAddress
    }
}
