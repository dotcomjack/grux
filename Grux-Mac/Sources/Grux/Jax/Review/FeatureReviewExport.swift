import Foundation

// Renders the Feature Review as a self-contained Chrome page (the "export" half
// of in-app + Chrome). Same data the in-app tab shows; one engine, two views.
// Pure string building, no assets. Dark/gold theme, zero em/en dashes.
enum FeatureReviewExport {

    @MainActor
    static func html(features: [ReviewFeature], generatedAt: Date = Date()) -> String {
        let df = DateFormatter(); df.dateFormat = "MMM d, yyyy h:mm a"
        let stamp = df.string(from: generatedAt)

        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;")
             .replacingOccurrences(of: "<", with: "&lt;")
             .replacingOccurrences(of: ">", with: "&gt;")
        }
        func badge(_ s: FeatureStatus) -> String {
            let c: String
            switch s {
            case .staged: c = "#c9962f"
            case .live: c = "#5fae6b"
            case .approved: c = "#5b8fd6"
            case .held: c = "#a89b84"
            case .rejected: c = "#c2563f"
            }
            return "<span class=\"st\" style=\"color:\(c);background:\(c)22;border-color:\(c)66\">\(esc(s.label))</span>"
        }

        // Order: awaiting review first (the queue), then approved/held, then live.
        let order: [FeatureStatus: Int] = [.staged: 0, .approved: 1, .held: 2, .rejected: 3, .live: 4]
        let sorted = features.sorted { (order[$0.status] ?? 9) < (order[$1.status] ?? 9) }
        let staged = features.filter { $0.status == .staged }.count

        func card(_ f: ReviewFeature) -> String {
            let p = f.pitch
            let pitch = p == nil ? "<div class=\"pending\">Pitch not generated yet. Open the Grux Feature Review tab to have Grux write it.</div>" : """
              <div class="row"><span class="k">What it is</span><span class="v">\(esc(p!.what))</span></div>
              <div class="row"><span class="k">Reasoning</span><span class="v">\(esc(p!.reasoning))</span></div>
              <div class="row"><span class="k">What it helps</span><span class="v">\(esc(p!.helps))</span></div>
              <div class="row"><span class="k">Why implement</span><span class="v">\(esc(p!.why))</span></div>
            """
            let actions = f.branch == "staging" ?
              "<div class=\"acts\">Decide in the Grux Feature Review tab: <b>implement to main</b> / hold / reject.</div>" :
              "<div class=\"acts live\">Already on main. This is the explanation, not a gate.</div>"
            return """
            <div class="card" style="--c:\(f.branch == "staging" ? "#c9962f" : "#5fae6b")">
              <div class="top">\(badge(f.status))<span class="sha">\(esc(String(f.id.prefix(8))))</span></div>
              <div class="title">\(esc(f.title))</div>
              \(pitch)
              \(actions)
            </div>
            """
        }

        let cards = sorted.map(card).joined(separator: "\n")

        return """
        <!DOCTYPE html><html lang="en"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>Grux | Feature Review</title><style>
        :root{--bg:#0d0b08;--panel:#16130d;--panel2:#1d1810;--ink:#f3ece0;--ink-soft:#a89b84;--ink-faint:#6f6451;--gold:#b8842e;--gold-soft:rgba(184,132,46,.18);--gold-line:rgba(184,132,46,.4);--line:rgba(243,236,224,.08)}
        *{box-sizing:border-box;margin:0;padding:0}body{background:radial-gradient(1100px 600px at 80% -10%,rgba(184,132,46,.12),transparent 60%),var(--bg);color:var(--ink);font:15px/1.6 -apple-system,system-ui,sans-serif;-webkit-font-smoothing:antialiased;padding-bottom:80px}
        .wrap{max-width:900px;margin:0 auto;padding:0 22px}
        header{padding:46px 0 8px}.eyebrow{font-size:12px;letter-spacing:.22em;text-transform:uppercase;color:var(--gold);margin-bottom:12px}
        h1{font-size:32px;line-height:1.1;letter-spacing:-.02em;font-weight:700;margin-bottom:8px}
        .lede{color:var(--ink-soft);font-size:15px;max-width:680px}.lede b{color:var(--ink)}.stamp{color:var(--ink-faint);font-size:12px;margin-top:8px}
        .count{display:inline-flex;gap:8px;align-items:center;margin-top:14px;font-size:13px;color:var(--ink-soft)}
        .count b{color:var(--gold);font-size:18px}
        .card{background:var(--panel);border:1px solid var(--line);border-left:4px solid var(--c);border-radius:14px;padding:18px 20px;margin:14px 0}
        .top{display:flex;align-items:center;gap:10px;margin-bottom:7px}
        .st{font-size:11px;font-weight:700;letter-spacing:.05em;text-transform:uppercase;padding:2px 9px;border-radius:999px;border:1px solid}
        .sha{margin-left:auto;font:12px ui-monospace,Menlo,monospace;color:var(--ink-faint)}
        .title{font-size:17px;font-weight:600;letter-spacing:-.01em;margin-bottom:12px}
        .row{display:flex;gap:12px;margin:7px 0}
        .k{flex:none;width:108px;font-size:11px;letter-spacing:.06em;text-transform:uppercase;color:var(--gold);padding-top:2px}
        .v{font-size:14px;color:var(--ink-soft)}
        .acts{margin-top:12px;font-size:12.5px;color:var(--ink-faint);border-top:1px solid var(--line);padding-top:9px}
        .acts.live{color:var(--ink-faint)}.acts b{color:#e0c074}
        .pending{font-size:13px;color:var(--ink-faint);font-style:italic}
        footer{color:var(--ink-faint);font-size:12px;text-align:center;padding:36px 0 10px}
        </style></head><body><div class="wrap">
        <header>
          <div class="eyebrow">Grux explains his work &middot; staging to main</div>
          <h1>Feature Review</h1>
          <p class="lede">Every feature Grux built, in his own words: what it is, why he built it that way, what it helps, and why to implement it. Staged features wait for your call; nothing reaches <b>main</b> without your tap. Generated live, not a static doc.</p>
          <div class="count"><b>\(staged)</b> awaiting your review &middot; <b>\(features.count)</b> total</div>
          <div class="stamp">Generated \(stamp). Pitches written by Grux from the real commits.</div>
        </header>
        \(cards)
        <footer>Grux Feature Review. Live + in-app; this is the Chrome export. Implement decisions happen in the Grux tab, merges run green-gated.</footer>
        </div></body></html>
        """
    }
}
