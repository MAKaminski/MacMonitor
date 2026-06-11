//
//  ClaudeTab.swift — MacMonitor "CLAUDE" tab
//
//  Claude chat with a left AGENTS ribbon (one conversation + system prompt
//  per agent). API key read from ~/.config/macmonitor/anthropic_key (single
//  line, chmod 600) — never stored in code or UserDefaults.
//
//  Agents are user config: ~/.config/macmonitor/claude_agents.json
//    [{"name":"Quant","icon":"chart.xyaxis.line","system":"You are…"}, …]
//  overrides the generic shipped defaults. Model override:
//    defaults write rybo.Macmonitor claude.model <model-id>
//

import SwiftUI
import Combine

struct ClaudeMsg: Identifiable, Equatable {
    let id = UUID()
    let role: String   // "user" | "assistant" | "error"
    var text: String
}

struct ClaudeAgent: Codable, Identifiable, Equatable {
    var name: String
    var icon: String? = nil       // SF Symbol
    var system: String? = nil     // system prompt
    var id: String { name }
}

@MainActor
final class ClaudeChatStore: ObservableObject {
    static let shared = ClaudeChatStore()
    @Published var conversations: [String: [ClaudeMsg]] = [:]
    @Published var busy = false
    @Published var keyPresent = false
    @Published var agents: [ClaudeAgent] = []
    @Published var current: String =
        UserDefaults.standard.string(forKey: "claude.agent") ?? "General"

    private let keyPath = (NSHomeDirectory() as NSString)
        .appendingPathComponent(".config/macmonitor/anthropic_key")
    private let agentsPath = (NSHomeDirectory() as NSString)
        .appendingPathComponent(".config/macmonitor/claude_agents.json")

    /// Bridge folder shared with the local "macmonitor-claude-agent" task
    /// (separate from Craft Auto Response so usage tracks independently).
    static let bridgeDir = (NSHomeDirectory() as NSString)
        .appendingPathComponent("Documents/Claude/Projects/Personal/claude-agent-bridge")
    private var pollTimer: Timer?

    static let defaultAgents: [ClaudeAgent] = [
        ClaudeAgent(name: "General", icon: "sparkles", system: nil),
        ClaudeAgent(name: "Coder", icon: "chevron.left.forwardslash.chevron.right",
                    system: "You are a senior software engineer. Be terse and precise; prefer code over prose."),
        ClaudeAgent(name: "Analyst", icon: "chart.bar",
                    system: "You are a sharp financial analyst. Show the math, use compact tables, flag estimates vs computed figures."),
        ClaudeAgent(name: "Writer", icon: "pencil.line",
                    system: "You are a crisp professional writing assistant. Tighten wording; no filler."),
    ]

    var model: String {
        UserDefaults.standard.string(forKey: "claude.model") ?? "claude-haiku-4-5-20251001"
    }

    var msgs: [ClaudeMsg] { conversations[current] ?? [] }

    var currentAgent: ClaudeAgent {
        agents.first(where: { $0.name == current }) ?? Self.defaultAgents[0]
    }

    func loadAgents() {
        if let d = try? Data(contentsOf: URL(fileURLWithPath: agentsPath)),
           let custom = try? JSONDecoder().decode([ClaudeAgent].self, from: d),
           !custom.isEmpty {
            agents = custom
        } else {
            agents = Self.defaultAgents
        }
        if !agents.contains(where: { $0.name == current }) {
            current = agents.first?.name ?? "General"
        }
    }

    func select(_ name: String) {
        current = name
        UserDefaults.standard.set(name, forKey: "claude.agent")
    }

    func clearCurrent() { conversations[current] = [] }

    private var apiKey: String? {
        guard let k = try? String(contentsOfFile: keyPath, encoding: .utf8) else { return nil }
        let t = k.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// Bridge mode needs no API key in-app; the local task does the inference.
    func checkKey() { keyPresent = true }

    /// Route the message through the local "macmonitor-claude-agent" task:
    /// write a request file, then watch for a response with the same nonce.
    /// Trigger that task in Claude to service the request.
    func send(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !busy else { return }
        let agent = current
        conversations[agent, default: []].append(ClaudeMsg(role: "user", text: t))
        busy = true
        let history = (conversations[agent] ?? [])
            .filter { $0.role == "user" || $0.role == "assistant" }
            .suffix(24)
            .map { ["role": $0.role, "content": $0.text] }
        let dir = Self.bridgeDir
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let nonce = UUID().uuidString
        var request: [String: Any] = [
            "nonce": nonce,
            "status": "pending",
            "createdAt": ISO8601DateFormatter().string(from: Date()),
            "agent": agent,
            "model": model,
            "messages": Array(history),
        ]
        if let sys = currentAgent.system, !sys.isEmpty { request["system"] = sys }
        let reqURL = URL(fileURLWithPath: dir).appendingPathComponent("request.json")
        guard let data = try? JSONSerialization.data(withJSONObject: request, options: [.prettyPrinted]),
              (try? data.write(to: reqURL)) != nil else {
            conversations[agent, default: []].append(ClaudeMsg(role: "error", text: "Couldn't write the request file at \(dir)."))
            busy = false
            return
        }
        pollForReply(nonce: nonce, agent: agent)
    }

    private func pollForReply(nonce: String, agent: String) {
        pollTimer?.invalidate()
        let start = Date()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] tm in
            let respURL = URL(fileURLWithPath: ClaudeChatStore.bridgeDir).appendingPathComponent("response.json")
            if let d = try? Data(contentsOf: respURL),
               let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               obj["nonce"] as? String == nonce,
               let text = (obj["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty {
                tm.invalidate()
                Task { @MainActor in self?.finishReply(agent: agent, text: text, isError: false) }
            } else if Date().timeIntervalSince(start) > 300 {
                tm.invalidate()
                Task { @MainActor in self?.finishReply(agent: agent,
                    text: "No reply from the local task — run “macmonitor-claude-agent” in Claude, then resend.",
                    isError: true) }
            }
        }
    }

    @MainActor private func finishReply(agent: String, text: String, isError: Bool) {
        pollTimer?.invalidate(); pollTimer = nil
        conversations[agent, default: []].append(ClaudeMsg(role: isError ? "error" : "assistant", text: text))
        busy = false
    }
}

struct ClaudeTabView: View {
    @ObservedObject var store = ClaudeChatStore.shared
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 0) {
            agentRibbon
            Divider().background(Color.white.opacity(0.1))
            chatPane
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.07)).foregroundColor(.white)
        .onAppear { store.checkKey(); store.loadAgents() }
    }

    // ------------------------------------------------------- agents ribbon
    private var agentRibbon: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("AGENTS")
                .font(.system(size: 8, weight: .bold)).tracking(1)
                .foregroundColor(.gray)
                .padding(.bottom, 2)
            ScrollView(showsIndicators: false) {
                VStack(spacing: 3) {
                    ForEach(store.agents) { a in
                        Button { store.select(a.name) } label: {
                            HStack(spacing: 5) {
                                Image(systemName: a.icon ?? "circle.dashed")
                                    .font(.system(size: 10))
                                    .frame(width: 13)
                                Text(a.name)
                                    .font(.system(size: 10, weight: store.current == a.name ? .bold : .regular))
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                let n = (store.conversations[a.name] ?? []).count
                                if n > 0 {
                                    Text("\(n)")
                                        .font(.system(size: 7, design: .monospaced))
                                        .foregroundColor(.gray)
                                }
                            }
                            .padding(.horizontal, 7).padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 7)
                                .fill(store.current == a.name
                                      ? Color.orange.opacity(0.28)
                                      : Color.white.opacity(0.05)))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Spacer(minLength: 4)
            Text("edit: claude_agents.json")
                .font(.system(size: 7)).foregroundColor(.gray.opacity(0.7))
                .lineLimit(1)
        }
        .padding(8)
        .frame(width: 118)
    }

    // ----------------------------------------------------------- chat pane
    private var chatPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if !store.keyPresent { keyBanner }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        if store.msgs.isEmpty && store.keyPresent {
                            Text("Ask \(store.current) anything — each agent keeps its own thread.")
                                .font(.system(size: 10)).foregroundColor(.secondary)
                                .padding(.top, 20)
                        }
                        ForEach(store.msgs) { m in ClaudeBubble(m: m) }
                        if store.busy {
                            Text("Waiting for the local Claude task…")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(.cyan).id("busy")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 2)
                }
                .onChange(of: store.conversations) { _ in
                    if let last = store.msgs.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            HStack(spacing: 6) {
                TextField("Message \(store.current)…", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.08)))
                    .focused($focused)
                    .onSubmit { submit() }
                Button { submit() } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(store.busy || draft.trimmingCharacters(in: .whitespaces).isEmpty
                                         ? .gray : .orange)
                }
                .buttonStyle(.plain)
                .disabled(store.busy)
            }
        }
        .padding(12)
    }

    private func submit() {
        let t = draft
        draft = ""
        store.send(t)
    }

    private var header: some View {
        HStack {
            Text("CLAUDE — \(store.current.uppercased()) — \(store.model.uppercased())")
                .font(.system(size: 10, weight: .bold)).tracking(1).foregroundColor(.gray)
                .lineLimit(1)
            Spacer()
            Circle().fill(Color.green).frame(width: 7, height: 7)
            Text("task bridge")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.green)
                .help("Messages route through the local macmonitor-claude-agent task")
            if !store.msgs.isEmpty {
                Button { store.clearCurrent() } label: {
                    Image(systemName: "trash").font(.system(size: 9)).foregroundColor(.gray)
                }
                .buttonStyle(.plain).help("Clear this agent's conversation")
            }
        }
    }

    private var keyBanner: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("No API key found").font(.system(size: 12, weight: .semibold)).foregroundColor(.orange)
            Text("Paste an Anthropic API key into ~/.config/macmonitor/anthropic_key (single line). The tab picks it up automatically — no restart needed.")
                .font(.system(size: 10)).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Re-check") { store.checkKey() }
                .font(.system(size: 10)).buttonStyle(.bordered)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.12)))
    }
}

struct ClaudeBubble: View {
    let m: ClaudeMsg

    var body: some View {
        HStack {
            if m.role == "user" { Spacer(minLength: 40) }
            Text(m.text)
                .font(.system(size: 11))
                .textSelection(.enabled)
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 9).fill(bg))
                .frame(maxWidth: 520, alignment: m.role == "user" ? .trailing : .leading)
            if m.role != "user" { Spacer(minLength: 40) }
        }
        .id(m.id)
    }

    private var bg: Color {
        switch m.role {
        case "user":  return Color.orange.opacity(0.25)
        case "error": return Color.red.opacity(0.25)
        default:      return Color.white.opacity(0.08)
        }
    }
}
