import Foundation
import Testing
@testable import VisorCore

@Suite("Away recap")
struct AwayRecapTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

    func hook(_ event: String, session: String, cwd: String? = nil, tool: String? = nil,
              input: [String: Any] = [:], extra: [String: Any] = [:]) -> HookMessage {
        var payload: [String: Any] = ["session_id": session, "cwd": cwd ?? "/Users/me/\(session)"]
        if let tool { payload["tool_name"] = tool; payload["tool_input"] = input }
        payload.merge(extra) { $1 }
        return HookMessage(event: event, pid: 1, payload: payload)
    }

    /// A session asking for approval of `npm install` at `time`.
    func approval(_ board: inout AgentBoard, _ session: String, at time: Date) {
        board.apply(hook("UserPromptSubmit", session: session, extra: ["prompt": "fix it"]), now: time.addingTimeInterval(-5))
        board.apply(hook("PermissionRequest", session: session, tool: "Bash", input: ["command": "npm install"]), now: time)
    }

    /// A session asking a question at `time`.
    func question(_ board: inout AgentBoard, _ session: String, at time: Date) {
        board.apply(hook("UserPromptSubmit", session: session, extra: ["prompt": "plan it"]), now: time.addingTimeInterval(-5))
        board.apply(hook("PreToolUse", session: session, tool: AgentQuestion.tool,
                         input: ["questions": [["header": "Which DB?", "question": "Which database?"]]]), now: time)
    }

    /// A session whose turn finished at `time`, already done on the board.
    func finished(_ board: inout AgentBoard, _ session: String, at time: Date) -> FinishedTurn {
        board.apply(hook("UserPromptSubmit", session: session, extra: ["prompt": "ship it"]), now: time.addingTimeInterval(-60))
        let stop = hook("Stop", session: session)
        let turn = board.finished(stop, now: time)!
        board.apply(stop, now: time)
        return turn
    }

    /// `npm test` failing 3 times in a row in `session`, the last run at `last`.
    func stuck(_ session: String, last: Date) -> [Stuck] {
        var watch = StuckWatch()
        for i in 0..<3 {
            let time = last.addingTimeInterval(Double(i - 2))
            _ = watch.record(hook("PreToolUse", session: session, tool: "Bash", input: ["command": "npm test"]), agent: "Claude Code", at: time)
            _ = watch.record(hook("PostToolUseFailure", session: session, tool: "Bash", input: ["command": "npm test"],
                                  extra: ["error": "FAIL"]), agent: "Claude Code", at: time)
        }
        return watch.active(at: last)
    }

    func stats(files: Int, tests: Bool?) -> TurnStats {
        var turn = TurnStats()
        for i in 0..<files {
            turn.record(hook("PreToolUse", session: "s", tool: "Edit",
                             input: ["file_path": "/Users/me/web/f\(i).ts", "old_string": "a", "new_string": "b"]))
        }
        if let tests {
            turn.record(hook("PreToolUse", session: "s", tool: "Bash", input: ["command": "npm test"]))
            turn.record(hook(tests ? "PostToolUse" : "PostToolUseFailure", session: "s", tool: "Bash", input: ["command": "npm test"],
                             extra: ["tool_response": ["stdout": "Tests: 4 passed, 4 total", "stderr": ""]]))
        }
        return turn
    }

    @Test func shortAbsenceGivesNothing() {
        var board = AgentBoard()
        var watch = AwayWatch()
        watch.lock(at: t0)
        approval(&board, "api", at: at(60))
        #expect(watch.unlock(at: at(599), board: board, stuck: []) == nil)
    }

    @Test func longAbsenceGivesRecap() {
        var board = AgentBoard()
        var watch = AwayWatch()
        watch.lock(at: t0)
        approval(&board, "api", at: at(60))
        let digest = watch.unlock(at: at(600), board: board, stuck: [])
        #expect(digest?.items.map(\.kind) == [.approval])
        #expect(digest?.top?.session == "api")
    }

    @Test func nothingChangedGivesNothing() {
        var board = AgentBoard()
        board.apply(hook("SessionStart", session: "web"), now: at(-600))
        var watch = AwayWatch()
        watch.lock(at: t0)
        #expect(watch.unlock(at: at(1800), board: board, stuck: []) == nil)
    }

    @Test func unlockWithoutLockGivesNothing() {
        var board = AgentBoard()
        approval(&board, "api", at: at(60))
        var watch = AwayWatch()
        #expect(watch.unlock(at: at(1800), board: board, stuck: []) == nil)
    }

    @Test func repeatedLockKeepsEarliest() {
        var board = AgentBoard()
        var watch = AwayWatch()
        watch.lock(at: t0)
        watch.lock(at: at(300))
        approval(&board, "api", at: at(400))
        let digest = watch.unlock(at: at(700), board: board, stuck: [])
        #expect(digest?.since == t0)
    }

    @Test func unlockResets() {
        var board = AgentBoard()
        var watch = AwayWatch()
        watch.lock(at: t0)
        let turn = finished(&board, "web", at: at(100))
        watch.noteFinished(turn, at: at(100))
        #expect(watch.isLocked)
        #expect(watch.unlock(at: at(60), board: board, stuck: []) == nil, "under ten minutes")
        #expect(!watch.isLocked)
        watch.lock(at: at(200))
        #expect(watch.unlock(at: at(900), board: board, stuck: []) == nil, "the turn noted in the earlier lock is gone")
        #expect(watch.unlock(at: at(2000), board: board, stuck: []) == nil)
    }

    @Test func onlyChangesWhileLocked() {
        var board = AgentBoard()
        approval(&board, "old", at: at(-60))
        question(&board, "api", at: at(120))
        var watch = AwayWatch()
        watch.lock(at: t0)
        let digest = watch.unlock(at: at(900), board: board, stuck: stuck("old", last: at(-30)))
        #expect(digest?.items.map(\.session) == ["api"])
        #expect(digest?.items.map(\.kind) == [.question])
    }

    @Test func stuckRowSaysWhatLoops() {
        var board = AgentBoard()
        board.apply(hook("UserPromptSubmit", session: "notch", cwd: "/Users/me/notch-app", extra: ["prompt": "fix"]), now: at(50))
        var watch = AwayWatch()
        watch.lock(at: t0)
        let item = watch.unlock(at: at(900), board: board, stuck: stuck("notch", last: at(102)))?.top
        #expect(item?.kind == .stuck)
        #expect(item?.detail == "npm test · failed 3x in a row")
        #expect(item?.project == "notch-app")
        #expect(item?.agent == "Claude Code")
        #expect(item?.at == at(102))
    }

    @Test func ordersWaitingThenStuckThenFinished() {
        var board = AgentBoard()
        var watch = AwayWatch()
        watch.lock(at: t0)
        watch.noteFinished(finished(&board, "web", at: at(50)), at: at(50))
        question(&board, "docs", at: at(60))
        approval(&board, "late", at: at(200))
        approval(&board, "early", at: at(100))
        let digest = watch.unlock(at: at(900), board: board, stuck: stuck("notch", last: at(30)))
        #expect(digest?.items.map(\.kind) == [.approval, .approval, .question, .stuck, .finished])
        #expect(digest?.items.prefix(2).map(\.session) == ["early", "late"])
    }

    @Test func finishedRowSaysFilesAndTests() {
        #expect(AwayDigest.facts(stats(files: 6, tests: true)) == "Finished · 6 files · tests passed")
        #expect(AwayDigest.facts(stats(files: 1, tests: false)) == "Finished · 1 file · tests failed")
        var board = AgentBoard()
        var watch = AwayWatch()
        watch.lock(at: t0)
        var turn = finished(&board, "web", at: at(100))
        turn.stats = stats(files: 6, tests: true)
        watch.noteFinished(turn, at: at(100))
        let item = watch.unlock(at: at(900), board: board, stuck: [])?.top
        #expect(item?.kind == .finished)
        #expect(item?.detail == "Finished · 6 files · tests passed")
        #expect(item?.project == "web")
    }

    @Test func finishedRowWithoutFacts() {
        #expect(AwayDigest.facts(TurnStats()) == "Finished")
        #expect(AwayDigest.facts(stats(files: 0, tests: nil)) == "Finished")
    }

    @Test func oneRowPerSession() {
        var board = AgentBoard()
        var watch = AwayWatch()
        watch.lock(at: t0)
        watch.noteFinished(finished(&board, "web", at: at(100)), at: at(100))
        watch.noteFinished(finished(&board, "web", at: at(300)), at: at(300))
        watch.noteFinished(finished(&board, "api", at: at(150)), at: at(150))
        approval(&board, "api", at: at(400))
        let digest = watch.unlock(at: at(900), board: board, stuck: [])
        #expect(digest?.items.map(\.kind) == [.approval, .finished])
        #expect(digest?.items.last?.session == "web")
        #expect(digest?.items.last?.at == at(300))
    }

    @Test func rowSaysAgo() {
        var board = AgentBoard()
        var watch = AwayWatch()
        watch.lock(at: t0)
        question(&board, "api", at: at(660))
        let unlock = at(900)
        let item = watch.unlock(at: unlock, board: board, stuck: [])?.top
        #expect(item?.at == at(660))
        #expect(item?.agent == "Claude Code")
        #expect(item?.project == "api")
        #expect(item.map { SessionText.ago($0.at, now: unlock) } == "4m ago")
    }

    @Test func headerSaysMinutesAway() {
        var board = AgentBoard()
        var watch = AwayWatch()
        watch.lock(at: t0)
        approval(&board, "api", at: at(60))
        question(&board, "docs", at: at(70))
        let digest = watch.unlock(at: at(42 * 60 + 30), board: board, stuck: [])
        #expect(digest?.minutes == 42)
        #expect(digest?.title == "While you were away · 42 min")
        board.apply(hook("PostToolUse", session: "api", tool: "Bash", input: ["command": "npm install"]), now: at(3000))
        let pruned = digest?.pruned(board: board, stuck: [])
        #expect(pruned?.count == 1)
        #expect(pruned?.title == "While you were away · 42 min")
    }

    @Test func handledItemsDrop() {
        var board = AgentBoard()
        var watch = AwayWatch()
        watch.lock(at: t0)
        approval(&board, "a1", at: at(10))
        approval(&board, "a2", at: at(11))
        question(&board, "q1", at: at(20))
        question(&board, "q2", at: at(21))
        watch.noteFinished(finished(&board, "f1", at: at(30)), at: at(30))
        watch.noteFinished(finished(&board, "f2", at: at(31)), at: at(31))
        watch.noteFinished(finished(&board, "f3", at: at(32)), at: at(32))
        let loops = stuck("s1", last: at(40))
        let digest = watch.unlock(at: at(900), board: board, stuck: loops)
        #expect(digest?.count == 8)
        // Answered approval and question, a new prompt in one finished session, another ended.
        board.apply(hook("PostToolUse", session: "a1", tool: "Bash", input: ["command": "npm install"]), now: at(1000))
        board.apply(hook("PostToolUse", session: "q1", tool: AgentQuestion.tool), now: at(1000))
        board.apply(hook("UserPromptSubmit", session: "f1", extra: ["prompt": "again"]), now: at(1000))
        board.apply(hook("SessionEnd", session: "f2"), now: at(1000))
        let pruned = digest?.pruned(board: board, stuck: loops)
        #expect(pruned?.items.map(\.session) == ["a2", "q2", "s1", "f3"])
        // The stuck warning cleared.
        #expect(pruned?.pruned(board: board, stuck: [])?.items.map(\.session) == ["a2", "q2", "f3"])
        // Asking again later is a new wait, not the one from while away.
        approval(&board, "a2", at: at(1100))
        #expect(pruned?.pruned(board: board, stuck: [])?.items.map(\.session) == ["q2", "f3"])
    }

    @Test func emptyRecapGoes() {
        var board = AgentBoard()
        var watch = AwayWatch()
        watch.lock(at: t0)
        approval(&board, "api", at: at(10))
        let digest = watch.unlock(at: at(900), board: board, stuck: [])
        #expect(digest?.pruned(board: board, stuck: []) == digest, "nothing handled yet")
        board.apply(hook("PostToolUse", session: "api", tool: "Bash", input: ["command": "npm install"]), now: at(1000))
        #expect(digest != nil)
        #expect(digest?.pruned(board: board, stuck: []) == nil)
    }

    @Test func removingTopItem() {
        var board = AgentBoard()
        var watch = AwayWatch()
        watch.lock(at: t0)
        approval(&board, "api", at: at(10))
        question(&board, "docs", at: at(20))
        let digest = watch.unlock(at: at(900), board: board, stuck: [])!
        #expect(digest.removing(id: "nope") == digest)
        let next = digest.removing(id: digest.top!.id)
        #expect(next?.top?.session == "docs")
        #expect(next?.count == 1)
        #expect(next.flatMap { $0.removing(id: $0.top!.id) } == nil)
    }

    @Test func rowsCapAtFour() {
        var board = AgentBoard()
        var watch = AwayWatch()
        watch.lock(at: t0)
        for i in 0..<6 { approval(&board, "s\(i)", at: at(Double(10 + i))) }
        let digest = watch.unlock(at: at(900), board: board, stuck: [])!
        let shown = digest.rows(limit: AwayDigest.maxRows)
        #expect(shown.rows.map(\.session) == ["s0", "s1", "s2", "s3"])
        #expect(shown.more == 2)
        let few = digest.removing(id: "approval|s0")!.removing(id: "approval|s1")!.removing(id: "approval|s2")!
        #expect(few.rows(limit: 4).rows.count == 3)
        #expect(few.rows(limit: 4).more == 0)
    }

    @Test func notesOnlyWhileLocked() {
        var board = AgentBoard()
        var watch = AwayWatch()
        watch.noteFinished(finished(&board, "web", at: at(-100)), at: at(-100))
        watch.lock(at: t0)
        #expect(watch.unlock(at: at(900), board: board, stuck: []) == nil)
    }

    @Test func newRecapKeepsEarlierItems() throws {
        // First lock: api asks for approval, web finishes. Neither is handled.
        var board = AgentBoard()
        var watch = AwayWatch()
        watch.lock(at: t0)
        approval(&board, "api", at: at(60))
        let turn = finished(&board, "web", at: at(120))
        watch.noteFinished(turn, at: at(120))
        let firstUnlock = watch.unlock(at: at(900), board: board, stuck: [])
        let first = try #require(firstUnlock)
        // Second lock: docs asks a question; web finishes again.
        watch.lock(at: at(1000))
        question(&board, "docs", at: at(1100))
        let again = finished(&board, "web", at: at(1200))
        watch.noteFinished(again, at: at(1200))
        let secondUnlock = watch.unlock(at: at(1700), board: board, stuck: [])
        let second = try #require(secondUnlock)
        let merged = second.adding(first)
        #expect(merged.items.map(\.kind) == [.approval, .question, .finished])
        #expect(merged.items.map(\.session) == ["api", "docs", "web"])
        // The later finished row for web wins; the title is the latest absence.
        #expect(merged.items.last?.at == at(1200))
        #expect(merged.since == at(1000))
        #expect(merged.title == second.title)
    }

    @Test func newRecapDropsEarlierRowOfSameSession() throws {
        var board = AgentBoard()
        var watch = AwayWatch()
        watch.lock(at: t0)
        let turn = finished(&board, "web", at: at(120))
        watch.noteFinished(turn, at: at(120))
        let firstUnlock = watch.unlock(at: at(900), board: board, stuck: [])
        let first = try #require(firstUnlock)
        watch.lock(at: at(1000))
        approval(&board, "web", at: at(1100))
        let secondUnlock = watch.unlock(at: at(1700), board: board, stuck: [])
        let second = try #require(secondUnlock)
        // web now waits on you: only that row, not the old finished one.
        #expect(second.adding(first).items.map(\.kind) == [.approval])
    }

    // QA cases (I2 QA, cases.md).

    /// QA 1: a turn finishing while locked under 10 minutes gives nothing, with or without 9 min away.
    @Test func qaFinishWhileShortLockGivesNothing() {
        for away: Double in [30, 540] {
            var board = AgentBoard()
            var watch = AwayWatch()
            watch.lock(at: t0)
            watch.noteFinished(finished(&board, "web", at: at(10)), at: at(10))
            #expect(watch.unlock(at: at(away), board: board, stuck: []) == nil)
        }
    }

    /// QA 7: A waits since before the lock; B finished, C stuck, D asks, E wants approval while locked.
    @Test func qaOrderWithOlderWaitLeftOut() {
        var board = AgentBoard()
        approval(&board, "A", at: at(-120))
        board.apply(hook("UserPromptSubmit", session: "C", extra: ["prompt": "test"]), now: at(-10))
        var watch = AwayWatch()
        watch.lock(at: t0)
        watch.noteFinished(finished(&board, "B", at: at(60)), at: at(60))
        question(&board, "D", at: at(120))
        approval(&board, "E", at: at(180))
        let digest = watch.unlock(at: at(42 * 60), board: board, stuck: stuck("C", last: at(90)))
        #expect(digest?.items.map(\.session) == ["E", "D", "C", "B"])
        #expect(digest?.items.map(\.kind) == [.approval, .question, .stuck, .finished])
    }

    /// QA 8: a finished turn that edited 2 files.
    @Test func qaFinishedRowWithTwoFiles() {
        var board = AgentBoard()
        var watch = AwayWatch()
        watch.lock(at: t0)
        var turn = finished(&board, "web", at: at(100))
        turn.stats = stats(files: 2, tests: nil)
        watch.noteFinished(turn, at: at(100))
        #expect(watch.unlock(at: at(900), board: board, stuck: [])?.top?.detail == "Finished · 2 files")
    }

    /// QA 12: an approval answered by a new prompt and a question answered drop; then the card goes.
    @Test func qaAnsweringEachItemClearsTheRecap() {
        var board = AgentBoard()
        var watch = AwayWatch()
        watch.lock(at: t0)
        approval(&board, "api", at: at(60))
        question(&board, "docs", at: at(70))
        let digest = watch.unlock(at: at(900), board: board, stuck: [])
        #expect(digest?.count == 2)
        board.apply(hook("UserPromptSubmit", session: "api", extra: ["prompt": "go on"]), now: at(1000))
        let one = digest?.pruned(board: board, stuck: [])
        #expect(one?.items.map(\.session) == ["docs"])
        board.apply(hook("PostToolUse", session: "docs", tool: AgentQuestion.tool), now: at(1010))
        #expect(one?.pruned(board: board, stuck: []) == nil)
    }

    /// QA 14: 42 minutes away with nothing changing gives nothing.
    @Test func qaLongLockWithNothingNewGivesNothing() {
        var board = AgentBoard()
        board.apply(hook("UserPromptSubmit", session: "api", extra: ["prompt": "work"]), now: at(-60))
        var watch = AwayWatch()
        watch.lock(at: t0)
        #expect(watch.unlock(at: at(42 * 60), board: board, stuck: []) == nil)
    }

    /// An approval known only from Claude Code's permission notification says it once.
    @Test func approvalFromNotificationSaysItOnce() {
        var board = AgentBoard()
        var watch = AwayWatch()
        watch.lock(at: t0)
        board.apply(hook("UserPromptSubmit", session: "docs", extra: ["prompt": "push"]), now: at(50))
        board.apply(hook("Notification", session: "docs", extra: ["notification_type": "permission_prompt",
                                                                   "message": "Claude needs your permission to use Bash"]), now: at(60))
        approval(&board, "api", at: at(70))
        let items = watch.unlock(at: at(900), board: board, stuck: [])?.items
        #expect(items?.map(\.detail) == ["Needs approval", "Needs approval · Bash: npm install"])
    }
}
