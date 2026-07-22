import Foundation

/// One captured browser console message decoded from the developer snapshot.
struct DeveloperConsoleEntry: Decodable, Equatable {
    let level: String
    let message: String
    let timestamp: Double

    var timeLabel: String {
        Date(timeIntervalSince1970: timestamp / 1_000).formatted(date: .omitted, time: .standard)
    }
}

/// Identity of one console row. The capture buffer drops its oldest entries
/// past 500, so an index alone can point at a different row after a refresh;
/// the timestamp alone collides for messages logged in the same millisecond.
/// Together they identify a row for as long as it stays in the buffer.
struct DeveloperConsoleLogID: Hashable {
    let index: Int
    let timestamp: Double

    init(index: Int, entry: DeveloperConsoleEntry) {
        self.index = index
        self.timestamp = entry.timestamp
    }
}

/// Tap-to-select state for the Developer Tools console list, plus the
/// clipboard formatting for the selected rows.
struct DeveloperConsoleSelection: Equatable {
    private(set) var selectedIDs: Set<DeveloperConsoleLogID> = []

    var count: Int { selectedIDs.count }
    var isEmpty: Bool { selectedIDs.isEmpty }

    func isSelected(_ id: DeveloperConsoleLogID) -> Bool {
        selectedIDs.contains(id)
    }

    mutating func toggle(_ id: DeveloperConsoleLogID) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    mutating func clear() {
        selectedIDs = []
    }

    /// Drops selections that no longer identify the same row, e.g. after the
    /// console was cleared or the capture buffer rotated under a refresh.
    mutating func reconcile(with logs: [DeveloperConsoleEntry]) {
        selectedIDs = selectedIDs.filter { id in
            logs.indices.contains(id.index) && logs[id.index].timestamp == id.timestamp
        }
    }

    /// Clipboard text for the selected rows, or nil when nothing is selected.
    /// Rows keep their capture order regardless of the order they were tapped
    /// in, one `line(for:)` per row joined with newlines.
    func copyText(from logs: [DeveloperConsoleEntry], timeZone: TimeZone = .current) -> String? {
        let lines = logs.enumerated()
            .filter { selectedIDs.contains(DeveloperConsoleLogID(index: $0.offset, entry: $0.element)) }
            .map { Self.line(for: $0.element, timeZone: timeZone) }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// Clipboard format for one log: `[level HH:mm:ss.SSS] message`. The
    /// message is the captured text verbatim, so multi-line messages keep
    /// their own newlines after the prefix.
    static func line(for entry: DeveloperConsoleEntry, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm:ss.SSS"
        let time = formatter.string(from: Date(timeIntervalSince1970: entry.timestamp / 1_000))
        return "[\(entry.level) \(time)] \(entry.message)"
    }
}
