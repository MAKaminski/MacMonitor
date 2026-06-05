//
//  MonarchTab.swift — MacMonitor "MONARCH" tab
//
//  Three accordion charts (cashflow, A/L/E, net worth) for the last 6 months,
//  fed from ~/.config/macmonitor/monarch.json which the hourly monarch-poller
//  LaunchAgent maintains (confined to MacMonitor — no external task runner).
//  Header shows a live countdown to the next refresh.
//

import SwiftUI
import Combine

struct MonarchData: Codable {
    var updated: Double = 0                  // unix seconds of last poller write
    var months: [String] = []                // oldest → newest, e.g. ["Jan", …]
    var income: [Double] = []
    var expense: [Double] = []
    var assets: [Double] = []
    var liabilities: [Double] = []
    var netWorth: [Double] = []
}

@MainActor
final class MonarchStore: ObservableObject {
    static let shared = MonarchStore()
    @Published var data = MonarchData()
    @Published var hasData = false
    private var timer: Timer?
    private let path = (NSHomeDirectory() as NSString)
        .appendingPathComponent(".config/macmonitor/monarch.json")

    func start() {
        load()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.load() }
        }
    }

    func load() {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let m = try? JSONDecoder().decode(MonarchData.self, from: d) else {
            hasData = false; return
        }
        data = m
        hasData = !m.months.isEmpty
    }
}

struct MonarchTabView: View {
    @ObservedObject var store = MonarchStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                header
                if store.hasData {
                    MonarchSection(id: "cashflow", title: "CASHFLOW — INCOME VS EXPENSE") {
                        StackedBarChart(months: store.data.months, series: [
                            ("Income",  .green, store.data.income),
                            ("Expense", .red,   store.data.expense),
                        ])
                    }
                    MonarchSection(id: "balance", title: "ASSETS / LIABILITIES / EQUITY") {
                        StackedBarChart(months: store.data.months, series: [
                            ("Assets",      .blue,   store.data.assets),
                            ("Liabilities", .orange, store.data.liabilities),
                            ("Equity",      .purple, equity),
                        ])
                    }
                    MonarchSection(id: "networth", title: "NET WORTH") {
                        StackedBarChart(months: store.data.months, series: [
                            ("Net worth", .mint, store.data.netWorth),
                        ])
                    }
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("No Monarch data yet").font(.system(size: 13, weight: .semibold))
                        Text("The hourly poller writes ~/.config/macmonitor/monarch.json once a Monarch token is configured — see tools/monarch-poller/install_monarch_poller.sh.")
                            .font(.system(size: 10)).foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 30)
                }
            }
            .padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.07)).foregroundColor(.white)
        .onAppear { store.start() }
    }

    private var equity: [Double] {
        zip(store.data.assets, store.data.liabilities).map { max($0 - $1, 0) }
    }

    /// Title row + live countdown to the next hourly refresh.
    private var header: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            HStack {
                Text("MONARCH — LAST 6 MONTHS")
                    .font(.system(size: 10, weight: .bold)).tracking(1).foregroundColor(.gray)
                Spacer()
                if store.data.updated > 0 {
                    let left = store.data.updated + 3600 - Date().timeIntervalSince1970
                    Text(left > 0
                         ? String(format: "next update in %02d:%02d", Int(left) / 60, Int(left) % 60)
                         : "update due — poller runs hourly")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(left > 0 ? .cyan : .orange)
                }
            }
        }
    }
}

/// Collapsible accordion section; state persists per id.
struct MonarchSection<Content: View>: View {
    let id: String
    let title: String
    let content: () -> Content
    @AppStorage private var collapsed: Bool

    init(id: String, title: String, @ViewBuilder content: @escaping () -> Content) {
        self.id = id; self.title = title; self.content = content
        _collapsed = AppStorage(wrappedValue: false, "monarch.collapsed.\(id)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { collapsed.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .bold)).foregroundColor(.gray)
                    Text(title).font(.system(size: 10, weight: .bold)).tracking(1).foregroundColor(.gray)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if !collapsed { content().frame(height: 150) }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.05)))
    }
}

/// Dependency-free stacked bar chart: legend, per-month stacks (liquid-filled
/// segments, first series at the bottom), totals above, month labels below.
struct StackedBarChart: View {
    let months: [String]
    let series: [(String, Color, [Double])]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                ForEach(series.indices, id: \.self) { i in
                    HStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 2).fill(series[i].1).frame(width: 8, height: 8)
                        Text(series[i].0).font(.system(size: 8)).foregroundColor(.secondary)
                    }
                }
            }
            GeometryReader { g in
                let n = months.count
                let totals = (0..<n).map { m in series.reduce(0.0) { $0 + (m < $1.2.count ? $1.2[m] : 0) } }
                let peak = max(totals.max() ?? 1, 1)
                HStack(alignment: .bottom, spacing: 8) {
                    ForEach(0..<n, id: \.self) { m in
                        VStack(spacing: 2) {
                            Text(fmtShort(totals[m]))
                                .font(.system(size: 7, design: .monospaced)).foregroundColor(.secondary)
                            VStack(spacing: 1) {
                                ForEach(series.indices.reversed(), id: \.self) { i in
                                    let v = m < series[i].2.count ? series[i].2[m] : 0
                                    LiquidFill(level: 1.0, color: series[i].1)
                                        .frame(height: max(CGFloat(v / peak) * (g.size.height - 34), v > 0 ? 2 : 0))
                                        .clipShape(RoundedRectangle(cornerRadius: 2))
                                }
                            }
                            .frame(maxHeight: .infinity, alignment: .bottom)
                            Text(m < months.count ? months[m] : "")
                                .font(.system(size: 8)).foregroundColor(.gray)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    private func fmtShort(_ v: Double) -> String {
        if abs(v) >= 1_000_000 { return String(format: "%.1fM", v / 1_000_000) }
        if abs(v) >= 1_000 { return String(format: "%.0fk", v / 1_000) }
        return String(format: "%.0f", v)
    }
}
