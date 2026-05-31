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

    /// Scroll-under-header fade height. Tuned between system `.soft` (~28pt) and `.hard` (~0).
    static let scrollEdgeFadeHeight: CGFloat = 16
}

extension View {
    /// Applies Loupe's standard Liquid Glass surface in a given shape.
    /// iOS 26+ uses native `.glassEffect`; older OS falls back to `.ultraThinMaterial`.
    /// Pass `interactive: true` on tappable controls so the system glass shimmer responds to touch.
    @ViewBuilder
    func loupeGlass<S: Shape>(in shape: S, interactive: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            if interactive {
                self.glassEffect(.regular.interactive(), in: shape)
            } else {
                self.glassEffect(.regular, in: shape)
            }
        } else {
            self
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(Color.white.opacity(0.35), lineWidth: 0.5))
        }
    }

    func loupeGlassCapsule(interactive: Bool = false) -> some View { loupeGlass(in: Capsule(), interactive: interactive) }
    func loupeGlassCircle(interactive: Bool = false) -> some View { loupeGlass(in: Circle(), interactive: interactive) }

    /// Pins a top bar over scrolling content with a tuned blur/fade as items pass underneath.
    /// Uses a custom material fade (between system `.soft` and `.hard`) on all OS versions.
    @ViewBuilder
    func loupeStickyTopBar<Bar: View>(@ViewBuilder bar: () -> Bar) -> some View {
        if #available(iOS 26.0, *) {
            self
                .safeAreaBar(edge: .top) {
                    bar()
                        .background { LoupeScrollEdgeFade(edge: .top) }
                }
                .scrollEdgeEffectHidden(true, for: .top)
        } else {
            self.safeAreaInset(edge: .top, spacing: 0) {
                bar()
                    .background { LoupeScrollEdgeFade(edge: .top) }
            }
        }
    }
}

// MARK: - Scroll edge fade
private struct LoupeScrollEdgeFade: View {
    enum Edge { case top, bottom }

    let edge: Edge

    private var fadeHeight: CGFloat { LoupeGlassSpec.scrollEdgeFadeHeight }

    var body: some View {
        Rectangle()
            .fill(.thinMaterial)
            .mask(fadeMask)
            .ignoresSafeArea(edges: edge == .top ? .top : .bottom)
    }

    private var fadeMask: some View {
        Group {
            switch edge {
            case .top:
                VStack(spacing: 0) {
                    Color.black
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black.opacity(0.55), location: 0.65),
                            .init(color: .clear, location: 1),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: fadeHeight)
                }
            case .bottom:
                VStack(spacing: 0) {
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .black.opacity(0.55), location: 0.35),
                            .init(color: .black, location: 1),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: fadeHeight)
                    Color.black
                }
            }
        }
    }
}
