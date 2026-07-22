import XCTest
@testable import RetoBrowser

final class TabOverviewLayoutTests: XCTestCase {
    func testIndexAtItemCentersMatchesItem() {
        let layout = TabOverviewLayout(containerWidth: 800, tabCount: 5)
        for index in 0..<5 {
            XCTAssertEqual(layout.index(at: layout.midX(at: index)), index)
        }
    }

    func testIndexClampsBeyondEdges() {
        let layout = TabOverviewLayout(containerWidth: 800, tabCount: 5)
        XCTAssertEqual(layout.index(at: -60), 0)
        XCTAssertEqual(layout.index(at: 900), 4)
    }

    func testIndexIsNilWithoutTabs() {
        let layout = TabOverviewLayout(containerWidth: 800, tabCount: 0)
        XCTAssertNil(layout.index(at: 100))
    }

    func testItemWidthShrinksWithManyTabsButStaysTappable() {
        let few = TabOverviewLayout(containerWidth: 800, tabCount: 3)
        let many = TabOverviewLayout(containerWidth: 800, tabCount: 40)
        XCTAssertGreaterThan(few.itemWidth, many.itemWidth)
        XCTAssertGreaterThanOrEqual(many.itemWidth, TabOverviewLayout.minItemWidth)
        XCTAssertLessThanOrEqual(few.itemWidth, TabOverviewLayout.maxItemWidth)
    }

    func testScalePeaksUnderFingerAndFallsOff() {
        let layout = TabOverviewLayout(containerWidth: 800, tabCount: 5)
        let finger = layout.midX(at: 2)

        let underFinger = layout.scale(forItemAt: 2, fingerX: finger)
        let neighbor = layout.scale(forItemAt: 1, fingerX: finger)
        let far = layout.scale(forItemAt: 0, fingerX: finger)

        XCTAssertEqual(underFinger, 1 + TabOverviewLayout.magnification, accuracy: 0.001)
        XCTAssertLessThan(neighbor, underFinger)
        XCTAssertEqual(far, 1, accuracy: 0.001)
        XCTAssertEqual(layout.scale(forItemAt: 2, fingerX: nil), 1)
    }

    func testDragGeometryResolvesOverviewAndQuadrantTargets() {
        let tabIDs = [UUID(), UUID(), UUID()]
        let geometry = TabDragGeometry(containerSize: CGSize(width: 900, height: 700), tabCount: tabIDs.count)
        let canvas = geometry.dropCanvas

        let overviewPoint = CGPoint(x: geometry.layout.midX(at: 1), y: 40)
        XCTAssertEqual(geometry.target(at: overviewPoint, tabIDs: tabIDs), .tab(tabIDs[1]))

        // Center of the drop canvas is the neutral cancel zone.
        XCTAssertNil(geometry.target(at: CGPoint(x: canvas.midX, y: canvas.midY), tabIDs: tabIDs))

        XCTAssertEqual(
            geometry.target(at: CGPoint(x: canvas.minX + 30, y: canvas.midY), tabIDs: tabIDs),
            .split(.leading)
        )
        XCTAssertEqual(
            geometry.target(at: CGPoint(x: canvas.maxX - 30, y: canvas.midY), tabIDs: tabIDs),
            .split(.trailing)
        )
        XCTAssertEqual(
            geometry.target(at: CGPoint(x: canvas.midX, y: canvas.minY + 30), tabIDs: tabIDs),
            .split(.top)
        )
        XCTAssertEqual(
            geometry.target(at: CGPoint(x: canvas.midX, y: canvas.maxY - 30), tabIDs: tabIDs),
            .split(.bottom)
        )
    }

    func testSplitPlacementMapsToAxisAndPane() {
        XCTAssertEqual(SplitPlacement.leading.axis, .horizontal)
        XCTAssertEqual(SplitPlacement.leading.pane, .primary)
        XCTAssertEqual(SplitPlacement.trailing.pane, .secondary)
        XCTAssertEqual(SplitPlacement.top.axis, .vertical)
        XCTAssertEqual(SplitPlacement.top.pane, .primary)
        XCTAssertEqual(SplitPlacement.bottom.axis, .vertical)
        XCTAssertEqual(SplitPlacement.bottom.pane, .secondary)
    }

    func testDragGeometryOverviewWinsInShortContainers() {
        // In a very short canvas the strip's grace area and the drop surface
        // could overlap; the overview must win so releasing near the strip
        // never splits by accident.
        let geometry = TabDragGeometry(containerSize: CGSize(width: 600, height: 160), tabCount: 2)
        let contested = CGPoint(x: 300, y: TabOverviewLayout.stripHeight + 20)
        if case .split = geometry.target(at: contested, tabIDs: [UUID(), UUID()]) {
            XCTFail("Overview grace area should take precedence over the drop surface")
        }
    }
}
