import Foundation

@main
struct CodexUsageTests {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError("FAIL: \(message)") }
            checks += 1
            print("PASS: \(message)")
        }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let future = now.addingTimeInterval(3600).timeIntervalSince1970
        func window(_ used: Any = 23, minutes: Any = 300, reset: Any? = nil) -> [String: Any] {
            ["used_percent": used, "window_minutes": minutes, "resets_at": reset ?? future]
        }
        func event(at date: Date, primary: Any = NSNull(), secondary: Any = NSNull(),
                   plan: Any = "plus", id: String? = "codex", type: String = "event_msg") throws -> Data {
            var limits: [String: Any] = ["primary": primary, "secondary": secondary, "plan_type": plan]
            if let id { limits["limit_id"] = id }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return try JSONSerialization.data(withJSONObject: ["type": type,
                "timestamp": formatter.string(from: date),
                "payload": ["type": "token_count", "rate_limits": limits]])
        }
        func parsed(_ primary: Any, secondary: Any = NSNull(), plan: Any = "plus") throws -> CodexUsageSnapshot {
            CodexQuotaEventDecoder.decode(try event(at: now, primary: primary, secondary: secondary, plan: plan), readAt: now)!
        }
        let both = try parsed(window(), secondary: window(45, minutes: 10080))
        check(both.windows.map(\.label) == ["5h", "7d"], "actual durations label two windows")
        check(both.windows[0].remainingPercent == 77, "remaining percentage is derived from used")
        let week = try parsed(window(2, minutes: 10080), plan: "prolite")
        check(week.windows.count == 1 && week.windows[0].label == "7d", "weekly-only plans remain one weekly row")
        let reverse = try parsed(window(30, minutes: 10080), secondary: window(2, minutes: 300))
        check(reverse.windows.map(\.label) == ["7d", "5h"], "window order never invents durations")
        let odd = try parsed(window(5, minutes: 90))
        check(odd.windows[0].label == "90m", "nonstandard window duration is preserved")
        let unknown = try parsed(["used_percent": 9])
        check(unknown.windows[0].label == "?", "missing duration stays unknown")
        let missing = try parsed(["window_minutes": 300])
        check(missing.windows[0].usedPercent == nil, "missing percentage is not zero")
        let zero = try parsed(window(0))
        check(zero.windows[0].usedPercent == 0, "reported zero is retained")
        let invalid = try parsed(window(true, minutes: true))
        check(invalid.windows[0].usedPercent == nil && invalid.windows[0].windowMinutes == 0,
              "JSON booleans cannot masquerade as numerical quota")
        let excessive = try parsed(window(120))
        check(excessive.windows[0].usedPercent == nil, "invalid percentages are unknown")
        let expired = try parsed(window(80, reset: now.timeIntervalSince1970)).effective(at: now)
        check(expired.windows[0].usedPercent == nil && expired.windows[0].resetsAt == nil,
              "expired windows clear percentage and reset without guessing")
        let noWindows = try parsed(NSNull(), plan: NSNull())
        check(noWindows.windows.isEmpty && noWindows.planType == nil, "empty latest quota event is meaningful")
        let foreign = try event(at: now, primary: window(), id: "premium")
        check(CodexQuotaEventDecoder.decode(foreign, readAt: now) == nil, "foreign rate-limit bucket is excluded")
        let quoted = try event(at: now, primary: window(), type: "response_item")
        check(CodexQuotaEventDecoder.decode(quoted, readAt: now) == nil, "conversation JSON is not treated as quota event")
        let legacy = try event(at: now, primary: window(), id: nil)
        check(CodexQuotaEventDecoder.decode(legacy, readAt: now) != nil, "legacy unnamed Codex event remains readable")
        let undated = Data(#"{"payload":{"rate_limits":{"primary":{"used_percent":2}}}}"#.utf8)
        check(CodexQuotaEventDecoder.decode(undated, readAt: now) == nil, "missing source timestamp is never replaced by file mtime")
        let malformed = Data("{broken \"rate_limits\":}".utf8)
        check(CodexQuotaEventDecoder.decode(malformed, readAt: now) == nil, "malformed log line is skipped")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PulseBar-CodexTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let older = directory.appendingPathComponent("older.jsonl")
        let newer = directory.appendingPathComponent("newer.jsonl")
        func writeLine(_ data: Data, to url: URL) throws { try (data + Data([10])).write(to: url) }
        func append(_ data: Data, to url: URL) throws {
            let file = try FileHandle(forWritingTo: url)
            defer { try? file.close() }
            try file.seekToEnd()
            try file.write(contentsOf: data)
        }
        try writeLine(event(at: now.addingTimeInterval(-100), primary: window(70)), to: older)
        try writeLine(event(at: now.addingTimeInterval(-10), primary: window(25), secondary: window(40, minutes: 10080)), to: newer)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: older.path)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-20)], ofItemAtPath: newer.path)
        let reader = CodexSessionLogReader(directory: directory)
        let first = reader.read(now: now)
        check(first.snapshot?.windows.first?.usedPercent == 25, "newest event wins despite unrelated newer file mtime")
        check(first.snapshot?.observedAt == now.addingTimeInterval(-10), "source event timestamp is retained")
        let unchanged = reader.read(now: now.addingTimeInterval(5))
        check(unchanged.bytesRead == 0 && unchanged.inspectedFiles == 2, "unchanged five-second poll performs no log reread")
        check(unchanged.snapshot?.observedAt == first.snapshot?.observedAt && unchanged.snapshot?.readAt != first.snapshot?.readAt,
              "local read time and source observation time are distinct")
        let latest = try event(at: now.addingTimeInterval(1), primary: window(4, minutes: 10080), plan: "prolite")
        try append(latest + Data([10]), to: older)
        let changed = reader.read(now: now.addingTimeInterval(10))
        check(changed.bytesRead == latest.count + 1, "append poll reads only the new bytes")
        check(changed.snapshot?.planType == "prolite" && changed.snapshot?.windows.count == 1,
              "account plan and windows switch atomically without stale merging")
        let partial = try event(at: now.addingTimeInterval(11), primary: window(8), plan: "pro")
        try append(partial.prefix(partial.count / 2), to: newer)
        let duringWrite = reader.read(now: now.addingTimeInterval(15))
        check(duringWrite.snapshot?.planType == "prolite", "partial JSONL writes cannot replace valid quota")
        try append(partial.suffix(partial.count - partial.count / 2) + Data([10]), to: newer)
        let completed = reader.read(now: now.addingTimeInterval(20))
        check(completed.snapshot?.planType == "pro" && completed.snapshot?.windows.first?.usedPercent == 8,
              "next poll completes an incremental partial line")
        try append(event(at: now.addingTimeInterval(12), primary: NSNull(), plan: NSNull()) + Data([10]), to: newer)
        let cleared = reader.read(now: now.addingTimeInterval(25))
        check(cleared.snapshot?.windows.isEmpty == true && cleared.snapshot?.planType == nil,
              "new empty event clears stale windows and account plan")
        let newFile = directory.appendingPathComponent("discovered.jsonl")
        try writeLine(event(at: now.addingTimeInterval(20), primary: window(51)), to: newFile)
        let beforeDiscovery = reader.read(now: now.addingTimeInterval(26))
        check(beforeDiscovery.inspectedFiles == 2, "frequent polls do not rediscover the session tree")
        let forced = reader.read(now: now.addingTimeInterval(27), forceDiscovery: true)
        check(forced.inspectedFiles == 3 && forced.snapshot?.windows.first?.usedPercent == 51,
              "force refresh immediately discovers new files locally")
        try append(event(at: now.addingTimeInterval(19), primary: window(99)) + Data([10]), to: newFile)
        try append(event(at: now.addingTimeInterval(28), primary: window(88), id: "premium") + Data([10]), to: newFile)
        let reordered = reader.read(now: now.addingTimeInterval(29))
        check(reordered.snapshot?.windows.first?.usedPercent == 51,
              "later append with older timestamp or foreign bucket cannot replace latest Codex event")
        let expiredRead = reader.read(now: now.addingTimeInterval(3601))
        check(expiredRead.snapshot?.windows.first?.usedPercent == nil, "cached quota expires even when files stop changing")

        let boundedDirectory = directory.appendingPathComponent("bounded")
        try FileManager.default.createDirectory(at: boundedDirectory, withIntermediateDirectories: true)
        let large = boundedDirectory.appendingPathComponent("large.jsonl")
        var bigData = Data(repeating: 65, count: 8192)
        bigData.append(10)
        bigData.append(try event(at: now, primary: window(61)))
        bigData.append(10)
        try bigData.write(to: large)
        let boundedReader = CodexSessionLogReader(directory: boundedDirectory, tailBytes: 1024)
        let bounded = boundedReader.read(now: now)
        check(bounded.bytesRead <= 1024 && bounded.snapshot?.windows.first?.usedPercent == 61,
              "large-file reads stay bounded while finding latest complete quota")
        let link = boundedDirectory.appendingPathComponent("symlink.jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: newFile)
        let afterLink = boundedReader.read(now: now.addingTimeInterval(2), forceDiscovery: true)
        check(afterLink.inspectedFiles == 1, "session discovery does not follow symlinks")
        let missingReader = CodexSessionLogReader(directory: directory.appendingPathComponent("missing"))
        check(missingReader.read(now: now).snapshot == nil, "missing local session directory is handled")

        // Service lifecycle: stop discards in-flight publications; force is still
        // strictly a local read. These fixtures never touch an account or network.
        let service = CodexUsageService(sessionsDirectory: directory)
        service.refresh(force: true)
        service.stop()
        try await Task.sleep(nanoseconds: 100_000_000)
        check(service.snapshot == nil && !service.isRefreshing, "stop discards an in-flight local result")
        service.refresh(force: true)
        try await Task.sleep(nanoseconds: 200_000_000)
        check(!service.isRefreshing, "local refresh completes without stuck loading")
        service.stop()
        print("\(checks) Codex checks passed.")
    }
}
