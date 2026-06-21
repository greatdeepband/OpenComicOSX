import Foundation

// MARK: - Modifier flags passed to selectionAfterClick

/// Modifier flags that influence how a tap on a grid card mutates the selection.
/// `selectMode` is a first-class flag so the caller does not need to duplicate
/// the "command || selectMode" branching at every call site.
struct ClickModifiers {
    var command: Bool
    var shift: Bool
    var selectMode: Bool
}

// MARK: - Pure selection logic

/// Computes the next `(selection, anchor)` pair after the user taps `clicked`.
///
/// Rules (evaluated top-to-bottom):
/// 1. **Shift + existing anchor** — grow the selection by unioning the range
///    `anchor…clicked` into `current`.  This is *grow-only* (never shrinks)
///    — an accepted limitation for this workstream; marquee/range-replace is
///    deferred.
/// 2. **⌘ or selectMode** — toggle `clicked` in / out of `current`.
/// 3. **Plain click** — replace `current` with `{clicked}`.
///
/// Shift with a nil anchor is treated as case 3 (plain click), matching the
/// Finder / Files behaviour of "start a new selection if there is no anchor".
///
/// - Parameters:
///   - current:   The current selection set.
///   - anchor:    The URL that was last used as a shift-range anchor (nil if none).
///   - clicked:   The URL the user just tapped.
///   - ordered:   The ordered, filtered URL list visible in the grid — used for
///                computing shift ranges.
///   - modifiers: Modifier flags at tap time.
/// - Returns: The new `(selection, anchor)` tuple.
func selectionAfterClick(
    current: Set<URL>,
    anchor: URL?,
    clicked: URL,
    ordered: [URL],
    modifiers: ClickModifiers
) -> (selection: Set<URL>, anchor: URL) {
    // 1. Shift-range (grow-only)
    if modifiers.shift,
       let a = anchor,
       let i = ordered.firstIndex(of: a),
       let j = ordered.firstIndex(of: clicked) {
        let range = Set(ordered[min(i, j)...max(i, j)])
        return (current.union(range), clicked)
    }
    // 2. Toggle (⌘ or select-mode)
    if modifiers.command || modifiers.selectMode {
        var s = current
        if s.contains(clicked) { s.remove(clicked) } else { s.insert(clicked) }
        return (s, clicked)
    }
    // 3. Plain click → replace
    return ([clicked], clicked)
}
