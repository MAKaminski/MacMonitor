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
        // Start the Whatnot producer at launch (runs with the app's Full Disk
        // Access) so the WTNT tab stays fresh even when it's never opened.
        WhatnotStore.shared.start()

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
        // Carry the position across the size switch: both sizes share one
        // top-left anchor, so the other size appears where this one sits.
        if let w = hudWindow {
            UserDefaults.standard.set(NSStringFromPoint(NSPoint(x: w.frame.minX, y: w.frame.maxY)),
                                      forKey: "hudAnchorTopLeft")
        }
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
                    .overlay(HUDEdgeRainbow(cornerRadius: 14).allowsHitTesting(false))
                    .contextMenu { HUDMenuItems() }
            )
            hosting.sizingOptions = []   // the window controls size; the view fills it
            panel.contentViewController = hosting
            panel.contentMinSize = NSSize(width: 420, height: 200)
        }
        // Attach the autosave name FIRST: attaching implicitly re-applies the
        // saved frame, so doing it last would clobber the anchor, sanity and
        // fit-to-screen corrections below. Attached here, it restores early and
        // every later pass can correct it.
        panel.setFrameAutosaveName("MacMonitorHUD-\(style)")
        var restoredSaved = false
        if let sv = UserDefaults.standard.string(forKey: "hudFrameSaved-\(style)") {
            let r = NSRectFromString(sv)
            if r.width >= 100, r.height >= 100 { panel.setFrame(r, display: true); restoredSaved = true }
        }
        if !restoredSaved, !panel.setFrameUsingName("MacMonitorHUD-\(style)"), let screen = NSScreen.main {
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
        // Shared anchor: both HUD sizes pin their TOP-LEFT to the same point,
        // so moving the small HUD moves where the large one appears (and vice
        // versa). Per-style frames keep their SIZE; the anchor sets position.
        if let a = UserDefaults.standard.string(forKey: "hudAnchorTopLeft") {
            let pt = NSPointFromString(a)
            if pt.x != 0 || pt.y != 0 {
                var fr = panel.frame
                fr.origin = NSPoint(x: pt.x, y: pt.y - fr.height)
                panel.setFrame(fr, display: true)
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
        // Off-screen recovery: clamp against the display the HUD actually
        // lives on (max overlap) — NOT NSScreen.main, which can be a different
        // monitor. If any bounds were pushed off that display, pull them back
        // in; if the window is larger than the display, SHRINK it so every
        // edge sits within the monitor's visible bounds.
        let owner = NSScreen.screens.max(by: { a, b in
            let ia = a.frame.intersection(panel.frame)
            let ib = b.frame.intersection(panel.frame)
            return (ia.width * ia.height) < (ib.width * ib.height)
        }) ?? NSScreen.main
        if let scr = owner {
            let vf = scr.visibleFrame
            var fr = panel.frame
            if fr.width  > vf.width  - 16 { fr.size.width  = max(vf.width  - 16, 320) }  // shrink to fit
            if fr.height > vf.height - 16 { fr.size.height = max(vf.height - 16, 160) }
            if fr.minX < vf.minX { fr.origin.x = vf.minX + 8 }
            if fr.maxX > vf.maxX { fr.origin.x = vf.maxX - fr.width - 8 }
            if fr.minY < vf.minY { fr.origin.y = vf.minY + 8 }            // above the Dock
            if fr.maxY > vf.maxY { fr.origin.y = vf.maxY - fr.height - 8 }
            panel.setFrame(fr, display: true)
        }
        UserDefaults.standard.set(NSStringFromPoint(NSPoint(x: panel.frame.minX, y: panel.frame.maxY)),
                                  forKey: "hudAnchorTopLeft")
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
    /// Turn the cursor into the system screenshot crosshair — synthesizes
    /// the \u{21E7}\u{2318}4 chord so the user never has to press it.
    @objc func snipScreen() {
        let src = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: 21, keyDown: true)   // kVK_ANSI_4
        down?.flags = [.maskCommand, .maskShift]
        let up = CGEvent(keyboardEventSource: src, virtualKey: 21, keyDown: false)
        up?.flags = [.maskCommand, .maskShift]
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

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
            contentRect:  NSRect(x: 0, y: 0, width: 520, height: 480),
            styleMask:    [.titled, .closable, .resizable],
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

    /// Prompt for a new launcher-group name and add it to the store.
    func promptAddGroup() {
        let alert = NSAlert()
        alert.messageText = "Add Launcher Group"
        alert.informativeText = "Name the new group:"
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        tf.placeholderString = "Group name"
        alert.accessoryView = tf
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = tf
        if alert.runModal() == .alertFirstButtonReturn {
            LauncherStore.shared.addGroup(tf.stringValue)
        }
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
                } else if tab == "monarch" {
                    MonarchTabView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else if tab == "whatnot" {
                    WhatnotTabView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else if tab == "calendar" {
                    CalendarTabView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else if tab == "claude" {
                    ClaudeTabView()
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
    @AppStorage("hudLocked") private var hudLocked = false
    @ObservedObject private var imsg = MessagesStore.shared
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
            HStack(spacing: 3) {
                Image(systemName: hudLocked ? "lock.fill" : "lock.open")
                    .font(.system(size: 10)).foregroundColor(hudLocked ? .orange : .green)
                Toggle("", isOn: Binding(get: { hudLocked },
                                         set: { _ in AppDelegate.shared?.toggleHUDLock() }))
                    .toggleStyle(.switch).labelsHidden().controlSize(.mini)
                    .help(hudLocked ? "Locked — flip to unlock & move/resize" : "Unlocked — flip to lock")
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
            HUDTabButton(label: "CAL", id: "calendar", tab: $tab)
            HUDTabButton(label: "MNRCH", id: "monarch", tab: $tab)
            HUDTabButton(label: "WTNT", id: "whatnot", tab: $tab)
            HUDTabButton(label: "OURA", id: "oura", tab: $tab)
            HUDTabButton(label: "iMSG", id: "messenger", tab: $tab, badge: imsg.unreadCount)
            HUDTabButton(label: "CLAUDE", id: "claude", tab: $tab)
            Text(hudFmtW(model.totalPower))
                .font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundColor(.yellow)
        }
        .contentShape(Rectangle())
        .onAppear { MessagesStore.shared.start() }
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
                .onEnded { _ in
                    dragOffset = nil
                    if let win = NSApp.windows.first(where: { $0 is HUDPanel }) {
                        let style = UserDefaults.standard.string(forKey: "hudStyle") ?? "full"
                        UserDefaults.standard.set(NSStringFromRect(win.frame), forKey: "hudFrameSaved-\(style)")
                        UserDefaults.standard.set(NSStringFromPoint(NSPoint(x: win.frame.minX, y: win.frame.maxY)),
                                                  forKey: "hudAnchorTopLeft")
                    }
                }
        )
    }
}

struct HUDTabButton: View {
    let label: String
    let id:    String
    @Binding var tab: String
    var badge: Int = 0
    var body: some View {
        Button { tab = id } label: {
            Text(label)
                .font(.system(size: 8, weight: .bold)).tracking(1)
                .foregroundColor(tab == id ? .black : .gray)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 5)
                    .fill(tab == id ? Color.white.opacity(0.85) : Color.gray.opacity(0.2)))
                .overlay(alignment: .topTrailing) {
                    if badge > 0 {
                        Text(badge > 99 ? "99+" : "\(badge)")
                            .font(.system(size: 8, weight: .bold)).foregroundColor(.white)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Color.red).clipShape(Capsule())
                            .offset(x: 6, y: -6)
                    }
                }
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
                    LiquidFill(level: Double(min(max(pct, 0), 100)) / 100, color: color ?? hudPctColor(pct))
                        .clipShape(Capsule())
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

struct LauncherAccount: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var url: String
    var badge: String? = nil
}
struct LauncherItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var url: String
    var badge: String? = nil   // poll kind: "gmail", "outlook", "financial", …
    var accounts: [LauncherAccount]? = nil   // if set, clicking opens an account modal
    var bgHex: String? = nil   // primary color (button background); nil → palette default
    var fgHex: String? = nil   // secondary color (button text); nil → white
    var group: String? = nil   // launcher group name; nil → default (first) group
}

final class LauncherStore: ObservableObject {
    static let shared = LauncherStore()
    private static let key = "hudLaunchers"
    private static let groupsKey = "hudLauncherGroups"

    @Published var items: [LauncherItem] {
        didSet { persist() }
    }
    /// Ordered list of launcher groups (each renders as its own HUD section).
    @Published var groups: [String] {
        didSet { UserDefaults.standard.set(groups, forKey: Self.groupsKey) }
    }
    /// Transient: which group the editor's "Add" row should preselect (not persisted).
    @Published var editorPreselectGroup: String? = nil

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([LauncherItem].self, from: data) {
            items = saved
        } else {
            items = [
                LauncherItem(name: "Google", url: "https://www.google.com"),
            ]
        }
        if let g = UserDefaults.standard.stringArray(forKey: Self.groupsKey), !g.isEmpty {
            groups = g
        } else {
            groups = ["LAUNCHER"]
        }
        ensureGroupsCoverItems()
    }

    var defaultGroup: String { groups.first ?? "LAUNCHER" }

    /// The group an item belongs to (falls back to the first group).
    func group(of item: LauncherItem) -> String {
        if let g = item.group, groups.contains(g) { return g }
        return defaultGroup
    }
    /// Items in a group, preserving their order in the master array.
    func items(in group: String) -> [LauncherItem] {
        items.filter { self.group(of: $0) == group }
    }

    func add(name: String, url: String, group: String? = nil) {
        items.append(LauncherItem(name: name, url: url, group: group ?? defaultGroup))
    }
    func remove(_ item: LauncherItem) { items.removeAll { $0.id == item.id } }
    /// Reorder the master array (used by the editor's drag handles; mirrors to the HUD).
    func move(from src: IndexSet, to dst: Int) { items.move(fromOffsets: src, toOffset: dst) }

    func setGroup(_ item: LauncherItem, to group: String) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[i].group = group
    }

    func addGroup(_ name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, !groups.contains(n) else { return }
        groups.append(n)
    }
    func renameGroup(_ old: String, to new: String) {
        let n = new.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, !groups.contains(n), let i = groups.firstIndex(of: old) else { return }
        groups[i] = n
        for idx in items.indices where items[idx].group == old { items[idx].group = n }
    }
    /// A group can be removed only once it's empty (and isn't the last group).
    func canRemoveGroup(_ name: String) -> Bool {
        groups.count > 1 && items(in: name).isEmpty
    }
    /// Remove an empty group (no-op if it still has buttons or is the last one).
    func removeGroup(_ name: String) {
        guard canRemoveGroup(name), let i = groups.firstIndex(of: name) else { return }
        groups.remove(at: i)
    }

    /// Make sure every group referenced by an item exists, and there's ≥1 group.
    private func ensureGroupsCoverItems() {
        for it in items where it.group != nil && !groups.contains(it.group!) {
            groups.append(it.group!)
        }
        if groups.isEmpty { groups = ["LAUNCHER"] }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}

// MARK: - Launcher row in the HUD

// MARK: - Launcher color + reorder helpers

let launcherPalette: [Color] = [.green, .blue, .orange, .pink, .teal, .indigo]

/// Effective background (primary) color for a launcher item.
func launcherBG(_ item: LauncherItem, _ idx: Int) -> Color {
    if let h = item.bgHex, !h.isEmpty { return Color(hex: h) }
    return launcherPalette[idx % launcherPalette.count]
}
/// Effective text (secondary) color for a launcher item.
func launcherFG(_ item: LauncherItem) -> Color {
    if let h = item.fgHex, !h.isEmpty { return Color(hex: h) }
    return .white
}

extension Color {
    /// "#RRGGBB" string for persisting a chosen color (pairs with init(hex:)).
    var hexRGB: String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? NSColor.white
        let r = Int((ns.redComponent   * 255).rounded())
        let g = Int((ns.greenComponent * 255).rounded())
        let b = Int((ns.blueComponent  * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

/// Records each launcher tile's frame in the grid's coordinate space so a
/// long-press drag can tell which tile the finger is currently over.
struct LauncherFramesKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// Fast revolving rainbow border (same palette as the HUD edge) shown when a
/// launcher tile is "armed" for moving.
struct ArmedRainbowBorder: View {
    var cornerRadius: CGFloat = 7
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            let spin = Angle.degrees((t * 220).truncatingRemainder(dividingBy: 360))
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(
                    AngularGradient(gradient: Gradient(colors: [
                        .red, .orange, .yellow, .green, .cyan, .blue, .purple, .pink, .red
                    ]), center: .center, angle: spin),
                    lineWidth: 3
                )
        }
    }
}

/// A launcher tile in the HUD grid: custom primary (background) + secondary
/// (text) colors, account popover, and a "hold 2 s to move" highlight.
struct LauncherTile: View {
    let item:  LauncherItem
    let idx:   Int
    let armed: Bool
    let badge: Int
    @State private var showAccounts = false

    var body: some View {
        let bg = launcherBG(item, idx)
        let fg = launcherFG(item)
        Text(item.name)
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(armed ? .black : fg)
            .lineLimit(1)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(armed ? Color.yellow : bg.opacity(0.85))
            )
            .overlay(alignment: .topLeading) {
                if badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 9, weight: .bold)).foregroundColor(.white)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Color.red).clipShape(Capsule())
                        .offset(x: -5, y: -5)
                }
            }
            .overlay { if armed { ArmedRainbowBorder(cornerRadius: 7) } }
            .scaleEffect(armed ? 1.12 : 1.0)
            .shadow(color: armed ? Color.yellow.opacity(0.9) : .clear, radius: armed ? 9 : 0)
            .zIndex(armed ? 1 : 0)
            .popover(isPresented: $showAccounts, arrowEdge: .bottom) {
                AccountPopover(title: item.name, accounts: item.accounts ?? [])
            }
            .onTapGesture {
                if let accts = item.accounts, !accts.isEmpty { showAccounts = true }
                else if let u = URL(string: item.url) { NSWorkspace.shared.open(u) }
            }
    }
}

struct HUDLauncherSection: View {
    @ObservedObject var store = LauncherStore.shared
    @ObservedObject var badges = BadgeStore.shared
    private let cols = [GridItem(.adaptive(minimum: 72), spacing: 6)]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(store.groups, id: \.self) { g in
                LauncherGroupView(group: g)
            }
            mediaGroup
        }
    }

    private var mediaGroup: some View {
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
                    LauncherButton(label: "\u{2702} SNIP", color: Color.gray.opacity(0.55)) {
                        AppDelegate.shared?.snipScreen()
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
    var accounts: [LauncherAccount] = []
    let action: () -> Void
    @State private var showAccounts = false
    var body: some View {
        Button(action: { if accounts.isEmpty { action() } else { showAccounts = true } }) {
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
        .popover(isPresented: $showAccounts, arrowEdge: .bottom) {
            AccountPopover(title: label, accounts: accounts)
        }
    }
}

struct AccountPopover: View {
    let title: String
    let accounts: [LauncherAccount]
    @ObservedObject var badges = BadgeStore.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.system(size: 10, weight: .bold)).foregroundColor(.secondary)
            ForEach(accounts) { acc in
                Button {
                    if let u = URL(string: acc.url) { NSWorkspace.shared.open(u) }
                } label: {
                    HStack(spacing: 8) {
                        if let n = badges.count(for: acc.badge) {
                            Text("\(n)").font(.system(size: 10, weight: .bold)).foregroundColor(.white)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Color.red).clipShape(Capsule())
                        } else {
                            Circle().fill(Color.gray.opacity(0.4)).frame(width: 7, height: 7)
                        }
                        Text(acc.name).font(.system(size: 12))
                        Spacer(minLength: 16)
                        Image(systemName: "arrow.up.forward.app").font(.system(size: 10)).foregroundColor(.secondary)
                    }
                    .frame(minWidth: 190).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
        .padding(12)
    }
}

/// One launcher group rendered as a collapsible HUD section. Owns its own
/// coordinate space + arm/drag state so reordering stays within the group.
struct LauncherGroupView: View {
    @ObservedObject var store  = LauncherStore.shared
    @ObservedObject var badges = BadgeStore.shared
    let group: String
    private let cols = [GridItem(.adaptive(minimum: 72), spacing: 6)]
    @State private var armedID: UUID? = nil
    @State private var frames:  [UUID: CGRect] = [:]

    var body: some View {
        HUDCollapsibleGroup(id: "launcher.\(group)", title: group) {
            LazyVGrid(columns: cols, alignment: .leading, spacing: 6) {
                ForEach(store.items(in: group)) { item in
                    tileCell(item)
                }
                addTile
            }
            .coordinateSpace(name: "lgrid")
            .onPreferenceChange(LauncherFramesKey.self) { frames = $0 }
        }
    }

    private var addTile: some View {
        LauncherButton(label: "+", color: Color.gray.opacity(0.35)) {
            store.editorPreselectGroup = group
            AppDelegate.shared?.openLauncherEditor()
        }
        .contextMenu {
            Button("Add Group…") { AppDelegate.shared?.promptAddGroup() }
            if store.canRemoveGroup(group) {
                Button("Remove Group “\(group)”") { store.removeGroup(group) }
            } else if store.groups.count > 1 {
                Button("Remove Group “\(group)” (empty it first)") { }.disabled(true)
            }
        }
    }

    @ViewBuilder
    private func tileCell(_ item: LauncherItem) -> some View {
        let pidx = store.items.firstIndex(where: { $0.id == item.id }) ?? 0
        LauncherTile(item: item, idx: pidx,
                     armed: armedID == item.id,
                     badge: badges.total(for: item) ?? 0)
            .background(GeometryReader { g in
                Color.clear.preference(
                    key: LauncherFramesKey.self,
                    value: [item.id: g.frame(in: .named("lgrid"))]
                )
            })
            .gesture(reorderGesture(for: item))
            .contextMenu { tileMenu(item) }
    }

    @ViewBuilder
    private func tileMenu(_ item: LauncherItem) -> some View {
        Menu("Change Group") {
            ForEach(store.groups, id: \.self) { g in
                Button(g) { store.setGroup(item, to: g) }
                    .disabled(g == store.group(of: item))   // current group greyed out
            }
        }
        Button("Add Group…") { AppDelegate.shared?.promptAddGroup() }
        Divider()
        Button("Remove \(item.name)") { store.remove(item) }
    }

    /// Hold a tile ~2 s to "arm" it (yellow + revolving rainbow), then drag over
    /// sibling tiles to reorder within this group. Release to drop.
    func reorderGesture(for item: LauncherItem) -> some Gesture {
        LongPressGesture(minimumDuration: 1.5)
            .sequenced(before: DragGesture(coordinateSpace: .named("lgrid")))
            .onChanged { value in
                switch value {
                case .first(true):
                    if armedID != item.id {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.6)) {
                            armedID = item.id
                        }
                    }
                case .second(true, let drag?):
                    if armedID == nil { armedID = item.id }
                    if let targetID = frames.first(where: { $0.value.contains(drag.location) })?.key,
                       targetID != armedID {
                        moveArmed(to: targetID)
                    }
                default:
                    break
                }
            }
            .onEnded { _ in
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { armedID = nil }
            }
    }

    private func moveArmed(to targetID: UUID) {
        guard let armed = armedID,
              let from = store.items.firstIndex(where: { $0.id == armed }),
              let to   = store.items.firstIndex(where: { $0.id == targetID }),
              from != to else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            let moved = store.items.remove(at: from)
            store.items.insert(moved, at: to)
        }
    }
}

// MARK: - Launcher editor window

struct LauncherEditorView: View {
    @ObservedObject var store = LauncherStore.shared
    @State private var name = ""
    @State private var url  = "https://"
    @State private var addGroup = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Launcher Buttons")
                    .font(.system(size: 14, weight: .bold))
                Spacer()
                Text("\(store.items.count) button\(store.items.count == 1 ? "" : "s") · \(store.groups.count) group\(store.groups.count == 1 ? "" : "s")")
                    .font(.system(size: 10)).foregroundColor(.gray)
            }

            // Groups: chips + add a new group.
            HStack(spacing: 6) {
                Text("Groups").font(.system(size: 10, weight: .semibold)).foregroundColor(.gray)
                ForEach(store.groups, id: \.self) { g in
                    HStack(spacing: 3) {
                        Text(g).font(.system(size: 10, weight: .semibold))
                        if store.canRemoveGroup(g) {
                            Button { store.removeGroup(g) } label: {
                                Image(systemName: "xmark.circle.fill").font(.system(size: 9))
                            }
                            .buttonStyle(.plain).foregroundColor(.gray)
                            .help("Remove this empty group")
                        }
                    }
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.gray.opacity(0.22)))
                }
                Button("＋ Group") { AppDelegate.shared?.promptAddGroup() }
                    .font(.system(size: 10))
                Spacer(minLength: 0)
            }

            // Add row pinned at the top so it's always reachable.
            HStack {
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder).frame(width: 100)
                TextField("https://…", text: $url)
                    .textFieldStyle(.roundedBorder)
                Picker("", selection: $addGroup) {
                    ForEach(store.groups, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden().frame(width: 104).help("Group for the new button")
                Button("Add") {
                    let trimmed = name.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty, let u = URL(string: url), u.scheme != nil else { return }
                    store.add(name: trimmed, url: url, group: addGroup.isEmpty ? nil : addGroup)
                    name = ""
                    url  = "https://"
                }
            }

            Divider()

            // Drag the ≡ handle (or any row) to reorder — mirrors live to the HUD.
            List {
                ForEach(Array(store.items.enumerated()), id: \.element.id) { idx, item in
                    rowView(idx: idx, item: item)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 3, leading: 4, bottom: 3, trailing: 4))
                        .listRowSeparator(.hidden)
                }
                .onMove { from, to in store.move(from: from, to: to) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Text("The two swatches set each button's background (primary) and text (secondary) color; the dropdown moves it to another group. In the HUD, hold a button ~2 s to pick it up and drag to reorder within its group; right-click a button for Change Group / Add Group / Remove.")
                .font(.system(size: 10)).foregroundColor(.gray)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(minWidth: 520, idealWidth: 520, minHeight: 380, idealHeight: 480)
        .onAppear {
            addGroup = store.editorPreselectGroup ?? store.defaultGroup
            store.editorPreselectGroup = nil
        }
    }

    @ViewBuilder
    private func rowView(idx: Int, item: LauncherItem) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11)).foregroundColor(.gray)
                .help("Drag to reorder")
            // Live preview swatch — shows both chosen colors.
            Text(item.name)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(launcherFG(item))
                .lineLimit(1)
                .padding(.vertical, 4).padding(.horizontal, 8)
                .background(RoundedRectangle(cornerRadius: 6).fill(launcherBG(item, idx)))
                .frame(width: 118, alignment: .leading)
            Text(item.url)
                .font(.system(size: 10)).foregroundColor(.gray).lineLimit(1)
            Spacer(minLength: 6)
            ColorPicker("", selection: bgBinding(idx), supportsOpacity: false)
                .labelsHidden().frame(width: 38).help("Background (primary) color")
            ColorPicker("", selection: fgBinding(idx), supportsOpacity: false)
                .labelsHidden().frame(width: 38).help("Text (secondary) color")
            Menu {
                ForEach(store.groups, id: \.self) { g in
                    Button(g) { store.setGroup(item, to: g) }
                        .disabled(g == store.group(of: item))
                }
            } label: {
                Text(store.group(of: item)).font(.system(size: 9)).lineLimit(1)
            }
            .frame(width: 80).help("Move to group")
            Button("Remove") { store.remove(item) }
        }
    }

    private func bgBinding(_ idx: Int) -> Binding<Color> {
        Binding(
            get: { idx < store.items.count ? launcherBG(store.items[idx], idx) : .gray },
            set: { if idx < store.items.count { store.items[idx].bgHex = $0.hexRGB } }
        )
    }
    private func fgBinding(_ idx: Int) -> Binding<Color> {
        Binding(
            get: { idx < store.items.count ? launcherFG(store.items[idx]) : .white },
            set: { if idx < store.items.count { store.items[idx].fgHex = $0.hexRGB } }
        )
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
    func total(for item: LauncherItem) -> Int? {
        if let accts = item.accounts, !accts.isEmpty {
            let sum = accts.compactMap { count(for: $0.badge) }.reduce(0, +)
            return sum > 0 ? sum : nil
        }
        return count(for: item.badge)
    }
}
