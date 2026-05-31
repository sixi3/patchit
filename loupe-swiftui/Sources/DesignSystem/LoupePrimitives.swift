import SwiftUI

// MARK: - HatchPattern
// Diagonal 45° stripes for the priority-tinted card header. Stroke at low opacity.
struct HatchPattern: Shape {
    var spacing: CGFloat = 9
    func path(in rect: CGRect) -> Path {
        var p = Path()
        var x = -rect.height
        while x < rect.width {
            p.move(to: CGPoint(x: x, y: rect.height))
            p.addLine(to: CGPoint(x: x + rect.height, y: 0))
            x += spacing
        }
        return p
    }
}

/// Header background: diagonal hatch stripes only (no priority wash).
struct PriorityHeaderBackground: View {
    let priority: LoupePriority
    var body: some View {
        ZStack {
            Color.surface
            HatchPattern()
                .stroke(priority.hatch.opacity(0.14), lineWidth: 1.2)
        }
        .clipped()
    }
}

// MARK: - ConfidenceRing
// Circular gauge for blueprint confidence (0–100). Color is threshold-based.
// NOTE: confidence is an uncalibrated self-report; label honestly in UI.
struct ConfidenceRing: View {
    let value: Int
    var diameter: CGFloat = LoupeSize.ring

    private var color: Color {
        if value >= 80 { return .ringHigh }
        if value >= 65 { return .ringMid }
        return .ringLow
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.hairline, lineWidth: LoupeStroke.ringTrack)
            Circle()
                .trim(from: 0, to: CGFloat(max(0, min(100, value))) / 100)
                .stroke(
                    color,
                    style: StrokeStyle(lineWidth: LoupeStroke.ringProgress, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
            Text("\(value)")
                .font(LoupeFont.ringValue)
                .monospacedDigit()
                .foregroundStyle(Color.textPrimary)
                .offset(y: 1)
        }
        .frame(width: diameter, height: diameter)
        .accessibilityLabel("Confidence \(value) percent")
    }
}

// MARK: - FileKind
// Maps a file path → icon + tint for file chips. Phosphor names noted in comments.
enum FileKind {
    case ts, js, swift, sql, html, css, json, py, other

    static func from(_ path: String) -> FileKind {
        let lower = path.lowercased()
        if lower.hasSuffix(".ts") || lower.hasSuffix(".tsx") { return .ts }
        if lower.hasSuffix(".js") || lower.hasSuffix(".jsx") { return .js }
        if lower.hasSuffix(".swift") { return .swift }
        if lower.hasSuffix(".sql") { return .sql }
        if lower.hasSuffix(".html") { return .html }
        if lower.hasSuffix(".css") || lower.hasSuffix(".scss") { return .css }
        if lower.hasSuffix(".json") { return .json }
        if lower.hasSuffix(".py") { return .py }
        return .other
    }

    var tint: Color {
        switch self {
        case .ts:    return .fileTS
        case .js, .json: return .fileJS
        case .sql:   return .fileSQL
        case .html:  return .fileHTML
        case .css:   return .fileCSS
        case .py:    return .filePY
        case .swift: return .fileHTML
        case .other: return .fileDefault
        }
    }

    /// SF Symbol fallback; swap for Phosphor glyphs when the package is added.
    var sfSymbol: String {
        switch self {
        case .ts, .js: return "chevron.left.forwardslash.chevron.right" // Ph.fileTs / fileJs
        case .sql, .json: return "cylinder.split.1x2"                   // Ph.database
        case .html:  return "chevron.left.forwardslash.chevron.right"   // Ph.code
        case .css:   return "number"                                    // Ph.hash
        case .py:    return "chevron.left.forwardslash.chevron.right"
        case .swift: return "swift"
        case .other: return "doc"                                       // Ph.file
        }
    }

    var label: String {
        switch self {
        case .ts: return "TS"; case .js: return "JS"; case .swift: return "SW"
        case .sql: return "SQL"; case .html: return "</>"; case .css: return "#"
        case .json: return "{}"; case .py: return "PY"; case .other: return "•"
        }
    }
}

// MARK: - Text style convenience
extension Text {
    func loupeStyle(_ font: Font, _ color: Color = .textPrimary) -> some View {
        self.font(font).foregroundStyle(color)
    }
}
