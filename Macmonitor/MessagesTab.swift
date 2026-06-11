//
//  MessagesTab.swift — MacMonitor "iMSG" tab (native iMessage)
//
//  Reads the local Messages database (~/Library/Messages/chat.db) for
//  conversations + messages, and sends via AppleScript to Messages.app.
//  Requires: Full Disk Access (to read chat.db) + Automation→Messages (to send).
//

import SwiftUI
import Combine
import SQLite3
import Contacts
import AppKit
import ApplicationServices

struct IMConversation: Identifiable, Equatable {
    let id: Int64; let guid: String; let name: String; let snippet: String
    static func == (a: IMConversation, b: IMConversation) -> Bool { a.id == b.id }
}
struct IMMessage: Identifiable { let id: Int64; let text: String; let fromMe: Bool }

@MainActor
final class MessagesStore: ObservableObject {
    static let shared = MessagesStore()
    @Published var conversations: [IMConversation] = []
    @Published var messages: [IMMessage] = []
    @Published var selected: IMConversation?
    @Published var error: String?
    @Published var unreadCount: Int = 0      // incoming unread, drives the iMSG tab badge
    @Published var crafting = false          // Craft Auto Response in flight
    @Published var suggestion: String?       // Claude's drafted reply (never auto-sent)

    private let dbPath = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Messages/chat.db")
    private var timer: Timer?
    private var started = false

    /// Shared folder for the Craft handshake with a local Claude task. Lives in
    /// the Cowork workspace so the task can read/write it with plain file tools.
    static let craftDir = (NSHomeDirectory() as NSString)
        .appendingPathComponent("Documents/Claude/Projects/Personal/craft-auto-response")
    private var craftTimer: Timer?

    func start() {
        if !started { started = true; ContactsResolver.shared.load(); refresh() }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        let path = dbPath, sel = selected?.id
        Task.detached {
            let convos = MessagesStore.queryConversations(path)
            let msgs = sel.map { MessagesStore.queryMessages(path, chatId: $0) }
            let unread = MessagesStore.queryUnread(path)
            await MainActor.run {
                self.conversations = convos.rows
                self.error = convos.error
                self.unreadCount = unread
                if let m = msgs { self.messages = m }
            }
        }
    }

    func select(_ c: IMConversation) {
        selected = c
        let path = dbPath, id = c.id
        Task.detached {
            let m = MessagesStore.queryMessages(path, chatId: id)
            await MainActor.run { self.messages = m }
        }
    }

    func send(_ text: String) {
        guard let c = selected else { return }
        let esc = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application \"Messages\" to send \"\(esc)\" to chat id \"\(c.guid)\""
        // Send via a child `osascript` process. In-app NSAppleScript from a
        // background agent gets its Automation prompt suppressed and silently
        // denied; routing through osascript makes macOS surface the
        // "MacMonitor wants to control Messages" consent prompt reliably.
        DispatchQueue.global().async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            proc.arguments = ["-e", script]
            let errPipe = Pipe()
            proc.standardError = errPipe
            do { try proc.run() } catch {
                DispatchQueue.main.async { self.error = "Couldn't launch osascript: \(error.localizedDescription)" }
                return
            }
            proc.waitUntilExit()
            let errStr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let ok = proc.terminationStatus == 0
            DispatchQueue.main.async {
                if ok {
                    self.error = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self.refresh() }
                } else {
                    self.error = "Send failed: \(errStr). If prompted, allow Automation → Messages."
                }
            }
        }
    }

    /// "Craft Auto Response" — hands the recent thread to a LOCAL Claude
    /// scheduled task (which can pull Michael's relationship + recent-work
    /// context from memory) and drops the reply it writes back into the draft
    /// field. NEVER sends; the user reviews first.
    ///
    /// Handshake: write request.json into the shared craft folder, then watch
    /// for a response.json carrying the matching nonce. Trigger the
    /// "MacMonitor Craft Auto Response" task in Claude to service the request.
    func craftReply() {
        guard let c = selected, !crafting else { return }
        let dir = Self.craftDir
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let nonce = UUID().uuidString
        let thread: [[String: Any]] = messages.suffix(14).map { ["fromMe": $0.fromMe, "text": $0.text] }
        let request: [String: Any] = [
            "nonce": nonce,
            "status": "pending",
            "createdAt": ISO8601DateFormatter().string(from: Date()),
            "contact": c.name,
            "guid": c.guid,
            "instruction": "Draft Michael's next iMessage reply to \(c.name)'s most recent message. Use the relationship context and recent shared work you know from memory. Match Michael's texting voice: concise, warm, casual, no sign-off, no quotes. Return only the reply text.",
            "messages": thread,
        ]
        let reqURL = URL(fileURLWithPath: dir).appendingPathComponent("request.json")
        guard let data = try? JSONSerialization.data(withJSONObject: request, options: [.prettyPrinted]),
              (try? data.write(to: reqURL)) != nil else {
            error = "Craft: couldn't write the request file at \(dir)."
            return
        }
        crafting = true
        error = "Craft request queued — run the “MacMonitor Craft Auto Response” task in Claude; the reply will drop into the box."
        let start = Date()
        craftTimer?.invalidate()
        craftTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
            let respURL = URL(fileURLWithPath: MessagesStore.craftDir).appendingPathComponent("response.json")
            if let d = try? Data(contentsOf: respURL),
               let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               obj["nonce"] as? String == nonce,
               let text = (obj["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty {
                t.invalidate()
                Task { @MainActor in self?.craftDidSucceed(text) }
            } else if Date().timeIntervalSince(start) > 300 {
                t.invalidate()
                Task { @MainActor in self?.craftDidTimeout() }
            }
        }
    }

    @MainActor private func craftDidSucceed(_ text: String) {
        craftTimer?.invalidate(); craftTimer = nil
        suggestion = text; crafting = false; error = nil
    }
    @MainActor private func craftDidTimeout() {
        craftTimer?.invalidate(); craftTimer = nil; crafting = false
        error = "Craft timed out — run the “MacMonitor Craft Auto Response” task in Claude, then click again."
    }

    /// Right-click → Delete Conversation. Confirms, then deletes the thread in
    /// Messages.app itself (so Messages-in-iCloud syncs the deletion to iPhone /
    /// other Macs). Never touches Contacts — only the conversation is removed.
    func confirmDeleteConversation(_ c: IMConversation) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete this conversation?"
        alert.informativeText = "Removes the iMessage thread with “\(c.name)” from Messages on this Mac and — via Messages in iCloud — your iPhone and other devices. The contact is NOT deleted. This can't be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // First-run: surface the Accessibility prompt the UI automation needs.
        if !AXIsProcessTrusted() {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
        }
        runDeleteConversation(c)
    }

    private func runDeleteConversation(_ c: IMConversation) {
        let esc = c.name
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        // A chunk of the last message — fallback match key when the sidebar
        // label differs from our name (common for group threads).
        let snipEsc = String(c.snippet.prefix(36))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        // Drive Messages.app via System Events: find the sidebar row matching
        // this conversation (by name, else by last-message snippet), select it,
        // ⌘⌫, then confirm the Delete sheet. Hierarchy-agnostic (scans the
        // window's AXRows), and aborts safely unless exactly one row matches —
        // it never guesses which thread to delete.
        let script = """
        set targetName to "\(esc)"
        set targetSnippet to "\(snipEsc)"
        tell application "Messages" to activate
        delay 0.5
        tell application "System Events"
            if not (exists process "Messages") then return "ERR Messages not running"
            tell process "Messages"
                set frontmost to true
                delay 0.3
                set nameHits to {}
                set snipHits to {}
                try
                    repeat with e in (entire contents of window 1)
                        try
                            if (role of e) is "AXRow" then
                                set rowText to ""
                                repeat with sub in (entire contents of e)
                                    try
                                        if (role of sub) is "AXStaticText" then set rowText to rowText & (value of sub) & " ¶ "
                                    end try
                                end repeat
                                if (targetName is not "") and (rowText contains targetName) then set end of nameHits to e
                                if (targetSnippet is not "") and (rowText contains targetSnippet) then set end of snipHits to e
                            end if
                        end try
                    end repeat
                end try
                set hitRow to missing value
                if (count nameHits) is 1 then
                    set hitRow to item 1 of nameHits
                else if ((count nameHits) is 0) and ((count snipHits) is 1) then
                    set hitRow to item 1 of snipHits
                end if
                if hitRow is missing value then
                    if (count nameHits) > 1 then return "ERR multiple matches for: " & targetName
                    return "ERR no unique match for: " & targetName
                end if
                try
                    set selected of hitRow to true
                on error
                    try
                        perform action "AXOpen" of hitRow
                    end try
                end try
                delay 0.4
                key code 51 using command down
                delay 0.6
                repeat with w in windows
                    try
                        click button "Delete" of sheet 1 of w
                        return "OK"
                    end try
                end repeat
                return "ERR could not confirm the Delete sheet"
            end tell
        end tell
        """
        DispatchQueue.global().async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            proc.arguments = ["-e", script]
            let outPipe = Pipe(); let errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe
            do { try proc.run() } catch {
                DispatchQueue.main.async { self.error = "Delete: couldn't launch osascript: \(error.localizedDescription)" }
                return
            }
            proc.waitUntilExit()
            let out = (String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let err = (String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                if out == "OK" {
                    self.error = nil
                    if self.selected?.id == c.id { self.selected = nil; self.messages = [] }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.refresh() }
                } else if !err.isEmpty {
                    self.error = "Delete failed: \(err) — if it mentions assistive access, grant MacMonitor (and osascript) Accessibility in System Settings → Privacy & Security → Accessibility."
                } else {
                    self.error = "Delete: \(out.isEmpty ? "no response from Messages" : out)"
                }
            }
        }
    }

    // MARK: - SQLite (nonisolated; runs off-main)

    nonisolated private static func open(_ path: String) -> OpaquePointer? {
        var db: OpaquePointer?
        return sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK ? db : nil
    }

    nonisolated static func queryConversations(_ path: String) -> (rows: [IMConversation], error: String?) {
        guard let db = open(path) else {
            return ([], "Can't read Messages. Grant MacMonitor Full Disk Access in System Settings → Privacy & Security → Full Disk Access, then reopen.")
        }
        defer { sqlite3_close(db) }
        let sql = """
        SELECT c.ROWID, c.guid, c.display_name,
          (SELECT m.text FROM chat_message_join j JOIN message m ON m.ROWID=j.message_id
             WHERE j.chat_id=c.ROWID ORDER BY m.date DESC LIMIT 1) AS snippet,
          (SELECT MAX(m.date) FROM chat_message_join j JOIN message m ON m.ROWID=j.message_id
             WHERE j.chat_id=c.ROWID) AS ldate,
          c.chat_identifier
        FROM chat c WHERE ldate IS NOT NULL ORDER BY ldate DESC LIMIT 50;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return ([], "Messages DB query failed (Full Disk Access?).")
        }
        defer { sqlite3_finalize(stmt) }
        var out: [IMConversation] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let guid = text(stmt, 1) ?? ""
            let disp = text(stmt, 2) ?? ""
            let snip = text(stmt, 3) ?? ""
            let ident = text(stmt, 5) ?? ""
            let name = displayName(db: db, chatId: id, displayName: disp, identifier: ident)
            out.append(IMConversation(id: id, guid: guid, name: name, snippet: snip))
        }
        return (out, nil)
    }

    /// Best display name for a conversation: the chat's own display_name if set,
    /// otherwise the contact name for a 1:1, otherwise a group title built from
    /// the participants (so multi-person threads stop showing raw "chatNNN…").
    nonisolated static func displayName(db: OpaquePointer?, chatId: Int64,
                                        displayName disp: String, identifier ident: String) -> String {
        if !disp.isEmpty { return disp }
        let handles = queryHandles(db, chatId)
        if handles.count >= 2 {
            let firsts = handles.map { firstName(ContactsResolver.shared.name(for: $0) ?? shortHandle($0)) }
            return groupTitle(firsts)
        }
        let h = handles.first ?? ident
        return ContactsResolver.shared.name(for: h)
            ?? ContactsResolver.shared.name(for: ident)
            ?? (h.isEmpty ? ident : h)
    }

    nonisolated static func queryHandles(_ db: OpaquePointer?, _ chatId: Int64) -> [String] {
        let sql = "SELECT h.id FROM chat_handle_join chj JOIN handle h ON h.ROWID=chj.handle_id WHERE chj.chat_id=\(chatId);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW { if let s = text(stmt, 0) { out.append(s) } }
        return out
    }

    nonisolated private static func firstName(_ full: String) -> String {
        String(full.split(separator: " ").first ?? Substring(full))
    }
    nonisolated private static func shortHandle(_ h: String) -> String {
        if h.contains("@") { return String(h.prefix(while: { $0 != "@" })) }
        let d = h.filter(\.isNumber)
        return d.count >= 4 ? "…\(d.suffix(4))" : h
    }
    /// "Keith, Lamar & Naomi" / "Keith, Lamar +3" — deduped, first three shown.
    nonisolated private static func groupTitle(_ names: [String]) -> String {
        var uniq: [String] = []
        for n in names where !n.isEmpty && !uniq.contains(n) { uniq.append(n) }
        if uniq.isEmpty { return "Group" }
        if uniq.count == 1 { return uniq[0] }
        if uniq.count <= 3 { return uniq.dropLast().joined(separator: ", ") + " & " + uniq.last! }
        return uniq.prefix(3).joined(separator: ", ") + " +\(uniq.count - 3)"
    }

    nonisolated static func queryMessages(_ path: String, chatId: Int64) -> [IMMessage] {
        guard let db = open(path) else { return [] }
        defer { sqlite3_close(db) }
        let sql = """
        SELECT m.ROWID, m.is_from_me, m.text, m.attributedBody
        FROM chat_message_join j JOIN message m ON m.ROWID=j.message_id
        WHERE j.chat_id=\(chatId) ORDER BY m.date DESC LIMIT 120;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [IMMessage] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let fromMe = sqlite3_column_int(stmt, 1) == 1
            var body = text(stmt, 2) ?? ""
            if body.isEmpty, let blob = blob(stmt, 3) { body = decodeAttributedBody(blob) ?? "" }
            if body.isEmpty { body = "[attachment]" }
            out.append(IMMessage(id: id, text: body, fromMe: fromMe))
        }
        return out.reversed()
    }

    /// Incoming unread messages in the last 30 days — the "new messages" count,
    /// not the entire is_read=0 backlog (the Mac's Messages DB keeps hundreds of
    /// ancient unread rows it never marked read; those would wrongly show 99+).
    nonisolated static func queryUnread(_ path: String) -> Int {
        guard let db = open(path) else { return 0 }
        defer { sqlite3_close(db) }
        let sql = """
        SELECT COUNT(*) FROM message
        WHERE is_from_me=0 AND is_read=0
          AND (date/1000000000 + 978307200) > strftime('%s','now','-30 days');
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
    }

    nonisolated private static func text(_ s: OpaquePointer?, _ i: Int32) -> String? {
        guard let c = sqlite3_column_text(s, i) else { return nil }
        return String(cString: c)
    }
    nonisolated private static func blob(_ s: OpaquePointer?, _ i: Int32) -> Data? {
        guard let p = sqlite3_column_blob(s, i) else { return nil }
        let n = sqlite3_column_bytes(s, i)
        return Data(bytes: p, count: Int(n))
    }

    /// Best-effort text extraction from a streamtyped `attributedBody` blob.
    nonisolated static func decodeAttributedBody(_ data: Data) -> String? {
        guard let r = data.range(of: Data("NSString".utf8)) else { return nil }
        var i = r.upperBound
        while i < data.endIndex && data[i] != 0x2b { i += 1 }   // find '+'
        i += 1
        guard i < data.endIndex else { return nil }
        var len = Int(data[i]); i += 1
        if len == 0x81 {                                        // 2-byte length
            guard i + 1 < data.endIndex else { return nil }
            len = Int(data[i]) | (Int(data[i + 1]) << 8); i += 2
        } else if len == 0x82 {                                 // 3-byte length
            guard i + 2 < data.endIndex else { return nil }
            len = Int(data[i]) | (Int(data[i + 1]) << 8) | (Int(data[i + 2]) << 16); i += 3
        }
        guard len > 0, i + len <= data.endIndex else { return nil }
        return String(data: data.subdata(in: i..<(i + len)), encoding: .utf8)
    }
}

/// Resolves chat.db handles (phone numbers / emails) to Contacts names so the
/// iMSG tab shows real names instead of raw numbers. Reads the Mac Contacts
/// store once (which syncs from iCloud / iPhone). Requires Contacts permission.
final class ContactsResolver {
    static let shared = ContactsResolver()
    private var phone: [String: String] = [:]   // last-10 digits → name
    private var email: [String: String] = [:]   // lowercased email → name
    private var loaded = false
    private var loading = false

    func load() {
        if loaded || loading { return }
        let status = CNContactStore.authorizationStatus(for: .contacts)
        if status == .denied || status == .restricted { return }   // can't re-prompt; user enables in Settings
        loading = true
        // Agent (LSUIElement) apps can't show a TCC prompt unless they briefly
        // become a regular, activatable app. Flip policy for the first prompt.
        let flipped = (status == .notDetermined)
        if flipped {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
        let store = CNContactStore()
        store.requestAccess(for: .contacts) { granted, _ in
            if flipped { DispatchQueue.main.async { NSApp.setActivationPolicy(.accessory) } }
            guard granted else { self.loading = false; return }
            let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey,
                        CNContactPhoneNumbersKey, CNContactEmailAddressesKey] as [CNKeyDescriptor]
            let req = CNContactFetchRequest(keysToFetch: keys)
            var pm: [String: String] = [:], em: [String: String] = [:]
            try? store.enumerateContacts(with: req) { c, _ in
                let nm = [c.givenName, c.familyName].filter { !$0.isEmpty }.joined(separator: " ")
                let disp = nm.isEmpty ? c.organizationName : nm
                guard !disp.isEmpty else { return }
                for ph in c.phoneNumbers {
                    let d = ph.value.stringValue.filter(\.isNumber)
                    if d.count >= 10 { pm[String(d.suffix(10))] = disp }
                }
                for e in c.emailAddresses { em[(e.value as String).lowercased()] = disp }
            }
            DispatchQueue.main.async {
                self.phone = pm; self.email = em; self.loaded = true; self.loading = false
                MessagesStore.shared.refresh()      // re-render with names now available
            }
        }
    }

    func name(for identifier: String) -> String? {
        if identifier.isEmpty { return nil }
        if identifier.contains("@") { return email[identifier.lowercased()] }
        let d = identifier.filter(\.isNumber)
        if d.count >= 10 { return phone[String(d.suffix(10))] }
        return nil
    }
}

struct MessagesTabView: View {
    @ObservedObject var store = MessagesStore.shared
    @State private var draft = ""

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 210).background(Color(white: 0.10))
            Divider()
            thread.frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.07)).foregroundColor(.white)
        .onAppear { store.start() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("MESSAGES").font(.system(size: 10, weight: .bold)).foregroundColor(.gray)
                .padding(.horizontal, 10).padding(.vertical, 8)
            if let e = store.error {
                Text(e).font(.system(size: 10)).foregroundColor(.orange).padding(10)
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(store.conversations) { c in
                        Button { store.select(c) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                                Text(c.snippet).font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(store.selected == c ? Color.white.opacity(0.10) : Color.clear)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Delete Conversation…", role: .destructive) {
                                store.confirmDeleteConversation(c)
                            }
                        }
                    }
                }
            }
        }
    }

    private var thread: some View {
        VStack(spacing: 0) {
            if let c = store.selected {
                Text(c.name).font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10).background(Color(white: 0.10))
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(store.messages) { m in bubble(m).id(m.id) }
                        }.padding(12)
                    }
                    .onChange(of: store.messages.last?.id) { _ in
                        if let last = store.messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                    }
                    .onChange(of: store.selected?.id) { _ in     // jump to newest when opening a thread
                        if let last = store.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                    .onAppear {
                        if let last = store.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
                HStack(spacing: 8) {
                    TextField("iMessage", text: $draft, onCommit: sendDraft)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        store.craftReply()
                    } label: {
                        if store.crafting {
                            ProgressView().controlSize(.small).frame(width: 126)
                        } else {
                            Text("Craft Auto Response").font(.system(size: 11, weight: .semibold))
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(red: 0.80, green: 0.47, blue: 0.36))   // Claude burnt orange (#CC785C)
                    .disabled(store.crafting)
                    .help("Queues a request for the local Claude task, which drafts a reply into the field using your relationship + recent-work context — nothing is sent until you hit Send")
                    Button("Send", action: sendDraft).disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(8).background(Color(white: 0.10))
                .onChange(of: store.suggestion) { s in
                    if let s { draft = s; store.suggestion = nil }   // fill, never send
                }
            } else {
                Text("Select a conversation").foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func bubble(_ m: IMMessage) -> some View {
        HStack {
            if m.fromMe { Spacer(minLength: 40) }
            Text(m.text).font(.system(size: 12)).foregroundColor(.white)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(m.fromMe ? Color.blue : Color.gray.opacity(0.35))
                .cornerRadius(13)
            if !m.fromMe { Spacer(minLength: 40) }
        }
    }

    private func sendDraft() {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        store.send(t); draft = ""
    }
}
