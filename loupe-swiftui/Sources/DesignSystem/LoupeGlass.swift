import SwiftUI

// MARK: - Liquid Glass
//
// Figma-CONFIRMED from node 210:18465 variables. The avatar and the agent-count
// pill ("Glass Effect" frames in metadata) are iOS 26 Liquid Glass surfaces.
//
//   Frost (Regular):  7
//   Refraction:     100
//   Splay (Regular):  6
//   Depth (Regular): 16
//   Light Angle:    -45°
//   Dispersion:       0
//   Opacity:         60
//
// SwiftUI on iOS 26 exposes `.glassEffect(...)`. We keep the numeric spec here for
// fidelity reference and provide one modifier so every glass surface is identical,
// with a graceful pre-iOS-26 fallback (frosted material).

enum LoupeGlassSpec {
    static let frost: Double      = 7
    static let refraction: Double = 100
    static let splay: Double      = 6
    static let depth: Double      = 16
    static let lightAngle: Double = -45
    static let dispersion: Double = 0
    static let opacity: Double    = 60
}

extension View {
    /// Applies Loupe's standard Liquid Glass surface in a given shape.
    /// iOS 26+ uses native `.glassEffect`; older OS falls back to `.ultraThinMaterial`.
    @ViewBuilder
    func loupeGlass<S: Shape>(in shape: S) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(Color.white.opacity(0.35), lineWidth: 0.5))
        }
    }

    func loupeGlassCapsule() -> some View { loupeGlass(in: Capsule()) }
    func loupeGlassCircle() -> some View { loupeGlass(in: Circle()) }
}
