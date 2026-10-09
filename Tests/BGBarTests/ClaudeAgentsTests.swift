import XCTest
@testable import BGBar

final class ClaudeAgentsTests: XCTestCase {
    private func line(_ o: [String: Any]) -> Data {
        var d = try! JSONSerialization.data(withJSONObject: o)
        d.append(0x0A)
        return d
    }

    private func assistant(_ ts: String, content: [[String: Any]], stop: String? = nil, id: String = "m") -> Data {
        var msg: [String: Any] = ["id": id, "role": "assistant", "content": content,
                                  "usage": ["input_tokens": 2, "output_tokens": 10,
                                            "cache_creation_input_tokens": 100, "cache_read_input_tokens": 1000]]
        if let stop { msg["stop_reason"] = stop }
        return line(["type": "assistant", "timestamp": ts, "message": msg])
    }

    private func toolResult(_ ts: String, id: String, error: Bool = false) -> Data {
        line(["type": "user", "timestamp": ts,
              "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": id, "is_error": error]]]])
    }

    func testPartialLineIsBufferedUntilNewline() {
        let r = ClaudeTranscriptReader(url: URL(fileURLWithPath: "/dev/null"))
        let full = assistant("2026-10-09T16:00:00.000Z", content: [["type": "tool_use", "id": "t1", "name": "Bash"]])
        r.consume(full.prefix(20))
        XCTAssertEqual(r.summary.lines, 0)
        r.consume(full.dropFirst(20))
        XCTAssertEqual(r.summary.lines, 1)
        XCTAssertEqual(r.summary.lastTool, "Bash")
        XCTAssertEqual(r.summary.pendingToolIds, ["t1"])
        XCTAssertEqual(r.summary.contextTokens, 1112)
    }

    func testStates() {
        let now = Date()
        let t = ClaudeAgentsScanner.Thresholds()
        let old = now.addingTimeInterval(-600), ancient = now.addingTimeInterval(-3600), fresh = now.addingTimeInterval(-5)

        var s = ClaudeTranscriptSummary()
        s.ingest(line: assistant("2026-10-09T16:00:00Z", content: [["type": "tool_use", "id": "t1", "name": "Read"]]))
        XCTAssertEqual(ClaudeAgentsScanner.baseState(s, mtime: old, now: now, t: t), .running, "tool pendente")
        XCTAssertEqual(ClaudeAgentsScanner.baseState(s, mtime: ancient, now: now, t: t), .failed, "abandonado")
        s.ingest(line: toolResult("2026-10-09T16:00:01Z", id: "t1"))
        s.ingest(line: assistant("2026-10-09T16:00:02Z", content: [["type": "text", "text": "ok"]], stop: "end_turn"))
        XCTAssertEqual(ClaudeAgentsScanner.baseState(s, mtime: fresh, now: now, t: t), .done)

        var h = ClaudeTranscriptSummary()
        h.ingest(line: assistant("2026-10-09T16:00:00Z", content: [["type": "tool_use", "id": "h", "name": "SubagentHandback"]]))
        XCTAssertTrue(h.handedBack)
        XCTAssertEqual(ClaudeAgentsScanner.baseState(h, mtime: fresh, now: now, t: t), .done)

        var e = ClaudeTranscriptSummary()
        e.ingest(line: line(["type": "assistant", "timestamp": "2026-10-09T16:00:00Z", "isApiErrorMessage": true,
                             "message": ["model": "<synthetic>", "stop_reason": "stop_sequence", "content": [["type": "text", "text": "API Error"]]]]))
        XCTAssertEqual(ClaudeAgentsScanner.baseState(e, mtime: old, now: now, t: t), .failed)
    }

    func testTreeFromFixtureDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bgbar-claude-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let proj = root.appendingPathComponent("-tmp-meuprojeto")
        let sid = "11111111-2222-3333-4444-555555555555"
        let sub = proj.appendingPathComponent(sid).appendingPathComponent("subagents")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try (line(["type": "mode"]) + line(["type": "user", "cwd": "/tmp/meuprojeto", "timestamp": "2026-10-09T16:00:00Z"]))
            .write(to: proj.appendingPathComponent(sid + ".jsonl"))
        func agent(_ id: String, parent: String?, depth: Int, _ body: Data) throws {
            var meta: [String: Any] = ["agentType": "general-purpose", "description": "agente \(id)", "spawnDepth": depth]
            if let parent { meta["parentAgentId"] = parent }
            try JSONSerialization.data(withJSONObject: meta).write(to: sub.appendingPathComponent("agent-\(id).meta.json"))
            try body.write(to: sub.appendingPathComponent("agent-\(id).jsonl"))
        }
        try agent("pai", parent: nil, depth: 1, assistant("2026-10-09T16:00:00Z", content: [["type": "text", "text": "aguardando"]], stop: "end_turn"))
        try agent("filho", parent: "pai", depth: 2, assistant("2026-10-09T16:00:01Z", content: [["type": "tool_use", "id": "x", "name": "Edit"]]))
        try agent("neto", parent: "filho", depth: 3, assistant("2026-10-09T16:00:02Z", content: [["type": "tool_use", "id": "y", "name": "SubagentHandback"]]))

        let sessions = ClaudeAgentsScanner(root: root).scan()
        XCTAssertEqual(sessions.count, 1)
        let s = try XCTUnwrap(sessions.first)
        XCTAssertEqual(s.projectName, "meuprojeto")
        XCTAssertEqual(s.agents.map(\.id), ["pai"])
        let pai = s.agents[0]
        XCTAssertEqual(pai.state, .running, "end_turn com filho rodando = esperando filhos")
        XCTAssertEqual(pai.children.first?.id, "filho")
        XCTAssertEqual(pai.children.first?.lastTool, "Edit")
        XCTAssertEqual(pai.children.first?.children.first?.state, .done)
        XCTAssertEqual(pai.children.first?.children.first?.depth, 3)
    }

    func testSessionWithoutSubagentsShowsWhileActive() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bgbar-claude-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let proj = root.appendingPathComponent("-tmp-solo")
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        let main = proj.appendingPathComponent("aaaaaaaa-2222-3333-4444-555555555555.jsonl")
        try line(["type": "user", "cwd": "/tmp/solo", "timestamp": "2026-10-09T16:00:00Z"]).write(to: main)

        let scanner = ClaudeAgentsScanner(root: root)
        scanner.host = "devbox"
        let s = try XCTUnwrap(scanner.scan().first)
        XCTAssertEqual(s.projectName, "solo")
        XCTAssertEqual(s.agents, [])
        XCTAssertEqual(s.host, "devbox")
        // Parada há mais que `mainOnly`: some.
        XCTAssertEqual(scanner.scan(now: Date().addingTimeInterval(16 * 60)).count, 0)
    }

    func testCycleBecomesRoots() throws {
        // Unidade: A→B→A vira raízes; C pendurado no ciclo continua filho de A; pai inexistente vira raiz.
        let p = ClaudeAgentsScanner.resolveParents(["a": "b", "b": "a", "c": "a", "d": "zz", "e": "e", "f": nil])
        XCTAssertEqual(p["a"], .some(nil))
        XCTAssertEqual(p["b"], .some(nil))
        XCTAssertEqual(p["c"], .some("a"))
        XCTAssertEqual(p["d"], .some(nil))
        XCTAssertEqual(p["e"], .some(nil))
        XCTAssertEqual(p["f"], .some(nil))

        // Integração: os agentes do ciclo aparecem na árvore.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bgbar-claude-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let sid = "99999999-2222-3333-4444-555555555555"
        let sub = root.appendingPathComponent("-tmp-ciclo").appendingPathComponent(sid).appendingPathComponent("subagents")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        for (id, parent) in [("a", "b"), ("b", "a"), ("c", "a")] {
            try JSONSerialization.data(withJSONObject: ["agentType": "x", "description": id, "parentAgentId": parent])
                .write(to: sub.appendingPathComponent("agent-\(id).meta.json"))
            try assistant("2026-10-09T16:00:00Z", content: [["type": "tool_use", "id": id, "name": "Bash"]])
                .write(to: sub.appendingPathComponent("agent-\(id).jsonl"))
        }
        let s = try XCTUnwrap(ClaudeAgentsScanner(root: root).scan().first)
        XCTAssertEqual(Set(s.agents.map(\.id)), ["a", "b"])
        XCTAssertEqual(s.agents.first { $0.id == "a" }?.children.map(\.id), ["c"])
        XCTAssertEqual(s.agents.first { $0.id == "b" }?.children.map(\.id), [])
    }

    func testTranscriptTailSurvivesCutInsideMultibyteChar() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bgbar-tail-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let first = line(["type": "user", "message": ["role": "user", "content": "ação é ótima"]])
        let second = line(["type": "user", "message": ["role": "user", "content": "segunda linha"]])
        try (first + second).write(to: url)
        // Janela que começa no meio do "ç" (2 bytes) da primeira linha.
        let cut = first.range(of: Data("ç".utf8))!.lowerBound + 1
        let window = UInt64(first.count + second.count - cut)
        let out = TranscriptTail.render(url, lines: 10, window: window)
        XCTAssertEqual(out, "› segunda linha")
    }
}

/// Imprime a árvore real (somente leitura). Só roda com BGBAR_LIVE=1.
final class ClaudeAgentsLiveDumpTests: XCTestCase {
    func testDumpRealTree() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BGBAR_LIVE"] == "1", "defina BGBAR_LIVE=1")
        let scanner = ClaudeAgentsScanner()
        let t0 = Date()
        let sessions = scanner.scan()
        let t1 = Date()
        _ = scanner.scan()
        print(String(format: "scan inicial: %.0f ms, incremental: %.0f ms",
                     t1.timeIntervalSince(t0) * 1000, Date().timeIntervalSince(t1) * 1000))
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        func dump(_ n: ClaudeAgentNode, _ indent: String) {
            print("\(indent)[\(n.state.rawValue)] \(n.id) d=\(n.depth) \"\(n.description)\" (\(n.agentType)) "
                  + "tokens=\(n.totalTokens) tool=\(n.lastTool ?? "-") ini=\(f.string(from: n.startedAt)) ult=\(f.string(from: n.lastActivityAt))")
            n.children.forEach { dump($0, indent + "    ") }
        }
        for s in sessions {
            print("SESSÃO \(s.projectName) \(s.id) última=\(f.string(from: s.lastActivityAt))")
            s.agents.forEach { dump($0, "  ") }
        }
    }
}
