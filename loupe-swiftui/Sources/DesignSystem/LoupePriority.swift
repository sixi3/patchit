import SwiftUI

// MARK: - Priority theme
//
// The signature Loupe visual: priority drives the left rail color, the header
// hatch tint, and the whole-card wash. One source maps priority → palette so
// every card stays consistent.
//
// Maps to issue priority (GitHub label / Jira priority). Keep the cases aligned
// with how the daemon normalizes priority into the inbox payload.

enum LoupePriority: String, CaseIterable {
    case p0          // urgent / blocker → red
    case p1          // high            → amber
    case normal      // default         → blue
    case low         // low             → green

    /// Solid color for the left rail + glyph accents.
    var rail: Color {
        switch self {
        case .p0:     return LoupeColor.Family.red
        case .p1:     return LoupeColor.Family.amber
        case .normal: return LoupeColor.Family.blue
        case .low:    return LoupeColor.Family.green
        }
    }

    /// Faint full-card wash behind the header (already low-opacity).
    var wash: Color {
        switch self {
        case .p0:     return LoupeColor.Family.redWash
        case .p1:     return LoupeColor.Family.amberWash
        case .normal: return LoupeColor.Family.blueWash
        case .low:    return LoupeColor.Family.greenWash
        }
    }

    /// Stroke color for the diagonal hatch (apply at ~0.12–0.18 opacity).
    var hatch: Color { rail }

    /// SF Symbol / Phosphor name for the priority caret glyph (top-left).
    var caretSymbol: String {
        switch self {
        case .p0:     return "chevron.up.2"      // → Ph.caretDoubleUp
        case .p1:     return "chevron.up"        // → Ph.caretUp
        case .normal: return "chevron.down"      // → Ph.caretDown
        case .low:    return "equal"             // → Ph.equals
        }
    }
}
