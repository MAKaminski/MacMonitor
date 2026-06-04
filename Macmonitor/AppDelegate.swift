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
                                       : NSSize(width: 340, height: 640)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height),
            styleMask:   [.borderless, .nonactivatingPanel],
            backing:     .buffered,
            defer:       false
        )
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.isOpaque                    = false
        panel.backgroundColor             = .clear
        panel.hasShadow                   = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate           = false
        panel.becomesKeyOnlyIfNeeded      = true
        if style == "compact" {
            panel.contentViewController = NSHostingController(
                rootView: DesktopHUDView(model: model).preferredColorScheme(.dark)
                    .contextMenu { HUDMenuItems() }
            )
        } else {
            // Full HUD — the entire performance overview (same view as the
            // menu-bar popover), pinned to the desktop, streaming at 0.5 s.
            panel.contentViewController = NSHostingController(
                rootView: PopoverView(model: model)
                    .preferredColorScheme(.dark)
                    .background(Color(red: 0.08, green: 0.08, blue: 0.12).opacity(0.96))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .contextMenu { HUDMenuItems() }
            )
        }
        if !panel.setFrameUsingName("MacMonitorHUD-\(style)"), let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: f.maxX - size.width - 20,
                                         y: f.maxY - size.height - 20))
        }
        panel.setFrameAutosaveName("MacMonitorHUD-\(style)")
        panel.orderFrontRegardless()
        hudWindow = panel
    }

    func hideHUD() {
        hudWindow?.orderOut(nil)
        hudWindow = nil
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
            Divider()
            Button("Quit MacMonitor") { NSApp.terminate(nil) }
        }
    }
}
