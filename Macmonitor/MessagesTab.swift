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

    private let dbPath = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Messages/chat.db")
    private var timer: Timer?
    private var started = false

    func start() {
        if !started { started = true; refresh() }
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
            await MainActor.run {
                self.conversations = convos.rows
                self.error = convos.error
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
        SELECT c.ROWID, c.guid,
          COALESCE(NULLIF(c.display_name,''), c.chat_identifier) AS name,
          (SELECT m.text FROM chat_message_join j JOIN message m ON m.ROWID=j.message_id
             WHERE j.chat_id=c.ROWID ORDER BY m.date DESC LIMIT 1) AS snippet,
          (SELECT MAX(m.date) FROM chat_message_join j JOIN message m ON m.ROWID=j.message_id
             WHERE j.chat_id=c.ROWID) AS ldate
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
            let name = text(stmt, 2) ?? "Unknown"
            let snip = text(stmt, 3) ?? ""
            out.append(IMConversation(id: id, guid: guid, name: name, snippet: snip))
        }
        return (out, nil)
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
                    .onChange(of: store.messages.count) { _ in
                        if let last = store.messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                    }
                }
                HStack(spacing: 8) {
                    TextField("iMessage", text: $draft, onCommit: sendDraft)
                        .textFieldStyle(.roundedBorder)
                    Button("Send", action: sendDraft).disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }.padding(8).background(Color(white: 0.10))
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
