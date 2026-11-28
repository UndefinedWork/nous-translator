import AppKit
import CryptoKit
import Foundation
import SwiftUI

/// SemVer representation supporting preview tags such as `0.6.0-beta.3`.
struct ReleaseVersion: Comparable, Equatable, Hashable, CustomStringConvertible {
    enum PrereleasePart: Comparable, Equatable, Hashable {
        case numeric(Int)
        case text(String)

        static func < (lhs: Self, rhs: Self) -> Bool {
            switch (lhs, rhs) {
            case let (.numeric(a), .numeric(b)): return a < b
            case let (.text(a), .text(b)): return a < b
            case (.numeric, .text): return true
            case (.text, .numeric): return false
            }
        }
    }

    let raw: String
    let major: Int
    let minor: Int
    let patch: Int
    let prerelease: [PrereleasePart]

    var isPrerelease: Bool { !prerelease.isEmpty }
    var description: String { raw }

    init?(_ string: String) {
        var trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("v") || trimmed.hasPrefix("V") {
            trimmed.removeFirst()
        }
        guard !trimmed.isEmpty else { return nil }
        let pieces = trimmed.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let coreParts = pieces[0].split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(coreParts.count),
              let major = Int(coreParts[0]), major >= 0,
              let minor = Int(coreParts[1]), minor >= 0 else { return nil }
        let patch: Int
        if coreParts.count == 3 {
            guard let parsed = Int(coreParts[2]), parsed >= 0 else { return nil }
            patch = parsed
        } else {
            patch = 0
        }
        var pre: [PrereleasePart] = []
        if pieces.count == 2 {
            let preString = String(pieces[1])
            guard !preString.isEmpty else { return nil }
            for segment in preString.split(separator: ".", omittingEmptySubsequences: false) {
                guard !segment.isEmpty else { return nil }
                if let num = Int(segment) {
                    pre.append(.numeric(num))
                } else {
                    pre.append(.text(String(segment).lowercased()))
                }
            }
        }
        self.raw = trimmed
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = pre
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        if lhs.prerelease.isEmpty && rhs.prerelease.isEmpty { return false }
        // Stable release > any prerelease of the same core version.
        if lhs.prerelease.isEmpty { return false }
        if rhs.prerelease.isEmpty { return true }
        for (a, b) in zip(lhs.prerelease, rhs.prerelease) where a != b {
            return a < b
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}

struct GitHubReleasePayload: Decodable {
    struct Asset: Decodable {
        let name: String
        let browserDownloadURL: String
        let size: Int64

        enum CodingKeys: String, CodingKey {
            case name, size
            case browserDownloadURL = "browser_download_url"
        }
    }

    let tagName: String
    let name: String?
    let body: String?
    let draft: Bool
    let prerelease: Bool
    let htmlURL: String
    let publishedAt: String?
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case name, body, draft, prerelease, assets
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case publishedAt = "published_at"
    }
}

struct ReleaseManifestPayload: Decodable {
    let release: String
    let channel: String
    let architecture: String
    let minimumMacOS: String
    let notarized: Bool?
    let assets: [String: String]

    enum CodingKeys: String, CodingKey {
        case release, channel, architecture, notarized, assets
        case minimumMacOS = "minimum_macos"
    }
}

struct AvailableUpdate: Equatable, Identifiable {
    var id: String { version.raw }
    let version: ReleaseVersion
    let title: String
    let notes: String
    let isPrerelease: Bool
    let htmlURL: URL
    let publishedAt: Date?
    let zipAssetName: String
    let zipURL: URL
    let zipSize: Int64
    let checksumsURL: URL
    let manifestURL: URL?
}

enum UpdaterRules {
    static let repository = "UndefinedWork/nous-translator"
    static let defaultReleasesAPI = URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=20")!
    static let releasesPageURL = URL(string: "https://github.com/\(repository)/releases")!
    static let maxArchiveBytes: Int64 = 250 * 1024 * 1024

    static func isAllowedURL(_ url: URL, allowLoopback: Bool = false) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host?.lowercased(), !host.isEmpty else { return false }
        if allowLoopback, components.scheme == "http", ["127.0.0.1", "localhost", "::1"].contains(host) {
            return true
        }
        guard components.scheme == "https" else { return false }
        if host == "api.github.com" || host == "github.com" { return true }
        return host.hasSuffix(".githubusercontent.com")
    }

    static func parseSHA256Sums(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let parts = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count == 2 else { continue }
            let digest = String(parts[0]).lowercased()
            var filename = String(parts[1]).trimmingCharacters(in: .whitespaces)
            if filename.hasPrefix("*") { filename.removeFirst() }
            guard digest.count == 64, digest.allSatisfy({ $0.isHexDigit }), !filename.isEmpty else { continue }
            result[filename] = digest
        }
        return result
    }

    static func isOSCompatible(minimum: String, current: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) -> Bool {
        let parts = minimum.split(separator: ".").compactMap { Int($0) }
        guard let minMajor = parts.first else { return true }
        let minMinor = parts.count > 1 ? parts[1] : 0
        let minPatch = parts.count > 2 ? parts[2] : 0
        if current.majorVersion != minMajor { return current.majorVersion > minMajor }
        if current.minorVersion != minMinor { return current.minorVersion > minMinor }
        return current.patchVersion >= minPatch
    }

    static func selectUpdate(
        from releases: [GitHubReleasePayload],
        currentVersion: ReleaseVersion,
        includePrereleases: Bool,
        architecture: String = "arm64",
        allowLoopback: Bool = false
    ) -> AvailableUpdate? {
        let iso = ISO8601DateFormatter()
        var best: AvailableUpdate?
        for release in releases {
            guard !release.draft else { continue }
            if !includePrereleases && release.prerelease { continue }
            guard let version = ReleaseVersion(release.tagName) else { continue }
            if !includePrereleases && version.isPrerelease { continue }
            guard version > currentVersion else { continue }
            guard let htmlURL = URL(string: release.htmlURL),
                  isAllowedURL(htmlURL, allowLoopback: allowLoopback) else { continue }

            let expectedZipSuffix = "-macOS-\(architecture).zip"
            guard let zipAsset = release.assets.first(where: {
                $0.name.hasPrefix("Nous-Translator-") && $0.name.hasSuffix(expectedZipSuffix)
            }),
                  let zipURL = URL(string: zipAsset.browserDownloadURL),
                  isAllowedURL(zipURL, allowLoopback: allowLoopback),
                  zipAsset.size <= maxArchiveBytes else { continue }

            guard let sumsAsset = release.assets.first(where: { $0.name == "SHA256SUMS.txt" }),
                  let checksumsURL = URL(string: sumsAsset.browserDownloadURL),
                  isAllowedURL(checksumsURL, allowLoopback: allowLoopback) else { continue }

            let manifestURL: URL? = release.assets
                .first(where: { $0.name == "release.json" })
                .flatMap { URL(string: $0.browserDownloadURL) }
                .flatMap { isAllowedURL($0, allowLoopback: allowLoopback) ? $0 : nil }

            let candidate = AvailableUpdate(
                version: version,
                title: (release.name?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? "Nous Translator \(version.raw)",
                notes: (release.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                isPrerelease: release.prerelease || version.isPrerelease,
                htmlURL: htmlURL,
                publishedAt: release.publishedAt.flatMap { iso.date(from: $0) },
                zipAssetName: zipAsset.name,
                zipURL: zipURL,
                zipSize: zipAsset.size,
                checksumsURL: checksumsURL,
                manifestURL: manifestURL
            )
            if best == nil || candidate.version > best!.version {
                best = candidate
            }
        }
        return best
    }

    static func canReplaceInPlace(appURL: URL) -> Result<Void, ModelError> {
        let resolved = appURL.standardizedFileURL
        guard resolved.pathExtension == "app" else {
            return .failure(.message(L10n.text(
                "In-app update requires running from an installed Nous Translator.app bundle.",
                zh: "应用内更新需要从已安装的 Nous Translator.app 运行。"
            )))
        }
        if let values = try? resolved.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink == true {
            return .failure(.message(L10n.text(
                "Cannot replace a symlinked application bundle automatically. Please download from GitHub Releases.",
                zh: "无法自动替换符号链接形式的应用，请从 GitHub Releases 手动更新。"
            )))
        }
        if resolved.path.contains("/AppTranslocation/") || resolved.path.hasPrefix("/Volumes/") {
            return .failure(.message(L10n.text(
                "Move Nous Translator.app into Applications first, then run the update again.",
                zh: "请先将 Nous Translator.app 拖入“应用程序”目录运行，再使用应用内更新。"
            )))
        }
        let parent = resolved.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            return .failure(.message(L10n.text(
                "No write permission for \(parent.path). Download the update manually from GitHub Releases.",
                zh: "当前账户对 \(parent.path) 没有写入权限，请点击下方按钮前往 GitHub Releases 手动更新。"
            )))
        }
        return .success(())
    }

    /// Detached POSIX `/bin/sh` helper script using only base macOS binaries (no Python/Xcode dependency).
    /// All paths are passed strictly as positional parameters `$1..$6` to prevent shell injection.
    static let detachedInstallScript = #"""
set -eu
old_pid="$1"
target_app="$2"
staged_app="$3"
backup_app="$4"
cleanup_dir="$5"
reset_tcc="$6"

# Wait for the running app process to finish terminating cleanly (up to 15s).
i=0
while [ "$i" -lt 75 ]; do
    if ! /bin/kill -0 "$old_pid" 2>/dev/null; then
        break
    fi
    /bin/sleep 0.2
    i=$((i + 1))
done
if /bin/kill -0 "$old_pid" 2>/dev/null; then
    /bin/rm -rf "$staged_app" "$cleanup_dir"
    exit 1
fi

backup_parent="$(/usr/bin/dirname "$backup_app")"
/bin/mkdir -p "$backup_parent"

# Atomic same-volume replacement with automatic rollback on any failure.
/bin/mv "$target_app" "$backup_app"
if ! /bin/mv "$staged_app" "$target_app" || ! /usr/bin/codesign --verify --deep --strict "$target_app" >/dev/null 2>&1; then
    /bin/rm -rf "$target_app"
    /bin/mv "$backup_app" "$target_app"
    /bin/rm -rf "$cleanup_dir"
    /usr/bin/open "$target_app" >/dev/null 2>&1 || true
    exit 2
fi

tcc_reset_failed=0
if [ "$reset_tcc" = "1" ]; then
    if ! /usr/bin/tccutil reset Accessibility com.nous.translator >/dev/null 2>&1; then
        tcc_reset_failed=1
    fi
fi

if [ "$reset_tcc" = "1" ] && [ "$tcc_reset_failed" = "0" ]; then
    /usr/bin/open "$target_app" --args --request-accessibility-after-update >/dev/null 2>&1 || /usr/bin/open "$target_app" >/dev/null 2>&1 || true
    /bin/sleep 0.6
    /usr/bin/open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" >/dev/null 2>&1 || true
elif [ "$tcc_reset_failed" = "1" ]; then
    /usr/bin/open "$target_app" --args --update-accessibility-reset-failed >/dev/null 2>&1 || /usr/bin/open "$target_app" >/dev/null 2>&1 || true
else
    /usr/bin/open "$target_app" >/dev/null 2>&1 || true
fi

# Confirm the replacement binary launched before deleting the temporary backup.
exe="$target_app/Contents/MacOS/NousTranslator"
j=0
while [ "$j" -lt 40 ]; do
    if /bin/ps -ax -o comm= | /usr/bin/grep -Fxq "$exe"; then
        /bin/rm -rf "$backup_app"
        /bin/rmdir "$backup_parent" 2>/dev/null || true
        break
    fi
    /bin/sleep 0.25
    j=$((j + 1))
done
/bin/rm -rf "$cleanup_dir"
"""#
}

private final class UpdaterDownloadTransfer: NSObject, URLSessionDownloadDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    let allowLoopback: Bool
    let onProgress: @Sendable (Int64, Int64) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(URL, URLResponse), Error>?
    private var task: URLSessionDownloadTask?
    private var cancelled = false
    private var result: Result<(URL, URLResponse), Error>?

    init(allowLoopback: Bool, onProgress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.allowLoopback = allowLoopback
        self.onProgress = onProgress
    }

    func download(from url: URL, configuration: URLSessionConfiguration) async throws -> (URL, URLResponse) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                guard !cancelled else { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                var request = URLRequest(url: url)
                request.setValue("NousTranslator", forHTTPHeaderField: "User-Agent")
                let task = session.downloadTask(with: request)
                self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: { self.cancel() }
    }

    private func cancel() {
        lock.lock(); cancelled = true; let task = self.task; lock.unlock()
        task?.cancel()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        if let target = request.url, UpdaterRules.isAllowedURL(target, allowLoopback: allowLoopback) {
            completionHandler(request)
        } else {
            completionHandler(nil)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > UpdaterRules.maxArchiveBytes {
            downloadTask.cancel()
            return
        }
        onProgress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let retained = FileManager.default.temporaryDirectory
            .appendingPathComponent("nous-update-" + UUID().uuidString + ".zip")
        do {
            guard let response = downloadTask.response else { throw URLError(.badServerResponse) }
            try FileManager.default.moveItem(at: location, to: retained)
            result = .success((retained, response))
        } catch {
            result = .failure(error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let completion = continuation; continuation = nil; self.task = nil; lock.unlock()
        session.finishTasksAndInvalidate()
        if let error {
            if case let .success((file, _)) = result { try? FileManager.default.removeItem(at: file) }
            completion?.resume(throwing: error)
        } else {
            completion?.resume(with: result ?? .failure(URLError(.badServerResponse)))
        }
    }
}

private final class UpdaterRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let allowLoopback: Bool
    init(allowLoopback: Bool) { self.allowLoopback = allowLoopback }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        if let target = request.url, UpdaterRules.isAllowedURL(target, allowLoopback: allowLoopback) {
            completionHandler(request)
        } else {
            completionHandler(nil)
        }
    }
}

@MainActor final class AppUpdater: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(AvailableUpdate)
        case downloading(AvailableUpdate, progress: Double?, detail: String)
        case verifying(AvailableUpdate, detail: String)
        case installing(AvailableUpdate)
        case failed(String, update: AvailableUpdate?)
    }

    static let shared = AppUpdater()
    static let autoCheckKey = "updates.autoCheck"
    static let includePrereleasesKey = "updates.includePrereleases"
    static let skippedVersionKey = "updates.skippedVersion"
    static let lastCheckedKey = "updates.lastChecked"

    @Published private(set) var state: State = .idle
    @Published private(set) var lastChecked: Date?
    @Published var autoCheckEnabled: Bool {
        didSet { defaults.set(autoCheckEnabled, forKey: Self.autoCheckKey); reschedulePeriodicCheck() }
    }
    @Published var includePrereleases: Bool {
        didSet { defaults.set(includePrereleases, forKey: Self.includePrereleasesKey); cachedETag = nil }
    }

    /// Invoked whenever a new, non-skipped release is discovered (drives menu badge & floating prompt).
    var onUpdateDiscovered: ((AvailableUpdate) -> Void)?
    /// Invoked right before self-replacement termination so the app can stop child processes cleanly.
    var onBeforeTerminate: (() -> Void)?

    let currentVersion: ReleaseVersion
    let currentChannel: String
    private let defaults: UserDefaults
    private let releasesAPIURL: URL
    private let allowLoopback: Bool
    private let targetAppURLProvider: () -> URL
    private let session: URLSession
    private var cachedETag: String?
    private var lastObservedUpdate: AvailableUpdate?
    private var notifiedVersions: Set<String> = []
    private var checkTask: Task<Void, Never>?
    private var installTask: Task<Void, Never>?
    private var periodicTimer: Timer?
    private var initialCheckTask: Task<Void, Never>?

    var availableUpdate: AvailableUpdate? {
        switch state {
        case let .available(u), let .downloading(u, _, _), let .verifying(u, _), let .installing(u):
            return u
        case let .failed(_, u):
            return u
        default:
            return nil
        }
    }

    var hasVisibleUpdate: Bool {
        guard let update = availableUpdate else { return false }
        return defaults.string(forKey: Self.skippedVersionKey) != update.version.raw
    }

    init(
        defaults: UserDefaults = .standard,
        currentVersionString: String? = nil,
        currentChannel: String? = nil,
        releasesAPIURL: URL = UpdaterRules.defaultReleasesAPI,
        allowLoopback: Bool = false,
        targetAppURLProvider: @escaping () -> URL = { Bundle.main.bundleURL }
    ) {
        self.defaults = defaults
        let bundleVersion = currentVersionString
            ?? (Bundle.main.object(forInfoDictionaryKey: "NousReleaseVersion") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? "0.0.0"
        self.currentVersion = ReleaseVersion(bundleVersion) ?? ReleaseVersion("0.0.0")!
        let channel = currentChannel
            ?? (Bundle.main.object(forInfoDictionaryKey: "NousReleaseChannel") as? String)
            ?? (self.currentVersion.isPrerelease ? "preview" : "stable")
        self.currentChannel = channel
        self.releasesAPIURL = releasesAPIURL
        self.allowLoopback = allowLoopback
        self.targetAppURLProvider = targetAppURLProvider

        let autoDefault = defaults.object(forKey: Self.autoCheckKey) == nil ? true : defaults.bool(forKey: Self.autoCheckKey)
        let preDefault = defaults.object(forKey: Self.includePrereleasesKey) == nil ? (channel == "preview" || self.currentVersion.isPrerelease) : defaults.bool(forKey: Self.includePrereleasesKey)
        self.autoCheckEnabled = autoDefault
        self.includePrereleases = preDefault
        if let ts = defaults.object(forKey: Self.lastCheckedKey) as? Double {
            self.lastChecked = Date(timeIntervalSince1970: ts)
        }

        let config = URLSessionConfiguration.ephemeral
        if allowLoopback { config.connectionProxyDictionary = [:] }
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        self.session = URLSession(configuration: config, delegate: UpdaterRedirectGuard(allowLoopback: allowLoopback), delegateQueue: nil)
    }

    func startBackgroundChecks() {
        reschedulePeriodicCheck()
        guard autoCheckEnabled else { return }
        initialCheckTask?.cancel()
        initialCheckTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 8_000_000_000) } catch { return }
            guard let self, self.autoCheckEnabled else { return }
            await self.checkForUpdates(userInitiated: false)
        }
    }

    func stop() {
        initialCheckTask?.cancel(); initialCheckTask = nil
        periodicTimer?.invalidate(); periodicTimer = nil
        checkTask?.cancel(); checkTask = nil
        installTask?.cancel(); installTask = nil
    }

    private func reschedulePeriodicCheck() {
        periodicTimer?.invalidate(); periodicTimer = nil
        guard autoCheckEnabled else { return }
        // Poll every 6 hours while running; ETag avoids consuming GitHub rate limit when unchanged.
        periodicTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.checkForUpdates(userInitiated: false)
            }
        }
    }

    func skip(_ update: AvailableUpdate) {
        defaults.set(update.version.raw, forKey: Self.skippedVersionKey)
        if case .available = state {
            state = .idle
        }
    }

    func cancelInstall() {
        installTask?.cancel()
        installTask = nil
        if let update = availableUpdate {
            state = .available(update)
        }
    }

    func checkForUpdates(userInitiated: Bool) async {
        // Don't interrupt an active download or installation.
        switch state {
        case .downloading, .verifying, .installing: return
        default: break
        }
        checkTask?.cancel()
        if userInitiated {
            state = .checking
            defaults.removeObject(forKey: Self.skippedVersionKey)
        }
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                var request = URLRequest(url: self.releasesAPIURL)
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                request.setValue("NousTranslator/\(self.currentVersion.raw)", forHTTPHeaderField: "User-Agent")
                if !userInitiated, let etag = self.cachedETag {
                    request.setValue(etag, forHTTPHeaderField: "If-None-Match")
                }
                let (data, response) = try await self.session.data(for: request)
                try Task.checkCancellation()
                guard let http = response as? HTTPURLResponse else {
                    throw ModelError.message(L10n.text("Invalid response from GitHub.", zh: "GitHub 返回了无效响应。"))
                }
                let now = Date()
                self.lastChecked = now
                self.defaults.set(now.timeIntervalSince1970, forKey: Self.lastCheckedKey)

                if http.statusCode == 304 {
                    if let existing = self.lastObservedUpdate, existing.version > self.currentVersion {
                        self.applyDiscoveredUpdate(existing, userInitiated: userInitiated)
                    } else if userInitiated {
                        self.state = .upToDate
                    }
                    return
                }
                guard http.statusCode == 200 else {
                    if http.statusCode == 403 || http.statusCode == 429 {
                        throw ModelError.message(L10n.text(
                            "GitHub API rate limit reached. Try again later or check the Releases page.",
                            zh: "GitHub API 访问频率已达上限，请稍后再试或直接查看 Releases 页面。"
                        ))
                    }
                    throw ModelError.message(L10n.text(
                        "Could not check for updates (HTTP \(http.statusCode)).",
                        zh: "检查更新失败（HTTP \(http.statusCode)）。"
                    ))
                }
                if let etag = http.value(forHTTPHeaderField: "ETag") {
                    self.cachedETag = etag
                }
                let releases = try JSONDecoder().decode([GitHubReleasePayload].self, from: data)
                if let update = UpdaterRules.selectUpdate(
                    from: releases,
                    currentVersion: self.currentVersion,
                    includePrereleases: self.includePrereleases,
                    allowLoopback: self.allowLoopback
                ) {
                    self.lastObservedUpdate = update
                    self.applyDiscoveredUpdate(update, userInitiated: userInitiated)
                } else {
                    self.lastObservedUpdate = nil
                    self.state = userInitiated ? .upToDate : .idle
                }
            } catch is CancellationError {
            } catch let error as URLError where error.code == .cancelled {
            } catch {
                if userInitiated {
                    self.state = .failed(error.localizedDescription, update: self.lastObservedUpdate)
                }
            }
        }
        checkTask = task
        await task.value
    }

    private func applyDiscoveredUpdate(_ update: AvailableUpdate, userInitiated: Bool) {
        let skipped = defaults.string(forKey: Self.skippedVersionKey)
        if !userInitiated && skipped == update.version.raw {
            return
        }
        state = .available(update)
        if !userInitiated && !notifiedVersions.contains(update.version.raw) {
            notifiedVersions.insert(update.version.raw)
            onUpdateDiscovered?(update)
        }
    }

    /// Downloads, SHA-256 checks, extracts, codesign-verifies, atomically replaces, and restarts the app.
    func downloadAndInstall(_ update: AvailableUpdate) {
        switch state {
        case .downloading, .verifying, .installing: return
        default: break
        }
        let targetApp = targetAppURLProvider().standardizedFileURL
        if case let .failure(error) = UpdaterRules.canReplaceInPlace(appURL: targetApp) {
            state = .failed(error.localizedDescription, update: update)
            return
        }

        installTask?.cancel()
        installTask = Task { [weak self] in
            guard let self else { return }
            defer { self.installTask = nil }
            let workRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("nous-updater-" + UUID().uuidString)
            var keepWorkRootForHelper = false
            defer {
                if !keepWorkRootForHelper {
                    try? FileManager.default.removeItem(at: workRoot)
                }
            }
            do {
                try FileManager.default.createDirectory(at: workRoot, withIntermediateDirectories: true)
                self.state = .verifying(update, detail: L10n.text("Fetching release checksums…", zh: "正在获取校验清单…"))

                let expectedZipSHA = try await self.fetchExpectedSHA256(for: update)
                try Task.checkCancellation()

                self.state = .downloading(update, progress: nil, detail: L10n.text("Connecting to GitHub…", zh: "正在连接 GitHub 下载…"))
                let dlConfig = URLSessionConfiguration.ephemeral
                if self.allowLoopback { dlConfig.connectionProxyDictionary = [:] }
                dlConfig.timeoutIntervalForRequest = 60
                dlConfig.timeoutIntervalForResource = 1800

                let transfer = UpdaterDownloadTransfer(allowLoopback: self.allowLoopback) { [weak self] received, expected in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if case .downloading = self.state {
                            let ratio = expected > 0 ? min(1, Double(received) / Double(expected)) : nil
                            let got = ByteCountFormatter.string(fromByteCount: received, countStyle: .file)
                            let total = expected > 0 ? " / " + ByteCountFormatter.string(fromByteCount: expected, countStyle: .file) : ""
                            self.state = .downloading(update, progress: ratio, detail: L10n.text("Downloading ", zh: "正在下载 ") + got + total + "…")
                        }
                    }
                }
                let (tempZip, dlResponse) = try await transfer.download(from: update.zipURL, configuration: dlConfig)
                let stagedZip = workRoot.appendingPathComponent(update.zipAssetName)
                try FileManager.default.moveItem(at: tempZip, to: stagedZip)
                try Task.checkCancellation()
                guard let http = dlResponse as? HTTPURLResponse, http.statusCode == 200 else {
                    throw ModelError.message(L10n.text("Download failed from GitHub Releases. Please try again.", zh: "从 GitHub Releases 下载失败，请重试。"))
                }

                self.state = .verifying(update, detail: L10n.text("Verifying SHA-256 checksum…", zh: "正在验证 SHA-256 校验和…"))
                let actualSHA = try await ModelDownload.sha256(of: stagedZip)
                guard actualSHA.lowercased() == expectedZipSHA.lowercased() else {
                    throw ModelError.message(L10n.text(
                        "Update archive SHA-256 checksum mismatch. Aborting installation for safety.",
                        zh: "安装包 SHA-256 校验不匹配，出于安全考虑已中止安装。"
                    ))
                }
                try Task.checkCancellation()

                self.state = .verifying(update, detail: L10n.text("Extracting and verifying signature…", zh: "正在解压并验证应用签名…"))
                let extractedDir = workRoot.appendingPathComponent("extracted")
                try FileManager.default.createDirectory(at: extractedDir, withIntermediateDirectories: true)
                let candidateApp = try await self.extractAndVerifyApp(zipURL: stagedZip, into: extractedDir, expectedVersion: update.version, installedApp: targetApp)
                try Task.checkCancellation()

                let stagedApp = targetApp.deletingLastPathComponent()
                    .appendingPathComponent(".Nous Translator-update-" + UUID().uuidString + ".app")
                do {
                    try await Self.runProcess("/usr/bin/ditto", arguments: ["--norsrc", candidateApp.path, stagedApp.path])
                    try await Self.runProcess("/usr/bin/codesign", arguments: ["--verify", "--deep", "--strict", stagedApp.path])
                } catch {
                    try? FileManager.default.removeItem(at: stagedApp)
                    throw error
                }

                let shouldResetTCC = await Self.shouldResetAccessibility(installedApp: targetApp, candidateApp: stagedApp)
                let timestamp = Self.backupTimestamp()
                let backupApp = LocalModel.directory
                    .appendingPathComponent("Backups")
                    .appendingPathComponent(timestamp)
                    .appendingPathComponent("Previous.bundle-backup")

                self.state = .installing(update)
                self.onBeforeTerminate?()

                let helper = Process()
                helper.executableURL = URL(fileURLWithPath: "/bin/sh")
                helper.arguments = [
                    "-c", UpdaterRules.detachedInstallScript, "--",
                    String(ProcessInfo.processInfo.processIdentifier),
                    targetApp.path,
                    stagedApp.path,
                    backupApp.path,
                    workRoot.path,
                    shouldResetTCC ? "1" : "0"
                ]
                helper.standardInput = FileHandle.nullDevice
                helper.standardOutput = FileHandle.nullDevice
                helper.standardError = FileHandle.nullDevice
                try helper.run()
                keepWorkRootForHelper = true
                NSApp.terminate(nil)
            } catch is CancellationError {
                self.state = .available(update)
            } catch let error as URLError where error.code == .cancelled {
                self.state = .available(update)
            } catch {
                self.state = .failed(error.localizedDescription, update: update)
            }
        }
    }

    private func fetchExpectedSHA256(for update: AvailableUpdate) async throws -> String {
        let (sumsData, sumsResponse) = try await fetchData(from: update.checksumsURL)
        guard (sumsResponse as? HTTPURLResponse)?.statusCode == 200,
              let sumsText = String(data: sumsData, encoding: .utf8) else {
            throw ModelError.message(L10n.text("Could not download SHA256SUMS.txt for this release.", zh: "无法下载该版本的 SHA256SUMS.txt 校验文件。"))
        }
        let sums = UpdaterRules.parseSHA256Sums(sumsText)
        guard let zipDigest = sums[update.zipAssetName] else {
            throw ModelError.message(L10n.text("Release checksums do not list \(update.zipAssetName).", zh: "校验文件中缺少 \(update.zipAssetName) 的摘要记录。"))
        }
        if let manifestURL = update.manifestURL {
            let (manifestData, manifestResponse) = try await fetchData(from: manifestURL)
            guard (manifestResponse as? HTTPURLResponse)?.statusCode == 200 else {
                throw ModelError.message(L10n.text("Could not download release.json manifest.", zh: "无法下载 release.json 版本清单。"))
            }
            if let expectedManifestDigest = sums["release.json"] {
                let actualManifestDigest = SHA256.hash(data: manifestData).map { String(format: "%02x", $0) }.joined()
                guard actualManifestDigest == expectedManifestDigest else {
                    throw ModelError.message(L10n.text("release.json checksum mismatch.", zh: "release.json 校验和不匹配。"))
                }
            }
            let manifest = try JSONDecoder().decode(ReleaseManifestPayload.self, from: manifestData)
            guard manifest.architecture == "arm64" else {
                throw ModelError.message(L10n.text("This release is not built for Apple Silicon (arm64).", zh: "该版本不适用于 Apple Silicon (arm64)。"))
            }
            guard UpdaterRules.isOSCompatible(minimum: manifest.minimumMacOS) else {
                throw ModelError.message(L10n.text(
                    "This update requires macOS \(manifest.minimumMacOS) or newer.",
                    zh: "该更新需要 macOS \(manifest.minimumMacOS) 或更高版本。"
                ))
            }
            if let manifestZipDigest = manifest.assets[update.zipAssetName]?.lowercased() {
                guard manifestZipDigest == zipDigest else {
                    throw ModelError.message(L10n.text("Release manifest checksum does not match SHA256SUMS.txt.", zh: "release.json 与 SHA256SUMS.txt 中的校验和不一致。"))
                }
            }
        }
        return zipDigest
    }

    private func fetchData(from url: URL) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        request.setValue("NousTranslator/\(currentVersion.raw)", forHTTPHeaderField: "User-Agent")
        return try await session.data(for: request)
    }

    private func extractAndVerifyApp(zipURL: URL, into directory: URL, expectedVersion: ReleaseVersion, installedApp: URL) async throws -> URL {
        try await Self.runProcess("/usr/bin/ditto", arguments: ["-x", "-k", zipURL.path, directory.path])
        let candidate = directory.appendingPathComponent("Nous Translator.app")
        guard FileManager.default.fileExists(atPath: candidate.path) else {
            throw ModelError.message(L10n.text("The downloaded archive does not contain Nous Translator.app.", zh: "下载的压缩包中未找到 Nous Translator.app。"))
        }
        if let values = try? candidate.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink == true {
            throw ModelError.message(L10n.text("Unexpected symlink in update archive.", zh: "更新包中包含非法符号链接。"))
        }
        let infoURL = candidate.appendingPathComponent("Contents/Info.plist")
        guard let infoData = try? Data(contentsOf: infoURL),
              let plist = try? PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any],
              plist["CFBundleIdentifier"] as? String == "com.nous.translator",
              plist["CFBundleExecutable"] as? String == "NousTranslator" else {
            throw ModelError.message(L10n.text("Update bundle identifier does not match Nous Translator.", zh: "更新包的 Bundle Identifier 不匹配，已中止安装。"))
        }
        if let rawVer = plist["NousReleaseVersion"] as? String,
           let parsedVer = ReleaseVersion(rawVer),
           parsedVer != expectedVersion {
            throw ModelError.message(L10n.text(
                "Update bundle version (\(rawVer)) does not match expected version (\(expectedVersion.raw)).",
                zh: "更新包内部版本（\(rawVer)）与预期版本（\(expectedVersion.raw)）不符。"
            ))
        }
        let mainExe = candidate.appendingPathComponent("Contents/MacOS/NousTranslator")
        let runtimeExe = candidate.appendingPathComponent("Contents/Resources/Runtime/llama-server")
        guard FileManager.default.isExecutableFile(atPath: mainExe.path),
              FileManager.default.isExecutableFile(atPath: runtimeExe.path) else {
            throw ModelError.message(L10n.text("Update bundle is missing required executables.", zh: "更新包缺少必要的可执行文件。"))
        }
        try await Self.runProcess("/usr/bin/codesign", arguments: ["--verify", "--deep", "--strict", candidate.path])
        // Prevent silent downgrade from a Developer ID signed installation to an ad-hoc build.
        if await Self.isDeveloperIDSigned(installedApp), !(await Self.isDeveloperIDSigned(candidate)) {
            throw ModelError.message(L10n.text(
                "Refusing to replace a Developer ID signed app with an unsigned/ad-hoc build.",
                zh: "安全拦截：拒绝使用 ad-hoc 预览签名替换 Developer ID 正式签名版本。"
            ))
        }
        return candidate
    }

    private static func isDeveloperIDSigned(_ app: URL) async -> Bool {
        guard let output = try? await runProcessOutput("/usr/bin/codesign", arguments: ["-dv", "--verbose=4", app.path]) else {
            return false
        }
        return output.contains("Authority=Developer ID Application:")
    }

    /// Ad-hoc preview builds change cdhash on every release, so macOS Accessibility needs a targeted reset.
    /// Stable Developer ID builds satisfying the existing designated requirement keep permissions intact.
    private static func shouldResetAccessibility(installedApp: URL, candidateApp: URL) async -> Bool {
        guard await isDeveloperIDSigned(installedApp) else { return true }
        guard let reqOutput = try? await runProcessOutput("/usr/bin/codesign", arguments: ["-d", "-r-", installedApp.path]),
              let range = reqOutput.range(of: "designated =>") else { return true }
        let requirement = String(reqOutput[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requirement.isEmpty else { return true }
        do {
            try await runProcess("/usr/bin/codesign", arguments: ["--verify", "-R=\(requirement)", candidateApp.path])
            return false
        } catch {
            return true
        }
    }

    private static func backupTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    static func runProcess(_ executable: String, arguments: [String]) async throws {
        _ = try await runProcessOutput(executable, arguments: arguments)
    }

    static func runProcessOutput(_ executable: String, arguments: [String]) async throws -> String {
        try await ImageRecognition.worker {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let text = String(data: data, encoding: .utf8) ?? ""
            guard process.terminationStatus == 0 else {
                let detail = ModelRouter.sanitizeDiagnostic(text) ?? "exit code \(process.terminationStatus)"
                throw ModelError.message("\(URL(fileURLWithPath: executable).lastPathComponent): \(detail)")
            }
            return text
        }
    }
}
