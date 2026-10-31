import Foundation
import JavaScriptCore
import NotchboardCore

var failures = 0
var passed = 0

func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if condition {
        passed += 1
    } else {
        failures += 1
        print("FAIL (line \(line)): \(message)")
    }
}

// `NotchboardChecks --real` times a scan of this Mac's real transcripts.
if CommandLine.arguments.contains("--real") {
    let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    let log = TranscriptUsage()
    let start = Date()
    log.scan(root: root)
    let first = Date().timeIntervalSince(start)
    let again = Date()
    log.scan(root: root)
    let s = SpendSummary.make(from: log.records)
    print(String(format: "%d responses, first scan %.2fs, rescan %.3fs", log.records.count, first, Date().timeIntervalSince(again)))
    print(String(format: "today $%.2f, 7d $%.2f, 30d $%.2f", s.today, s.last7Days, s.last30Days))
    exit(0)
}

func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }

// MARK: Pricing

do {
    let opus = Pricing.price(for: "claude-opus-5-5")!
    check(opus.input == 4 && opus.output == 20 && opus.cacheRead == 0.20, "Opus 5.5 list price")
    check(opus.cacheWrite5m == 5 && opus.cacheWrite1h == 8, "cache writes are 1.25x and 2x input")
    check(Pricing.price(for: "claude-opus-5")!.input == 5, "Opus 5 isn't priced as Opus 5.5")
    check(Pricing.price(for: "claude-opus-4-1-20250805")!.input == 15, "old Opus 4.x falls to the Opus 4 price")
    check(Pricing.price(for: "claude-sonnet-5")!.input == 2, "Sonnet 5")
    check(Pricing.price(for: "claude-haiku-4-5-20251001")!.input == 1, "dated Haiku id matches by prefix")
    check(Pricing.price(for: "<synthetic>") == nil, "synthetic messages cost nothing")

    let usage = TokenUsage(model: "claude-opus-5-5", timestamp: Date(), input: 1_000_000, output: 1_000_000,
                           cacheWrite5m: 0, cacheWrite1h: 1_000_000, cacheRead: 1_000_000)
    check(near(usage.cost, 4 + 20 + 8 + 0.2), "cost adds every token kind")
    var fast = usage
    fast.fast = true
    check(near(fast.cost, usage.cost * 2), "fast mode doubles the price")
}

// MARK: Transcripts

do {
    let line1 = #"{"type":"assistant","requestId":"req_1","timestamp":"2026-10-31T02:31:01.360Z","message":{"id":"msg_1","model":"claude-opus-5-5","usage":{"input_tokens":2,"cache_creation_input_tokens":100,"cache_read_input_tokens":1000,"output_tokens":50,"cache_creation":{"ephemeral_1h_input_tokens":100,"ephemeral_5m_input_tokens":0},"speed":"standard"}}}"#
    let user = #"{"type":"user","message":{"role":"user","content":"hi"}}"#
    let noSplit = #"{"type":"assistant","requestId":"req_2","timestamp":"2026-10-31T03:00:00Z","message":{"id":"msg_2","model":"claude-sonnet-5","usage":{"input_tokens":10,"cache_creation_input_tokens":40,"output_tokens":5}}}"#
    let log = TranscriptUsage()
    // The same response appears once per content block.
    log.ingest(Data([line1, user, line1, noSplit, ""].joined(separator: "\n").utf8))
    check(log.records.count == 2, "duplicate content-block lines count once, user lines are skipped")
    let first = log.records[0]
    check(first.cacheWrite1h == 100 && first.cacheWrite5m == 0 && first.cacheRead == 1000, "cache split is read")
    check(log.records[1].cacheWrite5m == 40, "without a split, cache writes count as 5-minute")
    check(log.records[1].timestamp == ISO8601DateFormatter().date(from: "2026-10-31T03:00:00Z"), "timestamps without fractions parse")

    // Incremental scan of a real directory.
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nb-checks-\(UUID().uuidString)")
    let sub = dir.appendingPathComponent("project")
    try! FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
    let file = sub.appendingPathComponent("s.jsonl")
    try! Data((line1 + "\n" + #"{"type":"assistant","#).utf8).write(to: file)
    let scanner = TranscriptUsage()
    check(scanner.scan(root: dir) && scanner.records.count == 1, "first scan reads complete lines only")
    let handle = try! FileHandle(forWritingTo: file)
    handle.seekToEndOfFile()
    handle.write(Data(#""requestId":"req_3","timestamp":"2026-10-31T04:00:00Z","message":{"id":"msg_3","model":"claude-opus-5-5","usage":{"output_tokens":7}}}"#.utf8 + [0x0A]))
    try! handle.close()
    check(scanner.scan(root: dir) && scanner.records.count == 2, "a finished half-line is picked up next scan")
    check(!scanner.scan(root: dir), "an unchanged directory finds nothing new")
    try? FileManager.default.removeItem(at: dir)
}

// MARK: Spend summary

do {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    let now = ISO8601DateFormatter().date(from: "2026-10-31T12:00:00Z")!
    func spend(_ daysAgo: Double, _ output: Int) -> TokenUsage {
        TokenUsage(model: "claude-sonnet-5", timestamp: now.addingTimeInterval(-daysAgo * 86_400), output: output)
    }
    // Sonnet 5 output is $10/MTok, so 100k tokens is $1.
    let records = [spend(0, 100_000), spend(1, 200_000), spend(6, 100_000), spend(10, 100_000), spend(40, 100_000)]
    let s = SpendSummary.make(from: records, now: now, calendar: cal)
    check(near(s.today, 1), "today")
    check(near(s.last7Days, 4), "last 7 days")
    check(near(s.last30Days, 5), "last 30 days")
    check(s.daily.count == 14 && near(s.daily[13], 1) && near(s.daily[12], 2) && near(s.daily[3], 1), "daily bars end today")
    check(s.tokensToday == 100_000, "tokens today")
}

// MARK: Plan limits

do {
    let json = #"{"five_hour":{"utilization":25.0,"resets_at":"2026-10-31T06:09:59.753857+00:00"},"limits":[{"kind":"session","percent":27,"severity":"normal","resets_at":"2026-10-31T06:09:59.773043+00:00"},{"kind":"weekly_all","percent":19,"severity":"normal","resets_at":"2026-11-05T08:59:59.773061+00:00"}],"extra_usage":{"is_enabled":false}}"#
    let plan = PlanUsage.parse(Data(json.utf8))!
    check(plan.limits.count == 2, "limits list wins over the per-window objects")
    check(plan.session?.percentUsed == 27 && plan.session?.percentLeft == 73, "session used and left")
    check(plan.session?.resetsAt != nil, "reset time with microseconds parses")
    check(plan.limits[1].title == "Weekly", "weekly title")
    check(plan.extra == nil, "disabled extra usage is hidden")

    let old = PlanUsage.parse(Data(#"{"five_hour":{"utilization":40,"resets_at":null},"seven_day":{"utilization":10}}"#.utf8))!
    check(old.limits.map(\.kind) == ["five_hour", "seven_day"] && old.session?.percentUsed == 40, "older shape still parses")
    check(PlanUsage.parse(Data("{}".utf8)) == nil, "empty response is no data")
}

// MARK: Agents

do {
    func message(_ event: String, _ raw: String) -> HookMessage {
        HookMessage.parse(Data(#"{"event":"\#(event)","pid":4242,"raw":\#(raw)}"#.utf8))!
    }
    let base = #""session_id":"s1","cwd":"/Users/me/workspace/notchboard""#
    var board = AgentBoard()
    board.apply(message("SessionStart", "{\(base)}"))
    check(board.sessions.count == 1 && board.sessions[0].state == .idle, "session starts idle")
    check(board.sessions[0].project == "notchboard" && board.sessions[0].pid == 4242, "project and pid")
    board.apply(message("UserPromptSubmit", #"{\#(base),"prompt":"Fix the login bug\nand add tests"}"#))
    check(board.sessions[0].state == .working("Thinking") && board.working == 1, "prompt starts work")
    check(board.sessions[0].task == "Fix the login bug" && board.sessions[0].agent == "Claude Code", "task is the prompt's first line")
    board.setHost("Ghostty", session: "s1")
    check(board.sessions[0].host == "Ghostty", "host app recorded")
    board.apply(message("PreToolUse", #"{\#(base),"tool_name":"Bash","tool_input":{"command":"swift build\nswift run"}}"#))
    check(board.sessions[0].state == .working("Bash: swift build"), "tool call shows the first command line")
    board.apply(message("PermissionRequest", #"{\#(base),"tool_name":"Edit","tool_input":{"file_path":"/a/b/Main.swift"}}"#))
    check(board.sessions[0].state == .needsApproval("Edit: Main.swift") && board.waiting == 1, "approval wait")
    board.apply(message("Notification", #"{\#(base),"notification_type":"permission_prompt","message":"Claude needs your permission"}"#))
    check(board.sessions[0].state == .needsApproval("Edit: Main.swift"), "permission notification keeps the detailed approval")
    board.resolveApproval(session: "s1")
    check(board.sessions[0].state == .working("Thinking"), "answering resumes work")
    board.apply(message("Stop", "{\(base)}"))
    check(board.sessions[0].state == .done && !board.sessions[0].isActive, "stop is done")
    board.apply(message("Notification", #"{\#(base),"notification_type":"idle_prompt","message":"Claude is waiting for your input"}"#))
    check(board.sessions[0].state == .needsInput, "idle prompt needs input")
    board.prune { _ in true }
    check(board.sessions.count == 1, "live process is kept")
    board.prune { _ in false }
    check(board.sessions.isEmpty, "exited process is dropped")
    board.apply(message("SessionStart", "{\(base)}"))
    board.apply(message("SessionEnd", "{\(base)}"))
    check(board.sessions.isEmpty, "session end removes it")
    board.apply(message("Stop", "{}"))
    check(board.sessions.isEmpty, "events without a session id are ignored")
}

// MARK: Approvals

do {
    let line = #"{"event":"PermissionRequest","pid":1,"raw":{"session_id":"s1","cwd":"/x/app","tool_name":"Bash","tool_input":{"command":"rm -rf build"},"permission_suggestions":[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"rm:*"}],"behavior":"allow","destination":"localSettings"}]}}"#
    let request = ApprovalRequest(HookMessage.parse(Data(line.utf8))!)!
    check(request.tool == "Bash" && request.preview == "rm -rf build" && request.project == "app", "approval fields")
    check(request.suggestions.count == 1, "suggestions kept for always-allow")
    func decision(_ d: ApprovalRequest.Decision) -> [String: Any] {
        let object = try! JSONSerialization.jsonObject(with: request.reply(d)) as! [String: Any]
        let output = object["hookSpecificOutput"] as! [String: Any]
        check(output["hookEventName"] as? String == "PermissionRequest", "reply names the event")
        return output["decision"] as! [String: Any]
    }
    check(decision(.allow)["behavior"] as? String == "allow", "allow")
    check(decision(.deny)["behavior"] as? String == "deny", "deny")
    check((decision(.allowAlways)["updatedPermissions"] as? [Any])?.count == 1, "always allow echoes the suggestion")
    check(request.reply(.allow).last == 0x0A, "reply is one line")
    check(HookMessage.parse(Data(#"{"event":"Stop","pid":1,"hpid":77,"raw":{}}"#.utf8))?.hookPID == 77, "hook pid is read")
    check(ApprovalRequest(HookMessage.parse(Data(#"{"event":"PreToolUse","raw":{"session_id":"s"}}"#.utf8))!) == nil,
          "only PermissionRequest makes an approval")
}

// MARK: Browser media

do {
    let json = #"{"p":true,"t":61.5,"d":200,"title":"Song","artist":"Band","album":"","art":"https://x/a.jpg","url":"https://www.youtube.com/watch?v=abc123"}"#
    let media = BrowserMedia.parse(json, tab: "1")!
    check(media.playing && media.position == 61.5 && media.duration == 200, "playback fields")
    check(media.title == "Song" && media.artist == "Band" && media.site == "YouTube", "metadata and site")
    check(media.artworkURL?.absoluteString == "https://x/a.jpg", "media session artwork wins")
    let bare = BrowserMedia.parse(#"{"p":false,"t":0,"d":0,"title":"(3) Lofi beats - YouTube","url":"https://www.youtube.com/watch?v=XYZ&t=4"}"#, tab: "2")!
    check(bare.title == "Lofi beats", "page title loses the unread count and site suffix")
    check(bare.artworkURL?.absoluteString == "https://i.ytimg.com/vi/XYZ/hqdefault.jpg", "YouTube thumbnail fallback")
    check(BrowserMedia.parse("", tab: "3") == nil, "a tab without media is skipped")
    check(BrowserMedia.fromTitle("Mix - YouTube", url: "https://music.youtube.com/watch?v=q", tab: "4", playing: true)?.site == "YouTube Music",
          "title-only fallback")
    check(BrowserMedia.isMediaSite("https://www.youtube.com/watch?v=1") && !BrowserMedia.isMediaSite("https://github.com"), "media sites")
    check(!BrowserMedia.probe.contains("\""), "probe has no double quotes, so it fits in AppleScript")

    // Run the page scripts against a fake YouTube page.
    let js = JSContext()!
    js.exceptionHandler = { _, e in check(false, "page script threw: \(e?.toString() ?? "")") }
    js.evaluateScript("""
    var video = {paused: false, currentTime: 42, duration: 180, play: function(){this.paused=false;}, pause: function(){this.paused=true;}};
    var clicked = '';
    var document = {title: '(2) Song - YouTube',
      querySelectorAll: function(){ return [video]; },
      querySelector: function(q){ if (q.indexOf('ytp-next-button') >= 0) return {click: function(){clicked='next';}}; return q.indexOf('video') === 0 ? video : null; }};
    var navigator = {mediaSession: {metadata: {title: 'Song', artist: 'Band', album: '', artwork: [{src: 'https://img/s.jpg'}]}}};
    var location = {href: 'https://www.youtube.com/watch?v=abc'};
    """)
    let probed = js.evaluateScript(BrowserMedia.probe)?.toString() ?? ""
    let live = BrowserMedia.parse(probed, tab: "7")
    check(live?.playing == true && live?.position == 42 && live?.duration == 180 && live?.title == "Song"
          && live?.artist == "Band" && live?.artworkURL?.absoluteString == "https://img/s.jpg", "probe reads the page")
    js.evaluateScript(BrowserMedia.script(for: .playPause))
    check(js.evaluateScript("video.paused")?.toBool() == true, "play/pause pauses a playing video")
    js.evaluateScript(BrowserMedia.script(for: .playPause))
    check(js.evaluateScript("video.paused")?.toBool() == false, "and plays it again")
    js.evaluateScript(BrowserMedia.script(for: .next))
    check(js.evaluateScript("clicked")?.toString() == "next", "next clicks the site's next button")
    js.evaluateScript(BrowserMedia.script(for: .previous))
    check(js.evaluateScript("video.currentTime")?.toInt32() == 0, "previous restarts when there's no previous button")
    js.evaluateScript("navigator.mediaSession = undefined; video.paused = true; video.currentTime = 0")
    check(js.evaluateScript(BrowserMedia.probe)?.toString() == "", "a page with untouched media reports nothing")
}

print("\(passed) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
