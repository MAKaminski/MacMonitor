import AppKit
import SwiftUI
import Combine
import ServiceManagement

class AppDelegate: NSObject, NSApplicationDelegate {

    var statusItem: NSStatusItem?
    var popover    = NSPopover()
    var welcomeWin: NSWindow?
    var hudWindow:  NSPanel?
    let model      = SystemStatsModel()

    // NSApp.delegate is SwiftUI's internal wrapper in the SwiftUI app
    // lifecycle — casting it to AppDelegate fails. Keep a real reference.
    static private(set) var shared: AppDelegate?

    // Subscribe to model changes so the label updates in sync with each tick,
    // not on a separate independent timer that may fire before data is ready.
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        NSApp.setActivationPolicy(.accessory)

        setupMenuBar()

        // Standard-setup support: menu-bar icon hidden, HUD as the only surface.
        if UserDefaults.standard.bool(forKey: "hideMenuBarIcon") {
            statusItem?.isVisible = false
            UserDefaults.standard.set(true, forKey: "showDesktopHUD")
        }
        model.startMonitoring()
        MetricHistory.shared.start(model: model)
        OuraStore.shared.refresh()
        BadgeStore.shared.start()

        // Restore the Desktop HUD if it was visible last session
        if UserDefaults.standard.bool(forKey: "showDesktopHUD") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.showHUD() }
        }

        // Drive the label from published model values — fires immediately on change
        Publishers.CombineLatest3(model.$cpuUsage, model.$memPct, model.$cpuTemp)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] cpu, mem, temp in
                self?.updateLabel(cpu: cpu, mem: mem, temp: temp)
            }
            .store(in: &cancellables)

        // Restore Open at Login state on launch
        if UserDefaults.standard.bool(forKey: "openAtLogin") {
            try? SMAppService.mainApp.register()
        }

        // Show welcome window on very first launch
        if !UserDefaults.standard.bool(forKey: "hasLaunched") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.showWelcomeWindow()
            }
        }

        // Check for updates in the background — non-blocking
        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 5.0) {
            UpdateChecker.shared.check()
        }
    }

    // MARK: - Menu bar

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem?.button {
            btn.title  = "🟢 CPU --%  MEM --%"
            btn.target = self
            btn.action = #selector(handleClick)
            btn.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        popover.contentSize = NSSize(width: 340, height: 640)
        popover.behavior    = .transient
        popover.animates    = true
        popover.contentViewController = NSHostingController(
            rootView: PopoverView(model: model).preferredColorScheme(.dark)
        )
    }

    private func updateLabel(cpu: Int, mem: Int, temp: Double) {
        guard let btn = statusItem?.button else { return }
        let dot = cpu >= 85 || mem >= 85 ? "🔴"
                : cpu >= 60 || mem >= 60 ? "🟡" : "🟢"
        let tempStr = temp > 0 ? String(format: " %.0f°", temp) : ""
        btn.title = "\(dot) CPU \(cpu)%\(tempStr)  MEM \(mem)%"
    }

    // MARK: - Click handling

    @objc func handleClick(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover(sender)
        }
    }

    func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func showContextMenu() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Open Dashboard",
                                action: #selector(openPopover), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: hudWindow == nil ? "Show Desktop HUD (0.5 s)" : "Hide Desktop HUD",
                                action: #selector(toggleHUD), keyEquivalent: "h"))
        let hudStyle = UserDefaults.standard.string(forKey: "hudStyle") ?? "full"
        menu.addItem(NSMenuItem(title: hudStyle == "compact" ? "HUD Style: Compact → switch to Full"
                                                             : "HUD Style: Full → switch to Compact",
                                action: #selector(toggleHUDStyle), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Hide Menu Bar Icon (HUD keeps running)",
                                action: #selector(toggleMenuBarIcon), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Settings…",
                                action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit MacMonitor",
                                action: #selector(NSApp.terminate(_:)), keyEquivalent: "q"))
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    @objc func openPopover() {
        if let btn = statusItem?.button { togglePopover(btn) }
    }

    // MARK: - Welcome window

    func showWelcomeWindow() {
        let win = NSWindow(
            contentRect:  NSRect(x: 0, y: 0, width: 480, height: 420),
            styleMask:    [.titled, .closable, .fullSizeContentView],
            backing:      .buffered,
            defer:        false
        )
        win.titlebarAppearsTransparent  = true
        win.titleVisibility             = .hidden
        win.isMovableByWindowBackground = true
        win.backgroundColor             = NSColor(Color(hex: "0E0E12"))
        win.contentViewController       = NSHostingController(rootView: WelcomeView())
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        welcomeWin = win
    }

    // MARK: - Settings window

    @objc func openSettings() {
        let win = NSWindow(
            contentRect:  NSRect(x: 0, y: 0, width: 320, height: 280),
            styleMask:    [.titled, .closable, .fullSizeContentView],
            backing:      .buffered,
            defer:        false
        )
        win.title                      = "MacMonitor Settings"
        win.titlebarAppearsTransparent = true
        win.backgroundColor            = NSColor(Color(hex: "1C1C1E"))
        win.contentViewController      = NSHostingController(
            rootView: SettingsSheet(isPresented: .constant(true))
                .preferredColorScheme(.dark)
        )
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Desktop HUD (0.5 s floating panel — the WidgetKit workaround)
    // WidgetKit widgets are throttled snapshots; this panel is rendered by the
    // app itself at desktop-icon window level, so it updates with every model
    // tick (0.5 s) while looking and behaving like a desktop widget.

    @objc func toggleHUD() {
        if hudWindow != nil {
            hideHUD()
            // Never strand the user with no surface: if the menu-bar icon is
            // hidden and the HUD goes away, bring the icon back.
            if UserDefaults.standard.bool(forKey: "hideMenuBarIcon") {
                UserDefaults.standard.set(false, forKey: "hideMenuBarIcon")
                statusItem?.isVisible = true
            }
        } else {
            showHUD()
        }
        UserDefaults.standard.set(hudWindow != nil, forKey: "showDesktopHUD")
    }

    @objc func toggleMenuBarIcon() {
        let hide = !(UserDefaults.standard.bool(forKey: "hideMenuBarIcon"))
        UserDefaults.standard.set(hide, forKey: "hideMenuBarIcon")
        statusItem?.isVisible = !hide
        // Hiding the icon with no HUD would strand the user — show the HUD.
        if hide && hudWindow == nil {
            showHUD()
            UserDefaults.standard.set(true, forKey: "showDesktopHUD")
        }
    }

    @objc func showMenuBarIcon() {
        UserDefaults.standard.set(false, forKey: "hideMenuBarIcon")
        statusItem?.isVisible = true
    }

    @objc func toggleHUDStyle() {
        let cur = UserDefaults.standard.string(forKey: "hudStyle") ?? "full"
        UserDefaults.standard.set(cur == "compact" ? "full" : "compact", forKey: "hudStyle")
        if hudWindow != nil { hideHUD(); showHUD() }   // rebuild with the new style
    }

    func showHUD() {
        guard hudWindow == nil else { return }
        let style = UserDefaults.standard.string(forKey: "hudStyle") ?? "full"
        let size  = style == "compact" ? NSSize(width: 280, height: 170)
                                       : NSSize(width: 760, height: 300)   // default: horizontal bar
        let panel = HUDPanel(
            contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height),
            styleMask:   [.borderless, .nonactivatingPanel, .resizable],
            backing:     .buffered,
            defer:       false
        )
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.isOpaque                    = false
        panel.backgroundColor             = .clear
        panel.hasShadow                   = true
        let hudLocked = UserDefaults.standard.bool(forKey: "hudLocked")
        panel.isMovableByWindowBackground = false
        if hudLocked { panel.styleMask.remove(.resizable) }
        panel.hidesOnDeactivate           = false
        panel.becomesKeyOnlyIfNeeded      = true
        if style == "compact" {
            panel.contentViewController = NSHostingController(
                rootView: DesktopHUDView(model: model).preferredColorScheme(.dark)
                    .contextMenu { HUDMenuItems() }
            )
        } else {
            // Full HUD — adaptive performance overview. Resizable from any
            // edge; layout re-flows by breakpoint (wide → columns, tall →
            // stacked). Defaults to a horizontal bar.
            let hosting = NSHostingController(
                rootView: AdaptiveHUDView(model: model)
                    .preferredColorScheme(.dark)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .contextMenu { HUDMenuItems() }
            )
            hosting.sizingOptions = []   // the window controls size; the view fills it
            panel.contentViewController = hosting
            panel.contentMinSize = NSSize(width: 420, height: 200)
        }
        if !panel.setFrameUsingName("MacMonitorHUD-\(style)"), let screen = NSScreen.main {
            // Device-aware defaults: sized from THIS display's visibleFrame,
            // which already excludes the menu bar and the Dock (the ribbon).
            let f = screen.visibleFrame
            if style == "compact" {
                panel.setFrameOrigin(NSPoint(x: f.maxX - size.width - 20,
                                             y: f.maxY - size.height - 20))
            } else {
                let w = min(max(f.width  * 0.62, 760), f.width  - 32)
                let h = min(max(f.height * 0.42, 320), f.height - 32)
                panel.setFrame(NSRect(x: f.maxX - w - 16, y: f.minY + 16,
                                      width: w, height: h), display: true)
            }
        }
        // Sanity guard: a saved frame can be degenerate (zero height) or
        // stranded on a display that is no longer attached — reset it.
        let onAnyScreen = NSScreen.screens.contains { $0.frame.intersects(panel.frame) }
        if panel.frame.height < 100 || panel.frame.width < 100 || !onAnyScreen {
            if let screen = NSScreen.main {
                let f = screen.visibleFrame
                panel.setFrame(NSRect(x: f.maxX - size.width - 20,
                                      y: f.maxY - size.height - 20,
                                      width: size.width, height: size.height),
                               display: true)
            }
        }
        if let scr = NSScreen.main {
            let vf = scr.visibleFrame
            var fr = panel.frame
            if fr.minY < vf.minY { fr.origin.y = vf.minY + 8 }            // above the Dock
            if fr.maxY > vf.maxY { fr.origin.y = vf.maxY - fr.height - 8 }
            if fr.maxX > vf.maxX { fr.origin.x = vf.maxX - fr.width - 8 }
            if fr.minX < vf.minX { fr.origin.x = vf.minX + 8 }
            panel.setFrame(fr, display: true)
        }
        panel.setFrameAutosaveName("MacMonitorHUD-\(style)")
        panel.orderFrontRegardless()
        hudWindow = panel
    }

    func hideHUD() {
        hudWindow?.orderOut(nil)
        hudWindow = nil
    }

    // MARK: - Launcher (Deckboard replacement) actions

    var launcherEditor: NSWindow?

    @objc func toggleHUDLock() {
        let locked = !UserDefaults.standard.bool(forKey: "hudLocked")
        UserDefaults.standard.set(locked, forKey: "hudLocked")
        if let p = hudWindow {
            p.isMovableByWindowBackground = false
            if locked { p.styleMask.remove(.resizable) }
            else      { p.styleMask.insert(.resizable) }
        }
    }

    func adjustVolume(by delta: Int) {
        let op = delta >= 0 ? "+" : "-"
        let script = "set volume output volume ((output volume of (get volume settings)) \(op) \(abs(delta)))"
        NSAppleScript(source: script)?.executeAndReturnError(nil)
    }
    func currentVolume() -> Int {
        let d = NSAppleScript(source: "output volume of (get volume settings)")?.executeAndReturnError(nil)
        return Int(d?.int32Value ?? 50)
    }
    func setVolume(to v: Int) {
        let clamped = max(0, min(100, v))
        NSAppleScript(source: "set volume output volume \(clamped)")?.executeAndReturnError(nil)
    }

    /// Media transport via the active player (Spotify, then Music). `cmd` is an
    /// AppleScript verb: "playpause", "next track", or "previous track".
    func mediaControl(_ cmd: String) {
        let players: Set<String> = ["com.spotify.client", "com.apple.Music"]
        let running = NSWorkspace.shared.runningApplications.contains { players.contains($0.bundleIdentifier ?? "") }
        if running {
            sendMediaKey(cmd)                       // control the running player
        } else if cmd == "playpause" {
            // Nothing playing: launch Spotify (never Apple Music), then play.
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client") {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { self.sendMediaKey("playpause") }
                }
            }
        }
        // next/prev with nothing running: ignore
    }
    private func sendMediaKey(_ cmd: String) {
        let key = cmd == "next track" ? 17 : (cmd == "previous track" ? 18 : 16)
        func post(_ down: Bool) {
            let flags = NSEvent.ModifierFlags(rawValue: UInt(down ? 0xA00 : 0xB00))
            let data1 = (key << 16) | ((down ? 0xA : 0xB) << 8)
            if let ev = NSEvent.otherEvent(with: .systemDefined, location: .zero,
                                           modifierFlags: flags, timestamp: 0, windowNumber: 0,
                                           context: nil, subtype: 8, data1: data1, data2: -1) {
                ev.cgEvent?.post(tap: .cghidEventTap)
            }
        }
        post(true); post(false)
    }
    private static var prevMicVolume = 100
    /// System mic mute toggle (input gain 0 / restore). No Accessibility needed.
    func toggleMicMute() {
        let cur = NSAppleScript(source: "input volume of (get volume settings)")?
            .executeAndReturnError(nil).int32Value ?? 0
        let script: String
        if cur > 0 {
            AppDelegate.prevMicVolume = Int(cur)
            script = "set volume input volume 0"
        } else {
            script = "set volume input volume \(AppDelegate.prevMicVolume > 0 ? AppDelegate.prevMicVolume : 100)"
        }
        NSAppleScript(source: script)?.executeAndReturnError(nil)
    }
    /// Google Meet camera toggle (sends \u{2318}E to the frontmost window). Needs Accessibility.
    func toggleGoogleCamera() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let key = CGKeyCode(0x0E) // ANSI 'e'
        if let down = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true),
           let up = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false) {
            down.flags = .maskCommand; up.flags = .maskCommand
            down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        }
    }
    func openLauncherEditor() {
        if let win = launcherEditor {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let win = NSWindow(
            contentRect:  NSRect(x: 0, y: 0, width: 480, height: 340),
            styleMask:    [.titled, .closable],
            backing:      .buffered,
            defer:        false
        )
        win.title                 = "HUD Launcher Buttons"
        win.isReleasedWhenClosed  = false
        win.contentViewController = NSHostingController(
            rootView: LauncherEditorView().preferredColorScheme(.dark)
        )
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        launcherEditor = win
    }
}

// MARK: - Desktop HUD view (bound to the same 0.5 s @Published stream)

struct DesktopHUDView: View {
    @ObservedObject var model: SystemStatsModel

    private func fmtBytes(_ b: Int64) -> String {
        let d = Double(b)
        if d >= 1_073_741_824 { return String(format: "%.1f GB", d / 1_073_741_824) }
        if d >= 1_048_576     { return String(format: "%.0f MB", d / 1_048_576) }
        return "\(b) B"
    }
    private func fmtRate(_ bps: Int64) -> String {
        let d = Double(bps)
        if d >= 1_048_576 { return String(format: "%.1f MB/s", d / 1_048_576) }
        if d >= 1_024     { return String(format: "%.0f KB/s", d / 1_024) }
        return String(format: "%.0f B/s", max(d, 0))
    }
    private func barColor(_ v: Int) -> Color { v >= 85 ? .red : v >= 60 ? .yellow : .green }
    private func dotColor(_ s: String) -> Color {
        switch s {
        case "Normal": return .green
        case "Fair":   return .yellow
        default:       return .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(dotColor(model.thermalState)).frame(width: 7, height: 7)
                Text(model.chipName)
                    .font(.system(size: 12, weight: .bold)).foregroundColor(.white)
                Spacer()
                Text("0.5 s live").font(.system(size: 8)).foregroundColor(.gray)
            }
            hudBar(label: "CPU", pct: model.cpuUsage)
            hudBar(label: "MEM", pct: model.memPct)
            Text("\(fmtBytes(model.memUsed)) / \(fmtBytes(model.memTotal))")
                .font(.system(size: 10, design: .monospaced)).foregroundColor(.white)
            HStack(spacing: 10) {
                Text("↓ \(fmtRate(model.netInBps))")
                    .font(.system(size: 9, design: .monospaced)).foregroundColor(.green)
                Text("↑ \(fmtRate(model.netOutBps))")
                    .font(.system(size: 9, design: .monospaced)).foregroundColor(.cyan)
                Spacer()
            }
        }
        .padding(14)
        .frame(width: 280)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(red: 0.08, green: 0.08, blue: 0.12).opacity(0.92))
        )
    }

    @ViewBuilder
    private func hudBar(label: String, pct: Int) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 9, design: .monospaced)).foregroundColor(.gray)
                .frame(width: 28, alignment: .leading)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.gray.opacity(0.15))
                    Capsule().fill(barColor(pct))
                        .frame(width: g.size.width * CGFloat(min(pct, 100)) / 100)
                }
            }
            .frame(height: 6)
            Text("\(pct)%")
                .font(.system(size: 9, design: .monospaced)).foregroundColor(.white)
                .frame(width: 30, alignment: .trailing)
        }
    }
}

// MARK: - HUD context menu (escape hatch when the menu-bar icon is hidden)

struct HUDMenuItems: View {
    var body: some View {
        Group {
            Button("Show Menu Bar Icon") { AppDelegate.shared?.showMenuBarIcon() }
            Button("Switch HUD Style (Full ↔ Compact)") { AppDelegate.shared?.toggleHUDStyle() }
            Button("Hide Desktop HUD") { AppDelegate.shared?.toggleHUD() }
            Button(UserDefaults.standard.bool(forKey: "hudLocked")
                   ? "Unlock HUD (allow move/resize)"
                   : "Lock HUD (fix position & size)") { AppDelegate.shared?.toggleHUDLock() }
            Divider()
            Button("Quit MacMonitor") { NSApp.terminate(nil) }
        }
    }
}

// MARK: - Adaptive HUD (resizable; breakpoint-driven responsive layout)

private let hudBG = Color(red: 0.08, green: 0.08, blue: 0.12)

private func hudFmtBytes(_ b: Int64) -> String {
    let d = Double(b)
    if d >= 1_073_741_824 { return String(format: "%.1f GB", d / 1_073_741_824) }
    if d >= 1_048_576     { return String(format: "%.0f MB", d / 1_048_576) }
    return "\(b) B"
}
private func hudFmtRate(_ bps: Int64) -> String {
    let d = Double(bps)
    if d >= 1_048_576 { return String(format: "%.1f MB/s", d / 1_048_576) }
    if d >= 1_024     { return String(format: "%.0f KB/s", d / 1_024) }
    return String(format: "%.0f B/s", max(d, 0))
}
private func hudFmtW(_ w: Double) -> String { String(format: "%.2f W", w) }
private func hudPctColor(_ v: Int) -> Color { v >= 85 ? .red : v >= 60 ? .yellow : .green }
private func hudThermColor(_ s: String) -> Color {
    switch s {
    case "Normal": return .green
    case "Fair":   return .yellow
    default:       return .red
    }
}

struct AdaptiveHUDView: View {
    @ObservedObject var model: SystemStatsModel
    @AppStorage("hudTab") private var tab = "dash"
    @AppStorage("dashCollapsed") private var dashCollapsed = false

    var body: some View {
        GeometryReader { g in
            let wide = g.size.width > g.size.height * 1.3
            let cols = g.size.width >= 980 ? 4 : (g.size.width >= 700 ? 3 : 2)
            VStack(alignment: .leading, spacing: 8) {
                HUDHeader(model: model, tab: $tab)
                if tab == "files" {
                    HUDFilesView()
                } else if tab == "finance" {
                    FinanceTabView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else if tab == "charts" {
                    TrendChartView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else if tab == "oura" {
                    OuraTabView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else if tab == "messenger" {
                    MessagesTabView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                if !dashCollapsed {
                if wide {
                    HStack(alignment: .top, spacing: 16) {
                        HUDCPUSection(model: model)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                        if cols == 2 {
                            VStack(alignment: .leading, spacing: 10) {
                                HUDMemorySection(model: model)
                                HUDNetBatterySection(model: model, showProcs: false)
                            }
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                        } else {
                            HUDMemorySection(model: model)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                            HUDNetBatterySection(model: model, showProcs: false)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                            if cols >= 4 {
                                HUDGPUPowerSection(model: model)
                                    .frame(maxWidth: .infinity, alignment: .topLeading)
                            }
                        }
                    }
                } else {
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 12) {
                            HUDCPUSection(model: model)
                            HUDMemorySection(model: model)
                            HUDGPUPowerSection(model: model)
                            HUDNetBatterySection(model: model, showProcs: false)
                        }
                    }
                }
                Spacer(minLength: 0)
                }
                if wide {
                    HStack(alignment: .top, spacing: 16) {
                        HUDLauncherSection()
                            .frame(maxWidth: 340, alignment: .topLeading)
                        HUDTerminalSection()
                            .frame(maxWidth: .infinity, minHeight: 110, maxHeight: dashCollapsed ? .infinity : nil)
                    }
                    .frame(maxHeight: dashCollapsed ? .infinity : nil)
                } else {
                    HUDTerminalSection().frame(minHeight: 110, maxHeight: dashCollapsed ? .infinity : nil)
                    HUDLauncherSection()
                }
                }
            }
            .padding(12)
            .frame(width: g.size.width, height: g.size.height, alignment: .topLeading)
            .background(hudBG.opacity(0.96))
        }
    }
}

struct HUDHeader: View {
    @ObservedObject var model: SystemStatsModel
    @Binding var tab: String
    @AppStorage("dashCollapsed") private var dashCollapsed = false
    @State private var dragOffset: CGSize? = nil
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(hudThermColor(model.thermalState)).frame(width: 8, height: 8)
            Text(model.chipName).font(.system(size: 13, weight: .bold)).foregroundColor(.white)
            Text(model.thermalState).font(.system(size: 10)).foregroundColor(hudThermColor(model.thermalState))
            if model.fanRPM > 0 {
                Text("FAN \(model.fanRPM) RPM")
                    .font(.system(size: 9, design: .monospaced)).foregroundColor(.gray)
            }
            if tab == "dash" {
                Button { dashCollapsed.toggle() } label: {
                    Image(systemName: dashCollapsed ? "chevron.down.square" : "chevron.up.square")
                        .font(.system(size: 11)).foregroundColor(.gray)
                }.buttonStyle(.plain).help("Collapse / expand metrics")
            }
            Spacer()
            HUDTabButton(label: "DASH",  id: "dash",  tab: $tab)
            HUDTabButton(label: "FILES", id: "files", tab: $tab)
            HUDTabButton(label: "FIN",   id: "finance", tab: $tab)
            HUDTabButton(label: "CHARTS", id: "charts", tab: $tab)
            HUDTabButton(label: "OURA", id: "oura", tab: $tab)
            HUDTabButton(label: "iMSG", id: "messenger", tab: $tab)
            Text(hudFmtW(model.totalPower))
                .font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundColor(.yellow)
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 3)
                .onChanged { _ in
                    if UserDefaults.standard.bool(forKey: "hudLocked") { return }
                    guard let win = NSApp.windows.first(where: { $0 is HUDPanel }) else { return }
                    let m = NSEvent.mouseLocation   // absolute screen coords — no feedback
                    if dragOffset == nil {
                        dragOffset = CGSize(width: m.x - win.frame.origin.x, height: m.y - win.frame.origin.y)
                    }
                    let off = dragOffset!
                    win.setFrameOrigin(NSPoint(x: m.x - off.width, y: m.y - off.height))
                }
                .onEnded { _ in dragOffset = nil }
        )
    }
}

struct HUDTabButton: View {
    let label: String
    let id:    String
    @Binding var tab: String
    var body: some View {
        Button { tab = id } label: {
            Text(label)
                .font(.system(size: 8, weight: .bold)).tracking(1)
                .foregroundColor(tab == id ? .black : .gray)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 5)
                    .fill(tab == id ? Color.white.opacity(0.85) : Color.gray.opacity(0.2)))
        }
        .buttonStyle(.plain)
    }
}

struct HUDSectionTitle: View {
    let t: String
    var body: some View {
        Text(t).font(.system(size: 8, weight: .semibold)).tracking(1.2).foregroundColor(.gray)
    }
}

struct HUDBar: View {
    let label: String
    let pct:   Int
    var color: Color? = nil
    var body: some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 9, design: .monospaced)).foregroundColor(.gray)
                .frame(width: 64, alignment: .leading)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.gray.opacity(0.15))
                    Capsule().fill(color ?? hudPctColor(pct))
                        .frame(width: g.size.width * CGFloat(min(max(pct, 0), 100)) / 100)
                }
            }
            .frame(height: 6)
            Text("\(pct)%").font(.system(size: 9, design: .monospaced)).foregroundColor(.white)
                .frame(width: 30, alignment: .trailing)
        }
    }
}

struct HUDTiny: View {
    let label: String
    let value: String
    var color: Color = .white
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 8)).foregroundColor(.gray)
            Text(value).font(.system(size: 10, design: .monospaced)).foregroundColor(color)
        }
    }
}

struct HUDCoreGrid: View {
    let perCore: [Double]
    let eCount:  Int
    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible())], spacing: 3) {
            ForEach(perCore.indices, id: \.self) { i in
                let pct = Int(perCore[i].rounded())
                HStack(spacing: 4) {
                    Text("C\(i)").font(.system(size: 7, design: .monospaced))
                        .foregroundColor(i < eCount ? .cyan : .purple)
                        .frame(width: 20, alignment: .leading)
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.gray.opacity(0.12))
                            Capsule().fill(i < eCount ? Color.cyan : Color.purple)
                                .frame(width: g.size.width * CGFloat(min(max(pct, 0), 100)) / 100)
                        }
                    }
                    .frame(height: 4)
                    Text("\(pct)%").font(.system(size: 7, design: .monospaced)).foregroundColor(.gray)
                        .frame(width: 24, alignment: .trailing)
                }
            }
        }
    }
}

struct HUDCPUSection: View {
    @ObservedObject var model: SystemStatsModel
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HUDSectionTitle(t: "CPU")
            HUDBar(label: "Overall", pct: model.cpuUsage)
            HUDBar(label: "E \(model.eCoresMHz)MHz", pct: model.eCoresPct, color: .cyan)
            HUDBar(label: "P \(model.pCoresMHz)MHz", pct: model.pCoresPct, color: .purple)
            if model.sClusterMHz > 0 {
                HUDBar(label: "S \(model.sClusterMHz)MHz", pct: model.sClusterPct, color: .orange)
            }
            HUDCoreGrid(perCore: model.perCoreCPU, eCount: model.eCoreCount)
            HStack {
                HUDTiny(label: "Temp",
                        value: model.cpuTemp > 0 ? String(format: "%.0f °C", model.cpuTemp) : "—")
                Spacer()
                HUDTiny(label: "Hotspot",
                        value: model.cpuDieHotspot > 0 ? String(format: "%.0f °C", model.cpuDieHotspot) : "—")
                Spacer()
                HUDTiny(label: "Power", value: hudFmtW(model.cpuPower), color: .yellow)
            }
        }
    }
}

struct HUDMemorySection: View {
    @ObservedObject var model: SystemStatsModel
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HUDSectionTitle(t: "MEMORY")
            HUDBar(label: "Used", pct: model.memPct, color: .blue)
            Text("\(hudFmtBytes(model.memUsed)) / \(hudFmtBytes(model.memTotal))")
                .font(.system(size: 10, design: .monospaced)).foregroundColor(.white)
            HStack {
                HUDTiny(label: "Swap",
                        value: model.swapUsed > 0 ? hudFmtBytes(model.swapUsed) : "None", color: .gray)
                Spacer()
                HUDTiny(label: "DRAM BW",
                        value: String(format: "%.1f GB/s", model.dramBW), color: .gray)
            }
        }
    }
}

struct HUDGPUPowerSection: View {
    @ObservedObject var model: SystemStatsModel
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HUDSectionTitle(t: model.gpuCoreCount > 0 ? "GPU · \(model.gpuCoreCount) CORES" : "GPU")
            HUDBar(label: "\(model.gpuMHz) MHz", pct: model.gpuUsage, color: .orange)
            HStack {
                HUDTiny(label: "Temp",
                        value: model.gpuTemp > 0 ? String(format: "%.0f °C", model.gpuTemp) : "—")
                Spacer()
                HUDTiny(label: "Power", value: hudFmtW(model.gpuPower), color: .yellow)
            }
            HUDSectionTitle(t: "POWER RAILS")
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 4) {
                HUDTiny(label: "CPU",   value: hudFmtW(model.cpuPower))
                HUDTiny(label: "GPU",   value: hudFmtW(model.gpuPower))
                HUDTiny(label: "ANE",   value: hudFmtW(model.anePower))
                HUDTiny(label: "DRAM",  value: hudFmtW(model.dramPower))
                HUDTiny(label: "SYS",   value: hudFmtW(model.sysPower))
                HUDTiny(label: "TOTAL", value: hudFmtW(model.totalPower), color: .yellow)
            }
        }
    }
}

struct HUDNetBatterySection: View {
    @ObservedObject var model: SystemStatsModel
    var showProcs: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HUDSectionTitle(t: "NETWORK")
            HStack(spacing: 12) {
                Text("↓ \(hudFmtRate(model.netInBps))")
                    .font(.system(size: 10, design: .monospaced)).foregroundColor(.green)
                Text("↑ \(hudFmtRate(model.netOutBps))")
                    .font(.system(size: 10, design: .monospaced)).foregroundColor(.cyan)
            }
            HUDSectionTitle(t: "DISK I/O")
            HStack(spacing: 12) {
                Text(String(format: "↓ %.0f KB/s", model.diskReadKBs))
                    .font(.system(size: 10, design: .monospaced)).foregroundColor(.green)
                Text(String(format: "↑ %.0f KB/s", model.diskWriteKBs))
                    .font(.system(size: 10, design: .monospaced)).foregroundColor(.cyan)
            }
            HUDSectionTitle(t: "BATTERY")
            HUDBar(label: batteryLabel, pct: model.batteryPct,
                   color: model.batteryPct <= 20 ? .red : .green)
            if showProcs && !model.topProcs.isEmpty {
                HUDSectionTitle(t: "TOP PROCESSES")
                ForEach(model.topProcs.prefix(4)) { p in
                    HStack {
                        Text(p.name).font(.system(size: 9)).foregroundColor(.white).lineLimit(1)
                        Spacer()
                        Text(String(format: "%.1f%%", p.cpu))
                            .font(.system(size: 9, design: .monospaced)).foregroundColor(.green)
                    }
                }
            }
        }
    }
    private var batteryLabel: String {
        model.batteryCharging ? "Charging"
            : model.batteryCharged ? "Charged"
            : model.batteryOnAC ? "AC"
            : model.batteryTimeLeft
    }
}


// MARK: - Launcher store (persisted to UserDefaults as JSON)

struct LauncherItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var url: String
    var badge: String? = nil   // poll kind: "gmail", "outlook", "financial", …
}

final class LauncherStore: ObservableObject {
    static let shared = LauncherStore()
    private static let key = "hudLaunchers"

    @Published var items: [LauncherItem] {
        didSet { persist() }
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([LauncherItem].self, from: data) {
            items = saved
        } else {
            items = [
                LauncherItem(name: "Google", url: "https://www.google.com"),
            ]
        }
    }

    func add(name: String, url: String) { items.append(LauncherItem(name: name, url: url)) }
    func remove(_ item: LauncherItem)   { items.removeAll { $0.id == item.id } }

    private func persist() {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}

// MARK: - Launcher row in the HUD

struct HUDLauncherSection: View {
    @ObservedObject var store = LauncherStore.shared
    @ObservedObject var badges = BadgeStore.shared
    private let palette: [Color] = [.green, .blue, .orange, .pink, .teal, .indigo]
    private let cols = [GridItem(.adaptive(minimum: 72), spacing: 6)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HUDCollapsibleGroup(id: "launcher", title: "LAUNCHER") {
                LazyVGrid(columns: cols, alignment: .leading, spacing: 6) {
                    ForEach(Array(store.items.enumerated()), id: \.element.id) { idx, item in
                        LauncherButton(label: item.name,
                                       color: palette[idx % palette.count],
                                       badge: badges.count(for: item.badge)) {
                            if let u = URL(string: item.url) { NSWorkspace.shared.open(u) }
                        }
                        .contextMenu {
                            Button("Remove \(item.name)") { store.remove(item) }
                        }
                    }
                    LauncherButton(label: "+", color: Color.gray.opacity(0.35)) {
                        AppDelegate.shared?.openLauncherEditor()
                    }
                }
            }
            HUDCollapsibleGroup(id: "media", title: "MEDIA") {
                VStack(alignment: .leading, spacing: 6) {
                    BatteryVolumeSlider().frame(maxWidth: 300)
                    LazyVGrid(columns: cols, alignment: .leading, spacing: 6) {
                        LauncherButton(label: "\u{23EE}", color: Color.gray.opacity(0.55)) {
                            AppDelegate.shared?.mediaControl("previous track")
                        }
                        LauncherButton(label: "\u{23EF}", color: Color.gray.opacity(0.55)) {
                            AppDelegate.shared?.mediaControl("playpause")
                        }
                        LauncherButton(label: "\u{23ED}", color: Color.gray.opacity(0.55)) {
                            AppDelegate.shared?.mediaControl("next track")
                        }
                        LauncherButton(label: "\u{1F3A4}", color: Color.gray.opacity(0.55)) {
                            AppDelegate.shared?.toggleMicMute()
                        }
                        LauncherButton(label: "\u{1F4F7}", color: Color.gray.opacity(0.55)) {
                            AppDelegate.shared?.toggleGoogleCamera()
                        }
                    }
                }
            }
        }
    }
}

/// A titled section whose body can be expanded/collapsed by tapping the header.
/// Collapse state persists per id via @AppStorage("group.collapsed.<id>").
struct HUDCollapsibleGroup<Content: View>: View {
    let id: String
    let title: String
    let content: () -> Content
    @AppStorage private var collapsed: Bool

    init(id: String, title: String, @ViewBuilder content: @escaping () -> Content) {
        self.id = id
        self.title = title
        self.content = content
        _collapsed = AppStorage(wrappedValue: false, "group.collapsed.\(id)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { collapsed.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 7, weight: .bold)).foregroundColor(.gray)
                    HUDSectionTitle(t: title)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if !collapsed { content() }
        }
    }
}

struct LauncherButton: View {
    let label:  String
    let color:  Color
    var badge:  Int? = nil
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.white)
                .lineLimit(1)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 7).fill(color.opacity(0.85)))
                .overlay(alignment: .topLeading) {
                    if let b = badge, b > 0 {
                        Text("\(b)")
                            .font(.system(size: 9, weight: .bold)).foregroundColor(.white)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Color.red).clipShape(Capsule())
                            .offset(x: -5, y: -5)
                    }
                }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Launcher editor window

struct LauncherEditorView: View {
    @ObservedObject var store = LauncherStore.shared
    @State private var name = ""
    @State private var url  = "https://"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Launcher Buttons")
                .font(.system(size: 14, weight: .bold))
            ForEach(store.items) { item in
                HStack {
                    Text(item.name)
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 90, alignment: .leading)
                    Text(item.url)
                        .font(.system(size: 10)).foregroundColor(.gray).lineLimit(1)
                    Spacer()
                    Button("Remove") { store.remove(item) }
                }
            }
            Divider()
            HStack {
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder).frame(width: 110)
                TextField("https://…", text: $url)
                    .textFieldStyle(.roundedBorder)
                Button("Add") {
                    let trimmed = name.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty, let u = URL(string: url), u.scheme != nil else { return }
                    store.add(name: trimmed, url: url)
                    name = ""
                    url  = "https://"
                }
            }
            Text("Buttons show in the Desktop HUD's LAUNCHER row. Right-click a button in the HUD to remove it.")
                .font(.system(size: 10)).foregroundColor(.gray)
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(width: 480, height: 320)
    }
}


// MARK: - Key-capable desktop panel (text input in a nonactivating panel)

final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - Embedded terminal (zsh console; splittable up to 4 panes)

final class TerminalSession: ObservableObject, Identifiable {
    let id = UUID()
    @Published var log = ""
    @Published var cwd = NSHomeDirectory()
    @Published var running = false

    func run(_ cmd: String) {
        let trimmed = cmd.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !running else { return }
        append("% " + trimmed + "\n")
        if trimmed == "clear" { log = ""; return }
        if trimmed == "cd" || trimmed.hasPrefix("cd ") {
            changeDir(String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces))
            return
        }
        running = true
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", trimmed]
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError  = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
            DispatchQueue.main.async { self?.append(s) }
        }
        p.terminationHandler = { _ in
            pipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async { [weak self] in self?.running = false }
        }
        do { try p.run() } catch {
            append("error: \(error.localizedDescription)\n")
            running = false
        }
    }

    private func changeDir(_ arg: String) {
        let home = NSHomeDirectory()
        var target = home
        if arg.isEmpty || arg == "~"      { target = home }
        else if arg.hasPrefix("~/")       { target = home + "/" + arg.dropFirst(2) }
        else if arg.hasPrefix("/")        { target = arg }
        else                              { target = cwd + "/" + arg }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: target, isDirectory: &isDir), isDir.boolValue {
            cwd = (target as NSString).standardizingPath
        } else {
            append("cd: no such directory: \(arg)\n")
        }
    }

    private func append(_ s: String) {
        log += s
        if log.count > 40_000 { log = String(log.suffix(30_000)) }
    }
}

final class TerminalHub: ObservableObject {
    static let shared = TerminalHub()
    @Published var sessions: [TerminalSession] = [TerminalSession()]
    func addPane() { if sessions.count < 4 { sessions.append(TerminalSession()) } }
    func remove(_ s: TerminalSession) { if sessions.count > 1 { sessions.removeAll { $0.id == s.id } } }
}

struct HUDTerminalSection: View {
    @ObservedObject var hub = TerminalHub.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                HUDSectionTitle(t: "TERMINAL")
                Spacer()
                Button(action: { hub.addPane() }) {
                    Text("+ Split").font(.system(size: 9)).foregroundColor(.gray)
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 8) {
                ForEach(hub.sessions) { s in
                    TerminalPaneView(session: s).frame(maxWidth: .infinity)
                }
            }
        }
    }
}

struct TerminalPaneView: View {
    @ObservedObject var session: TerminalSession
    @State private var input = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(session.cwd.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.system(size: 8, design: .monospaced)).foregroundColor(.gray).lineLimit(1)
                Spacer()
                if session.running {
                    Text("⋯").font(.system(size: 9)).foregroundColor(.yellow)
                }
                Button(action: { TerminalHub.shared.remove(session) }) {
                    Text("×").font(.system(size: 10)).foregroundColor(.gray)
                }
                .buttonStyle(.plain)
            }
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    Text(session.log.isEmpty ? "zsh — type a command below" : session.log)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.green)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(5)
                        .id("END")
                }
                .onChange(of: session.log) { _ in proxy.scrollTo("END", anchor: .bottom) }
            }
            .background(Color.black.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            TextField("command…", text: $input)
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.white)
                .padding(5)
                .background(Color.black.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .onSubmit {
                    session.run(input)
                    input = ""
                }
        }
    }
}

// MARK: - Files tab (directory explorer)

struct HUDFilesView: View {
    @State private var path = NSHomeDirectory()
    @State private var entries: [FileEntry] = []

    struct FileEntry: Identifiable {
        let id = UUID()
        let name:  String
        let isDir: Bool
        let path:  String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button(action: { path = NSHomeDirectory(); load() }) {
                    Text("⌂").font(.system(size: 12)).foregroundColor(.cyan)
                }
                .buttonStyle(.plain)
                Button(action: { path = (path as NSString).deletingLastPathComponent; load() }) {
                    Text("↑").font(.system(size: 12)).foregroundColor(.cyan)
                }
                .buttonStyle(.plain)
                Text(path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.system(size: 10, design: .monospaced)).foregroundColor(.gray).lineLimit(1)
                Spacer()
                Button(action: { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path) }) {
                    Text("Reveal in Finder").font(.system(size: 9)).foregroundColor(.cyan)
                }
                .buttonStyle(.plain)
            }
            ScrollView(showsIndicators: false) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 10)],
                          alignment: .leading, spacing: 3) {
                    ForEach(entries) { e in
                        HStack(spacing: 5) {
                            Image(systemName: e.isDir ? "folder.fill" : "doc")
                                .font(.system(size: 10))
                                .foregroundColor(e.isDir ? .cyan : .gray)
                            Text(e.name).font(.system(size: 10)).foregroundColor(.white).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if e.isDir { path = e.path; load() }
                            else { NSWorkspace.shared.open(URL(fileURLWithPath: e.path)) }
                        }
                    }
                }
            }
        }
        .onAppear(perform: load)
    }

    private func load() {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: path)) ?? []
        var dirs:  [FileEntry] = []
        var files: [FileEntry] = []
        for n in names.sorted(by: { $0.lowercased() < $1.lowercased() }) where !n.hasPrefix(".") {
            var d: ObjCBool = false
            let p = path + "/" + n
            fm.fileExists(atPath: p, isDirectory: &d)
            if d.boolValue { dirs.append(FileEntry(name: n, isDir: true,  path: p)) }
            else           { files.append(FileEntry(name: n, isDir: false, path: p)) }
        }
        entries = dirs + files
    }
}


// MARK: - Badge poller
// Renders a red unread/alert count on a launcher button. Reads
// ~/.config/macmonitor/badges/<kind>.count, written every ~5 min by a plugin /
// scheduled task (e.g. a Gmail-MCP task for "gmail", Outlook for "outlook",
// a financial-alerts task for "financial"). The app stays decoupled from the
// data source — any poller that writes the count file lights the badge.
@MainActor
final class BadgeStore: ObservableObject {
    static let shared = BadgeStore()
    @Published var counts: [String: Int] = [:]
    private var timer: Timer?
    private let dir = (NSHomeDirectory() as NSString).appendingPathComponent(".config/macmonitor/badges")

    func start() {
        reload()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }
    func reload() {
        var c: [String: Int] = [:]
        if let files = try? FileManager.default.contentsOfDirectory(atPath: dir) {
            for f in files where f.hasSuffix(".count") {
                let kind = String(f.dropLast(6))
                let path = (dir as NSString).appendingPathComponent(f)
                if let str = try? String(contentsOfFile: path, encoding: .utf8),
                   let n = Int(str.trimmingCharacters(in: .whitespacesAndNewlines)) { c[kind] = n }
            }
        }
        counts = c
    }
    func count(for kind: String?) -> Int? {
        guard let k = kind, let n = counts[k], n > 0 else { return nil }
        return n
    }
}
