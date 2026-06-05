//
//  TrendChartView.swift — DASH trends panel (issue #9)
//
//  A metric picker + granularity selector (1s/1m/1h/1d/1w/1mo) over a decimated
//  line chart. Default: 1 hour @ 1-second resolution (3,600 ticks). Reads
//  MetricHistory.shared, which updates once per second.
//

import SwiftUI

struct TrendChartView: View {
    @ObservedObject var history = MetricHistory.shared
    @State private var metric: TrendMetric = .cpu
    @State private var gran: Gran = .second

    enum Gran: String, CaseIterable, Identifiable {
        case second = "1s", minute = "1m", hour = "1h", day = "1d", week = "1w", month = "1mo"
        var id: String { rawValue }
        /// (bucketSeconds, windowSeconds, caption)
        var spec: (bucket: Double, window: Double, caption: String) {
            switch self {
            case .second: return (1,        3600,        "1 hour · 1s")
            case .minute: return (60,       6 * 3600,    "6 hours · 1m")
            case .hour:   return (3600,     7 * 86400,   "7 days · 1h")
            case .day:    return (86400,    90 * 86400,  "90 days · 1d")
            case .week:   return (7 * 86400, 365 * 86400, "1 year · 1w")
            case .month:  return (30 * 86400, 3 * 365 * 86400, "3 years · 1mo")
            }
        }
    }

    var body: some View {
        let spec = gran.spec
        let pts = history.points(metric, bucketSec: spec.bucket, windowSec: spec.window)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("TRENDS").font(.system(size: 10, weight: .bold)).foregroundColor(.secondary)
                Picker("", selection: $metric) {
                    ForEach(TrendMetric.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.menu).labelsHidden().frame(width: 130)
                Spacer()
                Text(spec.caption).font(.system(size: 10).monospacedDigit()).foregroundColor(.secondary)
            }
            chart(pts)
            HStack(spacing: 4) {
                ForEach(Gran.allCases) { g in
                    Text(g.rawValue)
                        .font(.system(size: 10, weight: gran == g ? .bold : .regular))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(gran == g ? Color.accentColor.opacity(0.30) : Color.white.opacity(0.06))
                        .cornerRadius(5)
                        .contentShape(Rectangle())
                        .onTapGesture { gran = g }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white.opacity(0.04))
        .cornerRadius(8)
    }

    @ViewBuilder private func chart(_ pts: [(t: Double, v: Double)]) -> some View {
        let vals = pts.map { $0.v }
        let lo = vals.min() ?? 0, hi = vals.max() ?? 1
        let span = Swift.max(hi - lo, 0.0001)
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                if pts.count > 1 {
                    Path { p in
                        let w = geo.size.width, h = geo.size.height
                        let step = Swift.max(1, pts.count / Swift.max(2, Int(w)))
                        var first = true, i = 0
                        while i < pts.count {
                            let x = w * CGFloat(i) / CGFloat(pts.count - 1)
                            let y = h - h * CGFloat((pts[i].v - lo) / span)
                            if first { p.move(to: CGPoint(x: x, y: y)); first = false }
                            else { p.addLine(to: CGPoint(x: x, y: y)) }
                            i += step
                        }
                    }
                    .stroke(Color.cyan, lineWidth: 1.5)
                    VStack {
                        Text(fmt(hi)).font(.system(size: 9).monospacedDigit()).foregroundColor(.secondary)
                        Spacer()
                        Text(fmt(lo)).font(.system(size: 9).monospacedDigit()).foregroundColor(.secondary)
                    }
                } else {
                    Text("Collecting \(metric.rawValue) history…")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(minHeight: 240, maxHeight: .infinity)
    }

    private func fmt(_ v: Double) -> String {
        v >= 1000 ? String(format: "%.0f", v) : String(format: "%.1f", v)
    }
}
