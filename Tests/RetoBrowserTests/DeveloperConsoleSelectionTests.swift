import XCTest
@testable import RetoBrowser

final class DeveloperConsoleSelectionTests: XCTestCase {
    private let logs = [
        DeveloperConsoleEntry(level: "log", message: "boot", timestamp: 1_000),
        DeveloperConsoleEntry(level: "warn", message: "slow request", timestamp: 2_000),
        DeveloperConsoleEntry(level: "error", message: "boom", timestamp: 3_000),
        DeveloperConsoleEntry(level: "log", message: "boot", timestamp: 3_000)
    ]

    private func id(_ index: Int) -> DeveloperConsoleLogID {
        DeveloperConsoleLogID(index: index, entry: logs[index])
    }

    func testToggleSelectsAndDeselects() {
        var selection = DeveloperConsoleSelection()
        XCTAssertTrue(selection.isEmpty)

        selection.toggle(id(1))
        XCTAssertTrue(selection.isSelected(id(1)))
        XCTAssertEqual(selection.count, 1)

        selection.toggle(id(1))
        XCTAssertFalse(selection.isSelected(id(1)))
        XCTAssertTrue(selection.isEmpty)
    }

    func testDuplicateMessagesSelectIndependently() {
        var selection = DeveloperConsoleSelection()
        selection.toggle(id(0))
        XCTAssertTrue(selection.isSelected(id(0)))
        XCTAssertFalse(selection.isSelected(id(3)))
    }

    func testCopyTextIsNilWithoutSelection() {
        let selection = DeveloperConsoleSelection()
        XCTAssertNil(selection.copyText(from: logs))
    }

    func testCopyTextPreservesCaptureOrderRegardlessOfToggleOrder() {
        var selection = DeveloperConsoleSelection()
        selection.toggle(id(2))
        selection.toggle(id(0))

        let text = selection.copyText(from: logs, timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(text, "[log 00:00:01.000] boot\n[error 00:00:03.000] boom")
    }

    func testLineKeepsMessageVerbatimIncludingNewlines() {
        let entry = DeveloperConsoleEntry(level: "error", message: "line one\n  line two", timestamp: 45_296_789)
        let line = DeveloperConsoleSelection.line(for: entry, timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(line, "[error 12:34:56.789] line one\n  line two")
    }

    func testClearEmptiesSelection() {
        var selection = DeveloperConsoleSelection()
        selection.toggle(id(0))
        selection.toggle(id(2))
        selection.clear()
        XCTAssertTrue(selection.isEmpty)
        XCTAssertNil(selection.copyText(from: logs))
    }

    func testReconcileKeepsRowsThatStillMatch() {
        var selection = DeveloperConsoleSelection()
        selection.toggle(id(1))
        selection.reconcile(with: logs)
        XCTAssertTrue(selection.isSelected(id(1)))
    }

    func testReconcileDropsRowsAfterBufferRotation() {
        var selection = DeveloperConsoleSelection()
        selection.toggle(id(1))

        // The capture buffer dropped its oldest entry, shifting everything
        // down one index; the timestamp at index 1 no longer matches.
        let rotated = Array(logs.dropFirst())
        selection.reconcile(with: rotated)
        XCTAssertTrue(selection.isEmpty)
    }

    func testReconcileDropsEverythingAfterConsoleClear() {
        var selection = DeveloperConsoleSelection()
        selection.toggle(id(0))
        selection.toggle(id(2))
        selection.reconcile(with: [])
        XCTAssertTrue(selection.isEmpty)
    }
}
