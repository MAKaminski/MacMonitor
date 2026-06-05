//
//  FinanceTab.swift — MacMonitor "FINANCE" tab (3rd tab, alongside DASH | FILES)
//  Financial Module · reads ~/.financial-module/state.json (written by poller.js)
//
//  Renders: live countdown to next poll, primary account value + daily P/L,
//  a D/W/M/YTD/1Y/LTD bar trendline, and earn-account detail. Read-only.
//
//  Integration: see INTEGRATION.md. Frame the hosting view explicitly
//  (NSHostingController collapses unframed views).
//

import SwiftUI
import Combine

// MARK: - Model (mirrors state.schema.json)

struct FMState: Codable {
    let updatedAt: String
    let nextUpdateAt: String
    let pollIntervalSeconds: Int
    let status: String
    var message: String?
    let sources: [FMSource]
}

struct FMSource: Codable, Identifiable {
    let id: String
    let name: String
    let accounts: [FMAccount]
}

struct FMAccount: Codable, Identifiable {
    let id: String
    let name: String
    let type: String          // "invest" | "earn"
    var primary: Bool? = false
    let value: Double
    var dayPL: Double? = nil
    var dayPLPct: Double? = nil
    var periods: [String: FMPeriod]? = nil
    var earn: FMEarn? = nil
}

struct FMPeriod: Codable { let pl: Double; let plPct: Double; let series: [Double] }
struct FMEarn: Codable { let apy: Double?; let interestMTD: Double?; let interestYTD: Double? }

// MARK: - Store (polls the state file + drives the countdown)

final class FinanceStore: ObservableObject {
    @Published var state: FMState?
    @Published var now: Date = Date()

    private var timer: Timer?
    private let path = (NSHomeDirectory() as NSString)
        .appendingPathComponent(".financial-module/state.json")

    init() { reload(); start() }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.now = Date()
            // cheap: reload file once per ~5s so UI tracks the poller
            if Int(self.now.timeIntervalSince1970) % 5 == 0 { self.reload() }
        }
    }

    func reload() {
        guard let data = FileManager.default.contents(atPath: path),
              let s = try? JSONDecoder().decode(FMState.self, from: data) else { return }
        state = s
    }

    var nextUpdate: Date? {
        guard let s = state else { return nil }
        return ISO8601DateFormatter().date(from: s.nextUpdateAt)
    }

    /// Seconds until next poll (clamped at 0).
    var countdown: Int {
        guard let n = nextUpdate else { return 0 }
        return max(0, Int(n.timeIntervalSince(now)))
    }
}

// MARK: - View

struct FinanceTabView: View {
    @StateObject private var store = FinanceStore()
    @State private var period = "1D"
    private let periods = ["1D", "1W", "1M", "YTD", "1Y", "LTD"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let acct = primaryAccount {
                primaryCard(acct)
                periodPicker
                if let p = acct.periods?[period] { trendline(p) }
            } else {
                Text("Waiting for poller…").foregroundColor(.secondary)
            }
            earnSection
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(minWidth: 360, minHeight: 360, alignment: .topLeading)
        .background(Color(white: 0.07))
        .foregroundColor(.white)
    }

    // Header: source name, status dot, MOCK badge, live countdown
    private var header: some View {
        HStack(spacing: 8) {
            Circle().fill(statusColor).frame(width: 9, height: 9)
            Text(store.state?.sources.first?.name ?? "Finance")
                .font(.system(size: 15, weight: .semibold))
            if (store.state?.message ?? "").contains("MOCK") {
                Text("MOCK").font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Color.orange.opacity(0.25)).cornerRadius(4)
                    .foregroundColor(.orange)
            }
            Spacer()
            Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 11))
                .foregroundColor(.secondary)
            Text(countdownString).font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundColor(.secondary)
        }
    }

    private func primaryCard(_ a: FMAccount) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(a.name).font(.system(size: 12)).foregroundColor(.secondary)
            Text(usd(a.value)).font(.system(size: 30, weight: .bold).monospacedDigit())
            HStack(spacing: 6) {
                Image(systemName: (a.dayPL ?? 0) >= 0 ? "arrow.up.right" : "arrow.down.right")
                Text("\(signedUsd(a.dayPL ?? 0))  (\(pct(a.dayPLPct ?? 0)))")
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                Text("today").font(.system(size: 11)).foregroundColor(.secondary)
            }
            .foregroundColor((a.dayPL ?? 0) >= 0 ? .green : .red)
        }
    }

    private var periodPicker: some View {
        HStack(spacing: 6) {
            ForEach(periods, id: \.self) { p in
                Text(p)
                    .font(.system(size: 11, weight: period == p ? .bold : .regular))
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(period == p ? Color.accentColor.opacity(0.30) : Color.white.opacity(0.06))
                    .cornerRadius(6)
                    .onTapGesture { period = p }
            }
        }
    }

    // Hand-rolled bar trendline (no Swift Charts dependency). Sized for legibility.
    private func trendline(_ p: FMPeriod) -> some View {
        let vals = p.series
        let lo = vals.min() ?? 0, hi = vals.max() ?? 1
        let span = max(hi - lo, 1)
        let up = p.pl >= 0
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(period) \(signedUsd(p.pl))").font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundColor(up ? .green : .red)
                Text("(\(pct(p.plPct)))").font(.system(size: 12).monospacedDigit()).foregroundColor(.secondary)
            }
            GeometryReader { geo in
                let n = max(vals.count, 1)
                let gap: CGFloat = 3
                let w = (geo.size.width - gap * CGFloat(n - 1)) / CGFloat(n)
                HStack(alignment: .bottom, spacing: gap) {
                    ForEach(Array(vals.enumerated()), id: \.offset) { _, v in
                        let h = 16 + (geo.size.height - 16) * CGFloat((v - lo) / span)
                        RoundedRectangle(cornerRadius: 2)
                            .fill((up ? Color.green : Color.red).opacity(0.85))
                            .frame(width: max(w, 2), height: h)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
            .frame(height: 150)   // never undersize chart elements
        }
    }

    private var earnSection: some View {
        let earns = store.state?.sources.flatMap { $0.accounts }.filter { $0.type == "earn" } ?? []
        return Group {
            if !earns.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("EARN").font(.system(size: 10, weight: .bold)).foregroundColor(.secondary)
                    ForEach(earns) { e in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(e.name).font(.system(size: 12, weight: .medium))
                                Text(usd(e.value)).font(.system(size: 16, weight: .semibold).monospacedDigit())
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                if let apy = e.earn?.apy {
                                    Text("\(pct(apy)) APY").font(.system(size: 12, weight: .bold)).foregroundColor(.green)
                                }
                                Text("MTD \(usd(e.earn?.interestMTD ?? 0)) · YTD \(usd(e.earn?.interestYTD ?? 0))")
                                    .font(.system(size: 10).monospacedDigit()).foregroundColor(.secondary)
                            }
                        }
                        .padding(10).background(Color.white.opacity(0.05)).cornerRadius(8)
                    }
                }
            }
        }
    }

    // MARK: helpers
    private var primaryAccount: FMAccount? {
        let all = store.state?.sources.flatMap { $0.accounts } ?? []
        return all.first { $0.primary == true } ?? all.first { $0.type == "invest" }
    }
    private var statusColor: Color {
        switch store.state?.status {
        case "ok": return .green
        case "auth_required", "stale": return .yellow
        default: return store.state == nil ? .gray : .red
        }
    }
    private var countdownString: String {
        let s = store.countdown; return String(format: "next in %d:%02d", s / 60, s % 60)
    }
    private func usd(_ v: Double) -> String { v.formatted(.currency(code: "USD").precision(.fractionLength(v < 100 ? 2 : 0))) }
    private func signedUsd(_ v: Double) -> String { (v >= 0 ? "+" : "") + usd(v) }
    private func pct(_ v: Double) -> String { (v >= 0 ? "+" : "") + (v * 100).formatted(.number.precision(.fractionLength(2))) + "%" }
}

#if DEBUG
struct FinanceTabView_Previews: PreviewProvider {
    static var previews: some View { FinanceTabView().frame(width: 420, height: 620) }
}
#endif
