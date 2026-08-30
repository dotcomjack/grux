import Foundation
import SwiftUI
import CryptoKit

// Global App Store Connect submission monitor - sweeps every 12h across
// EVERY app on the signed-in Apple Developer account (not just projects with a local
// .grux/ship-config.json), records the latest appStoreState per app, and
// surfaces transitions into REJECTED via voice + dashboard red badge so
// rejections are caught within hours instead of days.
//
// Discovery is two-step:
//   1. Find any one .grux/ship-config.json under ~/Projects to get ASC API
//      credentials (they're dev-account-wide - one set works for all apps).
//   2. GET /v1/apps to list every app on the dev account, then GET
//      /v1/apps/{id}/appStoreVersions for each to get latest state.
//
// Project naming: if a bundleId from /v1/apps matches one in a local
// ship-config.json, the row is labeled with the local project directory name
// (e.g. "MyApp"); otherwise it falls back to the ASC app display name
// (e.g. "MyApp - Tagline"). This means apps without a local repo
// still surface in the dashboard.
//
// Why a separate monitor (vs. piggybacking on V2 workflows): V2 workflows only
// poll for projects whose ship-ios-app run is currently active. Once a workflow
// reaches `wait-for-review`, it's only watching ITS project. If Apple rejects
// an app while no workflow is running for that app, nobody notices until someone
// manually checks. This monitor is global and project-agnostic.
//
// Cadence: 12h. Persisted last-sweep timestamp survives Grux restarts. On
// launch, ALWAYS sweeps immediately (one cheap GET per app, and it catches any
// state change that happened while the Mac was asleep), then schedules a
// repeating 12h timer anchored to launch. A Timer does not fire while the Mac
// sleeps, so the launch-sweep is the primary sleep-recovery path, not the timer.
//
// Transition detection: keeps the previous appStoreState per project on disk
// so a sweep can identify "moved INTO rejected this turn" vs. "still rejected
// from yesterday's sweep" - only the former triggers the voice cue.

struct ASCAppRecord: Identifiable, Hashable, Sendable {
    // Identity is the ASC app ID (globally unique). projectName is a display
    // label that can collide (two apps sharing an ASC display name, or a local
    // dir name equal to another app's name), so it must NOT key identity or
    // transition state, else SwiftUI rows and prevStates entries clobber.
    var id: String { ascAppId }
    let projectName: String       // human-facing label only (dir name or ASC display name)
    let bundleId: String
    let ascAppId: String
    let appStoreState: String     // raw ASC state string ("WAITING_FOR_REVIEW" etc.)
    let versionString: String     // "1.0", "1.7.1", etc.
    let lastChecked: Date
    let error: String?            // non-nil on poll failure; appStoreState=="ERROR"

    var inflightURL: URL? {
        guard !ascAppId.isEmpty else { return nil }
        return URL(string: "https://appstoreconnect.apple.com/apps/\(ascAppId)/distribution/ios/version/inflight")
    }

    enum Health { case live, queued, rejected, draft, unknown }

    var health: Health {
        switch appStoreState {
        case "READY_FOR_SALE", "PROCESSING_FOR_DISTRIBUTION", "PENDING_DEVELOPER_RELEASE": .live
        case "WAITING_FOR_REVIEW", "IN_REVIEW", "PREPARED_FOR_REVIEW": .queued
        case "REJECTED", "METADATA_REJECTED", "INVALID_BINARY", "DEVELOPER_REJECTED": .rejected
        case "PREPARE_FOR_SUBMISSION", "DEVELOPER_REMOVED_FROM_SALE", "REPLACED_WITH_NEW_VERSION": .draft
        default: .unknown
        }
    }
}

@MainActor
final class ASCStateMonitor: ObservableObject {
    static let shared = ASCStateMonitor()

    @Published private(set) var records: [ASCAppRecord] = []
    @Published private(set) var isSweeping: Bool = false
    @Published private(set) var lastSweep: Date?
    @Published private(set) var lastError: String?

    static let cadence: TimeInterval = 12 * 60 * 60   // 12h
    private var timer: Timer?
    private var prevStates: [String: String] = [:]    // project → last-known state, for transition detection

    private init() { loadPrevStates() }

    // MARK: - Lifecycle

    func start() {
        // Always sweep on launch - the API cost is tiny (~1 GET per app, ~5 apps)
        // and it catches state changes that happened while Mac was sleeping.
        // The 12h cadence is the steady-state interval, not a launch-throttle.
        Task { await sweep() }
        timer = Timer.scheduledTimer(withTimeInterval: Self.cadence, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.sweep() }
        }
    }

    func sweep() async {
        guard !isSweeping else { return }
        isSweeping = true
        defer { isSweeping = false }

        // Step 1: pick credentials. Any ship-config.json works as the credential
        // source because ASC API keys are dev-account-wide.
        let configs = Self.discoverShipConfigs()
        guard let credsURL = configs.first else {
            lastError = "Need at least one ~/Projects/*/.grux/ship-config.json for ASC API credentials. Currently zero found."
            records = []
            lastSweep = Date()
            persistLastSweep()
            return
        }

        // Step 2: build a bundleId → local project name lookup so apps that DO
        // have a local repo show their friendly directory name (else fall back
        // to the ASC display name).
        var nameByBundle: [String: String] = [:]
        for url in configs {
            if let data = try? Data(contentsOf: url),
               let cfg = try? JSONDecoder().decode(ShipConfig.self, from: data),
               let bid = cfg.bundleId, !bid.isEmpty {
                let projName = url
                    .deletingLastPathComponent()   // .grux/
                    .deletingLastPathComponent()   // <project>/
                    .lastPathComponent
                nameByBundle[bid] = projName
            }
        }

        // Step 3: mint JWT once, then list all apps + their latest state in parallel.
        do {
            let credsData = try Data(contentsOf: credsURL)
            let creds = try JSONDecoder().decode(ShipConfig.self, from: credsData)
            guard
                let keyId = creds.ascApiKeyId, !keyId.isEmpty,
                let issuerId = creds.ascApiKeyIssuerId, !issuerId.isEmpty,
                let p8Raw = creds.ascApiKeyPath, !p8Raw.isEmpty
            else {
                throw NSError(domain: "ASCSweep", code: 10,
                              userInfo: [NSLocalizedDescriptionKey: "credentials ship-config missing keyId/issuer/p8 path"])
            }
            let p8 = NSString(string: p8Raw).expandingTildeInPath
            let jwt = try ASCJWT.mint(keyId: keyId, issuerId: issuerId, p8Path: p8)
            let allApps = try await ASCAPI.fetchAllApps(jwt: jwt)

            let bundleMap = nameByBundle  // immutable snapshot for the closure
            var newRecords: [ASCAppRecord] = []
            await withTaskGroup(of: ASCAppRecord.self) { group in
                for app in allApps {
                    group.addTask {
                        let displayName = bundleMap[app.bundleId] ?? app.name
                        do {
                            let (state, version) = try await ASCAPI.fetchLatestVersion(ascAppId: app.id, jwt: jwt)
                            return ASCAppRecord(
                                projectName: displayName,
                                bundleId: app.bundleId,
                                ascAppId: app.id,
                                appStoreState: state,
                                versionString: version,
                                lastChecked: Date(),
                                error: nil
                            )
                        } catch {
                            return ASCAppRecord(
                                projectName: displayName,
                                bundleId: app.bundleId,
                                ascAppId: app.id,
                                appStoreState: "ERROR",
                                versionString: "-",
                                lastChecked: Date(),
                                error: error.localizedDescription
                            )
                        }
                    }
                }
                for await rec in group { newRecords.append(rec) }
            }

            // Sort: rejected apps first (so they catch the eye), then by name.
            newRecords.sort { lhs, rhs in
                let lr = Self.rejectedStates.contains(lhs.appStoreState)
                let rr = Self.rejectedStates.contains(rhs.appStoreState)
                if lr != rr { return lr }   // rejected before non-rejected
                return lhs.projectName.localizedCaseInsensitiveCompare(rhs.projectName) == .orderedAscending
            }

            // Transition detection - fire ONCE on entry into a rejected state.
            // Keyed on ascAppId (unique), not projectName (a collidable label).
            for r in newRecords where Self.rejectedStates.contains(r.appStoreState) {
                let prev = prevStates[r.ascAppId]
                if prev != r.appStoreState {
                    onNewRejection(r)
                }
            }
            // Only commit SUCCESSFUL reads to prevStates. An ERROR record is a
            // transient per-app poll failure (timeout, 5xx, bad JSON); letting
            // it overwrite the last known good state would make the next
            // successful REJECTED read look like a fresh rejection and re-fire
            // the alert. Preserve the prior state across a blip instead.
            for r in newRecords where r.error == nil { prevStates[r.ascAppId] = r.appStoreState }
            persistPrevStates()

            records = newRecords
            lastError = nil
        } catch {
            lastError = "ASC sweep failed: \(error.localizedDescription)"
        }

        lastSweep = Date()
        persistLastSweep()
    }

    // MARK: - Transition handler

    private static let rejectedStates: Set<String> =
        ["REJECTED", "METADATA_REJECTED", "INVALID_BINARY", "DEVELOPER_REJECTED"]

    private func onNewRejection(_ r: ASCAppRecord) {
        let line = "Heads up - Apple rejected \(r.projectName). Open Empire dashboard to recover."
        WakeLog.shared.log("ASC sweep: \(r.projectName) flipped to \(r.appStoreState) - speaking + posting badge")
        SpeechEngine.shared.speak(line)
        // System notification so it surfaces even if Mac is asleep when Grux wakes.
        NotificationManager.shared.sendInfo(
            title: "Apple rejected \(r.projectName)",
            body: "State: \(r.appStoreState). Open Empire dashboard."
        )
    }

    // MARK: - Discovery

    private static func discoverShipConfigs() -> [URL] {
        let projects = NSHomeDirectory() + "/Projects"
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(atPath: projects) else { return [] }
        var configs: [URL] = []
        for d in dirs {
            let path = "\(projects)/\(d)/.grux/ship-config.json"
            if fm.fileExists(atPath: path) {
                configs.append(URL(fileURLWithPath: path))
            }
        }
        return configs
    }

    // MARK: - Ship-config decoding

    private struct ShipConfig: Decodable {
        let ascAppId: String?
        let bundleId: String?
        let ascApiKeyId: String?
        let ascApiKeyIssuerId: String?
        let ascApiKeyPath: String?
    }

    // MARK: - Persistence (last sweep + prev states across Mac reboots)

    private var stateFileURL: URL {
        Persistence.supportDir.appendingPathComponent("asc-sweep-state.json", isDirectory: false)
    }

    private struct PersistedState: Codable {
        var lastSweep: Date?
        var prevStates: [String: String]
    }

    private func loadPrevStates() {
        guard let data = try? Data(contentsOf: stateFileURL) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let s = try? dec.decode(PersistedState.self, from: data) {
            self.lastSweep = s.lastSweep
            self.prevStates = s.prevStates
        }
    }

    private func persistLastSweep() { savePersisted() }
    private func persistPrevStates() { savePersisted() }
    private func savePersisted() {
        let s = PersistedState(lastSweep: lastSweep, prevStates: prevStates)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(s) {
            try? data.write(to: stateFileURL, options: .atomic)
        }
    }
}

// MARK: - JWT minting (CryptoKit P256 / ES256)

enum ASCJWT {
    enum Error: Swift.Error { case keyReadFailed, keyParseFailed, sigEncodeFailed }

    static func mint(keyId: String, issuerId: String, p8Path: String) throws -> String {
        guard let pem = try? String(contentsOfFile: p8Path, encoding: .utf8) else {
            throw Error.keyReadFailed
        }
        let key: P256.Signing.PrivateKey
        do {
            key = try P256.Signing.PrivateKey(pemRepresentation: pem)
        } catch {
            throw Error.keyParseFailed
        }
        let now = Int(Date().timeIntervalSince1970)
        let header: [String: Any] = ["alg": "ES256", "typ": "JWT", "kid": keyId]
        let payload: [String: Any] = [
            "iss": issuerId, "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"
        ]
        let h = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
        let p = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let signingInput = "\(b64u(h)).\(b64u(p))"
        guard let inputData = signingInput.data(using: .utf8) else { throw Error.sigEncodeFailed }
        let sig = try key.signature(for: inputData)
        // CryptoKit's `rawRepresentation` returns r || s (64 bytes for P256), which is exactly
        // what the JOSE spec wants for ES256. No DER ↔ raw conversion needed.
        return "\(signingInput).\(b64u(sig.rawRepresentation))"
    }

    private static func b64u(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - ASC API call

enum ASCAPI {
    enum Error: Swift.Error { case http(Int, String), badJSON }

    struct AppSummary: Sendable {
        let id: String        // ASC app ID (numeric string)
        let name: String      // ASC display name
        let bundleId: String
    }

    /// Lists every app on the dev account associated with the JWT.
    /// Used by the global sweep to discover apps without a local ship-config.
    static func fetchAllApps(jwt: String) async throws -> [AppSummary] {
        guard let url = URL(string: "https://api.appstoreconnect.apple.com/v1/apps?limit=200") else {
            throw Error.badJSON
        }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 10
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw Error.http((resp as? HTTPURLResponse)?.statusCode ?? -1, String(body.prefix(300)))
        }
        guard
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let arr = obj["data"] as? [[String: Any]]
        else { throw Error.badJSON }

        return arr.compactMap { item in
            guard
                let id = item["id"] as? String,
                let attrs = item["attributes"] as? [String: Any],
                let name = attrs["name"] as? String,
                let bundleId = attrs["bundleId"] as? String
            else { return nil }
            return AppSummary(id: id, name: name, bundleId: bundleId)
        }
    }

    /// Returns (appStoreState, versionString) for the most recently created
    /// AppStoreVersion of the given app. Sorts client-side because ASC's
    /// `?sort=-createdDate` returns 400.
    static func fetchLatestVersion(ascAppId: String, jwt: String) async throws -> (String, String) {
        guard let url = URL(string: "https://api.appstoreconnect.apple.com/v1/apps/\(ascAppId)/appStoreVersions?limit=10") else {
            throw Error.badJSON
        }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 10
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw Error.http(-1, "no HTTPURLResponse")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw Error.http(http.statusCode, String(body.prefix(300)))
        }
        guard
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let arr = obj["data"] as? [[String: Any]]
        else {
            throw Error.badJSON
        }
        // Pick the most recent by createdDate.
        let isoFmt = ISO8601DateFormatter()
        isoFmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoFmt2 = ISO8601DateFormatter()  // some ASC payloads omit fractional seconds
        isoFmt2.formatOptions = [.withInternetDateTime]
        func date(_ s: String?) -> Date {
            guard let s else { return .distantPast }
            return isoFmt.date(from: s) ?? isoFmt2.date(from: s) ?? .distantPast
        }
        let sorted = arr.sorted { a, b in
            let da = date((a["attributes"] as? [String: Any])?["createdDate"] as? String)
            let db = date((b["attributes"] as? [String: Any])?["createdDate"] as? String)
            return da > db
        }
        let attrs = (sorted.first?["attributes"] as? [String: Any]) ?? [:]
        let state = attrs["appStoreState"] as? String ?? "UNKNOWN"
        let version = attrs["versionString"] as? String ?? "?"
        return (state, version)
    }
}
