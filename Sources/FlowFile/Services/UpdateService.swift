import AppKit
import CryptoKit
import Foundation
import Observation

struct AppReleaseInfo: Sendable, Equatable {
    let version: String
    let title: String
    let releaseNotes: String
    let publishedAt: String?
    let zipDownloadURL: URL?
    let checksumsURL: URL?
    let htmlReleaseURL: URL?
}

enum UpdateCheckState: Equatable {
    case idle
    case checking
    case upToDate(currentVersion: String)
    case updateAvailable(AppReleaseInfo)
    case downloading(progress: Double)
    case installing
    case unconfigured
    case error(String)
}

@Observable
final class UpdateService: NSObject, URLSessionDownloadDelegate {
    var state: UpdateCheckState = .idle
    var availableRelease: AppReleaseInfo? = nil
    var dismissedBannerForVersion: String? = nil

    var checkAutomaticallyOnLaunch: Bool {
        didSet {
            UserDefaults.standard.set(checkAutomaticallyOnLaunch, forKey: "flowfile.autoCheckUpdates")
        }
    }

    /// Format: "owner/repo" (e.g. "nordiccraft/FlowFile") or full HTTPS release API URL.
    var updateSourceRepoOrURL: String {
        didSet {
            let trimmed = updateSourceRepoOrURL.trimmingCharacters(in: .whitespacesAndNewlines)
            UserDefaults.standard.set(trimmed, forKey: "flowfile.updateSource.v2")
        }
    }

    private var downloadContinuation: CheckedContinuation<URL, Error>?
    private var activeDownloadTask: URLSessionDownloadTask?

    var currentAppVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0.0"
    }

    override init() {
        let autoCheck = UserDefaults.standard.object(forKey: "flowfile.autoCheckUpdates") as? Bool ?? true
        let savedSource = UserDefaults.standard.string(forKey: "flowfile.updateSource.v2") ?? ""
        let bundledSource = (Bundle.main.infoDictionary?["FFUpdateRepository"] as? String) ?? ""
        let resolvedDefault = bundledSource.isEmpty ? "nordiccraft/FlowFile" : bundledSource
        self.checkAutomaticallyOnLaunch = autoCheck
        self.updateSourceRepoOrURL = savedSource.isEmpty ? resolvedDefault : savedSource
        super.init()
    }

    var hasVisibleUpdateBanner: Bool {
        guard let rel = availableRelease else { return false }
        return dismissedBannerForVersion != rel.version
    }

    // MARK: - Check for Updates

    @MainActor
    func checkForUpdates(silent: Bool = false) async {
        let source = effectiveSource
        guard !source.isEmpty else {
            if !silent {
                state = .unconfigured
            }
            return
        }

        guard let endpointURL = resolveEndpointURL(from: source),
              endpointURL.scheme?.lowercased() == "https" else {
            if !silent {
                state = .error(tr("Oppdateringsadresse må bruke HTTPS: \(source)", "Update source must use HTTPS: \(source)"))
            }
            return
        }

        if !silent {
            state = .checking
        }

        do {
            var request = URLRequest(url: endpointURL)
            request.timeoutInterval = 12
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("FlowFile-Updater/\(currentAppVersion)", forHTTPHeaderField: "User-Agent")

            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                if http.statusCode == 404 {
                    if !silent {
                        state = .error(tr(
                            "Fant ingen publiserte utgivelser (Releases) på «\(source)» ennå.",
                            "No published releases found at '\(source)' yet."
                        ))
                    }
                    return
                }
                throw NSError(
                    domain: "UpdateService",
                    code: http.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"]
                )
            }

            let release = try Self.parseReleasePayload(data: data)
            if Self.isVersion(release.version, newerThan: currentAppVersion) {
                self.availableRelease = release
                self.state = .updateAvailable(release)
            } else {
                self.availableRelease = nil
                if !silent {
                    self.state = .upToDate(currentVersion: currentAppVersion)
                } else {
                    self.state = .idle
                }
            }
        } catch {
            if !silent {
                self.state = .error(tr(
                    "Kunne ikke sjekke oppdateringer: \(error.localizedDescription)",
                    "Could not check for updates: \(error.localizedDescription)"
                ))
            }
        }
    }

    // MARK: - Download, Verify SHA-256 & Code Signature, Replace Bundle & Relaunch

    @MainActor
    func downloadAndInstall(_ release: AppReleaseInfo) async {
        guard let downloadURL = release.zipDownloadURL,
              downloadURL.scheme?.lowercased() == "https" else {
            if let webURL = release.htmlReleaseURL {
                NSWorkspace.shared.open(webURL)
            } else {
                state = .error(tr(
                    "Utgivelsen mangler HTTPS-nedlasting (FlowFile-Update.zip).",
                    "Release is missing HTTPS update archive (FlowFile-Update.zip)."
                ))
            }
            return
        }

        state = .downloading(progress: 0.02)

        do {
            let downloadedTempURL = try await downloadFileWithProgress(from: downloadURL)
            state = .installing

            let stagingDir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("flowfile-update-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)

            let zipFilename = downloadURL.lastPathComponent.isEmpty ? "FlowFile-Update.zip" : downloadURL.lastPathComponent
            let zipTarget = stagingDir.appendingPathComponent(zipFilename)
            try FileManager.default.moveItem(at: downloadedTempURL, to: zipTarget)

            // Require SHA256SUMS.txt over HTTPS (fail closed if missing, unreadable, or mismatched)
            guard let checksumsURL = release.checksumsURL,
                  checksumsURL.scheme?.lowercased() == "https" else {
                throw NSError(
                    domain: "UpdateService",
                    code: 10,
                    userInfo: [NSLocalizedDescriptionKey: tr(
                        "Utgivelsen mangler gyldig SHA256SUMS.txt over HTTPS. Oppdateringen ble avbrutt.",
                        "Release is missing a valid HTTPS SHA256SUMS.txt manifest. Update aborted."
                    )]
                )
            }
            try await Self.verifySHA256Checksum(of: zipTarget, filename: zipFilename, checksumsURL: checksumsURL)

            let extractDir = stagingDir.appendingPathComponent("extracted", isDirectory: true)
            try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)

            try Self.extractZip(at: zipTarget, into: extractDir)

            let extractedApp = extractDir.appendingPathComponent("FlowFile.app", isDirectory: true)
            let extractedBinary = extractedApp.appendingPathComponent("Contents/MacOS/FlowFile")
            guard FileManager.default.fileExists(atPath: extractedBinary.path) else {
                throw NSError(
                    domain: "UpdateService",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: tr(
                        "Oppdateringspakken inneholdt ikke en gyldig FlowFile.app.",
                        "Update archive did not contain a valid FlowFile.app."
                    )]
                )
            }

            try Self.verifyBundleIdentityAndSignature(at: extractedApp)

            let destinationAppURL = Self.resolveTargetAppLocation()
            try Self.preflightValidateTargetLocation(destinationAppURL)
            try Self.spawnAtomicUpdaterAndTerminate(
                newAppURL: extractedApp,
                destinationAppURL: destinationAppURL,
                stagingDir: stagingDir
            )
        } catch {
            state = .error(tr(
                "Oppdatering feilet: \(error.localizedDescription)",
                "Update failed: \(error.localizedDescription)"
            ))
        }
    }

    // MARK: - Networking & URLSessionDownloadDelegate

    private func downloadFileWithProgress(from url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            self.downloadContinuation = continuation
            let config = URLSessionConfiguration.ephemeral
            let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
            var request = URLRequest(url: url)
            request.setValue("FlowFile-Updater/\(currentAppVersion)", forHTTPHeaderField: "User-Agent")
            let task = session.downloadTask(with: request)
            self.activeDownloadTask = task
            task.resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = min(0.99, max(0.02, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
        Task { @MainActor [weak self] in
            self?.state = .downloading(progress: fraction)
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let persisted = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("flowfile-dl-\(UUID().uuidString).bin")
        do {
            try FileManager.default.moveItem(at: location, to: persisted)
            downloadContinuation?.resume(returning: persisted)
            downloadContinuation = nil
        } catch {
            downloadContinuation?.resume(throwing: error)
            downloadContinuation = nil
        }
        session.finishTasksAndInvalidate()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            downloadContinuation?.resume(throwing: error)
            downloadContinuation = nil
            session.finishTasksAndInvalidate()
        }
    }

    // MARK: - Helpers

    private var effectiveSource: String {
        let trimmed = updateSourceRepoOrURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return ((Bundle.main.infoDictionary?["FFUpdateRepository"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func resolveEndpointURL(from source: String) -> URL? {
        if source.lowercased().hasPrefix("https://") {
            if let url = URL(string: source),
               url.host?.lowercased() == "github.com" {
                let parts = url.pathComponents.filter { $0 != "/" }
                if parts.count >= 2 {
                    return URL(string: "https://api.github.com/repos/\(parts[0])/\(parts[1])/releases/latest")
                }
            }
            return URL(string: source)
        }
        let cleaned = source.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let segments = cleaned.split(separator: "/")
        guard segments.count == 2 else { return nil }
        return URL(string: "https://api.github.com/repos/\(segments[0])/\(segments[1])/releases/latest")
    }

    private static func parseReleasePayload(data: Data) throws -> AppReleaseInfo {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "UpdateService", code: 3, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON"])
        }

        let rawTag = (json["tag_name"] as? String) ?? (json["version"] as? String) ?? ""
        let cleanVersion = normalizeVersion(rawTag)
        guard !cleanVersion.isEmpty else {
            throw NSError(domain: "UpdateService", code: 4, userInfo: [NSLocalizedDescriptionKey: "Missing version tag"])
        }

        let title = (json["name"] as? String) ?? "FlowFile \(cleanVersion)"
        let notes = (json["body"] as? String) ?? (json["notes"] as? String) ?? ""
        let published = (json["published_at"] as? String)
        let htmlURL = (json["html_url"] as? String).flatMap(URL.init(string:))

        var zipURL = (json["zip_url"] as? String).flatMap(URL.init(string:))
        var checksumsURL: URL? = nil

        if let assets = json["assets"] as? [[String: Any]] {
            for asset in assets {
                guard let name = (asset["name"] as? String)?.lowercased(),
                      let dlStr = asset["browser_download_url"] as? String,
                      let dlURL = URL(string: dlStr) else { continue }
                if name.hasSuffix(".zip") && zipURL == nil {
                    zipURL = dlURL
                } else if name == "sha256sums.txt" {
                    checksumsURL = dlURL
                }
            }
        }

        return AppReleaseInfo(
            version: cleanVersion,
            title: title,
            releaseNotes: notes,
            publishedAt: published,
            zipDownloadURL: zipURL,
            checksumsURL: checksumsURL,
            htmlReleaseURL: htmlURL
        )
    }

    static func normalizeVersion(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased().hasPrefix("v") {
            s.removeFirst()
        }
        return s
    }

    static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        let cParts = normalizeVersion(candidate).split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        let curParts = normalizeVersion(current).split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        let count = max(cParts.count, curParts.count)
        for i in 0..<count {
            let a = i < cParts.count ? cParts[i] : 0
            let b = i < curParts.count ? curParts[i] : 0
            if a != b { return a > b }
        }
        return false
    }

    private static func verifySHA256Checksum(of fileURL: URL, filename: String, checksumsURL: URL) async throws {
        let (checksumData, response) = try await URLSession.shared.data(from: checksumsURL)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw NSError(domain: "UpdateService", code: http.statusCode, userInfo: [
                NSLocalizedDescriptionKey: tr(
                    "Kunne ikke hente SHA256SUMS.txt (HTTP \(http.statusCode)). Oppdateringen ble avbrutt.",
                    "Could not fetch SHA256SUMS.txt (HTTP \(http.statusCode)). Update aborted."
                )
            ])
        }
        try verifySHA256Checksum(of: fileURL, filename: filename, manifestData: checksumData)
    }

    static func verifySHA256Checksum(of fileURL: URL, filename: String, manifestData: Data) throws {
        guard let text = String(data: manifestData, encoding: .utf8) else {
            throw NSError(domain: "UpdateService", code: 11, userInfo: [
                NSLocalizedDescriptionKey: tr(
                    "SHA256SUMS.txt har ugyldig tegnkoding. Oppdateringen ble avbrutt.",
                    "SHA256SUMS.txt is not valid UTF-8. Update aborted."
                )
            ])
        }

        var expectedHex: String? = nil
        for line in text.components(separatedBy: .newlines) {
            let parts = line.split(whereSeparator: { $0.isWhitespace })
            if parts.count >= 2 {
                let candidateFile = String(parts[1]).trimmingCharacters(in: CharacterSet(charactersIn: "*./"))
                if candidateFile.caseInsensitiveCompare(filename) == .orderedSame {
                    expectedHex = String(parts[0]).lowercased()
                    break
                }
            }
        }

        guard let expected = expectedHex,
              expected.count == 64,
              expected.allSatisfy(\.isHexDigit) else {
            throw NSError(domain: "UpdateService", code: 12, userInfo: [
                NSLocalizedDescriptionKey: tr(
                    "Fant ingen gyldig SHA-256-oppføring for \(filename) i SHA256SUMS.txt.",
                    "No valid SHA-256 entry found for \(filename) in SHA256SUMS.txt."
                )
            ])
        }

        let archiveData = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        let digest = SHA256.hash(data: archiveData)
        let actualHex = digest.map { String(format: "%02x", $0) }.joined()

        if actualHex != expected {
            throw NSError(domain: "UpdateService", code: 9, userInfo: [
                NSLocalizedDescriptionKey: tr(
                    "SHA-256-sjekksum stemte ikke med utgivelsen. Oppdateringen ble avbrutt.",
                    "SHA-256 checksum mismatch against release manifest. Update aborted."
                )
            ])
        }
    }

    private static func extractZip(at zipURL: URL, into directory: URL) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        proc.arguments = ["-x", "-k", zipURL.path, directory.path]
        try proc.run()
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            throw NSError(domain: "UpdateService", code: Int(proc.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: "Kunne ikke pakke ut oppdateringsarkiv."
            ])
        }
    }

    private static func verifyBundleIdentityAndSignature(at appURL: URL) throws {
        let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let plistData = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
              let bundleID = plist["CFBundleIdentifier"] as? String,
              bundleID == "com.flowfile.app" else {
            throw NSError(domain: "UpdateService", code: 8, userInfo: [
                NSLocalizedDescriptionKey: tr(
                    "Ugyldig applikasjons-ID i oppdateringspakken.",
                    "Invalid bundle identifier in update archive."
                )
            ])
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        proc.arguments = ["--verify", "--deep", "--strict", appURL.path]
        try proc.run()
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            throw NSError(domain: "UpdateService", code: Int(proc.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: tr(
                    "Kodesignaturen på oppdateringen kunne ikke bekreftes.",
                    "Code signature verification failed on downloaded update."
                )
            ])
        }

        // If the currently running bundle is signed with an Apple Developer TeamIdentifier,
        // enforce that the incoming bundle is signed by the exact same TeamIdentifier.
        let runningURL = Bundle.main.bundleURL.standardizedFileURL
        if runningURL.pathExtension == "app",
           let currentTeam = extractTeamIdentifier(for: runningURL) {
            let incomingTeam = extractTeamIdentifier(for: appURL)
            if incomingTeam != currentTeam {
                throw NSError(domain: "UpdateService", code: 13, userInfo: [
                    NSLocalizedDescriptionKey: tr(
                        "Utgiversertifikat (Team ID) på oppdateringen stemmer ikke med installert app.",
                        "Update TeamIdentifier does not match the installed application."
                    )
                ])
            }
        }
    }

    private static func extractTeamIdentifier(for appURL: URL) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        proc.arguments = ["-dv", "--verbose=2", appURL.path]
        let errPipe = Pipe()
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = errPipe
        do {
            try proc.run()
            let data = errPipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0,
                  let text = String(data: data, encoding: .utf8) else {
                return nil
            }
            for line in text.components(separatedBy: .newlines) where line.hasPrefix("TeamIdentifier=") {
                let value = String(line.dropFirst("TeamIdentifier=".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty && value != "not set" {
                    return value
                }
            }
            return nil
        } catch {
            return nil
        }
    }

    static func preflightValidateTargetLocation(_ destinationAppURL: URL) throws {
        let path = destinationAppURL.path
        if path.contains("/AppTranslocation/") {
            throw NSError(domain: "UpdateService", code: 14, userInfo: [
                NSLocalizedDescriptionKey: tr(
                    "FlowFile kjører fra en skrivebeskyttet karantene-sti (App Translocation). Flytt FlowFile.app til /Applications før du oppdaterer.",
                    "FlowFile is running from a read-only App Translocation path. Move FlowFile.app to /Applications before updating."
                )
            ])
        }

        let fm = FileManager.default
        let parentDir = destinationAppURL.deletingLastPathComponent()
        guard fm.isWritableFile(atPath: parentDir.path) else {
            throw NSError(domain: "UpdateService", code: 15, userInfo: [
                NSLocalizedDescriptionKey: tr(
                    "Mappen «\(parentDir.path)» er skrivebeskyttet (f.eks. et åpent diskbilde). Kopier FlowFile.app til /Applications først.",
                    "Folder '\(parentDir.path)' is not writable (e.g. a mounted disk image). Copy FlowFile.app to /Applications first."
                )
            ])
        }

        if fm.fileExists(atPath: path) && !fm.isWritableFile(atPath: path) {
            throw NSError(domain: "UpdateService", code: 16, userInfo: [
                NSLocalizedDescriptionKey: tr(
                    "Har ikke skriverettigheter til å oppdatere «\(path)».",
                    "Insufficient write permissions to update '\(path)'."
                )
            ])
        }
    }

    private static func resolveTargetAppLocation() -> URL {
        let runningURL = Bundle.main.bundleURL.standardizedFileURL
        if runningURL.pathExtension == "app" {
            return runningURL
        }
        return URL(fileURLWithPath: "/Applications/FlowFile.app")
    }

    private static func spawnAtomicUpdaterAndTerminate(
        newAppURL: URL,
        destinationAppURL: URL,
        stagingDir: URL
    ) throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let scriptURL = stagingDir.appendingPathComponent("apply-update.sh")

        let scriptContent = """
        #!/bin/zsh
        set -u
        LOG_FILE="/tmp/flowfile-update.log"
        exec >>"$LOG_FILE" 2>&1
        echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Starting FlowFile atomic update for PID $FF_PID"

        for i in {1..50}; do
            if ! kill -0 "$FF_PID" 2>/dev/null; then
                break
            fi
            sleep 0.2
        done

        if kill -0 "$FF_PID" 2>/dev/null; then
            echo "ERROR: Old FlowFile process $FF_PID did not terminate in time; aborting update."
            rm -rf "$FF_STAGE_DIR" 2>/dev/null || true
            exit 1
        fi

        NEW_STAGE="${FF_DEST_APP}.new_$$"
        BACKUP_APP="${FF_DEST_APP}.backup_$$"
        rm -rf "$NEW_STAGE" "$BACKUP_APP" 2>/dev/null || true

        if ! /usr/bin/ditto "$FF_NEW_APP" "$NEW_STAGE"; then
            echo "ERROR: Failed to stage new app bundle to $NEW_STAGE"
            rm -rf "$NEW_STAGE" "$FF_STAGE_DIR" 2>/dev/null || true
            open "$FF_DEST_APP" || true
            exit 1
        fi

        if [[ -e "$FF_DEST_APP" ]]; then
            if ! mv "$FF_DEST_APP" "$BACKUP_APP"; then
                echo "ERROR: Failed to move existing app to backup $BACKUP_APP"
                rm -rf "$NEW_STAGE" "$FF_STAGE_DIR" 2>/dev/null || true
                open "$FF_DEST_APP" || true
                exit 1
            fi
        fi

        if mv "$NEW_STAGE" "$FF_DEST_APP"; then
            rm -rf "$BACKUP_APP" "$FF_STAGE_DIR" 2>/dev/null || true
            echo "Update succeeded; relaunching $FF_DEST_APP"
            open "$FF_DEST_APP"
        else
            echo "ERROR: Failed to move $NEW_STAGE into $FF_DEST_APP; restoring backup"
            if [[ -e "$BACKUP_APP" ]]; then
                mv "$BACKUP_APP" "$FF_DEST_APP" 2>/dev/null || true
            fi
            rm -rf "$NEW_STAGE" "$FF_STAGE_DIR" 2>/dev/null || true
            open "$FF_DEST_APP" || true
            exit 1
        fi
        """

        try scriptContent.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/bin/zsh")
        launcher.arguments = [scriptURL.path]
        var env = ProcessInfo.processInfo.environment
        env["FF_PID"] = String(pid)
        env["FF_NEW_APP"] = newAppURL.path
        env["FF_DEST_APP"] = destinationAppURL.path
        env["FF_STAGE_DIR"] = stagingDir.path
        launcher.environment = env
        launcher.standardOutput = FileHandle.nullDevice
        launcher.standardError = FileHandle.nullDevice
        try launcher.run()

        NSApp.terminate(nil)
    }
}
