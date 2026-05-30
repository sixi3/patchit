import SwiftUI

// MARK: - Color tokens
//
// Source of truth for every color in Loupe.
// Provenance:
//   • Liquid Glass material params are Figma-confirmed (node 210:18465 variables).
//   • Hex values below are screenshot-derived (node 210:18465 render) at high
//     precision. When the Figma Dev Mode codegen endpoint is responsive, reconcile
//     the RAW palette against the file's color variables — only the raw values
//     change, never the semantic names, so views never need editing.
//
// Architecture:
//   LoupeColor.Raw     – private hex palette (never used in views)
//   Color.<semantic>   – what views reference (Color.canvas, .textPrimary, …)
//   LoupeColor.Family  – raw families composed by LoupePriority

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red:   Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue:  Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

enum LoupeColor {
    // Raw palette — fileprivate so the Color extension below can compose it.
    fileprivate enum Raw {
        // Neutrals
        static let canvas       = Color(hex: 0xEAEAEC)  // app background
        static let surface      = Color(hex: 0xFFFFFF)  // card
        static let ink          = Color(hex: 0x181B22)  // primary text
        static let inkSecondary = Color(hex: 0x565A63)
        static let inkMuted     = Color(hex: 0x8E939C)
        static let hairline     = Color(hex: 0xE6E8EB)  // borders / dividers
        static let chip         = Color(hex: 0xF1F2F4)  // pill / chip background

        // Brand
        static let indigo       = Color(hex: 0x3D4EF5)  // inbox badge, accents
        static let onlineGreen  = Color(hex: 0x35C75A)  // status dot

        // Priority families
        static let red          = Color(hex: 0xEF3E45)
        static let redWash      = Color(hex: 0xFDF1F1)
        static let blue         = Color(hex: 0x2F6BFF)
        static let blueWash     = Color(hex: 0xF1F5FF)
        static let green        = Color(hex: 0x3FA862)
        static let greenWash    = Color(hex: 0xF1F8F2)
        static let amber        = Color(hex: 0xE8912A)
        static let amberWash    = Color(hex: 0xFBF3E8)

        // File-kind tints
        static let tsBlue       = Color(hex: 0x3178C6)
        static let sqlPink      = Color(hex: 0xE5489D)
        static let cssBlue      = Color(hex: 0x2F6BFF)
        static let htmlOrange   = Color(hex: 0xE34F26)
        static let jsYellow     = Color(hex: 0xC9A227)
        static let pyBlue       = Color(hex: 0x4B8BBE)
    }

    /// Raw priority families exposed for LoupePriority to compose.
    enum Family {
        static let red    = Raw.red,   redWash   = Raw.redWash
        static let blue   = Raw.blue,  blueWash  = Raw.blueWash
        static let green  = Raw.green, greenWash = Raw.greenWash
        static let amber  = Raw.amber, amberWash = Raw.amberWash
    }
}

// MARK: - Semantic tokens (use these in views)
extension Color {
    static let canvas        = LoupeColor.Raw.canvas
    static let surface       = LoupeColor.Raw.surface
    static let textPrimary   = LoupeColor.Raw.ink
    static let textSecondary = LoupeColor.Raw.inkSecondary
    static let textMuted     = LoupeColor.Raw.inkMuted
    static let hairline      = LoupeColor.Raw.hairline
    static let chipFill      = LoupeColor.Raw.chip

    static let accent        = LoupeColor.Raw.indigo
    static let onlineDot     = LoupeColor.Raw.onlineGreen
    static let riskAlert     = LoupeColor.Raw.red

    // Confidence ring (threshold-based — see ConfidenceRing)
    static let ringHigh      = LoupeColor.Raw.green   // >= 80
    static let ringMid       = LoupeColor.Raw.amber   // 65–79
    static let ringLow       = LoupeColor.Raw.red     // < 65

    // File-kind icon tints
    static let fileTS        = LoupeColor.Raw.tsBlue
    static let fileSQL       = LoupeColor.Raw.sqlPink
    static let fileCSS       = LoupeColor.Raw.cssBlue
    static let fileHTML      = LoupeColor.Raw.htmlOrange
    static let fileJS        = LoupeColor.Raw.jsYellow
    static let filePY        = LoupeColor.Raw.pyBlue
    static let fileDefault   = LoupeColor.Raw.inkMuted
}
