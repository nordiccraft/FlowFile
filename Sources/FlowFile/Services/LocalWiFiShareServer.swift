import Darwin
import Foundation
import Network
import Observation
import Security

@Observable
final class LocalWiFiShareServer {
    var isRunning: Bool = false
    var shareURLString: String = ""
    var sharedFileName: String = ""
    var sharedFileSize: Int64 = 0
    var downloadCount: Int = 0
    var autoStopAfterFirstDownload: Bool = true
    var autoExpireNanoseconds: UInt64 = 600_000_000_000
    var errorMessage: String? = nil

    private var listener: NWListener?
    private var servedFileURL: URL?
    private(set) var securityToken: String = ""
    private var autoExpireTask: Task<Void, Never>?
    private var currentSessionID = UUID()

    deinit {
        stop()
    }

    func startSharing(fileURL: URL) {
        stop()
        errorMessage = nil
        downloadCount = 0

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            errorMessage = "Fant ikke filen som skal deles."
            return
        }

        let sessionID = UUID()
        self.currentSessionID = sessionID
        self.servedFileURL = fileURL
        self.sharedFileName = fileURL.lastPathComponent
        let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        self.sharedFileSize = (attrs?[.size] as? Int64) ?? 0
        self.securityToken = Self.generateSecurityToken()
        let expireNs = self.autoExpireNanoseconds

        do {
            let nwListener = try NWListener(using: .tcp, on: .any)
            self.listener = nwListener

            nwListener.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async {
                    guard let self, self.currentSessionID == sessionID else { return }
                    switch state {
                    case .ready:
                        if let port = nwListener.port?.rawValue {
                            let ip = Self.localIPv4Address() ?? Host.current().localizedName ?? "localhost"
                            self.shareURLString = "http://\(ip):\(port)/s/\(self.securityToken)"
                            self.isRunning = true
                        }
                    case .failed(let err):
                        self.errorMessage = "Kunne ikke starte lokal Wi-Fi-deling: \(err.localizedDescription)"
                        self.stop()
                    default:
                        break
                    }
                }
            }

            nwListener.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection, sessionID: sessionID)
            }

            nwListener.start(queue: .global(qos: .userInitiated))

            // Automatically shut down after expiry duration unless cancelled or superseded by a newer share
            autoExpireTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(nanoseconds: expireNs)
                } catch {
                    return
                }
                guard let self, !Task.isCancelled, self.currentSessionID == sessionID else { return }
                self.stop()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stop() {
        currentSessionID = UUID()
        autoExpireTask?.cancel()
        autoExpireTask = nil
        listener?.cancel()
        listener = nil
        servedFileURL = nil
        isRunning = false
        shareURLString = ""
    }

    private func handleConnection(_ connection: NWConnection, sessionID: UUID) {
        connection.start(queue: .global(qos: .userInitiated))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, error in
            guard let self, self.currentSessionID == sessionID,
                  error == nil, let data, let request = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }

            let firstLine = request.split(whereSeparator: \.isNewline).first ?? ""
            let parts = firstLine.split(separator: " ")
            guard parts.count >= 2 else {
                connection.cancel()
                return
            }
            let path = String(parts[1])

            if path == "/s/\(self.securityToken)" {
                self.sendLandingPage(over: connection)
            } else if path.hasPrefix("/d/\(self.securityToken)") {
                self.streamServedFile(over: connection, sessionID: sessionID)
            } else {
                let notFound = "HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\nConnection: close\r\n\r\nNot Found"
                connection.send(content: notFound.data(using: .utf8), completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
    }

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

    static func contentDispositionHeaderValue(for fileName: String) -> String {
        let strippedControls = fileName.unicodeScalars.filter { scalar in
            scalar.value >= 0x20 && scalar.value != 0x7F && scalar != "\"" && scalar != "\\"
        }
        let asciiFallback = String(String.UnicodeScalarView(strippedControls.map { $0.isASCII ? $0 : "_" }))
        let cleanFallback = asciiFallback.isEmpty ? "download" : asciiFallback
        var rfc5987Allowed = CharacterSet.alphanumerics
        rfc5987Allowed.insert(charactersIn: "-._~")
        let encodedUTF8 = fileName.addingPercentEncoding(withAllowedCharacters: rfc5987Allowed) ?? cleanFallback
        return "attachment; filename=\"\(cleanFallback)\"; filename*=UTF-8''\(encodedUTF8)"
    }

    static func buildLandingPageHTML(fileName: String, sizeString: String, securityToken: String) -> String {
        let escapedName = escapeHTML(fileName)
        let escapedSize = escapeHTML(sizeString)
        let encodedPathName = fileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "fil"
        let downloadHref = "/d/\(securityToken)/\(encodedPathName)"

        return """
        <!DOCTYPE html>
        <html lang="no">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>FlowFile Deling – \(escapedName)</title>
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
            <p>\(escapedSize) • Delt direkte fra FlowFile</p>
            <a class="btn" href="\(downloadHref)">Last ned fil</a>
        </div>
        </body>
        </html>
        """
    }

    private func sendLandingPage(over connection: NWConnection) {
        let sizeStr = ByteFormatter.string(fromByteCount: sharedFileSize)
        let html = Self.buildLandingPageHTML(
            fileName: sharedFileName,
            sizeString: sizeStr,
            securityToken: securityToken
        )

        let bodyData = Data(html.utf8)
        let header = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(bodyData)

        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func streamServedFile(over connection: NWConnection, sessionID: UUID) {
        guard let fileURL = servedFileURL,
              let fileHandle = try? FileHandle(forReadingFrom: fileURL) else {
            connection.cancel()
            return
        }

        let disposition = Self.contentDispositionHeaderValue(for: sharedFileName)
        let header = [
            "HTTP/1.1 200 OK",
            "Content-Type: application/octet-stream",
            "Content-Length: \(sharedFileSize)",
            "Content-Disposition: \(disposition)",
            "Connection: close",
            "",
            ""
        ].joined(separator: "\r\n")

        connection.send(content: Data(header.utf8), completion: .contentProcessed { [weak self] err in
            guard err == nil else {
                try? fileHandle.close()
                connection.cancel()
                return
            }
            self?.sendNextChunk(fileHandle: fileHandle, over: connection, sessionID: sessionID)
        })
    }

    private func sendNextChunk(fileHandle: FileHandle, over connection: NWConnection, sessionID: UUID) {
        let chunk = (try? fileHandle.read(upToCount: 65_536)) ?? Data()
        if chunk.isEmpty {
            try? fileHandle.close()
            connection.cancel()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.currentSessionID == sessionID else { return }
                self.downloadCount += 1
                if self.autoStopAfterFirstDownload {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                        guard let self, self.currentSessionID == sessionID else { return }
                        self.stop()
                    }
                }
            }
            return
        }

        connection.send(content: chunk, completion: .contentProcessed { [weak self] err in
            if err != nil {
                try? fileHandle.close()
                connection.cancel()
                return
            }
            self?.sendNextChunk(fileHandle: fileHandle, over: connection, sessionID: sessionID)
        })
    }

    static func localIPv4Address() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>? = nil
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var fallback: String? = nil
        var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let current = ptr {
            let interface = current.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family
            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name != "lo0" {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(
                        interface.ifa_addr,
                        socklen_t(interface.ifa_addr.pointee.sa_len),
                        &hostname,
                        socklen_t(hostname.count),
                        nil,
                        socklen_t(0),
                        NI_NUMERICHOST
                    ) == 0 {
                        let ip = String(cString: hostname)
                        if name == "en0" || name == "en1" {
                            return ip
                        }
                        if fallback == nil {
                            fallback = ip
                        }
                    }
                }
            }
            ptr = interface.ifa_next
        }
        return fallback
    }
}
