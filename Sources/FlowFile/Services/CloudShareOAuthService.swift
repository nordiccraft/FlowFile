import AppKit
import CryptoKit
import Foundation
import Network
import Observation
import Security

enum CloudShareOAuthError: LocalizedError {
    case missingClientID(provider: String)
    case notSignedIn(provider: String)
    case loopbackStartFailed(String)
    case authorizationTimedOut
    case authorizationDenied(String)
    case stateMismatch
    case tokenExchangeFailed(String)
    case apiError(provider: String, statusCode: Int, message: String)
    case adminConsentOrPolicyBlocked(provider: String, detail: String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingClientID(let provider):
            return tr(
                "\(provider) Client ID mangler. Legg inn Client ID under Innstillinger → Direkte skydeling.",
                "\(provider) Client ID is not configured. Add your Client ID in Settings → Direct Cloud Sharing."
            )
        case .notSignedIn(let provider):
            return tr(
                "Du er ikke logget inn på \(provider). Logg inn under Innstillinger → Direkte skydeling.",
                "You are not signed in to \(provider). Sign in under Settings → Direct Cloud Sharing."
            )
        case .loopbackStartFailed(let msg):
            return tr(
                "Kunne ikke starte lokal OAuth-mottaker: \(msg)",
                "Could not start local OAuth callback listener: \(msg)"
            )
        case .authorizationTimedOut:
            return tr(
                "Påloggingen tidsavbrøt. Prøv igjen og fullfør påloggingen i nettleseren.",
                "Sign-in timed out. Please try again and complete sign-in in your browser."
            )
        case .authorizationDenied(let reason):
            return tr(
                "Påloggingen ble avbrutt eller avvist: \(reason)",
                "Sign-in was cancelled or denied: \(reason)"
            )
        case .stateMismatch:
            return tr(
                "Sikkerhetssjekk (OAuth state) feilet. Prøv på nytt.",
                "OAuth state verification failed. Please try again."
            )
        case .tokenExchangeFailed(let detail):
            return tr(
                "Kunne ikke hente tilgangstoken: \(detail)",
                "Could not exchange authorization token: \(detail)"
            )
        case .apiError(let provider, let code, let message):
            return tr(
                "\(provider) API-feil (\(code)): \(message)",
                "\(provider) API error (\(code)): \(message)"
            )
        case .adminConsentOrPolicyBlocked(let provider, let detail):
            return tr(
                "\(provider) blokkerte delingslenken (403 – IT-policy eller Admin Consent kreves): \(detail)",
                "\(provider) blocked link creation (403 – tenant policy or Admin Consent required): \(detail)"
            )
        case .invalidResponse:
            return tr(
                "Ugyldig svar fra skytjenesten.",
                "Invalid response from cloud service."
            )
        }
    }
}

private struct OAuthTokenBundle: Codable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date
    var accountEmail: String?
}

@Observable
@MainActor
final class CloudShareOAuthService {
    static let shared = CloudShareOAuthService()

    private static let msClientIDDefaultsKey = "flowfile.oauth.microsoftClientID"
    private static let googleClientIDDefaultsKey = "flowfile.oauth.googleClientID"
    private static let keychainService = "com.flowfile.app.oauth"
    private static let msKeychainAccount = "microsoft"
    private static let googleKeychainAccount = "google"

    var microsoftClientID: String {
        didSet {
            UserDefaults.standard.set(microsoftClientID, forKey: Self.msClientIDDefaultsKey)
        }
    }

    var googleClientID: String {
        didSet {
            UserDefaults.standard.set(googleClientID, forKey: Self.googleClientIDDefaultsKey)
        }
    }

    var isMicrosoftSignedIn: Bool = false
    var microsoftAccountEmail: String? = nil

    var isGoogleSignedIn: Bool = false
    var googleAccountEmail: String? = nil

    private init() {
        self.microsoftClientID = UserDefaults.standard.string(forKey: Self.msClientIDDefaultsKey) ?? ""
        self.googleClientID = UserDefaults.standard.string(forKey: Self.googleClientIDDefaultsKey) ?? ""
        reloadKeychainState()
    }

    private func reloadKeychainState() {
        if let ms = Self.loadTokenBundle(account: Self.msKeychainAccount) {
            isMicrosoftSignedIn = true
            microsoftAccountEmail = ms.accountEmail
        } else {
            isMicrosoftSignedIn = false
            microsoftAccountEmail = nil
        }

        if let gg = Self.loadTokenBundle(account: Self.googleKeychainAccount) {
            isGoogleSignedIn = true
            googleAccountEmail = gg.accountEmail
        } else {
            isGoogleSignedIn = false
            googleAccountEmail = nil
        }
    }

    // MARK: - Microsoft Sign-In / Sign-Out (Entra ID / MSA Multi-Tenant PKCE)

    func signInMicrosoft() async throws {
        let clientID = microsoftClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty else {
            throw CloudShareOAuthError.missingClientID(provider: "Microsoft")
        }

        let verifier = Self.generatePKCEVerifier()
        let challenge = Self.pkceChallenge(for: verifier)
        let state = Self.generateRandomHex(byteCount: 16)

        let callback = try await performLoopbackOAuth(state: state) { redirectURI in
            var comps = URLComponents(string: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize")!
            comps.queryItems = [
                URLQueryItem(name: "client_id", value: clientID),
                URLQueryItem(name: "response_type", value: "code"),
                URLQueryItem(name: "redirect_uri", value: redirectURI),
                URLQueryItem(name: "response_mode", value: "query"),
                URLQueryItem(name: "scope", value: "offline_access User.Read Files.ReadWrite"),
                URLQueryItem(name: "state", value: state),
                URLQueryItem(name: "code_challenge", value: challenge),
                URLQueryItem(name: "code_challenge_method", value: "S256"),
                URLQueryItem(name: "prompt", value: "select_account")
            ]
            return comps.url!
        }

        var tokenBundle = try await exchangeCodeForToken(
            tokenEndpoint: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token")!,
            formFields: [
                "client_id": clientID,
                "grant_type": "authorization_code",
                "code": callback.code,
                "redirect_uri": callback.redirectURI,
                "code_verifier": verifier,
                "scope": "offline_access User.Read Files.ReadWrite"
            ]
        )

        tokenBundle.accountEmail = await fetchMicrosoftAccountEmail(accessToken: tokenBundle.accessToken)
        Self.saveTokenBundle(tokenBundle, account: Self.msKeychainAccount)
        isMicrosoftSignedIn = true
        microsoftAccountEmail = tokenBundle.accountEmail
    }

    func signOutMicrosoft() {
        Self.deleteTokenBundle(account: Self.msKeychainAccount)
        isMicrosoftSignedIn = false
        microsoftAccountEmail = nil
    }

    // MARK: - Google Sign-In / Sign-Out (Drive API v3 Non-Sensitive `drive.file` PKCE)

    func signInGoogle() async throws {
        let clientID = googleClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty else {
            throw CloudShareOAuthError.missingClientID(provider: "Google")
        }

        let verifier = Self.generatePKCEVerifier()
        let challenge = Self.pkceChallenge(for: verifier)
        let state = Self.generateRandomHex(byteCount: 16)

        let callback = try await performLoopbackOAuth(state: state) { redirectURI in
            var comps = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
            comps.queryItems = [
                URLQueryItem(name: "client_id", value: clientID),
                URLQueryItem(name: "response_type", value: "code"),
                URLQueryItem(name: "redirect_uri", value: redirectURI),
                URLQueryItem(name: "scope", value: "https://www.googleapis.com/auth/drive.file email"),
                URLQueryItem(name: "state", value: state),
                URLQueryItem(name: "code_challenge", value: challenge),
                URLQueryItem(name: "code_challenge_method", value: "S256"),
                URLQueryItem(name: "access_type", value: "offline"),
                URLQueryItem(name: "prompt", value: "consent")
            ]
            return comps.url!
        }

        var tokenBundle = try await exchangeCodeForToken(
            tokenEndpoint: URL(string: "https://oauth2.googleapis.com/token")!,
            formFields: [
                "client_id": clientID,
                "grant_type": "authorization_code",
                "code": callback.code,
                "redirect_uri": callback.redirectURI,
                "code_verifier": verifier
            ]
        )

        tokenBundle.accountEmail = await fetchGoogleAccountEmail(accessToken: tokenBundle.accessToken)
        Self.saveTokenBundle(tokenBundle, account: Self.googleKeychainAccount)
        isGoogleSignedIn = true
        googleAccountEmail = tokenBundle.accountEmail
    }

    func signOutGoogle() {
        Self.deleteTokenBundle(account: Self.googleKeychainAccount)
        isGoogleSignedIn = false
        googleAccountEmail = nil
    }

    // MARK: - OneDrive Share Link Creation

    /// Creates a real OneDrive share link via Microsoft Graph API.
    /// If `fileURL` already resides inside a local OneDrive folder, attempts to share it in place via
    /// `/me/drive/root:/<relPath>:/createLink`. Otherwise (or if not found in the signed-in drive),
    /// uploads to `/FlowFile-Shares/<YYYY-MM-DD>/<filename>` (simple PUT <=4MB, resumable session >4MB)
    /// and creates the link on the uploaded item.
    func createOneDriveShareLink(for fileURL: URL, organizationOnly: Bool) async throws -> URL {
        let token = try await validMicrosoftAccessToken()

        // 1. If already inside a local OneDrive folder, try in-place Graph createLink (zero re-upload)
        if let relativePath = Self.oneDriveRelativePath(for: fileURL) {
            let encoded = Self.encodeGraphPath(relativePath)
            if let endpoint = URL(string: "https://graph.microsoft.com/v1.0/me/drive/root:/\(encoded):/createLink") {
                do {
                    return try await invokeOneDriveCreateLink(
                        endpoint: endpoint,
                        accessToken: token,
                        organizationOnly: organizationOnly
                    )
                } catch CloudShareOAuthError.apiError(_, let status, _) where status == 404 {
                    // File belongs to a different local OneDrive account than the signed-in Graph account; fall through to upload.
                }
            }
        }

        // 2. Upload to /FlowFile-Shares/<YYYY-MM-DD>/<filename>
        let itemID = try await uploadFileToOneDrive(fileURL: fileURL, accessToken: token)
        guard let linkEndpoint = URL(string: "https://graph.microsoft.com/v1.0/me/drive/items/\(itemID)/createLink") else {
            throw CloudShareOAuthError.invalidResponse
        }
        return try await invokeOneDriveCreateLink(
            endpoint: linkEndpoint,
            accessToken: token,
            organizationOnly: organizationOnly
        )
    }

    private func invokeOneDriveCreateLink(
        endpoint: URL,
        accessToken: String,
        organizationOnly: Bool
    ) async throws -> URL {
        let desiredScope = organizationOnly ? "organization" : "anonymous"
        do {
            return try await requestOneDriveCreateLink(
                endpoint: endpoint,
                accessToken: accessToken,
                scope: desiredScope
            )
        } catch CloudShareOAuthError.adminConsentOrPolicyBlocked(_, _) where !organizationOnly {
            // Many enterprise tenants disable anonymous links; gracefully retry with organization scope
            return try await requestOneDriveCreateLink(
                endpoint: endpoint,
                accessToken: accessToken,
                scope: "organization"
            )
        }
    }

    private func requestOneDriveCreateLink(
        endpoint: URL,
        accessToken: String,
        scope: String
    ) async throws -> URL {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "type": "view",
            "scope": scope
        ])

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw CloudShareOAuthError.invalidResponse
        }
        if http.statusCode == 403 {
            let msg = Self.extractErrorMessage(from: data) ?? "Forbidden"
            throw CloudShareOAuthError.adminConsentOrPolicyBlocked(provider: "OneDrive", detail: msg)
        }
        guard (200...299).contains(http.statusCode) else {
            let msg = Self.extractErrorMessage(from: data) ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw CloudShareOAuthError.apiError(provider: "OneDrive", statusCode: http.statusCode, message: msg)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let linkObj = json["link"] as? [String: Any],
              let webUrlStr = linkObj["webUrl"] as? String,
              let url = URL(string: webUrlStr) else {
            throw CloudShareOAuthError.invalidResponse
        }
        return url
    }

    private func uploadFileToOneDrive(fileURL: URL, accessToken: String) async throws -> String {
        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let fileSize = (attrs[.size] as? Int64) ?? 0

        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        let dateStamp = df.string(from: Date())
        let fileName = fileURL.lastPathComponent.precomposedStringWithCanonicalMapping
        let remotePath = "FlowFile-Shares/\(dateStamp)/\(fileName)"
        let encodedPath = Self.encodeGraphPath(remotePath)

        // Simple PUT for files <= 4 MB
        if fileSize <= 4 * 1_048_576 {
            guard let putURL = URL(string: "https://graph.microsoft.com/v1.0/me/drive/root:/\(encodedPath):/content") else {
                throw CloudShareOAuthError.invalidResponse
            }
            var req = URLRequest(url: putURL)
            req.httpMethod = "PUT"
            req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

            let (data, resp) = try await URLSession.shared.upload(for: req, fromFile: fileURL)
            guard let http = resp as? HTTPURLResponse else {
                throw CloudShareOAuthError.invalidResponse
            }
            if http.statusCode == 403 {
                throw CloudShareOAuthError.adminConsentOrPolicyBlocked(
                    provider: "OneDrive",
                    detail: Self.extractErrorMessage(from: data) ?? "Forbidden"
                )
            }
            guard (200...299).contains(http.statusCode),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = json["id"] as? String else {
                let msg = Self.extractErrorMessage(from: data) ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
                throw CloudShareOAuthError.apiError(provider: "OneDrive", statusCode: http.statusCode, message: msg)
            }
            return id
        }

        // Resumable upload session for files > 4 MB (chunk size must be a multiple of 320 KiB)
        guard let sessionURL = URL(string: "https://graph.microsoft.com/v1.0/me/drive/root:/\(encodedPath):/createUploadSession") else {
            throw CloudShareOAuthError.invalidResponse
        }
        var initReq = URLRequest(url: sessionURL)
        initReq.httpMethod = "POST"
        initReq.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        initReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        initReq.httpBody = try JSONSerialization.data(withJSONObject: [
            "item": ["@microsoft.graph.conflictBehavior": "rename"]
        ])

        let (initData, initResp) = try await URLSession.shared.data(for: initReq)
        guard let initHTTP = initResp as? HTTPURLResponse else {
            throw CloudShareOAuthError.invalidResponse
        }
        if initHTTP.statusCode == 403 {
            throw CloudShareOAuthError.adminConsentOrPolicyBlocked(
                provider: "OneDrive",
                detail: Self.extractErrorMessage(from: initData) ?? "Forbidden"
            )
        }
        guard (200...299).contains(initHTTP.statusCode),
              let initJSON = try? JSONSerialization.jsonObject(with: initData) as? [String: Any],
              let uploadUrlStr = initJSON["uploadUrl"] as? String,
              let uploadURL = URL(string: uploadUrlStr) else {
            let msg = Self.extractErrorMessage(from: initData) ?? HTTPURLResponse.localizedString(forStatusCode: initHTTP.statusCode)
            throw CloudShareOAuthError.apiError(provider: "OneDrive", statusCode: initHTTP.statusCode, message: msg)
        }

        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        let chunkSize = 10 * 327_680 // 3.2 MiB (exact multiple of 320 KiB)
        var offset: Int64 = 0
        var uploadedItemID: String? = nil

        while offset < fileSize {
            try handle.seek(toOffset: UInt64(offset))
            let remaining = fileSize - offset
            let toRead = Int(min(Int64(chunkSize), remaining))
            guard let chunk = try handle.read(upToCount: toRead), !chunk.isEmpty else { break }

            let endByte = offset + Int64(chunk.count) - 1
            var chunkReq = URLRequest(url: uploadURL)
            chunkReq.httpMethod = "PUT"
            chunkReq.setValue("bytes \(offset)-\(endByte)/\(fileSize)", forHTTPHeaderField: "Content-Range")
            chunkReq.setValue("\(chunk.count)", forHTTPHeaderField: "Content-Length")

            let (chunkData, chunkResp) = try await URLSession.shared.upload(for: chunkReq, from: chunk)
            guard let chunkHTTP = chunkResp as? HTTPURLResponse else {
                throw CloudShareOAuthError.invalidResponse
            }
            guard (200...299).contains(chunkHTTP.statusCode) else {
                let msg = Self.extractErrorMessage(from: chunkData) ?? HTTPURLResponse.localizedString(forStatusCode: chunkHTTP.statusCode)
                throw CloudShareOAuthError.apiError(provider: "OneDrive", statusCode: chunkHTTP.statusCode, message: msg)
            }
            if chunkHTTP.statusCode == 200 || chunkHTTP.statusCode == 201,
               let json = try? JSONSerialization.jsonObject(with: chunkData) as? [String: Any],
               let id = json["id"] as? String {
                uploadedItemID = id
            }
            offset += Int64(chunk.count)
        }

        guard let itemID = uploadedItemID else {
            throw CloudShareOAuthError.invalidResponse
        }
        return itemID
    }

    // MARK: - Google Drive Upload & Link Creation

    /// Uploads a file to Google Drive via API v3 resumable upload (streams from disk),
    /// optionally sets `anyone` reader permission, and returns the `webViewLink`.
    func uploadAndCreateGoogleDriveLink(for fileURL: URL, anyoneCanView: Bool) async throws -> URL {
        let token = try await validGoogleAccessToken()
        let fileName = fileURL.lastPathComponent.precomposedStringWithCanonicalMapping

        let folderID = try? await ensureGoogleDriveSharesFolder(accessToken: token)

        var metadata: [String: Any] = ["name": fileName]
        if let folderID {
            metadata["parents"] = [folderID]
        }

        // 1. Initiate resumable upload session
        guard let initURL = URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&fields=id,webViewLink") else {
            throw CloudShareOAuthError.invalidResponse
        }
        var initReq = URLRequest(url: initURL)
        initReq.httpMethod = "POST"
        initReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        initReq.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        initReq.setValue("application/octet-stream", forHTTPHeaderField: "X-Upload-Content-Type")
        if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
           let fileSize = attrs[.size] as? Int64 {
            initReq.setValue("\(fileSize)", forHTTPHeaderField: "X-Upload-Content-Length")
        }
        initReq.httpBody = try JSONSerialization.data(withJSONObject: metadata)

        let (initData, initResp) = try await URLSession.shared.data(for: initReq)
        guard let initHTTP = initResp as? HTTPURLResponse else {
            throw CloudShareOAuthError.invalidResponse
        }
        guard (200...299).contains(initHTTP.statusCode),
              let locationStr = initHTTP.value(forHTTPHeaderField: "Location"),
              let uploadURL = URL(string: locationStr) else {
            let msg = Self.extractErrorMessage(from: initData) ?? HTTPURLResponse.localizedString(forStatusCode: initHTTP.statusCode)
            throw CloudShareOAuthError.apiError(provider: "Google Drive", statusCode: initHTTP.statusCode, message: msg)
        }

        // 2. Stream file directly from disk to Google Drive resumable upload URL
        var uploadReq = URLRequest(url: uploadURL)
        uploadReq.httpMethod = "PUT"
        uploadReq.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

        let (uploadData, uploadResp) = try await URLSession.shared.upload(for: uploadReq, fromFile: fileURL)
        guard let uploadHTTP = uploadResp as? HTTPURLResponse else {
            throw CloudShareOAuthError.invalidResponse
        }
        guard (200...299).contains(uploadHTTP.statusCode),
              let uploadJSON = try? JSONSerialization.jsonObject(with: uploadData) as? [String: Any],
              let fileID = uploadJSON["id"] as? String else {
            let msg = Self.extractErrorMessage(from: uploadData) ?? HTTPURLResponse.localizedString(forStatusCode: uploadHTTP.statusCode)
            throw CloudShareOAuthError.apiError(provider: "Google Drive", statusCode: uploadHTTP.statusCode, message: msg)
        }

        // 3. Optionally grant "anyone with link can view" permission
        if anyoneCanView {
            guard let permURL = URL(string: "https://www.googleapis.com/drive/v3/files/\(fileID)/permissions") else {
                throw CloudShareOAuthError.invalidResponse
            }
            var permReq = URLRequest(url: permURL)
            permReq.httpMethod = "POST"
            permReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            permReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
            permReq.httpBody = try JSONSerialization.data(withJSONObject: [
                "role": "reader",
                "type": "anyone"
            ])
            let (permData, permResp) = try await URLSession.shared.data(for: permReq)
            if let permHTTP = permResp as? HTTPURLResponse, !(200...299).contains(permHTTP.statusCode) {
                let msg = Self.extractErrorMessage(from: permData) ?? HTTPURLResponse.localizedString(forStatusCode: permHTTP.statusCode)
                if permHTTP.statusCode == 403 {
                    throw CloudShareOAuthError.adminConsentOrPolicyBlocked(provider: "Google Drive", detail: msg)
                }
                throw CloudShareOAuthError.apiError(provider: "Google Drive", statusCode: permHTTP.statusCode, message: msg)
            }
        }

        if let linkStr = uploadJSON["webViewLink"] as? String, let linkURL = URL(string: linkStr) {
            return linkURL
        }

        // Fallback: fetch webViewLink explicitly
        guard let metaURL = URL(string: "https://www.googleapis.com/drive/v3/files/\(fileID)?fields=webViewLink") else {
            throw CloudShareOAuthError.invalidResponse
        }
        var metaReq = URLRequest(url: metaURL)
        metaReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (metaData, metaResp) = try await URLSession.shared.data(for: metaReq)
        guard let metaHTTP = metaResp as? HTTPURLResponse,
              (200...299).contains(metaHTTP.statusCode),
              let metaJSON = try? JSONSerialization.jsonObject(with: metaData) as? [String: Any],
              let linkStr = metaJSON["webViewLink"] as? String,
              let linkURL = URL(string: linkStr) else {
            throw CloudShareOAuthError.invalidResponse
        }
        return linkURL
    }

    private func ensureGoogleDriveSharesFolder(accessToken: String) async throws -> String {
        let query = "name='FlowFile Shares' and mimeType='application/vnd.google-apps.folder' and trashed=false"
        var comps = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        comps.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "fields", value: "files(id)"),
            URLQueryItem(name: "pageSize", value: "1")
        ]
        var listReq = URLRequest(url: comps.url!)
        listReq.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (listData, listResp) = try await URLSession.shared.data(for: listReq)
        if let http = listResp as? HTTPURLResponse, (200...299).contains(http.statusCode),
           let json = try? JSONSerialization.jsonObject(with: listData) as? [String: Any],
           let files = json["files"] as? [[String: Any]],
           let firstID = files.first?["id"] as? String {
            return firstID
        }

        var createReq = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files?fields=id")!)
        createReq.httpMethod = "POST"
        createReq.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        createReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        createReq.httpBody = try JSONSerialization.data(withJSONObject: [
            "name": "FlowFile Shares",
            "mimeType": "application/vnd.google-apps.folder"
        ])
        let (createData, createResp) = try await URLSession.shared.data(for: createReq)
        guard let http = createResp as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: createData) as? [String: Any],
              let folderID = json["id"] as? String else {
            throw CloudShareOAuthError.invalidResponse
        }
        return folderID
    }

    // MARK: - Microsoft Teams Deep Link Helper

    static func openTeamsChat(withShareURL url: URL, fileName: String) {
        // Always copy the share link to clipboard as a reliable fallback
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(url.absoluteString, forType: .string)

        let message = "\(fileName): \(url.absoluteString)"
        var comps = URLComponents()
        comps.scheme = "msteams"
        comps.path = "/l/chat/0/0"
        comps.queryItems = [
            URLQueryItem(name: "message", value: message)
        ]

        if let deepLink = comps.url, NSWorkspace.shared.open(deepLink) {
            return
        }

        // Fallback: bring New Teams (or Classic Teams) to front so user can press ⌘V
        if !ShareHubService.bringChatAppToFront(bundleID: "com.microsoft.teams2") {
            _ = ShareHubService.bringChatAppToFront(bundleID: "com.microsoft.teams")
        }
    }

    // MARK: - Token Refresh & User Profile

    private func validMicrosoftAccessToken() async throws -> String {
        guard var bundle = Self.loadTokenBundle(account: Self.msKeychainAccount) else {
            isMicrosoftSignedIn = false
            throw CloudShareOAuthError.notSignedIn(provider: "Microsoft OneDrive")
        }
        if bundle.expiresAt.timeIntervalSinceNow > 120 {
            return bundle.accessToken
        }
        guard let refreshToken = bundle.refreshToken else {
            signOutMicrosoft()
            throw CloudShareOAuthError.notSignedIn(provider: "Microsoft OneDrive")
        }
        let clientID = microsoftClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty else {
            throw CloudShareOAuthError.missingClientID(provider: "Microsoft")
        }
        var refreshed = try await exchangeCodeForToken(
            tokenEndpoint: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token")!,
            formFields: [
                "client_id": clientID,
                "grant_type": "refresh_token",
                "refresh_token": refreshToken,
                "scope": "offline_access User.Read Files.ReadWrite"
            ]
        )
        if refreshed.refreshToken == nil {
            refreshed.refreshToken = refreshToken
        }
        refreshed.accountEmail = bundle.accountEmail
        bundle = refreshed
        Self.saveTokenBundle(bundle, account: Self.msKeychainAccount)
        return bundle.accessToken
    }

    private func validGoogleAccessToken() async throws -> String {
        guard var bundle = Self.loadTokenBundle(account: Self.googleKeychainAccount) else {
            isGoogleSignedIn = false
            throw CloudShareOAuthError.notSignedIn(provider: "Google Drive")
        }
        if bundle.expiresAt.timeIntervalSinceNow > 120 {
            return bundle.accessToken
        }
        guard let refreshToken = bundle.refreshToken else {
            signOutGoogle()
            throw CloudShareOAuthError.notSignedIn(provider: "Google Drive")
        }
        let clientID = googleClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty else {
            throw CloudShareOAuthError.missingClientID(provider: "Google")
        }
        var refreshed = try await exchangeCodeForToken(
            tokenEndpoint: URL(string: "https://oauth2.googleapis.com/token")!,
            formFields: [
                "client_id": clientID,
                "grant_type": "refresh_token",
                "refresh_token": refreshToken
            ]
        )
        if refreshed.refreshToken == nil {
            refreshed.refreshToken = refreshToken
        }
        refreshed.accountEmail = bundle.accountEmail
        bundle = refreshed
        Self.saveTokenBundle(bundle, account: Self.googleKeychainAccount)
        return bundle.accessToken
    }

    private func exchangeCodeForToken(
        tokenEndpoint: URL,
        formFields: [String: String]
    ) async throws -> OAuthTokenBundle {
        var req = URLRequest(url: tokenEndpoint)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.formURLEncodedBody(formFields)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw CloudShareOAuthError.invalidResponse
        }
        guard (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String else {
            let detail = Self.extractErrorMessage(from: data) ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw CloudShareOAuthError.tokenExchangeFailed(detail)
        }
        let refreshToken = json["refresh_token"] as? String
        let expiresIn = (json["expires_in"] as? Double) ?? Double((json["expires_in"] as? Int) ?? 3600)
        return OAuthTokenBundle(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: Date().addingTimeInterval(expiresIn),
            accountEmail: nil
        )
    }

    private func fetchMicrosoftAccountEmail(accessToken: String) async -> String? {
        guard let url = URL(string: "https://graph.microsoft.com/v1.0/me?$select=mail,userPrincipalName") else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let mail = json["mail"] as? String, !mail.isEmpty { return mail }
        return json["userPrincipalName"] as? String
    }

    private func fetchGoogleAccountEmail(accessToken: String) async -> String? {
        guard let url = URL(string: "https://www.googleapis.com/oauth2/v2/userinfo") else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json["email"] as? String
    }

    // MARK: - Loopback OAuth 2.0 Callback Server (`127.0.0.1:<ephemeral-port>`)

    private struct OAuthCallbackResult: Sendable {
        let code: String
        let redirectURI: String
    }

    private final class LockedFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        func testAndSet() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if value { return false }
            value = true
            return true
        }
    }

    private func performLoopbackOAuth(
        state expectedState: String,
        buildAuthURL: (String) -> URL
    ) async throws -> OAuthCallbackResult {
        let queue = DispatchQueue(label: "com.flowfile.oauth-loopback", qos: .userInitiated)
        let params = NWParameters.tcp
        params.acceptLocalOnly = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)

        let listener: NWListener
        do {
            listener = try NWListener(using: params)
        } catch {
            throw CloudShareOAuthError.loopbackStartFailed(error.localizedDescription)
        }

        // 1. Start listener and obtain ephemeral loopback port
        let port: UInt16 = try await withCheckedThrowingContinuation { cont in
            let resumed = LockedFlag()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let assigned = listener.port?.rawValue, resumed.testAndSet() {
                        cont.resume(returning: assigned)
                    }
                case .failed(let err):
                    if resumed.testAndSet() {
                        listener.cancel()
                        cont.resume(throwing: CloudShareOAuthError.loopbackStartFailed(err.localizedDescription))
                    }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }

        let redirectURI = "http://127.0.0.1:\(port)/callback"
        let authURL = buildAuthURL(redirectURI)

        // 2. Wait for single browser callback (180s timeout)
        return try await withCheckedThrowingContinuation { cont in
            let finished = LockedFlag()
            let complete: @Sendable (Result<OAuthCallbackResult, Error>) -> Void = { result in
                guard finished.testAndSet() else { return }
                listener.cancel()
                cont.resume(with: result)
            }

            let timeoutTask = Task.detached {
                try? await Task.sleep(nanoseconds: 180_000_000_000)
                complete(.failure(CloudShareOAuthError.authorizationTimedOut))
            }

            listener.newConnectionHandler = { connection in
                connection.start(queue: queue)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                    defer { connection.cancel() }
                    guard let data,
                          let text = String(data: data, encoding: .utf8),
                          let firstLine = text.components(separatedBy: "\r\n").first else {
                        return
                    }
                    let parts = firstLine.split(separator: " ")
                    guard parts.count >= 2 else { return }
                    let target = String(parts[1])
                    guard target.hasPrefix("/callback"),
                          let comps = URLComponents(string: "http://127.0.0.1\(target)") else {
                        let resp = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                        connection.send(content: Data(resp.utf8), completion: .contentProcessed { _ in })
                        return
                    }

                    let items = comps.queryItems ?? []
                    let code = items.first(where: { $0.name == "code" })?.value
                    let returnedState = items.first(where: { $0.name == "state" })?.value
                    let oauthError = items.first(where: { $0.name == "error_description" })?.value
                        ?? items.first(where: { $0.name == "error" })?.value

                    let ok = (code != nil && returnedState == expectedState && oauthError == nil)
                    let html = Self.oauthResultHTML(success: ok)
                    let body = Data(html.utf8)
                    let header = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                    var responseData = Data(header.utf8)
                    responseData.append(body)
                    connection.send(content: responseData, completion: .contentProcessed { _ in
                        timeoutTask.cancel()
                        if let oauthError {
                            complete(.failure(CloudShareOAuthError.authorizationDenied(oauthError)))
                        } else if returnedState != expectedState {
                            complete(.failure(CloudShareOAuthError.stateMismatch))
                        } else if let code {
                            complete(.success(OAuthCallbackResult(code: code, redirectURI: redirectURI)))
                        } else {
                            complete(.failure(CloudShareOAuthError.invalidResponse))
                        }
                    })
                }
            }

            DispatchQueue.main.async {
                NSWorkspace.shared.open(authURL)
            }
        }
    }

    nonisolated private static func oauthResultHTML(success: Bool) -> String {
        let title = success
            ? tr("Pålogging fullført", "Sign-in complete")
            : tr("Pålogging feilet", "Sign-in failed")
        let body = success
            ? tr("FlowFile er nå tilkoblet. Du kan lukke denne fanen og gå tilbake til FlowFile.", "FlowFile is now connected. You can close this tab and return to FlowFile.")
            : tr("Noe gikk galt under påloggingen. Gå tilbake til FlowFile og prøv igjen.", "Something went wrong during sign-in. Return to FlowFile and try again.")
        return """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"><title>FlowFile – \(title)</title>
        <style>body{font-family:-apple-system,sans-serif;background:#0f172a;color:#f8fafc;display:flex;align-items:center;justify-content:center;min-height:100vh;margin:0}
        .card{background:#1e293b;border-radius:16px;padding:28px;max-width:420px;text-align:center;box-shadow:0 20px 40px rgba(0,0,0,.35)}
        h2{margin:0 0 10px 0;font-size:20px}p{color:#94a3b8;font-size:14px;margin:0}</style>
        </head><body><div class="card"><h2>\(title)</h2><p>\(body)</p></div></body></html>
        """
    }

    // MARK: - Keychain Persistence

    private static func saveTokenBundle(_ bundle: OAuthTokenBundle, account: String) {
        guard let data = try? JSONEncoder().encode(bundle) else { return }
        deleteTokenBundle(account: account)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: account,
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    private static func loadTokenBundle(account: String) -> OAuthTokenBundle? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        return try? JSONDecoder().decode(OAuthTokenBundle.self, from: data)
    }

    private static func deleteTokenBundle(account: String) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Crypto & Path Helpers

    private static func generatePKCEVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URLEncode(Data(bytes))
    }

    private static func pkceChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URLEncode(Data(digest))
    }

    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func generateRandomHex(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func formURLEncodedBody(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let joined = fields.map { k, v in
            let ek = k.addingPercentEncoding(withAllowedCharacters: allowed) ?? k
            let ev = v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v
            return "\(ek)=\(ev)"
        }.joined(separator: "&")
        return Data(joined.utf8)
    }

    private static func oneDriveRelativePath(for fileURL: URL) -> String? {
        let accounts = CloudStorageService.discoverCloudAccounts().filter { $0.provider == .oneDrive }
        guard let account = CloudStorageService.cloudAccount(containing: fileURL, accounts: accounts) else {
            return nil
        }
        let rootPath = account.rootURL.standardizedFileURL.resolvingSymlinksInPath().path
        let filePath = fileURL.standardizedFileURL.resolvingSymlinksInPath().path
        guard filePath.hasPrefix(rootPath + "/") else { return nil }
        return String(filePath.dropFirst(rootPath.count + 1))
    }

    private static func encodeGraphPath(_ relativePath: String) -> String {
        relativePath
            .split(separator: "/")
            .map { seg in
                String(seg).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String(seg)
            }
            .joined(separator: "/")
    }

    private static func extractErrorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(data: data, encoding: .utf8)?.prefix(200).description
        }
        if let err = json["error"] as? [String: Any], let msg = err["message"] as? String {
            return msg
        }
        if let desc = json["error_description"] as? String {
            return desc
        }
        if let err = json["error"] as? String {
            return err
        }
        return nil
    }
}
