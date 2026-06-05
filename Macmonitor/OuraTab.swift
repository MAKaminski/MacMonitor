//
//  OuraTab.swift — MacMonitor "OURA" tab (Epic #10, expanded dashboard)
//  Latest scores + 30-day trends + contributor breakdowns + all daily vitals.
//

import SwiftUI

struct OuraTabView: View {
    @ObservedObject var store = OuraStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                switch store.status {
                case .noToken: tokenSetup
                case .error(let m): Text("Oura error: \(m)").font(.system(size: 12)).foregroundColor(.red)
                case .loading where store.readiness.isEmpty: Text("Loading Oura…").foregroundColor(.secondary)
                default:
                    scoreCards
                    trends
                    contributors
                    vitals
                    circles
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.07)).foregroundColor(.white)
        .onAppear { if store.readiness.isEmpty { store.refresh() } }
    }

    // MARK: latest helpers
    private var lr: OReadiness? { store.readiness.last }
    private var ls: OSleep? { store.sleep.last }
    private var la: OActivity? { store.activity.last }
    private var ld: OSleepDetail? { store.sleepDetail.last }

    private var header: some View {
        HStack(spacing: 8) {
            Circle().fill(statusColor).frame(width: 9, height: 9)
            Text("OURA").font(.system(size: 15, weight: .semibold))
            if let d = lr?.day { Text(d).font(.system(size: 11)).foregroundColor(.secondary) }
            Spacer()
            if let u = store.updatedAt {
                Text(u.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 11).monospacedDigit()).foregroundColor(.secondary)
            }
            Button { store.refresh() } label: { Image(systemName: "arrow.clockwise").font(.system(size: 12)) }
                .buttonStyle(.plain).foregroundColor(.secondary)
        }
    }

    private var scoreCards: some View {
        HStack(spacing: 12) {
            scoreCard("Readiness", lr?.score)
            scoreCard("Sleep", ls?.score)
            scoreCard("Activity", la?.score)
        }
    }
    private func scoreCard(_ t: String, _ s: Int?) -> some View {
        VStack(spacing: 4) {
            Text(t).font(.system(size: 11)).foregroundColor(.secondary)
            Text(s.map(String.init) ?? "—").font(.system(size: 32, weight: .bold).monospacedDigit())
                .foregroundColor(scoreColor(s))
        }
        .frame(maxWidth: .infinity).padding(.vertical, 10)
        .background(Color.white.opacity(0.05)).cornerRadius(10)
    }

    // MARK: 30-day trends
    private var trends: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("30-DAY TRENDS")
            trendRow("Readiness", store.readiness.map { $0.score }, 100, .green)
            trendRow("Sleep", store.sleep.map { $0.score }, 100, .cyan)
            trendRow("Activity", store.activity.map { $0.score }, 100, .orange)
            trendRow("HRV (ms)", store.sleepDetail.map { $0.average_hrv.map { Int($0) } }, nil, .purple)
            trendRow("Resting HR (bpm)", store.sleepDetail.map { $0.lowest_heart_rate }, nil, .pink)
        }
    }
    private func trendRow(_ label: String, _ raw: [Int?], _ fixedMax: Int?, _ color: Color) -> some View {
        let vals = raw.compactMap { $0 }
        let hi = fixedMax ?? (vals.max() ?? 1)
        let lo = fixedMax != nil ? 0 : (vals.min() ?? 0)
        let span = max(hi - lo, 1)
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).font(.system(size: 11)).foregroundColor(.secondary)
                Spacer()
                Text(vals.last.map { "\($0)" } ?? "—").font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundColor(color)
            }
            GeometryReader { geo in
                let n = max(raw.count, 1)
                let gap: CGFloat = 2
                let w = (geo.size.width - gap * CGFloat(n - 1)) / CGFloat(n)
                HStack(alignment: .bottom, spacing: gap) {
                    ForEach(Array(raw.enumerated()), id: \.offset) { _, v in
                        let h = v.map { 6 + (geo.size.height - 6) * CGFloat(Double($0 - lo) / Double(span)) } ?? 2
                        RoundedRectangle(cornerRadius: 1.5).fill(color.opacity(v == nil ? 0.15 : 0.85))
                            .frame(width: max(w, 1.5), height: max(h, 2))
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }.frame(height: 60)
        }
    }

    // MARK: contributors
    private var contributors: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let c = lr?.contributors { contribBlock("READINESS CONTRIBUTORS", c.pairs, .green) }
            if let c = ls?.contributors { contribBlock("SLEEP CONTRIBUTORS", c.pairs, .cyan) }
        }
    }
    private func contribBlock(_ title: String, _ pairs: [(String, Int)], _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle(title)
            ForEach(pairs, id: \.0) { name, val in
                HStack(spacing: 8) {
                    Text(name).font(.system(size: 10)).foregroundColor(.secondary)
                        .frame(width: 92, alignment: .leading)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.08))
                            RoundedRectangle(cornerRadius: 3).fill(scoreColor(val))
                                .frame(width: geo.size.width * CGFloat(val) / 100.0)
                        }
                    }.frame(height: 10)
                    Text("\(val)").font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .frame(width: 26, alignment: .trailing).foregroundColor(scoreColor(val))
                }
            }
        }
    }

    // MARK: vitals
    private var vitals: some View {
        let cols = [GridItem(.adaptive(minimum: 110), spacing: 10)]
        return VStack(alignment: .leading, spacing: 8) {
            sectionTitle("VITALS (latest)")
            LazyVGrid(columns: cols, alignment: .leading, spacing: 10) {
                vital("Resting HR", ld?.lowest_heart_rate.map { "\($0) bpm" })
                vital("Avg HRV", ld?.average_hrv.map { "\(Int($0)) ms" })
                vital("Avg HR", ld?.average_heart_rate.map { "\(Int($0)) bpm" })
                vital("SpO₂", store.spo2.last?.spo2_percentage?.average.map { String(format: "%.1f%%", $0) })
                vital("Stress", store.stress.last?.day_summary?.capitalized)
                vital("Resilience", store.resilience.last?.level?.capitalized)
                vital("Temp dev", lr?.temperature_deviation.map { String(format: "%+.1f °C", $0) })
                vital("Steps", la?.steps.map { $0.formatted() })
                vital("Active cal", la?.active_calories.map { "\($0)" })
                vital("Ring batt", store.battery?.level.map { "\($0)%\(store.battery?.charging == true ? " ⚡" : "")" })
            }
        }
    }
    private func vital(_ label: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 10)).foregroundColor(.secondary)
            Text(value ?? "—").font(.system(size: 15, weight: .semibold).monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10).background(Color.white.opacity(0.04)).cornerRadius(8)
    }

    // MARK: circles
    private var circles: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle("CIRCLES")
            Text("Oura Circles (friends' scores) is not exposed by the Oura API — it's available only inside the Oura app, so it can't be shown here. Everything above is your own data, pulled live.")
                .font(.system(size: 10)).foregroundColor(.secondary)
        }
    }

    // MARK: helpers
    private func sectionTitle(_ t: String) -> some View {
        Text(t).font(.system(size: 10, weight: .bold)).tracking(1.0).foregroundColor(.gray)
    }
    private var statusColor: Color {
        switch store.status {
        case .ok: return .green; case .loading: return .yellow
        case .noToken: return .gray; case .error: return .red
        }
    }
    private func scoreColor(_ s: Int?) -> Color {
        guard let s else { return .gray }
        return s >= 85 ? .green : (s >= 70 ? .yellow : .orange)
    }

    private var tokenSetup: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Connect your Oura ring").font(.system(size: 13, weight: .semibold))
            Text("1. Create a Personal Access Token at cloud.ouraring.com/personal-access-tokens")
                .font(.system(size: 11)).foregroundColor(.secondary)
            Text("2. Save it to ~/.config/oura/token  (one line)")
                .font(.system(size: 11)).foregroundColor(.secondary)
            Text("3. Tap refresh ↻ above.").font(.system(size: 11)).foregroundColor(.secondary)
        }
    }
}
