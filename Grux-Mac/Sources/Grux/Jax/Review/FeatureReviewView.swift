import SwiftUI
import AppKit

// The in-app, live half of Feature Review: Grux pitches each feature he built and
// you decide what reaches main. Staged features carry implement / hold / reject;
// live (already on main) features are explained, not gated. "Export to Chrome"
// writes the same as a shareable page. Nothing static: every pitch is generated
// by Grux from the real commit and can be regenerated.
struct FeatureReviewView: View {
    @StateObject private var engine = FeatureReviewEngine.shared

    private var staged: [ReviewFeature] { engine.features.filter { $0.status == .staged } }
    private var decided: [ReviewFeature] { engine.features.filter { $0.status == .held || $0.status == .rejected || $0.status == .approved } }
    private var live: [ReviewFeature] { engine.features.filter { $0.status == .live } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: GruxSpacing.l) {
                header
                if engine.features.isEmpty {
                    OperatorToolNoticeView(tool: .featureReview)
                } else {
                    if !staged.isEmpty {
                        section("Awaiting your review", staged, accent: GruxTheme.warnAmber)
                    }
                    if !decided.isEmpty {
                        section("Decided", decided, accent: GruxTheme.accentCo)
                    }
                    section("Live on main", live, accent: GruxTheme.accentPrimary)
                }
            }
            .padding(GruxSpacing.xl)
            // This tab is almost entirely prose, so it is the one that suffers
            // most from an uncapped pane. Measured at a 2400pt window, a single
            // REASONING line ran the full width unbroken, which is roughly three
            // times a readable measure. Bounding the column here rather than at
            // the scroll view keeps the scrollbar on the pane edge where it
            // belongs. Inert at the 840pt floor, where the pane is handed 599.
            .frame(maxWidth: GruxLayout.contentMax, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(GruxTheme.base)
        .onAppear {
            engine.bootstrap()
            Task { await engine.generateMissingPitches() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("FEATURE REVIEW").font(.system(size: 12, weight: .bold)).tracking(2).foregroundStyle(GruxTheme.accentPrimary)
            Text("Grux explains his work, you decide what reaches main")
                .font(.system(size: 22, weight: .bold)).foregroundStyle(GruxTheme.textPrimary)
            Text("\(staged.count) awaiting review, \(engine.features.count) total. Every pitch is written live from the real commit. Nothing reaches main without your tap.")
                .font(.system(size: 13)).foregroundStyle(GruxTheme.textSecondary)
            HStack(spacing: 10) {
                Button {
                    Task { await engine.generateMissingPitches() }
                } label: { Label(engine.isGenerating ? "Generating..." : "Generate pitches", systemImage: "sparkles") }
                    .disabled(engine.isGenerating)
                Button {
                    let html = FeatureReviewExport.html(features: engine.features)
                    let out = Persistence.exportsDir.appendingPathComponent("grux-feature-review.html").path
                    try? html.write(toFile: out, atomically: true, encoding: .utf8)
                    NSWorkspace.shared.open(URL(fileURLWithPath: out))
                } label: { Label("Export to Chrome", systemImage: "safari") }
            }
            .font(.system(size: 12, weight: .semibold)).padding(.top, 6)
        }
    }

    private func section(_ title: String, _ items: [ReviewFeature], accent: Color) -> some View {
        VStack(alignment: .leading, spacing: GruxSpacing.m) {
            Text(title.uppercased()).font(.system(size: 11, weight: .bold)).tracking(1.2).foregroundStyle(accent)
            ForEach(items) { f in featureCard(f, accent: accent) }
        }
    }

    private func featureCard(_ f: ReviewFeature, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(f.status.label.uppercased())
                    .font(.system(size: 10, weight: .bold)).tracking(0.5)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(accent.opacity(0.16)).foregroundStyle(accent).clipShape(Capsule())
                Spacer()
                Text(String(f.id.prefix(8))).font(.system(size: 11, design: .monospaced)).foregroundStyle(GruxTheme.textSecondary.opacity(0.6))
            }
            Text(f.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(GruxTheme.textPrimary).fixedSize(horizontal: false, vertical: true)

            if let p = f.pitch {
                pitchRow("WHAT IT IS", p.what)
                pitchRow("REASONING", p.reasoning)
                pitchRow("WHAT IT HELPS", p.helps)
                pitchRow("WHY IMPLEMENT", p.why)
            } else {
                Text("Grux has not written this pitch yet.").font(.system(size: 13)).foregroundStyle(GruxTheme.textSecondary).italic()
            }

            if f.status == .staged { gatePanel(f) }

            HStack(spacing: 8) {
                Button { Task { await engine.regeneratePitch(for: f.id) } } label: {
                    Label("Regenerate", systemImage: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
                }.buttonStyle(.plain).foregroundStyle(GruxTheme.accentPrimary)
                Spacer()
                if f.status == .staged {
                    let gatePassed = engine.verdicts[f.id]?.status == .pass
                    let gating = engine.gatingIDs.contains(f.id)
                    Button("Reject") { engine.reject(f.id) }.foregroundStyle(GruxTheme.destructiveRose)
                    Button("Hold") { engine.hold(f.id) }.foregroundStyle(GruxTheme.textSecondary)
                    Button(gating ? "Reviewing..." : "Run quality gate") { Task { await engine.runGate(for: f.id) } }
                        .disabled(gating)
                        .foregroundStyle(GruxTheme.accentCo)
                    Button("Implement to main") { engine.implementToMain(f.id) }
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(gatePassed ? accent : GruxTheme.textTertiary.opacity(0.4))
                        .disabled(!gatePassed)
                }
            }
            .font(.system(size: 12, weight: .semibold)).padding(.top, 4)
        }
        .padding(16)
        .background(Color(red: 0x16/255, green: 0x13/255, blue: 0x0d/255))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(GruxTheme.textTertiary.opacity(0.15), lineWidth: 1))
        .overlay(Rectangle().fill(accent).frame(width: 3).clipShape(RoundedRectangle(cornerRadius: 2)), alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // Scrubs at the RENDER boundary, not only where the model reply is parsed.
    // Parsing is where a pitch is created, so scrubbing there fixes every future
    // pitch and nothing already on disk. The tab is full of pitches generated
    // before that fix, and they still showed "catch regressions<em dash>so you
    // can trust the autonomy layer" on screen. Scrubbing here covers stored and
    // future copy alike, and costs one pass over four short strings per card.
    private func pitchRow(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(k).font(.system(size: 10, weight: .bold)).tracking(0.5).foregroundStyle(GruxTheme.accentPrimary)
                .frame(width: 104, alignment: .leading).padding(.top, 2)
            Text(DashSanitizer.stripDashesOnly(v))
                .font(.system(size: 13)).foregroundStyle(GruxTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // The quality-gate panel: the proof a staged feature survived adversarial
    // review + the dup scan before its Implement button unlocks. Honest about
    // state: not reviewed / reviewing / passed / blocked / could-not-review.
    @ViewBuilder
    private func gatePanel(_ f: ReviewFeature) -> some View {
        let v = engine.verdicts[f.id]
        let status = engine.gatingIDs.contains(f.id) ? GateStatus.running : (v?.status ?? .pending)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: gateIcon(status)).font(.system(size: 11, weight: .bold)).foregroundStyle(gateColor(status))
                Text("QUALITY GATE: \(status.label.uppercased())").font(.system(size: 10, weight: .bold)).tracking(0.6).foregroundStyle(gateColor(status))
                Spacer()
                if let v, v.status != .running, v.diffLineCount > 0 {
                    Text("\(v.diffLineCount) diff lines").font(.system(size: 10, design: .monospaced)).foregroundStyle(GruxTheme.textSecondary.opacity(0.5))
                }
            }
            if let v, !v.summary.isEmpty, v.status != .running {
                Text(v.summary).font(.system(size: 11)).foregroundStyle(GruxTheme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            if let v {
                ForEach(v.dimensions) { d in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: d.approved ? "checkmark.circle.fill" : (d.blocks ? "xmark.octagon.fill" : "exclamationmark.triangle.fill"))
                            .font(.system(size: 10)).foregroundStyle(d.approved ? GruxTheme.successMint : (d.blocks ? GruxTheme.destructiveRose : GruxTheme.warnAmber))
                            .padding(.top, 2)
                        Text(d.name.uppercased()).font(.system(size: 9, weight: .bold)).tracking(0.4).foregroundStyle(GruxTheme.textSecondary.opacity(0.7)).frame(width: 78, alignment: .leading).padding(.top, 2)
                        Text(d.reason.isEmpty ? (d.approved ? "cleared" : "objection") : d.reason)
                            .font(.system(size: 11)).foregroundStyle(d.blocks ? GruxTheme.destructiveRose : GruxTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !v.dupFindings.isEmpty {
                    ForEach(v.dupFindings) { dup in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "doc.on.doc").font(.system(size: 10)).foregroundStyle(GruxTheme.warnAmber).padding(.top, 2)
                            Text("DUP LEAD").font(.system(size: 9, weight: .bold)).tracking(0.4).foregroundStyle(GruxTheme.warnAmber).frame(width: 78, alignment: .leading).padding(.top, 2)
                            Text(dup.note).font(.system(size: 11)).foregroundStyle(GruxTheme.textSecondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            } else {
                Text("Run the gate to adversarially review this change before it can reach main.")
                    .font(.system(size: 11)).foregroundStyle(GruxTheme.textSecondary.opacity(0.7)).italic()
            }
        }
        .padding(10)
        .background(gateColor(status).opacity(0.06))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(gateColor(status).opacity(0.25), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.top, 4)
    }

    private func gateColor(_ s: GateStatus) -> Color {
        switch s {
        case .pass: return GruxTheme.successMint
        case .fail: return GruxTheme.destructiveRose
        case .running, .error: return GruxTheme.warnAmber
        case .pending: return GruxTheme.textTertiary
        }
    }

    private func gateIcon(_ s: GateStatus) -> String {
        switch s {
        case .pass: return "checkmark.shield.fill"
        case .fail: return "xmark.shield.fill"
        case .running: return "hourglass"
        case .error: return "exclamationmark.triangle.fill"
        case .pending: return "shield"
        }
    }
}
