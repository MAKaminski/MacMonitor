//
//  WhatnotTab.swift — MacMonitor "WTNT" tab: Lacey's Whatnot sales.
//
//  Pure consumer of ~/.config/macmonitor/whatnot.json, maintained by the
//  whatnot-service repo (LaunchAgent, 15-min). Plug-and-play file contract —
//  the producer can move to SQLite/Docker/cloud without touching this tab.
//

import SwiftUI
import Combine

struct WhatnotMonthRef: Codable { var label: String; var value: Double }
struct WhatnotLifetime: Codable {
    var sales: Double = 0
    var avgMonth: Double = 0
    var bestMonth: WhatnotMonthRef? = nil
    var lastMonth: WhatnotMonthRef? = nil
}
struct WhatnotData: Codable {
    var updated: Double = 0
    var months: [String] = []
    var sales: [Double] = []
    var otherIncome: [Double] = []
    var totalRevenue: [Double] = []
    var cogs: [Double] = []
    var grossProfit: [Double] = []
    var lifetime = WhatnotLifetime()
}

@MainActor
final class WhatnotStore: ObservableObject {
    static let shared = WhatnotStore()
    @Published var data = WhatnotData()
    @Published var hasData = false
    private var timer: Timer?
    private var producer: Timer?
    private let path = (NSHomeDirectory() as NSString)
        .appendingPathComponent(".config/macmonitor/whatnot.json")
    private let serviceDir = (NSHomeDirectory() as NSString)
        .appendingPathComponent("whatnot-service")

    func start() {
        load()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.load() }
        }
        // The whatnot-service LaunchAgent can't read the iCloud source file
        // (no Full Disk Access). MacMonitor *does* have FDA, so run the
        // producer ourselves on launch + every 15 min and reload after.
        produce()
        producer?.invalidate()
        producer = Timer.scheduledTimer(withTimeInterval: 900, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.produce() }
        }
    }

    private func produce() {
        let dir = serviceDir
        guard FileManager.default.fileExists(atPath: dir) else { return }
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            p.arguments = ["-m", "whatnot_service.cli"]
            p.currentDirectoryURL = URL(fileURLWithPath: dir)
            p.standardOutput = nil
            p.standardError = nil
            do { try p.run() } catch { return }
            p.waitUntilExit()
            Task { @MainActor in WhatnotStore.shared.load() }
        }
    }

    func load() {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let w = try? JSONDecoder().decode(WhatnotData.self, from: d) else {
            hasData = false; return
        }
        data = w
        hasData = !w.months.isEmpty
    }
}

struct WhatnotTabView: View {
    @ObservedObject var store = WhatnotStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                header
                if store.hasData {
                    statRow
                    MonarchSection(id: "wtnt.sales", title: "WHATNOT SALES BY MONTH") {
                        StackedBarChart(months: store.data.months,
                                        series: [("Sales", .pink, store.data.sales)])
                    }
                    MonarchSection(id: "wtnt.margin", title: "GROSS PROFIT VS COGS (= REVENUE)") {
                        StackedBarChart(months: store.data.months, series: [
                            ("Gross profit", .green, store.data.grossProfit),
                            ("COGS",         .red,   store.data.cogs),
                        ])
                    }
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("No Whatnot data yet").font(.system(size: 13, weight: .semibold))
                        Text("whatnot-service writes ~/.config/macmonitor/whatnot.json every 15 minutes — see ~/whatnot-service/README.md.")
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

    private var header: some View {
        HStack {
            Text("LACE LUXX — WHATNOT").font(.system(size: 10, weight: .bold)).tracking(1)
                .foregroundColor(.gray)
            Spacer()
            if store.data.updated > 0 {
                Text("updated \(Self.hhmm(store.data.updated)) · refreshes every 15 min")
                    .font(.system(size: 9, design: .monospaced)).foregroundColor(.cyan)
            }
        }
    }

    private var statRow: some View {
        HStack(spacing: 8) {
            stat("LIFETIME SALES", money(store.data.lifetime.sales), .pink)
            stat("AVG / MONTH", money(store.data.lifetime.avgMonth), .cyan)
            if let b = store.data.lifetime.bestMonth {
                stat("BEST — \(b.label.uppercased())", money(b.value), .green)
            }
            if let l = store.data.lifetime.lastMonth {
                stat("LAST — \(l.label.uppercased())", money(l.value), .orange)
            }
        }
    }

    private func stat(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 8, weight: .semibold)).foregroundColor(.gray)
            Text(value).font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundColor(color)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
    }

    private func money(_ v: Double) -> String {
        v >= 1000 ? String(format: "$%.1fk", v / 1000) : String(format: "$%.0f", v)
    }

    private static func hhmm(_ ts: Double) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        return f.string(from: Date(timeIntervalSince1970: ts))
    }
}
