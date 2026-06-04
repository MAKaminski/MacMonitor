//
//  MacMonitorWidget.swift
//  MacMonitorWidget
//
//  Self-contained WidgetKit widget for MacMonitor, styled to match the
//  app's dashboard popover.
//
//  Samples everything in-process (Mach kernel / sysctl / IOKit power
//  sources) — no App Groups, no privileged helper, no dependency on the
//  host app being open. GPU, fan, temperatures, and power rails are NOT
//  shown because they require the root helper, which a widget process
//  cannot run.
//
//  No @main here — MacMonitorWidgetBundle.swift owns @main and
//  instantiates MacMonitorWidget().
//

import WidgetKit
import SwiftUI
import Darwin
import IOKit.ps

// MARK: - Entry

struct StatsEntry: TimelineEntry {
    let date:     Date
    let chip:     String        // "M5 Pro"
    let thermal:  String        // "Normal" / "Fair" / "Serious" / "Critical"
    let cpu:      Int           // overall %
    let perCore:  [Int]         // per-core %
    let eCores:   Int           // count of efficiency cores (first N of perCore)
    let mem:      Int           // memory used %
    let memUsed:  String
    let memTotal: String
    let swapUsed: String
    let netDown:  String        // "64 KB/s"
    let netUp:    String
    let battery:  Int           // -1 if no battery
    let battState: String       // "Fully Charged" / "Charging" / "AC Power" / "Battery"
}

// MARK: - Provider (collects own data — no App Groups needed)

struct StatsProvider: TimelineProvider {

    func placeholder(in context: Context) -> StatsEntry {
        StatsEntry(date: Date(), chip: "M5 Pro", thermal: "Normal",
                   cpu: 8, perCore: [30, 24, 19, 13, 8, 5, 0, 0, 0, 0, 0, 0, 20, 10, 6, 3, 3, 3],
                   eCores: 6, mem: 49, memUsed: "31.4 GB", memTotal: "64.0 GB",
                   swapUsed: "None", netDown: "64 KB/s", netUp: "46 KB/s",
                   battery: 100, battState: "Fully Charged")
    }

    func getSnapshot(in context: Context, completion: @escaping (StatsEntry) -> Void) {
        completion(placeholder(in: context))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StatsEntry>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let entry = self.collect()
            let next  = Calendar.current.date(byAdding: .second, value: 5, to: Date())!
            completion(Timeline(entries: [entry], policy: .after(next)))
        }
    }

    // ── Data collection ───────────────────────────────────────────────────────

    private func collect() -> StatsEntry {
        // Two-sample window: CPU ticks + network bytes around one 0.8 s sleep.
        let t1   = coreTicks()
        let n1   = netBytes()
        Thread.sleep(forTimeInterval: 0.8)
        let t2   = coreTicks()
        let n2   = netBytes()

        // Per-core + overall CPU
        var perCore: [Int] = []
        var usedSum = 0.0, totalSum = 0.0
        let n = min(t1.count, t2.count)
        for i in 0..<n {
            let du = t2[i].used  - t1[i].used
            let dt = t2[i].total - t1[i].total
            perCore.append(dt > 0 ? min(100, Int((du / dt * 100).rounded())) : 0)
            usedSum += du; totalSum += dt
        }
        let cpu = totalSum > 0 ? min(100, Int((usedSum / totalSum * 100).rounded())) : 0

        // Network rates over the same 0.8 s window
        let rxBps = Double(n2.rx &- n1.rx) / 0.8
        let txBps = Double(n2.tx &- n1.tx) / 0.8

        let (used, total) = memStats()
        let swap = swapUsedBytes()
        let batt = battery()

        return StatsEntry(
            date:      Date(),
            chip:      chipName(),
            thermal:   thermalState(),
            cpu:       cpu,
            perCore:   perCore,
            eCores:    efficiencyCoreCount(),
            mem:       total > 0 ? Int(used * 100 / total) : 0,
            memUsed:   fmtBytes(used),
            memTotal:  fmtBytes(total),
            swapUsed:  swap > 0 ? fmtBytes(swap) : "None",
            netDown:   fmtRate(rxBps),
            netUp:     fmtRate(txBps),
            battery:   batt?.pct ?? -1,
            battState: batt?.state ?? ""
        )
    }

    /// Per-core CPU ticks via Mach kernel
    private func coreTicks() -> [(used: Double, total: Double)] {
        var n: natural_t = 0
        var raw: processor_info_array_t?
        var cnt: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                  &n, &raw, &cnt) == KERN_SUCCESS,
              let raw = raw else { return [] }
        defer {
            vm_deallocate(mach_task_self_,
                          vm_address_t(bitPattern: raw),
                          vm_size_t(cnt) * vm_size_t(MemoryLayout<integer_t>.stride))
        }
        var out: [(Double, Double)] = []
        for i in 0..<Int(n) {
            let b    = i * Int(CPU_STATE_MAX)
            let user = Double(UInt32(bitPattern: raw[b + 0]))
            let sys  = Double(UInt32(bitPattern: raw[b + 1]))
            let idle = Double(UInt32(bitPattern: raw[b + 2]))
            let nice = Double(UInt32(bitPattern: raw[b + 3]))
            out.append((user + sys + nice, user + sys + idle + nice))
        }
        return out
    }

    /// Memory via vm_statistics64
    private func memStats() -> (used: Int64, total: Int64) {
        var s = vm_statistics64_data_t()
        var c = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &s) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(c)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &c)
            }
        }
        let total = Int64(ProcessInfo.processInfo.physicalMemory)
        guard kr == KERN_SUCCESS else { return (0, total) }
        let pg   = Int64(vm_kernel_page_size)
        let used = (Int64(s.active_count) + Int64(s.wire_count)
                  + Int64(s.compressor_page_count)) * pg
        return (min(max(used, 0), total), total)
    }

    /// Total received/sent bytes across non-loopback interfaces
    private func netBytes() -> (rx: UInt32, tx: UInt32) {
        var rx: UInt32 = 0, tx: UInt32 = 0
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return (0, 0) }
        defer { freeifaddrs(ifaddr) }
        var p = ifaddr
        while let cur = p {
            let a = cur.pointee
            if let sa = a.ifa_addr, sa.pointee.sa_family == UInt8(AF_LINK),
               let dataPtr = a.ifa_data {
                let name = String(cString: a.ifa_name)
                if !name.hasPrefix("lo") {
                    let d = dataPtr.assumingMemoryBound(to: if_data.self).pointee
                    rx = rx &+ d.ifi_ibytes
                    tx = tx &+ d.ifi_obytes
                }
            }
            p = a.ifa_next
        }
        return (rx, tx)
    }

    /// Swap used via sysctl vm.swapusage
    private func swapUsedBytes() -> Int64 {
        var sw = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &sw, &size, nil, 0) == 0 else { return 0 }
        return Int64(sw.xsu_used)
    }

    /// Chip name via sysctl, e.g. "M5 Pro"
    private func chipName() -> String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        guard size > 0 else { return "Apple Silicon" }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0)
        return String(cString: buf).replacingOccurrences(of: "Apple ", with: "")
    }

    /// Efficiency-core count (first N cores reported are E-cluster)
    private func efficiencyCoreCount() -> Int {
        var v: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("hw.perflevel1.logicalcpu", &v, &size, nil, 0) == 0 else { return 0 }
        return Int(v)
    }

    /// Battery via IOKit power sources (nil on desktops)
    private func battery() -> (pct: Int, state: String)? {
        guard let blobRef = IOPSCopyPowerSourcesInfo() else { return nil }
        let blob = blobRef.takeRetainedValue()
        guard let listRef = IOPSCopyPowerSourcesList(blob) else { return nil }
        let list = listRef.takeRetainedValue() as [CFTypeRef]
        guard let src = list.first,
              let descRef = IOPSGetPowerSourceDescription(blob, src),
              let desc = descRef.takeUnretainedValue() as? [String: Any]
        else { return nil }
        let cur = desc[kIOPSCurrentCapacityKey] as? Int ?? -1
        let max = desc[kIOPSMaxCapacityKey] as? Int ?? 100
        guard cur >= 0 else { return nil }
        let pct      = max > 0 ? cur * 100 / max : cur
        let charging = desc[kIOPSIsChargingKey] as? Bool ?? false
        let onAC     = (desc[kIOPSPowerSourceStateKey] as? String ?? "") == kIOPSACPowerValue
        let state    = charging ? "Charging"
                     : (pct >= 100 && onAC) ? "Fully Charged"
                     : onAC ? "AC Power" : "Battery"
        return (pct, state)
    }

    private func thermalState() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:  return "Normal"
        case .fair:     return "Fair"
        case .serious:  return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Normal"
        }
    }

    private func fmtBytes(_ b: Int64) -> String {
        let d = Double(b)
        if d >= 1_073_741_824 { return String(format: "%.1f GB", d / 1_073_741_824) }
        if d >= 1_048_576     { return String(format: "%.0f MB", d / 1_048_576) }
        return "\(b) B"
    }

    private func fmtRate(_ bps: Double) -> String {
        if bps >= 1_048_576 { return String(format: "%.1f MB/s", bps / 1_048_576) }
        if bps >= 1_024     { return String(format: "%.0f KB/s", bps / 1_024) }
        return String(format: "%.0f B/s", max(bps, 0))
    }
}

// MARK: - Style constants (matches the app's dashboard)

private let bgColor    = Color(red: 0.08, green: 0.08, blue: 0.12)
private let eCoreColor = Color.cyan
private let pCoreColor = Color.purple

private func dotColor(_ s: String) -> Color {
    switch s {
    case "Normal": return .green
    case "Fair":   return .yellow
    default:       return .red
    }
}

private func barColor(_ v: Int) -> Color {
    v >= 85 ? .red : v >= 60 ? .yellow : .green
}

// MARK: - Widget views

struct MacMonitorWidgetView: View {
    let entry: StatsEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        switch family {
        case .systemLarge:  LargeView(e: entry)
        case .systemMedium: MediumView(e: entry)
        default:            SmallView(e: entry)
        }
    }
}

// ── Shared pieces ──────────────────────────────────────────────────────────────

struct HeaderRow: View {
    let e: StatsEntry
    var compact = false
    var body: some View {
        HStack(spacing: 6) {
            Text(e.chip)
                .font(.system(size: compact ? 11 : 14, weight: .bold))
                .foregroundColor(.white)
            Circle().fill(dotColor(e.thermal)).frame(width: 6, height: 6)
            Text(e.thermal)
                .font(.system(size: compact ? 9 : 10))
                .foregroundColor(dotColor(e.thermal))
            Spacer()
            Text(e.date, style: .time)
                .font(.system(size: compact ? 8 : 9, design: .monospaced))
                .foregroundColor(.gray)
        }
    }
}

struct SectionHeader: View {
    let icon:  String
    let title: String
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 8)).foregroundColor(.gray)
            Text(title)
                .font(.system(size: 8, weight: .semibold))
                .tracking(1.2)
                .foregroundColor(.gray)
            Spacer()
        }
    }
}

struct WBar: View {
    let label: String
    let pct:   Int
    let color: Color
    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.gray)
                .frame(width: 38, alignment: .leading)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.gray.opacity(0.15))
                    Capsule()
                        .fill(color)
                        .frame(width: g.size.width * CGFloat(min(pct, 100)) / 100)
                }
            }
            .frame(height: 6)
            Text("\(pct)%")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.white)
                .frame(width: 30, alignment: .trailing)
        }
    }
}

struct CoreBar: View {
    let idx:   Int
    let pct:   Int
    let color: Color
    var body: some View {
        HStack(spacing: 4) {
            Text("C\(idx)")
                .font(.system(size: 7, design: .monospaced))
                .foregroundColor(color)
                .frame(width: 20, alignment: .leading)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.gray.opacity(0.12))
                    Capsule()
                        .fill(color)
                        .frame(width: g.size.width * CGFloat(min(pct, 100)) / 100)
                }
            }
            .frame(height: 4)
            Text("\(pct)%")
                .font(.system(size: 7, design: .monospaced))
                .foregroundColor(.gray)
                .frame(width: 22, alignment: .trailing)
        }
    }
}

struct CoreGrid: View {
    let e: StatsEntry
    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible())],
                  spacing: 3) {
            ForEach(Array(e.perCore.enumerated()), id: \.offset) { i, pct in
                CoreBar(idx: i, pct: pct,
                        color: i < e.eCores ? eCoreColor : pCoreColor)
            }
        }
    }
}

struct StatPair: View {
    let label: String
    let val:   String
    let color: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 8)).foregroundColor(.gray)
            Text(val).font(.system(size: 10, design: .monospaced)).foregroundColor(color)
        }
    }
}

// ── Small ──────────────────────────────────────────────────────────────────────

struct SmallView: View {
    let e: StatsEntry
    var body: some View {
        ZStack {
            bgColor
            VStack(alignment: .leading, spacing: 7) {
                HeaderRow(e: e, compact: true)
                WBar(label: "CPU", pct: e.cpu, color: barColor(e.cpu))
                WBar(label: "MEM", pct: e.mem, color: barColor(e.mem))
                Spacer(minLength: 0)
                Text("\(e.memUsed) / \(e.memTotal)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white)
                HStack(spacing: 8) {
                    Text("↓ \(e.netDown)")
                        .font(.system(size: 8, design: .monospaced)).foregroundColor(.green)
                    Text("↑ \(e.netUp)")
                        .font(.system(size: 8, design: .monospaced)).foregroundColor(.cyan)
                }
            }
            .padding(11)
        }
    }
}

// ── Medium ─────────────────────────────────────────────────────────────────────

struct MediumView: View {
    let e: StatsEntry
    var body: some View {
        ZStack {
            bgColor
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 7) {
                    HeaderRow(e: e, compact: true)
                    WBar(label: "CPU",  pct: e.cpu, color: barColor(e.cpu))
                    WBar(label: "MEM",  pct: e.mem, color: barColor(e.mem))
                    Spacer(minLength: 0)
                    HStack(spacing: 8) {
                        Text("↓ \(e.netDown)")
                            .font(.system(size: 8, design: .monospaced)).foregroundColor(.green)
                        Text("↑ \(e.netUp)")
                            .font(.system(size: 8, design: .monospaced)).foregroundColor(.cyan)
                    }
                }
                .frame(maxWidth: .infinity)

                Divider().background(Color.gray.opacity(0.3))

                VStack(alignment: .leading, spacing: 6) {
                    StatPair(label: "RAM",     val: "\(e.memUsed) / \(e.memTotal)", color: .white)
                    StatPair(label: "Swap",    val: e.swapUsed, color: .gray)
                    if e.battery >= 0 {
                        StatPair(label: "Battery",
                                 val: "\(e.battery)% · \(e.battState)",
                                 color: e.battery <= 20 ? .red : .green)
                    }
                    StatPair(label: "Thermal", val: e.thermal, color: dotColor(e.thermal))
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(12)
        }
    }
}

// ── Large (dashboard-style) ────────────────────────────────────────────────────

struct LargeView: View {
    let e: StatsEntry
    var body: some View {
        ZStack {
            bgColor
            VStack(alignment: .leading, spacing: 8) {
                HeaderRow(e: e)

                SectionHeader(icon: "cpu", title: "CPU")
                WBar(label: "Overall", pct: e.cpu, color: barColor(e.cpu))
                CoreGrid(e: e)

                Divider().background(Color.gray.opacity(0.25))

                SectionHeader(icon: "memorychip", title: "MEMORY")
                WBar(label: "Used", pct: e.mem, color: barColor(e.mem))
                HStack {
                    Text("\(e.memUsed) / \(e.memTotal)")
                        .font(.system(size: 9, design: .monospaced)).foregroundColor(.white)
                    Spacer()
                    Text("Swap: \(e.swapUsed)")
                        .font(.system(size: 9, design: .monospaced)).foregroundColor(.gray)
                }

                Divider().background(Color.gray.opacity(0.25))

                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        SectionHeader(icon: "network", title: "NETWORK")
                        Text("↓ \(e.netDown)")
                            .font(.system(size: 9, design: .monospaced)).foregroundColor(.green)
                        Text("↑ \(e.netUp)")
                            .font(.system(size: 9, design: .monospaced)).foregroundColor(.cyan)
                    }
                    Spacer()
                    if e.battery >= 0 {
                        VStack(alignment: .leading, spacing: 3) {
                            SectionHeader(icon: "battery.100", title: "BATTERY")
                            Text("\(e.battery)%")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(e.battery <= 20 ? .red : .green)
                            Text(e.battState)
                                .font(.system(size: 8)).foregroundColor(.gray)
                        }
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(14)
        }
    }
}

// MARK: - Widget declaration
// (No @main — MacMonitorWidgetBundle.swift owns @main and instantiates this.)

struct MacMonitorWidget: Widget {
    let kind = "MacMonitorWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: StatsProvider()) { entry in
            if #available(macOS 14.0, *) {
                MacMonitorWidgetView(entry: entry)
                    .containerBackground(bgColor, for: .widget)
            } else {
                MacMonitorWidgetView(entry: entry)
            }
        }
        .configurationDisplayName("MacMonitor")
        .description("Live CPU, memory, network & battery — works standalone")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
