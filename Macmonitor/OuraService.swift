//
//  OuraService.swift — Oura Ring API v2 client (Epic #10, expanded)
//
//  Read-only. Bearer Personal Access Token from ~/.config/oura/token (or
//  UserDefaults "ouraToken"). Pulls 30 days of history across all daily
//  collections for trends + contributor breakdowns.
//

import SwiftUI
import Combine

private struct Env<T: Decodable>: Decodable { let data: [T] }

// MARK: - Models

struct OReadiness: Decodable, Identifiable {
    var id: String { (day ?? "") }
    let day: String?; let score: Int?; let temperature_deviation: Double?
    let contributors: OReadinessContrib?
}
struct OReadinessContrib: Decodable {
    let activity_balance, body_temperature, hrv_balance, previous_day_activity: Int?
    let previous_night, recovery_index, resting_heart_rate, sleep_balance, sleep_regularity: Int?
    var pairs: [(String, Int)] {
        [("Activity bal", activity_balance), ("Body temp", body_temperature), ("HRV bal", hrv_balance),
         ("Prev-day act", previous_day_activity), ("Prev night", previous_night), ("Recovery idx", recovery_index),
         ("Resting HR", resting_heart_rate), ("Sleep bal", sleep_balance), ("Sleep reg", sleep_regularity)]
            .compactMap { n, v in v.map { (n, $0) } }
    }
}
struct OSleep: Decodable, Identifiable {
    var id: String { (day ?? "") }
    let day: String?; let score: Int?; let contributors: OSleepContrib?
}
struct OSleepContrib: Decodable {
    let deep_sleep, efficiency, latency, rem_sleep, restfulness, timing, total_sleep: Int?
    var pairs: [(String, Int)] {
        [("Deep", deep_sleep), ("Efficiency", efficiency), ("Latency", latency), ("REM", rem_sleep),
         ("Restful", restfulness), ("Timing", timing), ("Total", total_sleep)]
            .compactMap { n, v in v.map { (n, $0) } }
    }
}
struct OActivity: Decodable, Identifiable {
    var id: String { (day ?? "") }
    let day: String?; let score: Int?; let steps: Int?; let active_calories: Int?; let total_calories: Int?
}
struct OSleepDetail: Decodable, Identifiable {
    var id: String { (day ?? "") }
    let day: String?; let average_heart_rate: Double?; let average_hrv: Double?; let lowest_heart_rate: Int?
}
struct OStress: Decodable { let day: String?; let stress_high: Int?; let recovery_high: Int?; let day_summary: String? }
struct OSpo2: Decodable { let day: String?; let spo2_percentage: OSpo2Pct? }
struct OSpo2Pct: Decodable { let average: Double? }
struct OResilience: Decodable { let day: String?; let level: String? }
struct OBattery: Decodable { let level: Int?; let charging: Bool? }

@MainActor
final class OuraStore: ObservableObject {
    static let shared = OuraStore()

    enum Status: Equatable { case noToken, loading, ok, error(String) }
    @Published var status: Status = .noToken
    @Published var readiness: [OReadiness] = []
    @Published var sleep: [OSleep] = []
    @Published var activity: [OActivity] = []
    @Published var sleepDetail: [OSleepDetail] = []
    @Published var stress: [OStress] = []
    @Published var spo2: [OSpo2] = []
    @Published var resilience: [OResilience] = []
    @Published var battery: OBattery?
    @Published var updatedAt: Date?

    private let base = "https://api.ouraring.com/v2/usercollection"

    var token: String? {
        let path = (NSHomeDirectory() as NSString).appendingPathComponent(".config/oura/token")
        if let t = try? String(contentsOfFile: path, encoding: .utf8) {
            let s = t.trimmingCharacters(in: .whitespacesAndNewlines); if !s.isEmpty { return s }
        }
        if let t = UserDefaults.standard.string(forKey: "ouraToken")?
            .trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { return t }
        return nil
    }

    func refresh() {
        guard let token = token else { status = .noToken; return }
        if readiness.isEmpty { status = .loading }
        Task { await load(token) }
    }

    private func load(_ token: String) async {
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
        let end = Date(), start = Calendar.current.date(byAdding: .day, value: -30, to: end)!
        let qs = "?start_date=\(fmt.string(from: start))&end_date=\(fmt.string(from: end))"
        do {
            async let r:  [OReadiness]   = fetch("daily_readiness" + qs, token)
            async let s:  [OSleep]       = fetch("daily_sleep" + qs, token)
            async let a:  [OActivity]    = fetch("daily_activity" + qs, token)
            async let sd: [OSleepDetail] = fetch("sleep" + qs, token)
            async let st: [OStress]      = fetch("daily_stress" + qs, token)
            async let sp: [OSpo2]        = fetch("daily_spo2" + qs, token)
            async let rs: [OResilience]  = fetch("daily_resilience" + qs, token)
            let (rr, ss, aa, sdd, stt, spp, rss) = try await (r, s, a, sd, st, sp, rs)
            readiness = rr; sleep = ss; activity = aa; sleepDetail = sdd
            stress = stt; spo2 = spp; resilience = rss
            if let bb: [OBattery] = try? await fetch("ring_battery_level" + qs, token) { battery = bb.last }
            updatedAt = Date(); status = .ok
        } catch {
            status = .error((error as NSError).localizedDescription)
        }
    }

    private func fetch<T: Decodable>(_ path: String, _ token: String) async throws -> [T] {
        guard let url = URL(string: base + "/" + path) else { return [] }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            let m = http.statusCode == 401 ? "Unauthorized — check your Oura token" : "HTTP \(http.statusCode)"
            throw NSError(domain: "Oura", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: m])
        }
        return try JSONDecoder().decode(Env<T>.self, from: data).data
    }
}
