import AppKit
import CryptoKit
import Security

/// A published GitHub release that can be installed.
struct Release {
    let version: String
    let notes: String
    let pageURL: URL
    let archiveURL: URL
    let checksumURL: URL
}

enum UpdateError: LocalizedError {
    case badResponse(Int)
    case noInstallableAsset
    case checksumMismatch
    case invalidArchive
    case invalidSignature(String)
    case notWritable(String)
    case translocated
    case installerFailed

    var errorDescription: String? {
        switch self {
        case .badResponse(let status): return "GitHub responded with HTTP \(status)."
        case .noInstallableAsset: return "The latest release has no downloadable Para archive."
        case .checksumMismatch: return "The downloaded archive does not match its published SHA-256 checksum."
        case .invalidArchive: return "The downloaded archive does not contain a valid Para.app."
        case .invalidSignature(let reason): return "The update's code signature could not be verified (\(reason))."
        case .notWritable(let path): return "Para cannot replace itself because \(path) is not writable."
        case .translocated:
            return "macOS is running Para from a temporary, read-only location. "
                + "Move Para.app to /Applications, open it from there and try again."
        case .installerFailed: return "The installer could not be started."
        }
    }
}

/// Checks GitHub Releases for newer versions of Para and installs them in place.
///
/// Updates are verified before they replace the running app: the archive must match
/// the release's published SHA-256, contain an app with the same bundle identifier,
/// and carry a valid code signature from the same signer as the running app.
final class Updater {
    static let repository = "kpricorn/para"
    static let checkInterval: TimeInterval = 24 * 60 * 60

    enum State: Equatable {
        case idle
        case checking
        case installing
    }

    private(set) var state: State = .idle {
        didSet { onChange?() }
    }
    private(set) var availableRelease: Release? {
        didSet { onChange?() }
    }
    var onChange: (() -> Void)?

    private var timer: Timer?


    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Starts periodic background checks (if enabled in Settings).
    func start() {
        timer?.invalidate()
        // Tick hourly and check once a day: survives sleep better than a 24h timer.
        timer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in
            self?.checkIfDue()
        }
        timer?.tolerance = 5 * 60
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            self?.checkIfDue()
        }
    }

    func checkIfDue() {
        guard Settings.automaticallyChecksForUpdates, state == .idle else { return }
        if let last = Settings.lastUpdateCheck, Date().timeIntervalSince(last) < Self.checkInterval { return }
        Task { @MainActor in await check(userInitiated: false) }
    }

    /// Menu/Settings action: checks now and always reports the outcome.
    func checkForUpdates() {
        if let release = availableRelease {
            present(release, userInitiated: true)
            return
        }
        guard state == .idle else { return }
        Task { @MainActor in await check(userInitiated: true) }
    }

    @MainActor
    private func check(userInitiated: Bool) async {
        state = .checking
        defer { if state == .checking { state = .idle } }
        do {
            let release = try await Self.fetchLatestRelease()
            Settings.lastUpdateCheck = Date()
            guard Self.isVersion(release.version, newerThan: Self.currentVersion) else {
                availableRelease = nil
                if userInitiated { showUpToDate() }
                return
            }
            availableRelease = release
            if userInitiated || Settings.skippedUpdateVersion != release.version {
                state = .idle
                present(release, userInitiated: userInitiated)
            }
        } catch {
            if userInitiated { showError(error, title: "Couldn't check for updates") }
        }
    }

    // MARK: - GitHub

    static func fetchLatestRelease() async throws -> Release {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Para/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response)
        return try parseRelease(data)
    }

    static func parseRelease(_ data: Data) throws -> Release {
        struct Payload: Decodable {
            struct Asset: Decodable {
                let name: String
                let browser_download_url: URL
            }
            let tag_name: String
            let body: String?
            let html_url: URL
            let assets: [Asset]
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        let version = payload.tag_name.hasPrefix("v") ? String(payload.tag_name.dropFirst()) : payload.tag_name
        guard let archive = payload.assets.first(where: { $0.name == "Para-\(version).zip" })
            ?? payload.assets.first(where: { $0.name.hasPrefix("Para") && $0.name.hasSuffix(".zip") }),
            let checksum = payload.assets.first(where: { $0.name == archive.name + ".sha256" })
        else { throw UpdateError.noInstallableAsset }
        return Release(
            version: version,
            notes: payload.body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            pageURL: payload.html_url,
            archiveURL: archive.browser_download_url,
            checksumURL: checksum.browser_download_url
        )
    }

    static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        func components(_ version: String) -> [Int] {
            let core = version.split(whereSeparator: { $0 == "-" || $0 == "+" }).first ?? ""
            return core.split(separator: ".").map { Int($0) ?? 0 }
        }
        let a = components(candidate), b = components(current)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }

    private static func validate(_ response: URLResponse) throws {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw UpdateError.badResponse(http.statusCode)
        }
    }

    // MARK: - UI

    private func present(_ release: Release, userInitiated: Bool) {
        let alert = NSAlert()
        alert.messageText = "Para \(release.version) is available"
        alert.informativeText = "You have version \(Self.currentVersion). "
            + "Para will download the update, verify it, and relaunch."
        alert.icon = NSApp.applicationIconImage
        alert.addButton(withTitle: "Install and Relaunch")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Skip This Version")
        if !release.notes.isEmpty {
            alert.accessoryView = notesView(release.notes)
        }

        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Task { @MainActor in await install(release) }
        case .alertThirdButtonReturn:
            Settings.skippedUpdateVersion = release.version
        default:
            break
        }
    }

    private func notesView(_ markdown: String) -> NSView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 360, height: 160))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let text = NSTextView(frame: scroll.bounds)
        text.isEditable = false
        text.textContainerInset = NSSize(width: 6, height: 6)
        text.autoresizingMask = [.width]
        text.textStorage?.setAttributedString(Self.formatNotes(markdown))
        scroll.documentView = text
        return scroll
    }

    /// Renders the changelog subset used in release notes: `#` headings, `-` bullets
    /// (with hard-wrapped continuation lines) and inline markdown.
    static func formatNotes(_ markdown: String) -> NSAttributedString {
        var blocks: [(text: String, heading: Bool)] = []
        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                blocks.append(("", false))
            } else if line.hasPrefix("#") {
                blocks.append((line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces), true))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                blocks.append(("•  " + line.dropFirst(2), false))
            } else if let last = blocks.last, !last.heading, !last.text.isEmpty {
                blocks[blocks.count - 1].text += " " + line
            } else {
                blocks.append((line, false))
            }
        }

        let result = NSMutableAttributedString()
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        for block in blocks where !block.text.isEmpty {
            let parsed = (try? NSMutableAttributedString(AttributedString(markdown: block.text, options: options)))
                ?? NSMutableAttributedString(string: block.text)
            let range = NSRange(location: 0, length: parsed.length)
            let style = NSMutableParagraphStyle()
            style.paragraphSpacing = 4
            if block.heading {
                style.paragraphSpacingBefore = result.length == 0 ? 0 : 6
            } else {
                style.headIndent = 14
            }
            parsed.addAttribute(.font, value: NSFont.systemFont(ofSize: 11, weight: block.heading ? .semibold : .regular), range: range)
            parsed.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range)
            parsed.addAttribute(.paragraphStyle, value: style, range: range)
            if result.length > 0 { result.append(NSAttributedString(string: "\n")) }
            result.append(parsed)
        }
        return result
    }

    private func showUpToDate() {
        let alert = NSAlert()
        alert.messageText = "You're up to date"
        alert.informativeText = "Para \(Self.currentVersion) is the latest version."
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func showError(_ error: Error, title: String, release: Release? = nil) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        if release != nil { alert.addButton(withTitle: "Open Releases Page") }
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn, let release {
            NSWorkspace.shared.open(release.pageURL)
        }
    }

    // MARK: - Install

    @MainActor
    private func install(_ release: Release) async {
        state = .installing
        do {
            let target = Bundle.main.bundleURL
            let staged = try await Self.download(release, besides: target)
            try Self.launchInstaller(replacing: target, with: staged)
            NSApp.terminate(nil)
        } catch {
            state = .idle
            showError(error, title: "Couldn't install Para \(release.version)", release: release)
        }
    }

    /// Downloads, verifies and unpacks `release` next to `target`, returning the staged app.
    static func download(_ release: Release, besides target: URL) async throws -> URL {
        if target.path.contains("/AppTranslocation/") { throw UpdateError.translocated }
        let parent = target.deletingLastPathComponent()
        let fileManager = FileManager.default
        guard fileManager.isWritableFile(atPath: parent.path) else { throw UpdateError.notWritable(parent.path) }

        let (checksumData, checksumResponse) = try await URLSession.shared.data(from: release.checksumURL)
        try validate(checksumResponse)
        guard let expected = String(decoding: checksumData, as: UTF8.self)
            .split(whereSeparator: \.isWhitespace).first?.lowercased(),
            expected.count == 64
        else { throw UpdateError.checksumMismatch }

        let (archive, archiveResponse) = try await URLSession.shared.download(from: release.archiveURL)
        defer { try? fileManager.removeItem(at: archive) }
        try validate(archiveResponse)
        let actual = try sha256(of: archive)
        guard actual == expected else { throw UpdateError.checksumMismatch }

        // Stage on the same volume so the final swap is an atomic rename.
        let staging = parent.appendingPathComponent(".Para-update-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
        do {
            try run("/usr/bin/ditto", ["-x", "-k", archive.path, staging.path])
            let app = staging.appendingPathComponent("Para.app", isDirectory: true)
            guard let bundle = Bundle(url: app),
                  bundle.bundleIdentifier == Bundle.main.bundleIdentifier,
                  bundle.executableURL.map({ fileManager.isExecutableFile(atPath: $0.path) }) == true
            else { throw UpdateError.invalidArchive }
            try verifySignature(of: app)
            _ = try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
            return app
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    private static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Requires a valid signature with the running app's identifier and, if the running
    /// app is Developer ID signed, the same Apple-issued team certificate.
    static func verifySignature(of app: URL) throws {
        guard let identifier = Bundle.main.bundleIdentifier else {
            throw UpdateError.invalidSignature("running app has no bundle identifier")
        }
        var requirementText = "identifier \"\(identifier)\""
        if let team = currentTeamIdentifier() {
            requirementText = "anchor apple generic and \(requirementText) "
                + "and certificate leaf[subject.OU] = \"\(team)\""
        }

        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &staticCode) == errSecSuccess, let staticCode else {
            throw UpdateError.invalidSignature("unreadable signature")
        }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess else {
            throw UpdateError.invalidSignature("bad requirement")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        let status = SecStaticCodeCheckValidity(staticCode, flags, requirement)
        guard status == errSecSuccess else {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            throw UpdateError.invalidSignature(message)
        }
    }

    static func currentTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
            == errSecSuccess,
            let dictionary = info as? [String: Any]
        else { return nil }
        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// Spawns a detached shell that waits for Para to quit, swaps the bundles and relaunches.
    private static func launchInstaller(replacing target: URL, with staged: URL) throws {
        let script = """
        pid="$1"; new="$2"; target="$3"; staging="$(dirname "$new")"
        while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
        backup="$staging/Para-old.app"
        if mv "$target" "$backup"; then
          if mv "$new" "$target"; then rm -rf "$backup"; else mv "$backup" "$target"; fi
        fi
        rm -rf "$staging"
        open "$target"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c", script, "para-updater",
            String(ProcessInfo.processInfo.processIdentifier), staged.path, target.path,
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw UpdateError.installerFailed }
    }

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateError.invalidArchive }
        return process.terminationStatus
    }
}
