import Foundation
import AppKit
import MusicKit

// Plays an EXACT track through MusicKit's ApplicationMusicPlayer, which queues a
// single resolved Song and plays it in the app's own player session. This fixes
// the two pain points of the old AppleScript catalog path at once:
//   1. No Music.app focus takeover (no UI navigation, no AX Play press, no
//      `activate`). A focus-restore guard neutralizes the documented edge case
//      where some macOS builds still front Music.app.
//   2. No album-then-skip: we queue the exact Song (owned via MusicLibraryRequest,
//      catalog via MusicCatalogResourceRequest by store id), never an album.
//
// Library playback needs only MusicKit authorization (no subscription). Catalog
// playback needs an active Apple Music subscription AND the MusicKit capability
// (com.apple.developer.musickit) provisioned; when either is missing the methods
// return nil so MusicTool falls back to the AppleScript path. Every failure is
// swallowed to nil + logged so playback never hangs and never regresses.
@MainActor
enum MusicKitPlayer {
    private static var cachedAuth: MusicAuthorization.Status?

    /// Request MusicKit authorization once and cache it. Returns true only when
    /// authorized; a denied/restricted state returns false so the caller falls
    /// back. First call surfaces the NSAppleMusicUsageDescription prompt.
    static func ensureAuthorized() async -> Bool {
        if cachedAuth == .authorized { return true }
        let status = await MusicAuthorization.request()
        cachedAuth = status
        return status == .authorized
    }

    /// Play an owned-library track by title (+ optional artist). Returns
    /// "<title> by <artist>" on success, nil on no-match / failure.
    static func playLibrary(song: String, artist: String) async -> String? {
        guard await ensureAuthorized() else { return nil }
        do {
            var req = MusicLibraryRequest<Song>()
            req.filter(matching: \.title, equalTo: song)
            let items = try await req.response().items
            let matched: Song? = artist.isEmpty
                ? items.first
                : (items.first { $0.artistName.localizedCaseInsensitiveContains(artist) } ?? items.first)
            guard let track = matched else { return nil }
            try await playSingle(track)
            return "\(track.title) by \(track.artistName)"
        } catch {
            WakeLog.shared.log("musickit library play failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Play a catalog (streaming) track by its Apple Music store id, which is the
    /// same `trackId` the iTunes Search API returns. Returns nil when the user
    /// is not subscribed / not authorized / the id does not resolve, so the
    /// caller can fall back. No album page, no skip: the exact Song is queued.
    static func playCatalog(storeID: String) async -> String? {
        guard await ensureAuthorized() else { return nil }
        let subscription = try? await MusicSubscription.current
        guard subscription?.canPlayCatalogContent == true else { return nil }
        do {
            let req = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: MusicItemID(storeID))
            guard let track = try await req.response().items.first else { return nil }
            try await playSingle(track)
            return "\(track.title) by \(track.artistName)"
        } catch {
            WakeLog.shared.log("musickit catalog play failed: \(error.localizedDescription)")
            return nil
        }
    }

    // One-shot diagnostic so a CLI trigger can verify whether MusicKit actually
    // FUNCTIONS in this signed build (with or without the restricted
    // com.apple.developer.musickit entitlement) before we commit to a signing /
    // provisioning change. Reports auth status, subscription, a catalog resolve,
    // and an actual play attempt, capturing the precise error string so we can
    // tell "needs the entitlement / developer token" apart from other failures.
    static func probe(testStoreID: String) async -> String {
        var out: [String] = []
        let cur = MusicAuthorization.currentStatus
        out.append("currentStatus=\(cur)")
        var status = cur
        if cur != .authorized {
            status = await MusicAuthorization.request()
            out.append("afterRequest=\(status)")
        }
        guard status == .authorized else { return out.joined(separator: " | ") + " | STOP: not authorized" }
        let sub = try? await MusicSubscription.current
        out.append("canPlayCatalog=\(sub?.canPlayCatalogContent ?? false)")
        do {
            let req = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: MusicItemID(testStoreID))
            let items = try await req.response().items
            if let song = items.first {
                out.append("catalogResolved='\(song.title)' by \(song.artistName)")
                do {
                    let p = ApplicationMusicPlayer.shared
                    p.queue = ApplicationMusicPlayer.Queue(for: [song])
                    try await p.play()
                    out.append("PLAY_OK (no entitlement needed!)")
                } catch {
                    out.append("PLAY_ERR=\(error.localizedDescription)")
                }
            } else {
                out.append("catalogResolved=none")
            }
        } catch {
            out.append("catalogReqErr=\(error.localizedDescription)")
        }
        return out.joined(separator: " | ")
    }

    // Queue exactly one Song and play it, restoring the frontmost app if the
    // player happened to front Music.app (the medium-confidence macOS edge case).
    private static func playSingle(_ song: Song) async throws {
        let prior = NSWorkspace.shared.frontmostApplication
        let player = ApplicationMusicPlayer.shared
        player.queue = ApplicationMusicPlayer.Queue(for: [song])
        try await player.play()
        // Settle, then bounce focus back if Music.app stole it.
        try? await Task.sleep(nanoseconds: 180_000_000)
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.Music",
           let prior, prior.bundleIdentifier != "com.apple.Music" {
            prior.activate()
        }
    }
}
