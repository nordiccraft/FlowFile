import CryptoKit
import Foundation
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
}
#else
@main
struct LocalCLTTestRunner {
    static func main() async throws {
        try await FlowFileVerificationSuite.runAll()
        print("ALL 12 FLOWFILE TEST SUITES PASSED")
    }
}
#endif
