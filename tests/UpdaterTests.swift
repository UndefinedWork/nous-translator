import AppKit
import CryptoKit
import Foundation
#if canImport(NousCore)
@testable import NousCore
#endif

@main struct UpdaterTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nous-updater-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        // 1. SemVer parsing & ordering
        let v060b3 = ReleaseVersion("v0.6.0-beta.3")!
        let v060b10 = ReleaseVersion("0.6.0-beta.10")!
        let v060 = ReleaseVersion("0.6.0")!
        let v061a1 = ReleaseVersion("0.6.1-alpha.1")!
        let v061 = ReleaseVersion("0.6.1")!
        let v100 = ReleaseVersion("1.0.0")!
        precondition(v060b3 < v060b10, "Numeric prerelease segment 10 > 3")
        precondition(v060b10 < v060, "Stable > prerelease of same core version")
        precondition(v060 < v061a1 && v061a1 < v061 && v061 < v100)
        precondition(v060b3.isPrerelease && !v060.isPrerelease)
        precondition(ReleaseVersion("") == nil && ReleaseVersion("abc") == nil && ReleaseVersion("0.6.0-") == nil)

        // 2. Host & URL security policy
        precondition(UpdaterRules.isAllowedURL(URL(string: "https://api.github.com/repos/UndefinedWork/nous-translator/releases")!))
        precondition(UpdaterRules.isAllowedURL(URL(string: "https://github.com/UndefinedWork/nous-translator/releases/download/v0.7.0/app.zip")!))
        precondition(UpdaterRules.isAllowedURL(URL(string: "https://objects.githubusercontent.com/github-production-release-asset/123")!))
        precondition(!UpdaterRules.isAllowedURL(URL(string: "http://github.com/UndefinedWork/nous-translator/releases")!), "HTTP GitHub URLs must be rejected")
        precondition(!UpdaterRules.isAllowedURL(URL(string: "https://evil.example.com/app.zip")!), "Non-GitHub hosts must be rejected")
        precondition(!UpdaterRules.isAllowedURL(URL(string: "http://127.0.0.1:8080/releases")!, allowLoopback: false))
        precondition(UpdaterRules.isAllowedURL(URL(string: "http://127.0.0.1:8080/releases")!, allowLoopback: true))

        // 3. Checksum parsing & OS compatibility
        let sums = UpdaterRules.parseSHA256Sums("""
        a674e4c55c0beb76e2a02f5cd7e943a448e7de5fdec23b8262ea38753a55f400  Nous-Translator-0.6.0-beta.3-macOS-arm64.zip
        6370122c9d054ae2d88d5bb8f5e6ff6eea1a1bc48416536c2243766a9c8a9fe6  release.json
        not-a-valid-hash  ignored.zip
        """)
        precondition(sums["Nous-Translator-0.6.0-beta.3-macOS-arm64.zip"] == "a674e4c55c0beb76e2a02f5cd7e943a448e7de5fdec23b8262ea38753a55f400")
        precondition(sums["release.json"] == "6370122c9d054ae2d88d5bb8f5e6ff6eea1a1bc48416536c2243766a9c8a9fe6")
        precondition(sums["ignored.zip"] == nil)
        precondition(UpdaterRules.isOSCompatible(minimum: "14.0", current: OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0)))
        precondition(UpdaterRules.isOSCompatible(minimum: "14.0", current: OperatingSystemVersion(majorVersion: 27, minorVersion: 3, patchVersion: 0)))
        precondition(!UpdaterRules.isOSCompatible(minimum: "15.2", current: OperatingSystemVersion(majorVersion: 15, minorVersion: 1, patchVersion: 9)))

        // 4. In-place replacement path checks
        if case .success = UpdaterRules.canReplaceInPlace(appURL: URL(fileURLWithPath: "/Volumes/Nous Translator/Nous Translator.app")) {
            fatalError("Mounted DMG path must be rejected")
        }
        if case .success = UpdaterRules.canReplaceInPlace(appURL: URL(fileURLWithPath: "/private/var/folders/AppTranslocation/abc/Nous Translator.app")) {
            fatalError("App Translocation path must be rejected")
        }
        let installedApp = folder.appendingPathComponent("Nous Translator.app")
        try FileManager.default.createDirectory(at: installedApp, withIntermediateDirectories: true)
        if case .failure(let error) = UpdaterRules.canReplaceInPlace(appURL: installedApp) {
            fatalError("Writable .app bundle should be allowed: \(error.localizedDescription)")
        }

        // 5. Status bar badge icon rendering
        precondition(StatusBarIcon.image(hasUpdate: false) != nil)
        precondition(StatusBarIcon.image(hasUpdate: true) != nil)

        // 6. Shell syntax validation & real atomic swap + rollback test on detachedInstallScript
        let syntaxCheck = Process()
        syntaxCheck.executableURL = URL(fileURLWithPath: "/bin/sh")
        syntaxCheck.arguments = ["-n", "-c", UpdaterRules.detachedInstallScript]
        try syntaxCheck.run(); syntaxCheck.waitUntilExit()
        precondition(syntaxCheck.terminationStatus == 0, "Updater shell script must pass /bin/sh -n syntax check")

        // Build two real ad-hoc signed dummy apps to exercise atomic swap and bad-signature rollback.
        func makeSignedApp(at appURL: URL, version: String, sign: Bool) throws {
            let macos = appURL.appendingPathComponent("Contents/MacOS")
            let runtime = appURL.appendingPathComponent("Contents/Resources/Runtime")
            try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
            let exe = macos.appendingPathComponent("NousTranslator")
            let helper = runtime.appendingPathComponent("llama-server")
            try "#!/bin/sh\nexit 0\n".write(to: exe, atomically: true, encoding: .utf8)
            try "#!/bin/sh\nexit 0\n".write(to: helper, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
            let info: [String: Any] = [
                "CFBundleExecutable": "NousTranslator",
                "CFBundleIdentifier": "com.nous.translator",
                "CFBundleName": "Nous Translator",
                "CFBundlePackageType": "APPL",
                "CFBundleShortVersionString": "0.7.0",
                "CFBundleVersion": "11",
                "NousReleaseVersion": version,
                "NousReleaseChannel": "preview"
            ]
            let plistData = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            try plistData.write(to: appURL.appendingPathComponent("Contents/Info.plist"))
            if sign {
                let cs = Process()
                cs.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
                cs.arguments = ["--force", "--sign", "-", appURL.path]
                cs.standardOutput = FileHandle.nullDevice; cs.standardError = FileHandle.nullDevice
                try cs.run(); cs.waitUntilExit()
                precondition(cs.terminationStatus == 0)
            }
        }

        // Test rollback when staged app has a broken signature (replace /usr/bin/open with /usr/bin/true so no GUI opens).
        let rollbackScript = UpdaterRules.detachedInstallScript
            .replacingOccurrences(of: "/usr/bin/open", with: "/usr/bin/true")
            .replacingOccurrences(of: "/bin/ps -ax -o comm= | /usr/bin/grep -Fxq \"$exe\"", with: "true")
        let targetForSwap = folder.appendingPathComponent("SwapTarget.app")
        let badStaged = folder.appendingPathComponent(".SwapStaged-bad.app")
        let backupSlot = folder.appendingPathComponent("Backups/test1/Previous.bundle-backup")
        let cleanupSlot = folder.appendingPathComponent("cleanup-bad")
        try FileManager.default.createDirectory(at: cleanupSlot, withIntermediateDirectories: true)
        try makeSignedApp(at: targetForSwap, version: "0.6.0-beta.3", sign: true)
        try makeSignedApp(at: badStaged, version: "0.7.0-beta.1", sign: false) // Unsigned -> fails codesign --verify!
        // Run with an already-exited PID (999999)
        let rollbackProc = Process()
        rollbackProc.executableURL = URL(fileURLWithPath: "/bin/sh")
        rollbackProc.arguments = ["-c", rollbackScript, "--", "999999", targetForSwap.path, badStaged.path, backupSlot.path, cleanupSlot.path, "0"]
        try rollbackProc.run(); rollbackProc.waitUntilExit()
        precondition(rollbackProc.terminationStatus == 2, "Broken signature must trigger rollback exit code 2")
        let rolledBackPlist = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: targetForSwap.appendingPathComponent("Contents/Info.plist")),
            format: nil
        ) as! [String: Any]
        precondition(rolledBackPlist["NousReleaseVersion"] as? String == "0.6.0-beta.3", "Rollback must restore original app version")

        // Test successful atomic swap when staged app is validly signed!
        let goodStaged = folder.appendingPathComponent(".SwapStaged-good.app")
        let backupSlot2 = folder.appendingPathComponent("Backups/test2/Previous.bundle-backup")
        let cleanupSlot2 = folder.appendingPathComponent("cleanup-good")
        try FileManager.default.createDirectory(at: cleanupSlot2, withIntermediateDirectories: true)
        try makeSignedApp(at: goodStaged, version: "0.7.0-beta.1", sign: true)
        let swapProc = Process()
        swapProc.executableURL = URL(fileURLWithPath: "/bin/sh")
        swapProc.arguments = ["-c", rollbackScript, "--", "999999", targetForSwap.path, goodStaged.path, backupSlot2.path, cleanupSlot2.path, "0"]
        try swapProc.run(); swapProc.waitUntilExit()
        precondition(swapProc.terminationStatus == 0, "Valid signed update must atomically swap")
        let swappedPlist = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: targetForSwap.appendingPathComponent("Contents/Info.plist")),
            format: nil
        ) as! [String: Any]
        precondition(swappedPlist["NousReleaseVersion"] as? String == "0.7.0-beta.1", "Target must now contain the new release")
        precondition(!FileManager.default.fileExists(atPath: cleanupSlot2.path), "Cleanup dir must be removed after swap")

        // 7. End-to-end loopback mock GitHub Releases API tests (channel filtering, ETag 304, skip, SHA-256 mismatch)
        let badZip = folder.appendingPathComponent("Nous-Translator-0.7.0-beta.1-macOS-arm64.zip")
        try Data("not-a-valid-zip-but-has-hash".utf8).write(to: badZip)
        let badZipSHA = SHA256.hash(data: try Data(contentsOf: badZip)).map { String(format: "%02x", $0) }.joined()
        let wrongSHA = String(repeating: "f", count: 64)

        let server = Process(), pipe = Pipe()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-u", "-c", #"""
import json, pathlib, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

zip_bytes = pathlib.Path(sys.argv[1]).read_bytes()
real_sha = sys.argv[2]
wrong_sha = sys.argv[3]
etag = '"releases-v1"'

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self):
        base = f'http://127.0.0.1:{self.server.server_port}'
        if self.path.startswith('/releases'):
            if self.headers.get('If-None-Match') == etag:
                self.send_response(304)
                self.end_headers()
                return
            payload = [
                {
                    "tag_name": "v0.8.0-beta.1",
                    "name": "Draft Release",
                    "body": "Should be ignored",
                    "draft": True,
                    "prerelease": True,
                    "html_url": f"{base}/html/v0.8.0-beta.1",
                    "published_at": "2026-11-28T00:00:00Z",
                    "assets": []
                },
                {
                    "tag_name": "v0.7.0-beta.1",
                    "name": "Nous Translator 0.7.0-beta.1",
                    "body": "New in-app updater and global shortcuts.",
                    "draft": False,
                    "prerelease": True,
                    "html_url": f"{base}/html/v0.7.0-beta.1",
                    "published_at": "2026-11-28T00:00:00Z",
                    "assets": [
                        {"name": "Nous-Translator-0.7.0-beta.1-macOS-arm64.zip", "browser_download_url": f"{base}/download/good.zip", "size": len(zip_bytes)},
                        {"name": "SHA256SUMS.txt", "browser_download_url": f"{base}/download/SHA256SUMS-wrong.txt", "size": 120}
                    ]
                },
                {
                    "tag_name": "v0.6.0-beta.3",
                    "name": "Nous Translator 0.6.0-beta.3",
                    "body": "Current release",
                    "draft": False,
                    "prerelease": True,
                    "html_url": f"{base}/html/v0.6.0-beta.3",
                    "published_at": "2026-11-20T00:00:00Z",
                    "assets": [
                        {"name": "Nous-Translator-0.6.0-beta.3-macOS-arm64.zip", "browser_download_url": f"{base}/download/good.zip", "size": len(zip_bytes)},
                        {"name": "SHA256SUMS.txt", "browser_download_url": f"{base}/download/SHA256SUMS-ok.txt", "size": 120}
                    ]
                }
            ]
            body = json.dumps(payload).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('ETag', etag)
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        elif self.path == '/download/SHA256SUMS-wrong.txt':
            body = f'{wrong_sha}  Nous-Translator-0.7.0-beta.1-macOS-arm64.zip\n'.encode()
            self.send_response(200); self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)
        elif self.path == '/download/good.zip':
            self.send_response(200); self.send_header('Content-Length', str(len(zip_bytes))); self.end_headers(); self.wfile.write(zip_bytes)
        else:
            self.send_error(404)

srv = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
print(srv.server_port, flush=True)
srv.serve_forever()
"""#, badZip.path, badZipSHA, wrongSHA]
        server.standardOutput = pipe
        server.standardError = FileHandle.nullDevice
        try server.run()
        defer { server.terminate(); server.waitUntilExit() }
        let port = String(data: pipe.fileHandleForReading.availableData, encoding: .utf8)!.trimmingCharacters(in: .whitespacesAndNewlines)
        precondition(Int(port) != nil)

        let suite = "nous-updater-suite-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let apiURL = URL(string: "http://127.0.0.1:\(port)/releases")!
        let updater = AppUpdater(
            defaults: defaults,
            currentVersionString: "0.6.0-beta.3",
            currentChannel: "preview",
            releasesAPIURL: apiURL,
            allowLoopback: true,
            targetAppURLProvider: { targetForSwap }
        )
        var discoveredCount = 0
        updater.onUpdateDiscovered = { _ in discoveredCount += 1 }

        // Background check discovers 0.7.0-beta.1 and fires toast callback once.
        await updater.checkForUpdates(userInitiated: false)
        precondition(updater.availableUpdate?.version == ReleaseVersion("0.7.0-beta.1"), "Should find 0.7.0-beta.1")
        precondition(discoveredCount == 1, "Background discovery should notify once")

        // Second background check hits HTTP 304 ETag and does NOT re-trigger toast.
        await updater.checkForUpdates(userInitiated: false)
        precondition(discoveredCount == 1, "ETag 304 must not re-fire toast for same version")

        // Disabling preview channel hides prerelease updates.
        updater.includePrereleases = false
        await updater.checkForUpdates(userInitiated: true)
        precondition(updater.state == .upToDate && updater.availableUpdate == nil, "Stable-only mode must ignore beta releases")

        // Re-enabling preview channel finds it again; skipping hides it on background checks.
        updater.includePrereleases = true
        await updater.checkForUpdates(userInitiated: true)
        guard let found = updater.availableUpdate else { fatalError("Expected update after re-enabling preview") }
        updater.skip(found)
        precondition(!updater.hasVisibleUpdate)
        await updater.checkForUpdates(userInitiated: false)
        precondition(updater.state == .idle, "Skipped version must stay suppressed during background checks")

        // Download with mismatched SHA-256 fails cleanly without touching installed app.
        updater.downloadAndInstall(found)
        for _ in 0..<200 {
            if case .failed = updater.state { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        guard case let .failed(msg, _) = updater.state else {
            fatalError("Expected SHA-256 mismatch failure, got \(updater.state)")
        }
        precondition(msg.contains("SHA-256"), "Error should clearly report SHA-256 mismatch: \(msg)")

        print("PASS: SemVer precedence, GitHub host/HTTPS guard, SHA256SUMS & OS checks, in-place path guards, badge icon, shell syntax, real atomic swap & bad-signature rollback, ETag 304, prerelease channel filter, skip persistence, and SHA-256 tamper rejection")
    }
}
