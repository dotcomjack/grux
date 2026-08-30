import AppKit
import ApplicationServices
import Foundation

// Apple Music playback via AppleScript + iTunes Search API.
//
// Two-stage cascade:
//   1. Library first (fastest, instant): scripts Music.app to find a track
//      whose name (± artist) matches and calls `play`.
//   2. Catalog fallback: hits the free iTunes Search API for the best song
//      match, then `open location` on Music.app to stream from the Apple
//      Music subscription catalog. Requires active Apple Music subscription.
//
// Strategy gate (the user's setting, read fresh every call):
//   - libraryFirst: stage 1 → stage 2 (default)
//   - libraryOnly:  stage 1 only; hard stop on miss
//   - webFirst:     same cascade; the prompt routes Claude to pre-research
//                   before invoking this tool
//
// Requires: Automation permission for Music.app (macOS prompts once; grant
// persists). Library path needs the track to be cloud-available or owned;
// catalog path needs Apple Music subscription.

@MainActor
enum MusicTool {
    static func play(song: String, artist: String = "") async -> String {
        let songTrim = song.trimmingCharacters(in: .whitespacesAndNewlines)
        let artistTrim = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !songTrim.isEmpty else { return "error: empty song name" }

        // PRIMARY: MusicKit ApplicationMusicPlayer queues the EXACT track and
        // plays it in the app's own session, so there is no Music.app focus
        // takeover and no album-then-skip. Falls through to the AppleScript
        // cascade below on any miss/failure so nothing regresses.
        //
        // GATED OFF by default: catalog playback needs the restricted
        // `com.apple.developer.musickit` entitlement, which CRASHES Grux at
        // launch under its self-signed TCC-stable identity (a self-signed cert
        // cannot carry a provisioned restricted entitlement). Enabling MusicKit
        // therefore requires switching Grux to an Apple development/distribution
        // signing identity + provisioning profile, which resets TCC grants on
        // every rebuild. That tradeoff is the user's call. The code is ready: flip
        // `defaults write com.gruxai.grux musicKitEnabled -bool true` once Grux is
        // signed with a MusicKit-provisioned profile.
        if UserDefaults.standard.bool(forKey: "musicKitEnabled"),
           await MusicKitPlayer.ensureAuthorized() {
            if let lib = await MusicKitPlayer.playLibrary(song: songTrim, artist: artistTrim) {
                return "ok: playing '\(lib)'"
            }
            if AppState.shared.config.musicStrategy != .libraryOnly,
               let hit = await searchCatalog(song: songTrim, artist: artistTrim),
               !hit.trackId.isEmpty,
               let cat = await MusicKitPlayer.playCatalog(storeID: hit.trackId) {
                return "ok: playing '\(cat)' (Apple Music catalog)"
            }
        }

        // FALLBACK: the original AppleScript cascade, kept until MusicKit catalog
        // is verified on a shipping macOS build. Library already plays in the
        // background; the catalog path now restores focus after it starts.
        let libResult = playFromLibrary(song: songTrim, artist: artistTrim)
        if libResult.hasPrefix("ok:") { return libResult }
        if libResult.hasPrefix("error:") { return libResult }
        guard libResult.hasPrefix("miss:") else { return libResult }

        if AppState.shared.config.musicStrategy == .libraryOnly {
            return libResult
        }

        let catalogResult = await playFromCatalog(song: songTrim, artist: artistTrim)
        if catalogResult.hasPrefix("ok:") { return catalogResult }
        // The catalog FOUND and opened the track but couldn't auto-start it
        // (usually a missing Accessibility grant). Surface that honestly instead
        // of reporting "not found" - the track is real and on screen.
        if catalogResult.hasPrefix("partial:") { return catalogResult }

        // Both paths failed - combine for Claude to reason about.
        let label = artistTrim.isEmpty ? songTrim : "\(songTrim) by \(artistTrim)"
        return "miss: '\(label)' not found in the local library OR Apple Music catalog. Library said: \(libResult). Catalog said: \(catalogResult)"
    }

    // Library candidate row, parsed out of the AppleScript fetch.
    private struct LibCandidate {
        let persistentID: String
        let name: String
        let artist: String
        let album: String
        let duration: Double
        let playedCount: Int
    }

    private static func playFromLibrary(song: String, artist: String) -> String {
        let songEsc = escapeForAppleScript(song)
        let artistEsc = escapeForAppleScript(artist)

        // Two-stage: (1) fetch all candidates whose name contains the request
        // (and artist contains the artist request when given), (2) score them
        // in Swift, (3) play the winner by persistent ID.
        //
        // Why scoring instead of `item 1 of strictMatches`: AppleScript's
        // `name contains` is a raw substring match, so "play Stan" matches
        // "Outstanding", "Bystanders", "Distant Strangers", etc. The library
        // routinely returned the wrong song. We now favor word-boundary and
        // exact-title hits, penalize Live/Karaoke/Snippet variants, and use
        // Music.app's `played count` as the affinity tiebreaker.
        let strictClause = artist.isEmpty
            ? "name contains \"\(songEsc)\""
            : "name contains \"\(songEsc)\" and artist contains \"\(artistEsc)\""

        // Field separator: U+2016 DOUBLE VERTICAL LINE - extremely unlikely to
        // appear inside a track title. Row separator is linefeed.
        let source = """
        launch application "Music"
        tell application "Music"
            try
                set strictMatches to (every track of library playlist 1 whose \(strictClause))
                set total to count of strictMatches
                if total = 0 then return "miss"
                set maxN to 60
                if total < maxN then set maxN to total

                set rows to "candidates|" & total & linefeed
                repeat with i from 1 to maxN
                    set t to item i of strictMatches
                    set pid to ""
                    try
                        set pid to (persistent ID of t) as string
                    end try
                    set tn to ""
                    try
                        set tn to (name of t) as string
                    end try
                    set ta to ""
                    try
                        set ta to (artist of t) as string
                    end try
                    set tal to ""
                    try
                        set tal to (album of t) as string
                    end try
                    set td to "0"
                    try
                        set td to (duration of t as string)
                    end try
                    set tpc to "0"
                    try
                        set tpc to (played count of t as string)
                    end try
                    set rows to rows & pid & "‖" & tn & "‖" & ta & "‖" & tal & "‖" & td & "‖" & tpc & linefeed
                end repeat
                return rows
            on error errMsg number errNum
                return "err|" & errNum & "|" & errMsg
            end try
        end tell
        """

        var err: NSDictionary?
        let script = NSAppleScript(source: source)
        let result = script?.executeAndReturnError(&err)

        if let err = err {
            let num = (err[NSAppleScript.errorNumber] as? Int).map { String($0) } ?? "?"
            let msg = (err[NSAppleScript.errorMessage] as? String) ?? "unknown"
            if num == "-1743" {
                return "error: macOS blocked Grux from controlling Music. Grant it in System Settings → Privacy & Security → Automation → Grux → Music."
            }
            return "error: Music scripting failed (\(num)): \(msg)"
        }

        let raw = (result?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("err|") {
            let parts = raw.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            if parts.count >= 3 { return "error: Music script failed (\(parts[1])): \(parts[2])" }
            return "error: Music script failed: '\(raw)'"
        }
        if raw == "miss" {
            let label = artist.isEmpty ? song : "\(song) by \(artist)"
            return "miss: '\(label)' not in the local owned library."
        }

        // Parse candidates.
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: true).map { String($0).trimmingCharacters(in: .whitespaces) }
        guard let header = lines.first, header.hasPrefix("candidates|") else {
            return "error: unexpected Music result header: '\(raw.prefix(120))'"
        }
        var candidates: [LibCandidate] = []
        for line in lines.dropFirst() {
            let f = line.components(separatedBy: "‖")
            guard f.count >= 6 else { continue }
            candidates.append(LibCandidate(
                persistentID: f[0],
                name: f[1],
                artist: f[2],
                album: f[3],
                duration: Double(f[4]) ?? 0,
                playedCount: Int(f[5]) ?? 0
            ))
        }
        if candidates.isEmpty {
            let label = artist.isEmpty ? song : "\(song) by \(artist)"
            return "miss: '\(label)' not in the local owned library."
        }

        // Score + rank.
        let scored = candidates.map { ($0, libraryScore(candidate: $0, requestedSong: song, requestedArtist: artist)) }
            .sorted { a, b in
                if a.1 != b.1 { return a.1 > b.1 }
                if a.0.playedCount != b.0.playedCount { return a.0.playedCount > b.0.playedCount }
                return a.0.name.count < b.0.name.count
            }

        // Persist a debug ranking log so we can audit picks later.
        writeRankingLog(query: song, artist: artist, ranked: scored)

        guard let winner = scored.first else {
            let label = artist.isEmpty ? song : "\(song) by \(artist)"
            return "miss: '\(label)' not in the local owned library."
        }

        // Substring-noise gate: a candidate must score at least 30 - the
        // word-boundary threshold - on the name match alone. Without this
        // gate, a substring-noise track with high played count can win on
        // affinity (e.g. 'Stand On It' pc=60 → score 20 from pc alone, no
        // name signal). Threshold of 30 also lets a stripped-suffix match
        // (50) survive a Live/Karaoke penalty stack and still cascade to
        // catalog if penalties drop the score below the bar.
        if winner.1 < 30 {
            let label = artist.isEmpty ? song : "\(song) by \(artist)"
            return "miss: '\(label)' not in the local owned library (only substring noise)."
        }

        // Already-playing check: if the current track matches the winner,
        // don't restart it.
        if isCurrentlyPlaying(candidate: winner.0) {
            return "ok: '\(winner.0.name)' by \(winner.0.artist) already playing - left alone"
        }

        // Play the winner by persistent ID, then map the VERIFIED outcome to the
        // ok/partial/error prefix contract ChatService routes on. Only a probe
        // that confirmed audio is advancing on this track returns "ok:".
        let label = "'\(winner.0.name)' by \(winner.0.artist)"
        let playRes = playByPersistentID(winner.0.persistentID)
        switch playRes {
        case "ok":
            return "ok: playing \(label)"
        case "stalled", "notplaying":
            return "partial: started \(label) but the audio isn't advancing. It may be cloud-unavailable; tap Play in Music."
        case "wrongtrack":
            return "partial: Music is on a different track than \(label); the owned item may be cloud-unavailable."
        default:
            return "error: \(playRes)"
        }
    }

    // Ranks a candidate against the requested song/artist. Higher = better.
    // Hierarchy:
    //   100  exact name match (after normalize)
    //    50  bare title plus a parens/dash variant suffix (e.g. "Stan (feat. Dido)")
    //    30  word-bounded substring (request appears as a whole word in the name)
    //     0  raw substring only (request appears mid-word: "Stan" inside "Outstanding")
    // Modifiers:
    //   - variant penalty for Live / Acoustic / Demo / Remix / Karaoke / Cover / Snippet / Edit
    //   - duration < 60s → -50 (snippet)
    //   + min(playedCount, 20) for affinity
    //   + small bump for exact-artist match (already filtered, so this just
    //     biases toward bare-name match when artist substring matched too loosely)
    private static func libraryScore(candidate: LibCandidate, requestedSong: String, requestedArtist: String) -> Double {
        let req = normalizeForMatch(requestedSong)
        let cand = normalizeForMatch(candidate.name)
        let candStripped = normalizeForMatch(stripVariantSuffix(candidate.name))

        var s: Double = 0
        if cand == req {
            s += 100
        } else if candStripped == req {
            s += 50
        } else if hasWordBoundaryMatch(needle: req, haystack: cand) {
            s += 30
        }

        s -= Double(variantPenalty(name: candidate.name))

        if candidate.duration > 0 && candidate.duration < 60 {
            s -= 50
        }

        s += min(Double(candidate.playedCount), 20)

        if !requestedArtist.isEmpty {
            let candArtist = normalizeForMatch(candidate.artist)
            let reqArt = normalizeForMatch(requestedArtist)
            if candArtist == reqArt {
                s += 8
            } else if hasWordBoundaryMatch(needle: reqArt, haystack: candArtist) {
                s += 4
            }
        }

        return s
    }

    private static func normalizeForMatch(_ s: String) -> String {
        s.lowercased()
            .folding(options: .diacriticInsensitive, locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Strip "(...)", "[...]", and " - <suffix>" so "Stan (feat. Dido)" → "Stan"
    // and "Lose Yourself - From '8 Mile' Soundtrack" → "Lose Yourself".
    private static func stripVariantSuffix(_ s: String) -> String {
        var t = s
        while let r = t.range(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, options: .regularExpression) {
            t.removeSubrange(r)
        }
        if let r = t.range(of: " - ") {
            t.removeSubrange(r.lowerBound..<t.endIndex)
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func hasWordBoundaryMatch(needle: String, haystack: String) -> Bool {
        let n = needle.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return false }
        // \b doesn't always cleanly handle Unicode in NSRegularExpression's
        // default ICU mode; build a manual character-class boundary.
        let escaped = NSRegularExpression.escapedPattern(for: n)
        let pattern = "(^|[^\\p{L}\\p{N}])\(escaped)([^\\p{L}\\p{N}]|$)"
        return haystack.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    // Penalty (added negatively to the score) for variant markers in the title.
    private static func variantPenalty(name: String) -> Int {
        let n = name.lowercased()
        var p = 0
        // Live (any framing).
        if n.contains("(live") || n.contains("[live") || n.contains(" - live") {
            p += 10
        }
        if n.contains("(acoustic") || n.contains("(unplugged") {
            p += 8
        }
        if n.contains("(demo") {
            p += 8
        }
        if n.contains("(remix") || n.contains(" remix)") || n.contains(" remix]") || n.contains("- remix") {
            p += 12
        }
        if n.contains("(karaoke") || n.contains("(instrumental") {
            p += 25
        }
        if n.contains("(cover") {
            p += 20
        }
        if n.contains("snippet") {
            p += 50
        }
        if n.contains("(radio edit") || n.contains("(edit)") || n.contains("(clean") {
            p += 2
        }
        return p
    }

    // Play a track by its Music.app persistent ID. Persistent ID is stable
    // across launches and survives library re-indexing.
    // Returns a sentinel describing the VERIFIED outcome - never a bare "ok"
    // on faith. The two-sample probe (state + position read twice, 0.8s apart)
    // plus a current-track persistent-ID match proves audio is actually
    // advancing on the requested track, so play() can report honestly instead
    // of claiming "now playing" over silence. Sentinels: "ok" (verified),
    // "stalled" (playing but position not advancing), "wrongtrack" (advancing
    // but a different track than requested), "notplaying" (not playing), or
    // "Music play-by-pid failed (...)" on an AppleScript error.
    private static func playByPersistentID(_ pid: String) -> String {
        let pidEsc = escapeForAppleScript(pid)
        let source = """
        tell application "Music"
            try
                set t to (first track of library playlist 1 whose persistent ID is "\(pidEsc)")
                play t
                delay 0.6
                try
                    if player state is paused then play
                end try
                set p1 to 0
                try
                    set p1 to player position
                end try
                set s1 to player state as string
                delay 0.8
                set p2 to 0
                try
                    set p2 to player position
                end try
                set s2 to player state as string
                set cpid to ""
                try
                    set cpid to (persistent ID of current track) as string
                end try
                return "ok|" & s2 & "|" & p1 & "|" & p2 & "|" & cpid
            on error errMsg number errNum
                return "err|" & errNum & "|" & errMsg
            end try
        end tell
        """
        var err: NSDictionary?
        let res = NSAppleScript(source: source)?.executeAndReturnError(&err)
        if let err = err {
            let num = (err[NSAppleScript.errorNumber] as? Int).map { String($0) } ?? "?"
            let msg = (err[NSAppleScript.errorMessage] as? String) ?? "unknown"
            return "Music play-by-pid failed (\(num)): \(msg)"
        }
        let raw = (res?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = raw.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        // parts: ok|s2|p1|p2|cpid
        guard parts.first == "ok", parts.count >= 5 else {
            return "play-by-pid said: \(raw)"
        }
        let state = parts[1]
        let p1 = Double(parts[2]) ?? 0
        let p2 = Double(parts[3]) ?? 0
        let cpid = parts[4]
        let advancing = p2 > p1 + 0.3
        // Empty cpid = cloud-only track that won't expose a persistent ID; treat
        // as a match rather than a false wrongtrack as long as audio advances.
        let pidMatches = cpid.isEmpty || cpid.uppercased() == pid.uppercased()

        if state == "playing" && advancing && pidMatches { return "ok" }
        if state == "playing" && advancing && !pidMatches { return "wrongtrack" }
        if state == "playing" { return "stalled" }
        return "notplaying"
    }

    // Detects whether the candidate Grux is about to play is already the
    // current track. Tolerates the property-read failures Music.app emits on
    // some cloud-only items.
    private static func isCurrentlyPlaying(candidate: LibCandidate) -> Bool {
        let source = """
        tell application "Music"
            try
                if player state is not playing then return "no"
                set cn to (name of current track) as string
                set ca to (artist of current track) as string
                return cn & "‖" & ca
            on error
                return "no"
            end try
        end tell
        """
        var err: NSDictionary?
        let res = NSAppleScript(source: source)?.executeAndReturnError(&err)
        if err != nil { return false }
        let raw = (res?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if raw == "no" || raw.isEmpty { return false }
        let parts = raw.components(separatedBy: "‖")
        guard parts.count >= 2 else { return false }
        return parts[0] == candidate.name && parts[1] == candidate.artist
    }

    // Append a one-line summary of the ranking decision to the audit log so we
    // can replay why Grux picked what it picked. Path mirrors the FS audit log.
    private static func writeRankingLog(query: String, artist: String, ranked: [(LibCandidate, Double)]) {
        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = support.appendingPathComponent("Grux", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let logPath = dir.appendingPathComponent("music-ranking.log")

        let stamp = ISO8601DateFormatter().string(from: Date())
        let label = artist.isEmpty ? "'\(query)'" : "'\(query)' by \(artist)"
        var lines = ["\(stamp)  request=\(label)  candidates=\(ranked.count)"]
        for (i, pair) in ranked.prefix(8).enumerated() {
            let c = pair.0
            let durStr = String(format: "%.0fs", c.duration)
            lines.append("  #\(i + 1)  score=\(String(format: "%.1f", pair.1))  pc=\(c.playedCount)  \(durStr)  '\(c.name)' - \(c.artist) · \(c.album)")
        }
        let payload = lines.joined(separator: "\n") + "\n\n"
        LogRotation.appendRotating(payload, to: logPath)
    }

    // MARK: - Apple Music catalog (iTunes Search API + open location)

    private struct CatalogHit {
        let trackName: String
        let artistName: String
        let albumName: String
        let trackViewUrl: String
        let trackNumber: Int  // 1-based within the album (0 if unknown)
        let trackId: String   // Apple Music catalog store id (== MusicKit Song id)
    }

    private static func playFromCatalog(song: String, artist: String) async -> String {
        // The catalog path has to front Music.app to AX-press Play. Snapshot
        // the frontmost app and bounce focus back on every exit so the
        // takeover is transient, not permanent. (The MusicKit primary path
        // avoids fronting entirely; this only runs as the fallback.)
        let priorApp = NSWorkspace.shared.frontmostApplication
        defer {
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.Music",
               let priorApp, priorApp.bundleIdentifier != "com.apple.Music" {
                priorApp.activate()
            }
        }
        guard let hit = await searchCatalog(song: song, artist: artist) else {
            let label = artist.isEmpty ? song : "\(song) by \(artist)"
            return "miss: no Apple Music catalog hit for '\(label)'."
        }

        // Rewrite https://music.apple.com/... to music://music.apple.com/...
        // so `open location` deep-links into Music.app instead of the default
        // HTTP handler (Chrome/Safari). Without this rewrite the URL opens in
        // the browser and Music.app lands on its "New" browse page.
        let musicUrl = hit.trackViewUrl.hasPrefix("https://")
            ? "music://" + hit.trackViewUrl.dropFirst("https://".count)
            : hit.trackViewUrl
        let urlEsc = escapeForAppleScript(musicUrl)
        let albumTail = hit.albumName.isEmpty ? "" : " · \(hit.albumName)"

        // Step 1 - AppleScript: navigate Music.app to the track page.
        // `open location` with a catalog URL opens the subscription page but
        // does NOT auto-play; we need to press Play afterwards.
        let openSource = """
        tell application "Music"
            try
                try
                    stop
                end try
                activate
                open location "\(urlEsc)"
                return "ok"
            on error errMsg number errNum
                return "err|" & errNum & "|" & errMsg
            end try
        end tell
        """
        var openErr: NSDictionary?
        let openResult = NSAppleScript(source: openSource)?.executeAndReturnError(&openErr)
        if let openErr = openErr {
            let num = (openErr[NSAppleScript.errorNumber] as? Int).map { String($0) } ?? "?"
            let msg = (openErr[NSAppleScript.errorMessage] as? String) ?? "unknown"
            if num == "-1743" {
                return "error: macOS blocked Grux from controlling Music. Grant Automation → Grux → Music in System Settings."
            }
            return "error: Music catalog open failed (\(num)): \(msg)"
        }
        let openRaw = (openResult?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if openRaw.hasPrefix("err") {
            return "error: Music catalog open: \(openRaw)"
        }

        // Step 2 - Wait for Music.app to render the track page, then press
        // the Play button directly via AXUIElement. Space keystroke doesn't
        // reliably trigger playback on catalog store pages; AX-pressing the
        // Play button does. Requires Accessibility grant (Grux has it).
        try? await Task.sleep(nanoseconds: 2_500_000_000)

        _ = activateMusicApp()
        try? await Task.sleep(nanoseconds: 350_000_000)

        // The catalog path can ONLY start playback by AX-pressing the Play
        // button, which needs Accessibility. Check up front (non-prompting, so
        // no system dialog pops mid voice-command) and bail honestly if denied
        // rather than pressing into the void and then claiming "now playing".
        if !accessibilityGranted() {
            return "partial: opened '\(hit.trackName)' by \(hit.artistName)\(albumTail) in Apple Music, but Grux needs Accessibility access to press Play. Grant Grux under System Settings > Privacy & Security > Accessibility, then ask again."
        }

        let pressed = pressMusicPlayButton()

        // Step 3 - Verify playback actually registered.
        try? await Task.sleep(nanoseconds: 1_500_000_000)

        // Verify: read state + position twice separated by 0.8s so we can
        // confirm the position is actually advancing (Music.app sometimes
        // reports state="playing" but position stuck at 0 when the page is in
        // a limbo state). Catalog track names can fail to coerce into Unicode
        // text, so we wrap each metadata read in its own try.
        let verifySource = """
        tell application "Music"
            set s1 to player state as string
            set p1 to 0
            try
                set p1 to player position
            end try
            delay 0.8
            set p2 to 0
            try
                set p2 to player position
            end try
            set s2 to player state as string
            set tName to "?"
            try
                set tName to (name of current track as string)
            end try
            set tArtist to "?"
            try
                set tArtist to (artist of current track as string)
            end try
            return "ok|" & tName & "|" & tArtist & "|" & s2 & "|" & p1 & "|" & p2
        end tell
        """
        var verifyErr: NSDictionary?
        let verifyResult = NSAppleScript(source: verifySource)?.executeAndReturnError(&verifyErr)
        let verifyRaw = (verifyResult?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = verifyRaw.split(separator: "|", omittingEmptySubsequences: false).map(String.init)

        // verifyRaw format: ok|name|artist|state|p1|p2
        if parts.first == "ok" && parts.count >= 6 {
            let curState = parts[3]
            let p1 = Double(parts[4]) ?? 0
            let p2 = Double(parts[5]) ?? 0
            var advancing = p2 > p1 + 0.3
            var playedName = parts[1] == "?" ? hit.trackName : parts[1]
            var playedArtist = parts[2] == "?" ? hit.artistName : parts[2]

            // The album-header Play button starts the album from track 1,
            // ignoring the `?i=TRACKID` param. If we landed on the wrong
            // track AND we know the target's track number, hop exactly
            // (trackNumber - 1) times to reach it.
            if curState == "playing" && advancing
               && !trackMatches(playedName, hit.trackName)
               && hit.trackNumber > 1 {
                let hopped = skipTracks(hops: hit.trackNumber - 1)
                if !hopped.name.isEmpty { playedName = hopped.name }
                if !hopped.artist.isEmpty { playedArtist = hopped.artist }
                advancing = true
            }

            if curState == "playing" && advancing {
                return "ok: playing '\(playedName)' by \(playedArtist)\(albumTail) (Apple Music catalog - not in your library)"
            }
            // NOT actually advancing: do NOT report success. A "partial:" makes
            // play() surface an honest result instead of Grux claiming "now
            // playing" while silence plays. The usual cause is a missing
            // Accessibility grant, so the AX Play-press never lands.
            if curState == "playing" {
                return "partial: opened '\(playedName)' by \(playedArtist) in Apple Music but audio isn't advancing (pos \(p1)→\(p2)). Tap Play, or grant Grux Accessibility in System Settings > Privacy & Security > Accessibility."
            }
            let hint = pressed ? "pressed Play but Music stayed \(curState)" : "couldn't auto-press the Play button"
            return "partial: opened '\(playedName)' by \(playedArtist)\(albumTail) in Apple Music - \(hint). Tap Play, or grant Grux Accessibility (System Settings > Privacy & Security > Accessibility)."
        }

        // Verify script itself failed.
        let hint = pressed ? "pressed Play but Music didn't start" : "couldn't auto-press the Play button"
        return "partial: opened '\(hit.trackName)' by \(hit.artistName)\(albumTail) in Apple Music - \(hint). Tap Play, or grant Grux Accessibility (System Settings > Privacy & Security > Accessibility)."
    }

    private static func trackMatches(_ current: String, _ target: String) -> Bool {
        let c = current.lowercased().trimmingCharacters(in: .whitespaces)
        let t = target.lowercased().trimmingCharacters(in: .whitespaces)
        if c.isEmpty || t.isEmpty { return false }
        return c == t || c.contains(t) || t.contains(c)
    }

    // Hop forward exactly `hops` tracks, then read the final track name/artist.
    // Used after the album-header Play lands us on track 1 when we actually
    // wanted track N - iTunes Search's trackNumber gives us the target index.
    private static func skipTracks(hops: Int) -> (name: String, artist: String) {
        guard hops > 0 else { return ("", "") }
        let clamped = min(hops, 30)
        let script = """
        tell application "Music"
            repeat \(clamped) times
                try
                    next track
                end try
            end repeat
            delay 0.8
            set nm to "?"
            try
                set nm to (name of current track as string)
            end try
            set ar to "?"
            try
                set ar to (artist of current track as string)
            end try
            return nm & "|" & ar
        end tell
        """
        var err: NSDictionary?
        let res = NSAppleScript(source: script)?.executeAndReturnError(&err)
        if err != nil { return ("", "") }
        let raw = (res?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let bits = raw.split(separator: "|", maxSplits: 1).map(String.init)
        let nm = bits.first ?? ""
        let ar = bits.count > 1 ? bits[1] : ""
        return (nm == "?" ? "" : nm, ar == "?" ? "" : ar)
    }

    private static func activateMusicApp() -> Bool {
        guard let musicApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").first else {
            return false
        }
        return musicApp.activate(options: [])
    }

    // Non-prompting Accessibility check. Deliberately NOT the
    // AXIsProcessTrustedWithOptions(prompt:true) variant - we never want a
    // system permission dialog to pop in the middle of a voice command. If this
    // returns false the catalog play path surfaces an honest "grant Accessibility"
    // partial instead of pressing a button it can't reach.
    private static func accessibilityGranted() -> Bool {
        AXIsProcessTrusted()
    }

    // Walk Music.app's accessibility tree and AX-press the first Play button.
    // Requires Accessibility grant for Grux. Targets the big "Play" button on
    // the track/album page that `open location` navigated to.
    private static func pressMusicPlayButton() -> Bool {
        guard let musicApp = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.Music").first else { return false }
        let axApp = AXUIElementCreateApplication(musicApp.processIdentifier)

        // Prefer searching the main window first - that's where the Play
        // button lives after open-location.
        var windowRef: CFTypeRef?
        AXUIElementCopyAttributeValue(axApp, kAXMainWindowAttribute as CFString, &windowRef)
        let root: AXUIElement = (windowRef as! AXUIElement?) ?? axApp

        return findAndPressPlay(in: root, depth: 0)
    }

    // Debug helper: walk Music.app's main window and return a formatted list
    // of every AXButton with its title, description, subrole, and position.
    // Used by --dump-music-ax to diagnose which button Grux should press.
    static func dumpMusicAXButtons() -> String {
        guard let musicApp = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.Music").first else {
            return "ERROR: Music.app is not running - launch it first."
        }
        let axApp = AXUIElementCreateApplication(musicApp.processIdentifier)
        var windowRef: CFTypeRef?
        AXUIElementCopyAttributeValue(axApp, kAXMainWindowAttribute as CFString, &windowRef)
        guard let window = windowRef as! AXUIElement? else {
            return "ERROR: Music.app has no main window."
        }
        var lines: [String] = []
        lines.append("=== Music.app AX button dump ===")
        walkDumpButtons(window, depth: 0, out: &lines)
        lines.append("=== end ===")
        return lines.joined(separator: "\n")
    }

    private static func walkDumpButtons(_ element: AXUIElement, depth: Int, out: inout [String]) {
        if depth > 25 { return }
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let role = (roleRef as? String) ?? ""
        if role == (kAXButtonRole as String) {
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef)
            var descRef: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &descRef)
            var subRef: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subRef)
            var helpRef: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXHelpAttribute as CFString, &helpRef)
            let title = (titleRef as? String) ?? ""
            let desc = (descRef as? String) ?? ""
            let sub = (subRef as? String) ?? ""
            let help = (helpRef as? String) ?? ""
            let indent = String(repeating: "  ", count: depth)
            out.append("\(indent)BTN depth=\(depth) title='\(title)' desc='\(desc)' sub='\(sub)' help='\(help)'")
        }
        var childrenRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef)
        if let children = childrenRef as? [AXUIElement] {
            for child in children {
                walkDumpButtons(child, depth: depth + 1, out: &out)
            }
        }
    }

    private static func findAndPressPlay(in element: AXUIElement, depth: Int) -> Bool {
        if depth > 20 { return false }

        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let role = (roleRef as? String) ?? ""

        if role == (kAXButtonRole as String) {
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef)
            let title = (titleRef as? String) ?? ""

            var descRef: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &descRef)
            let desc = (descRef as? String) ?? ""

            let combined = (title + " " + desc).lowercased().trimmingCharacters(in: .whitespaces)
            // Exact "play" match - avoids "playlist", "play next", "play later", etc.
            if combined == "play" || title.lowercased() == "play" || desc.lowercased() == "play" {
                let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
                if result == .success { return true }
            }
        }

        var childrenRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef)
        if let children = childrenRef as? [AXUIElement] {
            for child in children {
                if findAndPressPlay(in: child, depth: depth + 1) { return true }
            }
        }
        return false
    }

    private static func searchCatalog(song: String, artist: String) async -> CatalogHit? {
        let term = artist.isEmpty ? song : "\(song) \(artist)"
        guard var comps = URLComponents(string: "https://itunes.apple.com/search") else { return nil }
        comps.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "15"),
            URLQueryItem(name: "country", value: "US"),
            URLQueryItem(name: "media", value: "music"),
        ]
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            guard
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let results = json["results"] as? [[String: Any]],
                !results.isEmpty
            else { return nil }

            let songLower = song.lowercased()
            let artistLower = artist.lowercased()

            var best: (hit: CatalogHit, score: Int, index: Int)? = nil
            for (idx, r) in results.enumerated() {
                guard
                    let trackName = r["trackName"] as? String,
                    let artistName = r["artistName"] as? String,
                    let trackViewUrl = r["trackViewUrl"] as? String
                else { continue }
                let albumName = (r["collectionName"] as? String) ?? ""

                var score = 0
                let tnLower = trackName.lowercased()
                let anLower = artistName.lowercased()
                if tnLower == songLower { score += 10 }
                else if tnLower.hasPrefix(songLower) { score += 7 }
                else if tnLower.contains(songLower) { score += 5 }
                else if songLower.contains(tnLower) { score += 3 }

                if !artistLower.isEmpty {
                    if anLower == artistLower { score += 10 }
                    else if anLower.contains(artistLower) { score += 5 }
                    else if artistLower.contains(anLower) { score += 3 }
                }

                let trackNumber = (r["trackNumber"] as? Int) ?? 0
                let trackId = (r["trackId"] as? Int).map(String.init) ?? ""
                let hit = CatalogHit(
                    trackName: trackName,
                    artistName: artistName,
                    albumName: albumName,
                    trackViewUrl: trackViewUrl,
                    trackNumber: trackNumber,
                    trackId: trackId
                )
                if best == nil || score > best!.score || (score == best!.score && idx < best!.index) {
                    best = (hit, score, idx)
                }
            }
            // Require at least some signal - pure zero-score results usually
            // mean the API returned tangentially related items (e.g.
            // term="stan" → "Why'd You Only Call Me When You're High?" cover).
            // We'd rather return nil and let the caller report a miss than
            // play a tangentially related track.
            if let b = best, b.score > 0 { return b.hit }
            return nil
        } catch {
            return nil
        }
    }

    // MARK: - Library listing (kept for vague-request resolution)

    // Returns a machine-readable listing of every track in the local Apple Music
    // library whose artist CONTAINS the given substring (case-insensitive by
    // default in AppleScript's `contains`). Used by Claude whenever the user asks
    // for a song by an artist without naming the specific track - Claude can
    // pick an owned track by mood and call `play_music_track` with an exact
    // (song, artist) pair that WILL hit.
    static func listLibraryTracks(artist: String, limit: Int = 20) -> String {
        let artistTrim = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !artistTrim.isEmpty else { return "error: empty artist" }

        let clampedLimit = max(1, min(50, limit))
        let artistEsc = escapeForAppleScript(artistTrim)

        let source = """
        launch application "Music"
        tell application "Music"
            try
                set matches to (every track of library playlist 1 whose artist contains "\(artistEsc)")
                set total to count of matches
                if total = 0 then return "empty"
                set maxN to \(clampedLimit)
                if total < maxN then set maxN to total
                set lines to ""
                repeat with i from 1 to maxN
                    set t to item i of matches
                    try
                        set tName to name of t
                        set tArtist to artist of t
                        set tAlbum to album of t
                        set lines to lines & tName & " ||| " & tArtist & " ||| " & tAlbum & linefeed
                    end try
                end repeat
                return "ok|" & total & "|" & lines
            on error errMsg number errNum
                return "err|" & errNum & "|" & errMsg
            end try
        end tell
        """

        var err: NSDictionary?
        let script = NSAppleScript(source: source)
        let result = script?.executeAndReturnError(&err)

        if let err = err {
            let num = (err[NSAppleScript.errorNumber] as? Int).map { String($0) } ?? "?"
            let msg = (err[NSAppleScript.errorMessage] as? String) ?? "unknown"
            if num == "-1743" {
                return "error: macOS blocked Grux from controlling Music. Grant it in System Settings → Privacy & Security → Automation → Grux → Music."
            }
            return "error: Music scripting failed (\(num)): \(msg)"
        }

        let raw = (result?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if raw == "empty" {
            return "empty: no owned tracks whose artist contains '\(artistTrim)'. This artist is not in the local library - call play_music_track directly (it will stream from the Apple Music catalog)."
        }
        let parts = raw.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        if parts.first == "err", parts.count >= 3 {
            return "error: Music script failed (\(parts[1])): \(parts[2])"
        }
        guard parts.count == 3, parts[0] == "ok" else {
            return "error: unexpected list result: '\(raw.prefix(120))'"
        }
        let total = parts[1]
        let rows = parts[2]
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .prefix(clampedLimit)

        let formatted = rows.enumerated().map { (i, line) -> String in
            let fields = line.components(separatedBy: " ||| ")
            let name = fields.first ?? ""
            let artistF = fields.count > 1 ? fields[1] : ""
            let albumF = fields.count > 2 ? fields[2] : ""
            return "\(i + 1). '\(name)' by \(artistF)\(albumF.isEmpty ? "" : " · \(albumF)")"
        }.joined(separator: "\n")

        return """
        ok: \(total) owned track(s) by '\(artistTrim)' - showing up to \(clampedLimit):
        \(formatted)
        Next step: call play_music_track with song=exact-track-name and artist=exact-artist-name from this list.
        """
    }

    private static func escapeForAppleScript(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
