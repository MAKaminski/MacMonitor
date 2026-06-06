//
//  CalendarTab.swift — MacMonitor "CAL" tab
//
//  Unified 7-day agenda merged from Google (Gmail) Calendar and Outlook,
//  fed from ~/.config/macmonitor/calendar.json which the hourly
//  "macmonitor-calendar" scheduled task maintains. Same store pattern as
//  MonarchTab: poll the JSON, render dependency-free.
//

import SwiftUI
import Combine

struct HubCalEvent: Codable, Identifiable {
    var id: String { start + "|" + title + "|" + source }
    var title: String = ""
    var start: String = ""          // ISO-8601
    var end: String? = nil
    var source: String = "gmail"    // "gmail" | "outlook"
    var location: String? = nil
    var allDay: Bool? = nil

    var startDate: Date? { HubCalData.parse(start) }
    var endDate: Date? { end.flatMap { HubCalData.parse($0) } }
}

struct HubCalData: Codable {
    var updated: Double = 0
    var events: [HubCalEvent] = []

    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
    static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    static let dateOnly: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current; return f
    }()
    static func parse(_ s: String) -> Date? {
        iso.date(from: s) ?? isoFrac.date(from: s) ?? dateOnly.date(from: s)
    }
}

@MainActor
final class HubCalStore: ObservableObject {
    static let shared = HubCalStore()
    @Published var data = HubCalData()
    @Published var hasData = false
    private var timer: Timer?
    private let path = (NSHomeDirectory() as NSString)
        .appendingPathComponent(".config/macmonitor/calendar.json")

    func start() {
        load()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.load() }
        }
    }

    func load() {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let m = try? JSONDecoder().decode(HubCalData.self, from: d) else {
            hasData = false; return
        }
        data = m
        hasData = !m.events.isEmpty
    }
}

struct CalendarTabView: View {
    @ObservedObject var store = HubCalStore.shared

    private var upcoming: [(day: String, items: [HubCalEvent])] {
        let now = Date()
        let horizon = now.addingTimeInterval(7 * 86400)
        let evs = store.data.events
            .filter { ev in
                guard let s = ev.startDate else { return false }
                let e = ev.endDate ?? s.addingTimeInterval(3600)
                return e >= now && s <= horizon
            }
            .sorted { ($0.startDate ?? .distantFuture) < ($1.startDate ?? .distantFuture) }
        let df = DateFormatter(); df.dateFormat = "EEE MMM d"
        var out: [(String, [HubCalEvent])] = []
        for ev in evs {
            let key = df.string(from: ev.startDate ?? now)
            if let i = out.firstIndex(where: { $0.0 == key }) { out[i].1.append(ev) }
            else { out.append((key, [ev])) }
        }
        return out
    }

    private var nextEvent: HubCalEvent? {
        let now = Date()
        return store.data.events
            .filter { ($0.startDate ?? .distantPast) > now }
            .min { ($0.startDate ?? .distantFuture) < ($1.startDate ?? .distantFuture) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                header
                if store.hasData {
                    ForEach(upcoming, id: \.day) { day in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(day.day.uppercased())
                                .font(.system(size: 10, weight: .bold)).tracking(1)
                                .foregroundColor(.gray)
                            ForEach(day.items) { ev in CalEventRow(ev: ev) }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.05)))
                    }
                    legend
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("No calendar data yet").font(.system(size: 13, weight: .semibold))
                        Text("The hourly \"macmonitor-calendar\" scheduled task merges Google + Outlook events into ~/.config/macmonitor/calendar.json.")
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
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            HStack {
                Text("CALENDAR — GOOGLE + OUTLOOK, NEXT 7 DAYS")
                    .font(.system(size: 10, weight: .bold)).tracking(1).foregroundColor(.gray)
                Spacer()
                if let nx = nextEvent, let s = nx.startDate {
                    let mins = max(Int(s.timeIntervalSinceNow / 60), 0)
                    Text(mins < 600
                         ? String(format: "next: %@ in %d:%02d", nx.title.prefix(18) as CVarArg, mins / 60, mins % 60)
                         : "next: \(nx.title.prefix(24))")
                        .font(.system(size: 9, design: .monospaced)).foregroundColor(.cyan)
                        .lineLimit(1)
                }
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                Circle().fill(Color.green).frame(width: 7, height: 7)
                Text("Google / Gmail").font(.system(size: 8)).foregroundColor(.secondary)
            }
            HStack(spacing: 4) {
                Circle().fill(Color.blue).frame(width: 7, height: 7)
                Text("Outlook").font(.system(size: 8)).foregroundColor(.secondary)
            }
            Spacer()
            if store.data.updated > 0 {
                Text("synced " + relAge(store.data.updated))
                    .font(.system(size: 8, design: .monospaced)).foregroundColor(.gray)
            }
        }
        .padding(.horizontal, 2)
    }

    private func relAge(_ t: Double) -> String {
        let s = Int(Date().timeIntervalSince1970 - t)
        if s < 90 { return "just now" }
        if s < 5400 { return "\(s / 60)m ago" }
        return "\(s / 3600)h ago"
    }
}

struct CalEventRow: View {
    let ev: HubCalEvent

    private var timeLabel: String {
        if ev.allDay == true { return "all-day" }
        guard let s = ev.startDate else { return "—" }
        let tf = DateFormatter(); tf.dateFormat = "h:mma"
        var out = tf.string(from: s).lowercased()
        if let e = ev.endDate { out += "–" + tf.string(from: e).lowercased() }
        return out
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle()
                .fill(ev.source == "outlook" ? Color.blue : Color.green)
                .frame(width: 7, height: 7)
                .padding(.top, 1)
            Text(timeLabel)
                .font(.system(size: 9, design: .monospaced)).foregroundColor(.cyan)
                .frame(width: 92, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(ev.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                if let loc = ev.location, !loc.isEmpty {
                    Text(loc).font(.system(size: 8)).foregroundColor(.secondary).lineLimit(1)
                }
            }
            Spacer()
        }
    }
}
