//
//  MetricHistory.swift — tiered time-series store for DASH trend charts (issue #9)
//
//  Samples SystemStatsModel once per second into a raw tier, and rolls up into
//  minute and hour tiers (avg) so long ranges stay cheap. Persists minute/hour
//  tiers across relaunch. Query points() for a metric at any bucket/window.
//
//  Retention: raw 1s ~2h · minute ~14d · hour ~13mo. (min/avg/max rollups are a
//  planned refinement; v1 stores avg.)
//

import SwiftUI
import Combine

enum TrendMetric: String, CaseIterable, Identifiable {
    case cpu = "CPU %", mem = "MEM %", gpu = "GPU %"
    case netIn = "Net ↓ KB/s", netOut = "Net ↑ KB/s"
    case power = "Power W", cpuTemp = "CPU °C", gpuTemp = "GPU °C"
    case fan = "Fan RPM", battery = "Batt %"
    var id: String { rawValue }
    func read(_ m: SystemStatsModel) -> Double {
        switch self {
        case .cpu:     return Double(m.cpuUsage)
        case .mem:     return Double(m.memPct)
        case .gpu:     return Double(m.gpuUsage)
        case .netIn:   return Double(m.netInBps) / 1024.0
        case .netOut:  return Double(m.netOutBps) / 1024.0
        case .power:   return m.totalPower
        case .cpuTemp: return m.cpuTemp
        case .gpuTemp: return m.gpuTemp
        case .fan:     return Double(m.fanRPM)
        case .battery: return Double(m.batteryPct)
        }
    }
}

@MainActor
final class MetricHistory: ObservableObject {
    static let shared = MetricHistory()

    /// Bumped each sample so observing views re-query (cheap; arrays are not @Published).
    @Published private(set) var lastSampleAt = Date()

    private struct Tier: Codable {
        var bucket: Double
        var cap: Int
        var times: [Double] = []
        var vals: [String: [Double]] = [:]
        mutating func append(_ t: Double, _ sample: [String: Double]) {
            times.append(t)
            for (k, v) in sample { vals[k, default: []].append(v) }
            if times.count > cap {
                times.removeFirst(times.count - cap)
                for k in vals.keys where vals[k]!.count > cap {
                    vals[k]!.removeFirst(vals[k]!.count - cap)
                }
            }
        }
    }

    private var raw   = Tier(bucket: 1,    cap: 7200)
    private var min1  = Tier(bucket: 60,   cap: 20160)
    private var hour1 = Tier(bucket: 3600, cap: 9360)

    private weak var model: SystemStatsModel?
    private var timer: Timer?
    private var curMin: Double = 0, curHour: Double = 0
    private var minAccum: [String: [Double]] = [:], hourAccum: [String: [Double]] = [:]

    private let saveURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacMonitor", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("trends.json")
    }()

    func start(model: SystemStatsModel) {
        self.model = model
        load()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
    }

    private func sample() {
        guard let m = model else { return }
        let now = Date().timeIntervalSince1970
        var s: [String: Double] = [:]
        for metric in TrendMetric.allCases { s[metric.rawValue] = metric.read(m) }
        raw.append(now, s)

        let mb = (now / 60).rounded(.down) * 60
        if curMin == 0 { curMin = mb }
        if mb != curMin { flush(&min1, bucket: curMin, accum: &minAccum); curMin = mb }
        for (k, v) in s { minAccum[k, default: []].append(v) }

        let hb = (now / 3600).rounded(.down) * 3600
        if curHour == 0 { curHour = hb }
        if hb != curHour { flush(&hour1, bucket: curHour, accum: &hourAccum); curHour = hb }
        for (k, v) in s { hourAccum[k, default: []].append(v) }

        lastSampleAt = Date()
        if Int(now) % 60 == 0 { save() }
    }

    private func flush(_ tier: inout Tier, bucket: Double, accum: inout [String: [Double]]) {
        var avg: [String: Double] = [:]
        for (k, arr) in accum where !arr.isEmpty { avg[k] = arr.reduce(0, +) / Double(arr.count) }
        if !avg.isEmpty { tier.append(bucket, avg) }
        accum.removeAll()
    }

    /// Points for a metric at a given bucket size + window (seconds), aggregated from the finest covering tier.
    func points(_ metric: TrendMetric, bucketSec: Double, windowSec: Double) -> [(t: Double, v: Double)] {
        let tier = bucketSec < 60 ? raw : (bucketSec < 3600 ? min1 : hour1)
        let now = Date().timeIntervalSince1970
        let from = now - windowSec
        guard let vals = tier.vals[metric.rawValue] else { return [] }
        let n = Swift.min(tier.times.count, vals.count)
        var pts: [(Double, Double)] = []
        for i in 0..<n where tier.times[i] >= from { pts.append((tier.times[i], vals[i])) }
        guard !pts.isEmpty else { return [] }

        let count = Swift.max(1, Int((windowSec / bucketSec).rounded(.up)))
        if pts.count <= count { return pts.map { (t: $0.0, v: $0.1) } }
        var out: [(t: Double, v: Double)] = []
        var bi = 0
        for b in 0..<count {
            let bStart = from + Double(b) * bucketSec, bEnd = bStart + bucketSec
            var sum = 0.0, c = 0
            while bi < pts.count && pts[bi].0 < bEnd {
                if pts[bi].0 >= bStart { sum += pts[bi].1; c += 1 }
                bi += 1
            }
            if c > 0 { out.append((t: bStart, v: sum / Double(c))) }
        }
        return out
    }

    private struct Snapshot: Codable { var min1: Tier; var hour1: Tier }
    private func save() {
        if let d = try? JSONEncoder().encode(Snapshot(min1: min1, hour1: hour1)) { try? d.write(to: saveURL) }
    }
    private func load() {
        guard let d = try? Data(contentsOf: saveURL),
              let s = try? JSONDecoder().decode(Snapshot.self, from: d) else { return }
        min1 = s.min1; hour1 = s.hour1
    }
}
