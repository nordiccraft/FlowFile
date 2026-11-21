import Darwin
import Foundation
import UniformTypeIdentifiers

/// Preserves macOS Gatekeeper protection for content extracted from downloaded archives.
///
/// When a downloaded `.zip` carries `com.apple.quarantine`, everything extracted from it must carry the same
/// attribute. Otherwise Gatekeeper/XProtect never checks extracted apps, scripts or `.command` files.
enum QuarantineService {
    static let attributeName = "com.apple.quarantine"

    /// Reads the raw quarantine attribute value of a file (nil when the file is not quarantined).
    static func quarantineValue(of url: URL) -> Data? {
        let path = url.path
        let size = getxattr(path, attributeName, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var buffer = Data(count: size)
        let read = buffer.withUnsafeMutableBytes { raw -> Int in
            getxattr(path, attributeName, raw.baseAddress, size, 0, 0)
        }
        guard read > 0 else { return nil }
        return buffer.prefix(read)
    }

    static func isQuarantined(_ url: URL) -> Bool {
        quarantineValue(of: url) != nil
    }

    /// Copies the archive's quarantine attribute onto every extracted item (recursively). No-op when the archive
    /// itself is not quarantined.
    static func propagate(from archiveURL: URL, to extractedRoots: [URL]) {
        guard let value = quarantineValue(of: archiveURL) else { return }
        let fm = FileManager.default
        for root in extractedRoots {
            apply(value, to: root)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue,
                  let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil, options: [], errorHandler: { _, _ in true }) else {
                continue
            }
            while let child = enumerator.nextObject() as? URL {
                apply(value, to: child)
            }
        }
    }

    private static func apply(_ value: Data, to url: URL) {
        _ = value.withUnsafeBytes { raw in
            setxattr(url.path, attributeName, raw.baseAddress, value.count, 0, XATTR_NOFOLLOW)
        }
    }

    /// File types that can execute code when opened (apps, scripts, installers, Terminal/Automator documents).
    static func isPotentiallyExecutable(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        let riskyExtensions: Set<String> = [
            "app", "command", "tool", "terminal", "sh", "zsh", "bash", "csh", "ksh", "py", "rb", "pl", "php",
            "scpt", "scptd", "applescript", "workflow", "action", "pkg", "mpkg", "dmg", "jar", "webloc",
            "inetloc", "fileloc", "osax", "prefpane", "kext", "plugin", "bundle", "dylib", "so", "url"
        ]
        if riskyExtensions.contains(ext) { return true }
        if let type = UTType(filenameExtension: ext) {
            if type.conforms(to: .executable) || type.conforms(to: .application) || type.conforms(to: .script) {
                return true
            }
        }
        // Extensionless Mach-O / shell scripts with the executable bit set
        if ext.isEmpty, FileManager.default.isExecutableFile(atPath: url.path) {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue {
                return true
            }
        }
        return false
    }
}
