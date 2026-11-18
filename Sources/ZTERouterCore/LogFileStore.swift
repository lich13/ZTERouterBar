import Foundation

/// Appends log entries to plain-text files. With `retentionDays` set, entries go to one file per day
/// (`<name>-yyyy-MM-dd.log`) and files older than that many days are deleted; without it, everything
/// goes to a single `<name>.log` that is never pruned.
public final class LogFileStore: @unchecked Sendable {
    private let directory: URL
    private let name: String
    private let retentionDays: Int?
    private let queue = DispatchQueue(label: "zte.router.logfile")
    private let formatter: DateFormatter
    private var lastPrunedDay = ""

    public init(directory: URL, name: String, retentionDays: Int? = nil) {
        self.directory = directory
        self.name = name
        self.retentionDays = retentionDays
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        self.formatter = formatter
    }

    public func append(_ entry: WatchdogLogEntry) {
        queue.async { [self] in
            let stamp = formatter.string(from: entry.timestamp)
            let message = entry.message.replacingOccurrences(of: "\n", with: " ")
            let line = Data("\(stamp)\t\(entry.level.rawValue)\t\(message)\n".utf8)
            let day = String(stamp.prefix(10))
            let url = fileURL(day: day)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: line)
            } else {
                try? line.write(to: url)
            }
            if day != lastPrunedDay {
                lastPrunedDay = day
                prune(now: entry.timestamp)
            }
        }
    }

    /// The newest `limit` entries, oldest first.
    public func recentEntries(limit: Int) -> [WatchdogLogEntry] {
        queue.sync {
            var entries: [WatchdogLogEntry] = []
            for url in logFiles().reversed() where entries.count < limit {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let parsed = text.split(separator: "\n").suffix(limit - entries.count).compactMap(parse)
                entries.insert(contentsOf: parsed, at: 0)
            }
            return entries
        }
    }

    private func fileURL(day: String) -> URL {
        directory.appendingPathComponent(retentionDays == nil ? "\(name).log" : "\(name)-\(day).log")
    }

    /// This store's files, oldest first (daily names sort chronologically).
    private func logFiles() -> [URL] {
        let all = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return all
            .filter {
                let file = $0.lastPathComponent
                return retentionDays == nil ? file == "\(name).log" : file.hasPrefix("\(name)-") && file.hasSuffix(".log")
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func prune(now: Date) {
        guard let retentionDays else { return }
        let cutoff = fileURL(day: String(formatter.string(from: now.addingTimeInterval(-Double(retentionDays) * 86_400)).prefix(10)))
        for url in logFiles() where url.lastPathComponent < cutoff.lastPathComponent {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func parse(_ line: Substring) -> WatchdogLogEntry? {
        let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3,
              let timestamp = formatter.date(from: String(parts[0])),
              let level = WatchdogLogLevel(rawValue: String(parts[1])) else {
            return nil
        }
        return WatchdogLogEntry(timestamp: timestamp, level: level, message: String(parts[2]))
    }
}
