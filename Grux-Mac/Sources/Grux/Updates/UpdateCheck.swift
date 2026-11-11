import Foundation
import Network

// The 3.2 update check (spec docs/superpowers/specs/2026-10-17-update-check-scope.md).
// Grux had no way to learn that a newer release exists: shipping 3.1.0 reached the site,
// GitHub, Homebrew and npm, and none of the copies already installed. This asks GitHub's
// public latest-release page, the same page anyone can open, at most once a day. It
// notifies and never installs: no download, no replace, no relaunch.
//
// What it sends: one anonymous GET with an Accept header, a fixed `Accept-Language: en`
// (the system would otherwise send the person's own language list, measured on the wire:
// `en-US,en;q=0.9`), the system's Accept-Encoding and standard user agent. No install id,
// no key, no cookie, no query string. Nothing goes to a Grux server, because there is none.
enum UpdateCheck {

    /// THE DEFAULT, IN ONE PLACE. The spec says on, because the request carries nothing
    /// about the person; the owner has not ruled yet, and his word flips this one line.
    static let onByDefault = true

    /// GitHub's public latest-release page for this repository. `releases/latest` never
    /// answers with a draft or a prerelease, and the verdict ignores both anyway.
    static let latestReleaseURL = URL(string: "https://api.github.com/repos/dotcomjack/grux/releases/latest")!

    /// At most one scheduled request per this long, counted from the last request made,
    /// whether it succeeded or not, so a failing server is not asked on every launch.
    static let interval: TimeInterval = 24 * 3600

    /// The two fields of GitHub's release answer the verdict reads, and the tag.
    struct Release: Decodable, Equatable {
        var tagName: String
        var draft: Bool
        var prerelease: Bool

        init(tagName: String, draft: Bool, prerelease: Bool) {
            self.tagName = tagName
            self.draft = draft
            self.prerelease = prerelease
        }

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name", draft, prerelease
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            tagName = try c.decode(String.self, forKey: .tagName)
            draft = try c.decodeIfPresent(Bool.self, forKey: .draft) ?? false
            prerelease = try c.decodeIfPresent(Bool.self, forKey: .prerelease) ?? false
        }
    }

    enum Verdict: Equatable {
        case newer(version: String)
        case upToDate(latest: String)
        case ignored(String)
    }

    /// The network as the check sees it. Metered (a phone hotspot) and constrained (Low
    /// Data Mode) are not asked on, as the spec says.
    enum Network: Equatable { case online, offline, metered, constrained }

    enum Outcome: Equatable {
        case skipped(String)
        case upToDate(latest: String)
        case newer(version: String)
        case ignored(String)
        case failed(String)

        /// One plain line, for wake.log and the Settings "Check now" result.
        var line: String {
            switch self {
            case .skipped(let why): return "not checked: \(why)"
            case .upToDate(let latest): return "up to date (the latest release is \(latest))"
            case .newer(let version): return "Grux AI \(version) is available"
            case .ignored(let why): return "the latest release is \(why), so nothing to offer"
            case .failed(let why): return "could not check: \(why)"
            }
        }
    }

    // MARK: - U1, the version compare

    /// "v3.10.0" or "3.10" as numbers, nil for anything that is not dotted numbers. A
    /// missing component is zero, so 3.2 and 3.2.0 are the same version.
    static func components(_ version: String) -> [Int]? {
        var v = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.hasPrefix("v") || v.hasPrefix("V") { v.removeFirst() }
        let parts = v.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 4 else { return nil }
        var out: [Int] = []
        for p in parts {
            guard !p.isEmpty, p.allSatisfy(\.isASCII), p.allSatisfy(\.isNumber), let n = Int(p) else { return nil }
            out.append(n)
        }
        while out.count < 3 { out.append(0) }
        return out
    }

    /// Strips the leading "v" for display: "v3.2.0" reads "3.2.0".
    static func display(_ tag: String) -> String {
        let t = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.hasPrefix("v") || t.hasPrefix("V") ? String(t.dropFirst()) : t
    }

    static func verdict(installed: String, latest: Release) -> Verdict {
        if latest.draft { return .ignored("a draft release") }
        // A semver prerelease or build suffix ("v3.2.0-beta.1") counts as a prerelease
        // even when GitHub was not told it is one.
        if latest.prerelease || latest.tagName.contains("-") || latest.tagName.contains("+") {
            return .ignored("a prerelease")
        }
        guard let theirs = components(latest.tagName) else {
            return .ignored("the tag \(latest.tagName) is not a version")
        }
        let shown = display(latest.tagName)
        // An installed version that does not parse is never told a release is newer:
        // offering a download from a comparison that could not be made is a guess.
        guard let ours = components(installed) else { return .upToDate(latest: shown) }
        let width = max(ours.count, theirs.count)
        let a = ours + Array(repeating: 0, count: width - ours.count)
        let b = theirs + Array(repeating: 0, count: width - theirs.count)
        return a.lexicographicallyPrecedes(b) ? .newer(version: shown) : .upToDate(latest: shown)
    }

    // MARK: - U2, the request carries nothing about the person

    static func request() -> URLRequest {
        var r = URLRequest(url: latestReleaseURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        r.httpMethod = "GET"
        r.httpShouldHandleCookies = false
        r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // The same for everyone: an explicit value wins over the one CFNetwork adds.
        r.setValue("en", forHTTPHeaderField: "Accept-Language")
        return r
    }

    /// A session that keeps nothing: no cookies sent or stored, no cache, no saved
    /// credentials, no extra headers.
    static func sessionConfiguration() -> URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.httpCookieAcceptPolicy = .never
        c.urlCache = nil
        c.urlCredentialStorage = nil
        c.httpAdditionalHeaders = [:]
        return c
    }

    // MARK: - U3 and U4, whether to ask now

    /// nil means ask. "Check now" (manual) skips the switch and the once-a-day limit; it
    /// still needs a network, and nothing asks during first run.
    static func reasonNotToAsk(now: Date, lastCheckedAt: Date?, enabled: Bool, firstRunDone: Bool,
                               network: Network, manual: Bool) -> String? {
        if !manual, !enabled { return "the check is turned off" }
        if !firstRunDone { return "first run is not finished" }
        switch network {
        case .online: break
        case .offline: return "this Mac is offline"
        case .metered: return "this network is metered"
        case .constrained: return "Low Data Mode is on"
        }
        if !manual, let last = lastCheckedAt, now.timeIntervalSince(last) < interval, now >= last {
            return "checked less than a day ago"
        }
        return nil
    }
}

// What the check remembers between launches: when it last asked, what it last saw.
struct UpdateCheckState: Codable, Equatable {
    var lastCheckedAt: Date?
    var latestTag: String?
    /// The version the person said Not now to. A newer one shows again.
    var dismissedVersion: String?
    /// Why the last request got no release, nil once one answered. Without it a failed
    /// check would read as the release seen before it.
    var lastFailure: String?
}

@MainActor
final class UpdateChecker: ObservableObject {
    struct Environment {
        var now: () -> Date
        var installedVersion: () -> String
        var enabled: @MainActor () -> Bool
        var firstRunDone: @MainActor () -> Bool
        var network: () async -> UpdateCheck.Network
        /// The body and the HTTP status.
        var fetch: (URLRequest) async throws -> (Data, Int)
        var stateURL: URL
        var log: (String) -> Void
    }

    static let shared = UpdateChecker(environment: .live)

    /// The newer version on offer ("3.2.0"), nil when there is none.
    @Published private(set) var available: String?
    /// What the last real check found and when, for Settings: "up to date (the latest
    /// release is 3.1.0), checked today at 4:41 PM". A scheduled look skipped inside the
    /// day leaves it alone (D129: About read "not checked: checked less than a day ago"
    /// beside a Now row offering 3.2.0); Check now that cannot ask says why. Made when
    /// read, so the day it names is right after midnight (wave 37: stored as text, it
    /// said "today" about yesterday until the next real check).
    var lastLine: String? { cannotAskLine ?? resultLine(loadState()) }

    /// Why Check now could not ask, until the next real answer replaces it.
    @Published private var cannotAskLine: String?
    /// Bumped by every real answer, so a view showing `lastLine` redraws.
    @Published private var answers = 0

    private let environment: Environment
    private var inFlight = false
    private var timer: Timer?

    init(environment: Environment) {
        self.environment = environment
        // The last answer on disk, so an offer survives a relaunch inside the day
        // without asking again, and is gone once the person has upgraded.
        let state = loadState()
        if let tag = state.latestTag {
            available = offered(UpdateCheck.verdict(
                installed: environment.installedVersion(),
                latest: UpdateCheck.Release(tagName: tag, draft: false, prerelease: false)), state: state)
        }
    }

    /// The last real check's answer, read from disk, with when it asked. nil before the
    /// first one.
    private func resultLine(_ state: UpdateCheckState) -> String? {
        guard let asked = state.lastCheckedAt else { return nil }
        let found: UpdateCheck.Outcome
        if let why = state.lastFailure {
            found = .failed(why)
        } else if let tag = state.latestTag {
            switch UpdateCheck.verdict(installed: environment.installedVersion(),
                                       latest: UpdateCheck.Release(tagName: tag, draft: false, prerelease: false)) {
            case .newer(let v): found = .newer(version: v)
            case .upToDate(let latest): found = .upToDate(latest: latest)
            case .ignored(let why): found = .ignored(why)
            }
        } else {
            return nil
        }
        return found.line + ", checked " + FoundrySchedule.when(asked, now: environment.now(), calendar: .current)
    }

    /// The version a Now row offers for this verdict, nil for none or for the version
    /// the person said Not now to.
    private func offered(_ verdict: UpdateCheck.Verdict, state: UpdateCheckState) -> String? {
        guard case .newer(let v) = verdict, v != state.dismissedVersion else { return nil }
        return v
    }

    /// Not now: hides this version's row for good. A newer version shows again.
    func notNow(version: String) {
        var state = loadState()
        state.dismissedVersion = version
        Persistence.save(state, to: environment.stateURL)
        if available == version { available = nil }
        environment.log("update-check: not now for \(version)")
    }

    /// What Now offers, read live.
    var offer: UpdateOffer? {
        available.map { UpdateOffer(version: $0, viaHomebrew: UpdateCheck.installedByHomebrew()) }
    }

    private func loadState() -> UpdateCheckState {
        Persistence.load(UpdateCheckState.self, from: environment.stateURL, fallback: UpdateCheckState())
    }

    @discardableResult
    func run(manual: Bool) async -> UpdateCheck.Outcome {
        guard !inFlight else { return finish(.skipped("a check is already running"), manual: manual) }
        inFlight = true
        defer { inFlight = false }

        var state = loadState()
        let now = environment.now()
        let enabled = environment.enabled()
        let firstRunDone = environment.firstRunDone()
        // Everything but the network first, so an hourly look with the switch off or
        // inside the day never starts a network probe.
        func reason(_ network: UpdateCheck.Network) -> String? {
            UpdateCheck.reasonNotToAsk(now: now, lastCheckedAt: state.lastCheckedAt, enabled: enabled,
                                       firstRunDone: firstRunDone, network: network, manual: manual)
        }
        if let why = reason(.online) { return finish(.skipped(why), manual: manual) }
        if let why = reason(await environment.network()) { return finish(.skipped(why), manual: manual) }

        // Re-read after every await: Not now may have written the file meanwhile.
        state = loadState()
        // The day is counted from the request, before the answer, so a failure counts.
        state.lastCheckedAt = now
        Persistence.save(state, to: environment.stateURL)

        let outcome: UpdateCheck.Outcome
        do {
            let (data, status) = try await environment.fetch(UpdateCheck.request())
            if status != 200 {
                outcome = .failed("GitHub answered HTTP \(status)")
            } else if let release = try? JSONDecoder().decode(UpdateCheck.Release.self, from: data) {
                state = loadState()
                state.latestTag = release.tagName
                state.lastFailure = nil
                Persistence.save(state, to: environment.stateURL)
                switch UpdateCheck.verdict(installed: environment.installedVersion(), latest: release) {
                case .newer(let v): outcome = .newer(version: v)
                case .upToDate(let latest): outcome = .upToDate(latest: latest)
                case .ignored(let why): outcome = .ignored(why)
                }
            } else {
                outcome = .failed("the answer was not a release")
            }
        } catch {
            outcome = .failed(error.localizedDescription)
        }
        if case .failed(let why) = outcome {
            state = loadState()
            state.lastFailure = why
            Persistence.save(state, to: environment.stateURL)
        }
        switch outcome {
        case .newer(let v): available = offered(.newer(version: v), state: loadState())
        case .upToDate: available = nil
        case .skipped, .ignored, .failed: break
        }
        return finish(outcome, manual: manual)
    }

    private func finish(_ outcome: UpdateCheck.Outcome, manual: Bool) -> UpdateCheck.Outcome {
        if case .skipped = outcome {
            if manual { cannotAskLine = outcome.line }
        } else {
            cannotAskLine = nil
            answers += 1
        }
        environment.log("update-check: \(manual ? "check now" : "scheduled"): \(outcome.line)")
        return outcome
    }

    /// After launch, in the background: a first look a minute in, then hourly looks that
    /// ask only once the day has passed. Each look re-reads the switch, so turning it off
    /// in Settings takes effect without a relaunch.
    func start(firstDelay: TimeInterval = 60) {
        guard timer == nil, !Persistence.isUnderTest else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + firstDelay) { [weak self] in
            Task { @MainActor in await self?.run(manual: false) }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.run(manual: false) }
        }
    }
}

extension UpdateChecker.Environment {
    @MainActor static var live: UpdateChecker.Environment {
        UpdateChecker.Environment(
            now: { Date() },
            installedVersion: {
                let bundle = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
                let pretend = try? String(contentsOf: UpdateCheck.pretendVersionURL, encoding: .utf8)
                let compared = UpdateCheck.comparedVersion(bundle: bundle, pretend: pretend)
                if compared != bundle {
                    WakeLog.shared.log("update-check: comparing as \(compared), not \(bundle) (update-check-pretend-version)")
                }
                return compared
            },
            enabled: { AppState.shared.config.updateCheckEnabled },
            firstRunDone: { OnboardingModel.shared.stage == .done },
            network: { await UpdateNetwork.current() },
            fetch: { request in
                let session = URLSession(configuration: UpdateCheck.sessionConfiguration())
                defer { session.finishTasksAndInvalidate() }
                let (data, response) = try await session.data(for: request)
                return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
            },
            stateURL: Persistence.supportDir.appendingPathComponent("update-check.json"),
            log: { WakeLog.shared.log($0) }
        )
    }
}

// The network path right now, read once from NWPathMonitor.
enum UpdateNetwork {
    static func classify(satisfied: Bool, expensive: Bool, constrained: Bool) -> UpdateCheck.Network {
        if !satisfied { return .offline }
        if expensive { return .metered }
        if constrained { return .constrained }
        return .online
    }

    static func current() async -> UpdateCheck.Network {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let once = ResumeOnce()
            monitor.pathUpdateHandler = { path in
                guard once.claim() else { return }
                monitor.cancel()
                continuation.resume(returning: classify(
                    satisfied: path.status == .satisfied,
                    expensive: path.isExpensive,
                    constrained: path.isConstrained))
            }
            monitor.start(queue: DispatchQueue(label: "com.gruxai.grux.update-network"))
        }
    }

    /// The monitor may call back more than once; the continuation resumes exactly once.
    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }
}


// MARK: - U5, what a Now row offers

/// A newer version on offer, and how this copy of Grux was installed.
struct UpdateOffer: Equatable {
    let version: String
    let viaHomebrew: Bool
}

extension UpdateCheck {
    /// GitHub's stable link to the newest release's disk image. Opened in the browser by
    /// Download; Grux itself never downloads or installs anything.
    static let downloadURL = URL(string: "https://github.com/dotcomjack/grux/releases/latest/download/Grux.dmg")!

    /// What a Homebrew install is told instead of Download: brew owns that copy.
    static let brewCommand = "brew upgrade --cask grux"

    /// Settings, General, under "Check for new versions": what is asked, from where, how
    /// often, that nothing about the person is sent, and what off means.
    static let settingsExplanation = "Once a day, Grux asks GitHub's public release page (api.github.com) whether a newer Grux AI exists, and if one does, says so in Now. The request carries nothing about you: no account, no install id, no cookie; like any web request it names your Grux and macOS versions. Grux never downloads or installs anything by itself; Download opens the newest disk image in your browser. Off means it never asks. Check now asks once, even when this is off."

    /// A Homebrew cask install: the app sits in a Caskroom, is a brew symlink into one,
    /// or brew moved it to Applications and keeps its Caskroom entry for `grux`.
    static func installedByHomebrew(appPath: String, resolvedPath: String, caskroomHasGrux: Bool) -> Bool {
        appPath.contains("/Caskroom/") || resolvedPath.contains("/Caskroom/") || caskroomHasGrux
    }

    static func installedByHomebrew() -> Bool {
        let app = Bundle.main.bundleURL
        let fm = FileManager.default
        return installedByHomebrew(
            appPath: app.path,
            resolvedPath: app.resolvingSymlinksInPath().path,
            caskroomHasGrux: fm.fileExists(atPath: "/opt/homebrew/Caskroom/grux")
                || fm.fileExists(atPath: "/usr/local/Caskroom/grux"))
    }

    /// The version the check compares as. A debugging seam for proving the Now row on a
    /// build that is already the latest: `~/.grux/update-check-pretend-version` holding
    /// a version (say 3.0.0) makes the check compare as that version, and wake.log says
    /// so on every check. It changes only the compare, never what is installed.
    static func comparedVersion(bundle: String, pretend: String?) -> String {
        guard let p = pretend?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty,
              components(p) != nil else { return bundle }
        return p
    }

    static var pretendVersionURL: URL { Persistence.gruxDir.appendingPathComponent("update-check-pretend-version") }
}

/// Download, from the Now row. On a headless Mac it opens nothing and says what it held
/// back, like every other door that would put a window on someone else's screen.
@MainActor
enum UpdateDownload {
    static func open(headless: Bool, open: (URL) -> Void, withhold: (String) -> Void) {
        if headless {
            withhold("open the Grux AI download (\(UpdateCheck.downloadURL.absoluteString)) in the browser")
        } else {
            open(UpdateCheck.downloadURL)
        }
    }
}
