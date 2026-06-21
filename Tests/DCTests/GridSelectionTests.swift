import XCTest
@testable import DC

// MARK: - GridSelectionTests

/// Tests for the pure `selectionAfterClick` function defined in GridSelection.swift.
///
/// Ordered URL list used throughout: [a, b, c, d, e]
final class GridSelectionTests: XCTestCase {

    // Five stable test URLs.
    let a = URL(string: "file:///comics/a.cbz")!
    let b = URL(string: "file:///comics/b.cbz")!
    let c = URL(string: "file:///comics/c.cbz")!
    let d = URL(string: "file:///comics/d.cbz")!
    let e = URL(string: "file:///comics/e.cbz")!

    var ordered: [URL]!

    override func setUp() {
        super.setUp()
        ordered = [a, b, c, d, e]
    }

    // MARK: - Plain click (no modifiers)

    func testPlainClickReplaces() {
        // Plain click on c from empty selection → {c}, anchor = c
        let (sel, anchor) = selectionAfterClick(
            current: [],
            anchor: nil,
            clicked: c,
            ordered: ordered,
            modifiers: ClickModifiers(command: false, shift: false, selectMode: false)
        )
        XCTAssertEqual(sel, [c])
        XCTAssertEqual(anchor, c)
    }

    func testPlainClickReplacesExistingSelection() {
        // Plain click on c while {a, b} is selected → {c}, anchor = c
        let (sel, anchor) = selectionAfterClick(
            current: [a, b],
            anchor: a,
            clicked: c,
            ordered: ordered,
            modifiers: ClickModifiers(command: false, shift: false, selectMode: false)
        )
        XCTAssertEqual(sel, [c])
        XCTAssertEqual(anchor, c)
    }

    // MARK: - ⌘ click (command toggle)

    func testCommandClickAdds() {
        // {c} + ⌘-click b → {b, c}
        let (sel, anchor) = selectionAfterClick(
            current: [c],
            anchor: c,
            clicked: b,
            ordered: ordered,
            modifiers: ClickModifiers(command: true, shift: false, selectMode: false)
        )
        XCTAssertEqual(sel, [b, c])
        XCTAssertEqual(anchor, b)
    }

    func testCommandClickRemoves() {
        // {b, c} + ⌘-click c → {b}
        let (sel, anchor) = selectionAfterClick(
            current: [b, c],
            anchor: b,
            clicked: c,
            ordered: ordered,
            modifiers: ClickModifiers(command: true, shift: false, selectMode: false)
        )
        XCTAssertEqual(sel, [b])
        XCTAssertEqual(anchor, c)
    }

    // MARK: - Shift-click range

    func testShiftRangeForwardFromAnchor() {
        // Anchor = a, shift-click d → {a, b, c, d}
        let (sel, anchor) = selectionAfterClick(
            current: [a],
            anchor: a,
            clicked: d,
            ordered: ordered,
            modifiers: ClickModifiers(command: false, shift: true, selectMode: false)
        )
        XCTAssertEqual(sel, [a, b, c, d])
        XCTAssertEqual(anchor, d)
    }

    func testShiftRangeReverseFromAnchor() {
        // Anchor = d, shift-click a → same set {a, b, c, d}
        let (sel, anchor) = selectionAfterClick(
            current: [d],
            anchor: d,
            clicked: a,
            ordered: ordered,
            modifiers: ClickModifiers(command: false, shift: true, selectMode: false)
        )
        XCTAssertEqual(sel, [a, b, c, d])
        XCTAssertEqual(anchor, a)
    }

    func testShiftClickWithNilAnchorActsAsPlainClick() {
        // Shift with nil anchor → plain click behaviour (anchor has no home)
        let (sel, anchor) = selectionAfterClick(
            current: [a, b],
            anchor: nil,
            clicked: c,
            ordered: ordered,
            modifiers: ClickModifiers(command: false, shift: true, selectMode: false)
        )
        XCTAssertEqual(sel, [c])
        XCTAssertEqual(anchor, c)
    }

    func testShiftClickGrowOnly_doesNotShrink() {
        // Grow-only: current = {a,b,c,d,e}, anchor = a, shift-click c
        // Range {a..c} unioned into {a..e} → still {a..e} (not shrunk to {a,b,c})
        let allFive: Set<URL> = [a, b, c, d, e]
        let (sel, _) = selectionAfterClick(
            current: allFive,
            anchor: a,
            clicked: c,
            ordered: ordered,
            modifiers: ClickModifiers(command: false, shift: true, selectMode: false)
        )
        // Must still contain d and e — grow-only, never shrinks
        XCTAssertTrue(sel.isSuperset(of: allFive),
            "Shift-click into an existing selection must not shrink it (grow-only semantics)")
    }

    // MARK: - selectMode (plain click toggles rather than replaces)

    func testSelectModePlainClickAdds() {
        // {a, b} plain-click c with selectMode → {a, b, c}
        let (sel, anchor) = selectionAfterClick(
            current: [a, b],
            anchor: b,
            clicked: c,
            ordered: ordered,
            modifiers: ClickModifiers(command: false, shift: false, selectMode: true)
        )
        XCTAssertEqual(sel, [a, b, c])
        XCTAssertEqual(anchor, c)
    }

    func testSelectModePlainClickRemoves() {
        // {a, b, c} plain-click b with selectMode → {a, c}
        let (sel, anchor) = selectionAfterClick(
            current: [a, b, c],
            anchor: c,
            clicked: b,
            ordered: ordered,
            modifiers: ClickModifiers(command: false, shift: false, selectMode: true)
        )
        XCTAssertEqual(sel, [a, c])
        XCTAssertEqual(anchor, b)
    }

    func testSelectModeAndCommandBothToggle() {
        // selectMode + command → still toggle (command bit redundant but must not break)
        let (sel, _) = selectionAfterClick(
            current: [a],
            anchor: a,
            clicked: a,
            ordered: ordered,
            modifiers: ClickModifiers(command: true, shift: false, selectMode: true)
        )
        XCTAssertEqual(sel, [])
    }
}
