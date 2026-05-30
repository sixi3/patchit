import SwiftUI

// MARK: - Spacing & radius tokens
// Derived from node 210:18465 metadata (exact px) + screenshot proportions.

enum LoupeSpace {
    static let xxs: CGFloat = 4
    static let xs:  CGFloat = 6
    static let sm:  CGFloat = 8
    static let md:  CGFloat = 12   // avatar→greeting gap, screen inset
    static let lg:  CGFloat = 16   // card inner padding
    static let xl:  CGFloat = 20
    static let xxl: CGFloat = 28

    /// Horizontal inset for the user-info row / inbox header (Figma: 8–12px).
    static let screenInset: CGFloat = 12
    /// Vertical gap between ticket cards (cards are full-bleed horizontally).
    static let cardGap: CGFloat = 8
}

enum LoupeRadius {
    static let chip:    CGFloat = 6    // repo pill, file chip
    static let control: CGFloat = 10   // dispatch button, metric strip
    static let card:    CGFloat = 10
    static let capsule: CGFloat = 999  // glass pills, count badge, status capsule
}

enum LoupeSize {
    static let avatar:        CGFloat = 40   // glass
    static let statusDot:     CGFloat = 8
    static let caret:         CGFloat = 20
    static let ring:          CGFloat = 46   // confidence ring
    static let agentBadge:    CGFloat = 22   // notification/agent glyph circle
    static let rail:          CGFloat = 5    // priority left rail
    static let kebab:         CGFloat = 48
}

enum LoupeStroke {
    static let hairline: CGFloat = 1
    static let card:     CGFloat = 1
    static let ring:     CGFloat = 4
}
