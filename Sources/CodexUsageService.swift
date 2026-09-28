import Foundation
import Combine
import CoreFoundation

// Native, offline adaptation of QuotaStrip's Codex quota rules.
// QuotaStrip Copyright (c) 2026 hohocf, MIT; see ThirdParty/QuotaStrip-LICENSE.txt.
// Reads only local session quota events. No credentials, network or subprocesses.

struct CodexQuotaWindow: Codable, Sendable, Equatable {
    /// Zero means the source did not report a valid duration; it is labelled "?".
    let windowMinutes: Int
    let usedPercent: Double?
    let resetsAt: Date?

    var label: String {
        guard windowMinutes > 0 else { return "?" }
        if windowMinutes.isMultiple(of: 1440) { return "\(windowMinutes / 1440)d" }
        if windowMinutes.isMultiple(of: 60) { return "\(windowMinutes / 60)h" }
        return "\(windowMinutes)m"
    }
    var remainingPercent: Double? { usedPercent.map { min(100, max(0, 100 - $0)) } }

    func effective(at date: Date) -> Self {
        guard let resetsAt, resetsAt <= date else { return self }
        return Self(windowMinutes: windowMinutes, usedPercent: nil, resetsAt: nil)
    }
}

struct CodexUsageSnapshot: Codable, Sendable, Equatable {
    let windows: [CodexQuotaWindow]
    let planType: String?
    /// Timestamp carried by the actual quota event; never a file modification time.
    let observedAt: Date
    /// Time PulseBar last inspected local files; this is not a server refresh.
    let readAt: Date

    func effective(at date: Date) -> Self {
        Self(windows: windows.map { $0.effective(at: date) }, planType: planType,
             observedAt: observedAt, readAt: readAt)
    }
}

enum CodexQuotaEventDecoder {
    /// Decode only the event envelope and its quota metadata. Do not recursively
    /// search conversation bodies, which may themselves contain example JSON.
    static func decode(_ data: Data, readAt: Date) -> CodexUsageSnapshot? {
        guard data.range(of: Data("\"rate_limits".utf8)) != nil,
              let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let observedAt = timestamp(event["timestamp"]),
              observedAt <= readAt.addingTimeInterval(300) else { return nil }
        if let type = event["type"] as? String, type != "event_msg" { return nil }
        let payload = event["payload"] as? [String: Any] ?? event
        if let type = payload["type"] as? String,
           !["token_count", "rate_limits", "rate_limits_updated", "event_msg"].contains(type) { return nil }

        var limits: [String: Any]?
        if let byID = payload["rate_limits_by_limit_id"] as? [String: Any] {
            limits = byID["codex"] as? [String: Any]
        } else if let raw = payload["rate_limits"] as? [String: Any] {
            limits = raw["codex"] as? [String: Any] ?? raw
        }
        guard let limits else { return nil }
        if let id = limits["limit_id"] as? String, id != "codex" { return nil }
        if let id = limits["rate_limit_id"] as? String, id != "codex" { return nil }
        // Legacy Codex events can omit the ID; named foreign buckets never pass.
        guard limits.keys.contains("primary") || limits.keys.contains("secondary") else { return nil }
        let windows = ["primary", "secondary"].compactMap { key -> CodexQuotaWindow? in
            guard let window = limits[key] as? [String: Any], !window.isEmpty else { return nil }
            let duration = number(window["window_minutes"])
            let minutes = duration.flatMap { value -> Int? in
                guard value > 0, value <= 5_256_000, value.rounded() == value else { return nil }
                return Int(value)
            } ?? 0
            let used = number(window["used_percent"]).flatMap { (0...100).contains($0) ? $0 : nil }
            let reset = number(window["resets_at"]).flatMap { value -> Date? in
                guard value > 0, value < 253_402_300_800 else { return nil }
                return Date(timeIntervalSince1970: value)
            }
            return CodexQuotaWindow(windowMinutes: minutes, usedPercent: used, resetsAt: reset)
        }
        let plan = (limits["plan_type"] as? String).flatMap { raw -> String? in
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : String(text.prefix(64))
        }
        return CodexUsageSnapshot(windows: windows, planType: plan,
                                  observedAt: observedAt, readAt: readAt)
    }

    private static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber,
              CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        let result = value.doubleValue
        return result.isFinite ? result : nil
    }

    private static func timestamp(_ value: Any?) -> Date? {
        guard let value = value as? String, value.count <= 40 else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

/// Confined to a serial utility queue. File cursors retain only an incomplete
/// final JSONL line and the latest quota metadata, never full conversation logs.
final class CodexSessionLogReader: @unchecked Sendable {
    struct Result: Sendable {
        let snapshot: CodexUsageSnapshot?
        let status: String
        let inspectedFiles: Int
        let bytesRead: Int
    }
    private struct Metadata {
        let url: URL
        let size: UInt64
        let modified: Date
    }
    private struct Cursor {
        var size: UInt64
        var modified: Date
        var pending = Data()
        var latest: CodexUsageSnapshot?
    }

    private let directory: URL
    private let maxFiles: Int
    private let tailBytes: Int
    private var trackedURLs: [URL] = []
    private var cursors: [URL: Cursor] = [:]
    private var lastDiscovery = Date.distantPast
    private var newest: CodexUsageSnapshot?
    private let manager = FileManager.default
    // All mutable cursors and discovery state are guarded by this lock, including
    // in tests; the service also schedules reads on one serial utility queue.
    private let lock = NSLock()
    private let resourceKeys: Set<URLResourceKey> = [
        .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey
    ]

    init(directory: URL, maxFiles: Int = 64, tailBytes: Int = 262_144) {
        self.directory = directory
        self.maxFiles = max(1, min(maxFiles, 128))
        self.tailBytes = max(128, min(tailBytes, 1_048_576))
    }

    func read(now: Date = Date(), forceDiscovery: Bool = false) -> Result {
        lock.lock()
        defer { lock.unlock() }
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            newest = nil
            cursors.removeAll()
            trackedURLs.removeAll()
            return Result(snapshot: nil, status: "未找到 Codex 本地会话记录", inspectedFiles: 0, bytesRead: 0)
        }
        if forceDiscovery || trackedURLs.isEmpty || now.timeIntervalSince(lastDiscovery) >= 30 {
            trackedURLs = discover().map(\.url)
            let retained = Set(trackedURLs)
            cursors = cursors.filter { retained.contains($0.key) }
            lastDiscovery = now
        }
        var bytesRead = 0
        var inspected = 0
        var readFailure = false
        for url in trackedURLs {
            guard let metadata = metadata(for: url) else { continue }
            inspected += 1
            if let cached = cursors[url], cached.size == metadata.size,
               cached.modified == metadata.modified { continue }
            do {
                let output = try read(metadata, now: now)
                bytesRead += output.1
                cursors[url] = output.0
                if let candidate = output.0.latest,
                   newest == nil || candidate.observedAt >= newest!.observedAt {
                    newest = candidate
                }
            } catch {
                // Intentionally never log filenames, raw records or error payloads.
                readFailure = true
            }
        }
        if let latest = newest {
            let snapshot = CodexUsageSnapshot(windows: latest.windows.map { $0.effective(at: now) },
                planType: latest.planType, observedAt: latest.observedAt, readAt: now)
            let state: String
            if readFailure { state = "本地记录暂时无法完整读取 · 显示最近记录" }
            else if snapshot.windows.isEmpty { state = "最新本地记录未报告额度窗口" }
            else if snapshot.windows.allSatisfy({ $0.usedPercent == nil }) { state = "额度已重置或数值缺失 · 等待 Codex 新记录" }
            else { state = "来自 Codex 本地记录 · 不主动查询服务器" }
            return Result(snapshot: snapshot, status: state, inspectedFiles: inspected, bytesRead: bytesRead)
        }
        return Result(snapshot: nil,
                      status: readFailure ? "无法读取 Codex 本地会话记录" : "暂无 Codex 额度记录 · 使用 Codex 后自动更新",
                      inspectedFiles: inspected, bytesRead: bytesRead)
    }

    private func read(_ metadata: Metadata, now: Date) throws -> (Cursor, Int) {
        let cached = cursors[metadata.url]
        let append = cached.map { metadata.size > $0.size && metadata.size - $0.size <= UInt64(tailBytes) } ?? false
        let start = append ? cached!.size : (metadata.size > UInt64(tailBytes) ? metadata.size - UInt64(tailBytes) : 0)
        let handle = try FileHandle(forReadingFrom: metadata.url)
        defer { try? handle.close() }
        try handle.seek(toOffset: start)
        let length = Int(min(UInt64(tailBytes), metadata.size - start))
        let chunk = try handle.read(upToCount: length) ?? Data()
        // If the file changed while it was read, retry at the next normal tick.
        guard chunk.count == length else { throw CocoaError(.fileReadUnknown) }
        var data = append ? (cached?.pending ?? Data()) : Data()
        data.append(chunk)
        if !append && start > 0 {
            guard let newline = data.firstIndex(of: 10) else {
                return (Cursor(size: metadata.size, modified: metadata.modified,
                               latest: cached?.latest), chunk.count)
            }
            data = Data(data[data.index(after: newline)...])
        }
        var latest = cached?.latest
        var lineStart = data.startIndex
        while let newline = data[lineStart...].firstIndex(of: 10) {
            let line = Data(data[lineStart..<newline])
            if let event = CodexQuotaEventDecoder.decode(line, readAt: now),
               latest == nil || event.observedAt >= latest!.observedAt {
                latest = event
            }
            lineStart = data.index(after: newline)
        }
        var pending = Data(data[lineStart...])
        // Bound memory even when a session writes an unusually large JSON line.
        if pending.count > tailBytes { pending.removeAll() }
        // A file replacement/truncation is not an append; only events actually
        // observed in it can update the global newest timestamp.
        return (Cursor(size: metadata.size, modified: metadata.modified,
                       pending: pending, latest: latest), chunk.count)
    }

    private func metadata(for url: URL) -> Metadata? {
        // Directory enumeration prefetches URL resource values. Discard that
        // cache so each five-second poll sees a newly appended log immediately.
        var freshURL = url
        freshURL.removeAllCachedResourceValues()
        guard let values = try? freshURL.resourceValues(forKeys: resourceKeys),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size >= 0 else { return nil }
        return Metadata(url: url, size: UInt64(size), modified: values.contentModificationDate ?? .distantPast)
    }

    private func children(of url: URL, directoriesOnly: Bool) -> [URL] {
        let contents = (try? manager.contentsOfDirectory(at: url,
            includingPropertiesForKeys: Array(resourceKeys), options: [.skipsHiddenFiles])) ?? []
        return contents.filter { child in
            guard let values = try? child.resourceValues(forKeys: resourceKeys),
                  values.isSymbolicLink != true else { return false }
            return directoriesOnly ? values.isDirectory == true :
                (values.isRegularFile == true && child.pathExtension == "jsonl")
        }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    private func discover() -> [Metadata] {
        // Codex stores sessions as YYYY/MM/DD/*.jsonl. Walk only newest date
        // folders, not an unbounded recursive historical tree on every tick.
        var days: [URL] = []
        outer: for year in children(of: directory, directoriesOnly: true).prefix(3) {
            for month in children(of: year, directoriesOnly: true).prefix(12) {
                for day in children(of: month, directoriesOnly: true) {
                    days.append(day)
                    if days.count >= 32 { break outer }
                }
            }
        }
        var files: [Metadata] = []
        // Direct JSONL entries also make isolated fixture tests straightforward.
        for parent in [directory] + days {
            for file in children(of: parent, directoriesOnly: false).prefix(4096 - files.count) {
                if let item = metadata(for: file) { files.append(item) }
            }
            if files.count >= 4096 { break }
        }
        return Array(files.sorted {
            $0.modified == $1.modified ? $0.url.path > $1.url.path : $0.modified > $1.modified
        }.prefix(maxFiles))
    }
}

@MainActor
final class CodexUsageService: ObservableObject {
    @Published private(set) var snapshot: CodexUsageSnapshot?
    @Published private(set) var status = "等待 Codex 本地额度记录"
    @Published private(set) var isRefreshing = false

    private let reader: CodexSessionLogReader
    private let queue = DispatchQueue(label: "app.pulsebar.codex-local-quota", qos: .utility)
    private var timer: Timer?
    private var generation = UUID()

    init(sessionsDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/sessions", isDirectory: true)) {
        reader = CodexSessionLogReader(directory: sessionsDirectory)
    }

    deinit { timer?.invalidate() }

    func start() {
        guard timer == nil else { return }
        refresh(force: true)
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        generation = UUID()
        isRefreshing = false
    }

    func refresh(force: Bool = false) {
        guard !isRefreshing else { return }
        isRefreshing = true
        let token = generation
        let reader = self.reader
        queue.async { [weak self] in
            let result = reader.read(forceDiscovery: force)
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.snapshot = result.snapshot
                self.status = result.status
                self.isRefreshing = false
            }
        }
    }
}
