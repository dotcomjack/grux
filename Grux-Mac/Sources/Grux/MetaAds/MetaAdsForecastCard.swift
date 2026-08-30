import SwiftUI

// Spend pacing forecast: burn rate, cap runway in days, projected month vs the
// authorized budget, and a daily-spend area chart with the cap line drawn in.
struct MetaAdsForecastCard: View {
    let forecast: BrandForecast?

    var body: some View {
        GruxGlassCard {
            VStack(alignment: .leading, spacing: 12) {
                MetaAdsEyebrow(text: "Forecast", icon: "chart.line.uptrend.xyaxis", tint: GruxTheme.accentCo)
                if let f = forecast {
                    HStack(spacing: 18) {
                        stat("Burn / day", MetaAdsFormat.dollars(f.burnRateCentsPerDay), GruxTheme.textPrimary)
                        stat("Runway", f.runwayDays.map { String(format: "%.1f d", $0) } ?? "n/a", runwayTint(f))
                        stat("Proj. month", MetaAdsFormat.dollars(f.projectedMonthCents), GruxTheme.textPrimary)
                        stat("Of budget", MetaAdsFormat.pct(f.projectedMonthVsBudgetPct), budgetTint(f))
                    }
                    if f.spendSeries.count >= 2 {
                        MetaAdsSparkline(series: f.spendSeries, tint: GruxTheme.accentCo, capLine: f.capLineCents)
                            .frame(height: 48)
                            .padding(.top, 2)
                        HStack {
                            Text("daily spend").font(GruxTheme.Font.microCaps).foregroundStyle(GruxTheme.textTertiary)
                            Spacer()
                            if f.capLineCents != nil {
                                HStack(spacing: 4) {
                                    Rectangle().fill(GruxTheme.textTertiary).frame(width: 10, height: 1)
                                    Text("cap").font(GruxTheme.Font.microCaps).foregroundStyle(GruxTheme.textTertiary)
                                }
                            }
                        }
                    }
                } else {
                    Text("No forecast yet. Needs a few days of spend to project.")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(GruxTheme.textTertiary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func stat(_ label: String, _ value: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased()).font(GruxTheme.Font.microCaps).foregroundStyle(GruxTheme.textTertiary)
            Text(value).font(.system(size: 15, weight: .bold, design: .rounded).monospacedDigit()).foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func runwayTint(_ f: BrandForecast) -> Color {
        guard let d = f.runwayDays else { return GruxTheme.textPrimary }
        if d < 2 { return GruxTheme.destructiveRose }
        if d < 4 { return GruxTheme.warnAmber }
        return GruxTheme.successMint
    }
    private func budgetTint(_ f: BrandForecast) -> Color {
        guard let p = f.projectedMonthVsBudgetPct else { return GruxTheme.textPrimary }
        if p > 1 { return GruxTheme.destructiveRose }
        if p > 0.85 { return GruxTheme.warnAmber }
        return GruxTheme.successMint
    }
}
