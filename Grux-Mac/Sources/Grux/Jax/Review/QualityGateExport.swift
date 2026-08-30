import Foundation

// QualityGateExport: renders the quality-gate verdicts for staged features as a
// self-contained Chrome page, the visual counterpart to running the gate. Same
// data the in-app gate panel shows (status, the five adversarial dimensions, the
// dup-scan leads), as a shareable report. Pure string building, dark/gold,
// zero em/en dashes.
enum QualityGateExport {

    @MainActor
    static func html(features: [ReviewFeature], verdicts: [String: QualityVerdict], generatedAt: Date = Date()) -> String {
        let df = DateFormatter(); df.dateFormat = "MMM d, yyyy h:mm a"
        let stamp = df.string(from: generatedAt)

        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;")
             .replacingOccurrences(of: "<", with: "&lt;")
             .replacingOccurrences(of: ">", with: "&gt;")
        }
        func statusColor(_ s: GateStatus) -> String {
            switch s {
            case .pass: return "#5fae6b"
            case .fail: return "#c2563f"
            case .running, .error: return "#c9962f"
            case .pending: return "#a89b84"
            }
        }
        func dimColor(_ d: DimensionVerdict) -> String {
            if d.approved { return "#5fae6b" }
            return d.blocks ? "#c2563f" : "#c9962f"
        }

        let staged = features.filter { $0.status == .staged }
        func card(_ f: ReviewFeature) -> String {
            let v = verdicts[f.id]
            let status = v?.status ?? .pending
            let sc = statusColor(status)
            let dims = (v?.dimensions ?? []).map { d in
                let mark = d.approved ? "cleared" : (d.blocks ? "BLOCKS" : "noted")
                return """
                <div class="dim"><span class="dimname" style="color:\(dimColor(d))">\(esc(d.name.uppercased()))</span>
                <span class="dimmark" style="color:\(dimColor(d))">\(mark)\(d.approved ? "" : " &middot; " + esc(d.severity.rawValue))</span>
                <span class="dimreason">\(esc(d.reason.isEmpty ? "(no detail)" : d.reason))</span></div>
                """
            }.joined(separator: "\n")
            let dup = (v?.dupFindings ?? []).map { "<div class=\"dup\">DUP LEAD &middot; \(esc($0.note))</div>" }.joined(separator: "\n")
            let lines = (v?.diffLineCount ?? 0) > 0 ? "<span class=\"lines\">\(v!.diffLineCount) diff lines</span>" : ""
            return """
            <div class="card" style="--c:\(sc)">
              <div class="top"><span class="st" style="color:\(sc);background:\(sc)22;border-color:\(sc)66">\(esc(status.label))</span><span class="sha">\(esc(String(f.id.prefix(8))))</span>\(lines)</div>
              <div class="title">\(esc(f.title))</div>
              \(v == nil ? "<div class=\"pending\">Not yet reviewed.</div>" : "<div class=\"summary\">\(esc(v!.summary))</div>")
              \(dims)
              \(dup)
            </div>
            """
        }

        let cards = staged.isEmpty
            ? "<div class=\"empty\">No staged features awaiting review. Everything is on main.</div>"
            : staged.map(card).joined(separator: "\n")
        let blocked = staged.filter { verdicts[$0.id]?.status == .fail }.count
        let passed = staged.filter { verdicts[$0.id]?.status == .pass }.count

        return """
        <!DOCTYPE html><html lang="en"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>Grux | Quality Gate</title><style>
        :root{--bg:#0d0b08;--panel:#16130d;--ink:#f3ece0;--ink-soft:#a89b84;--ink-faint:#6f6451;--gold:#b8842e;--line:rgba(243,236,224,.08)}
        *{box-sizing:border-box;margin:0;padding:0}body{background:radial-gradient(1100px 600px at 80% -10%,rgba(184,132,46,.12),transparent 60%),var(--bg);color:var(--ink);font:15px/1.6 -apple-system,system-ui,sans-serif;-webkit-font-smoothing:antialiased;padding-bottom:80px}
        .wrap{max-width:900px;margin:0 auto;padding:0 22px}
        header{padding:46px 0 8px}.eyebrow{font-size:12px;letter-spacing:.22em;text-transform:uppercase;color:var(--gold);margin-bottom:12px}
        h1{font-size:32px;line-height:1.1;letter-spacing:-.02em;font-weight:700;margin-bottom:8px}
        .lede{color:var(--ink-soft);font-size:15px;max-width:680px}.lede b{color:var(--ink)}
        .count{display:inline-flex;gap:16px;align-items:center;margin-top:14px;font-size:13px;color:var(--ink-soft)}.count b{color:var(--gold);font-size:18px}
        .stamp{color:var(--ink-faint);font-size:12px;margin-top:8px}
        .card{background:var(--panel);border:1px solid var(--line);border-left:4px solid var(--c);border-radius:14px;padding:18px 20px;margin:14px 0}
        .top{display:flex;align-items:center;gap:10px;margin-bottom:7px}
        .st{font-size:11px;font-weight:700;letter-spacing:.05em;text-transform:uppercase;padding:2px 9px;border-radius:999px;border:1px solid}
        .sha{font:12px ui-monospace,Menlo,monospace;color:var(--ink-faint)}.lines{margin-left:auto;font:11px ui-monospace,Menlo,monospace;color:var(--ink-faint)}
        .title{font-size:17px;font-weight:600;margin-bottom:8px}
        .summary{font-size:13px;color:var(--ink-soft);margin-bottom:10px}
        .dim{display:grid;grid-template-columns:108px 96px 1fr;gap:10px;align-items:start;padding:5px 0;border-top:1px solid var(--line);font-size:13px}
        .dimname{font-size:10px;font-weight:700;letter-spacing:.06em;padding-top:2px}
        .dimmark{font-size:10px;font-weight:700;text-transform:uppercase;padding-top:2px}
        .dimreason{color:var(--ink-soft)}
        .dup{margin-top:8px;font-size:12.5px;color:#c9962f}
        .pending{color:var(--ink-faint);font-style:italic}
        .empty{color:var(--ink-soft);padding:40px 0;text-align:center}
        footer{color:var(--ink-faint);font-size:12px;text-align:center;padding:36px 0 10px}
        </style></head><body><div class="wrap">
        <header>
          <div class="eyebrow">Grux quality gate &middot; staging to main</div>
          <h1>Quality Gate</h1>
          <p class="lede">Every staged feature, adversarially reviewed across five lenses before it can reach <b>main</b>. Confirmed high or critical objections block the merge. Build and the full test suite run again at land time.</p>
          <div class="count"><span><b>\(passed)</b> passed</span><span><b>\(blocked)</b> blocked</span><span><b>\(staged.count)</b> staged</span></div>
          <div class="stamp">Generated \(stamp). Verdicts written by the live QualityGate engine.</div>
        </header>
        \(cards)
        <footer>Grux Quality Gate. The in-app review half; build + test gate runs in tools/implement-feature.sh at land.</footer>
        </div></body></html>
        """
    }
}
