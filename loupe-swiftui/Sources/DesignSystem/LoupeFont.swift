import SwiftUI
import CoreText

// MARK: - Typography tokens
//
// Fonts: Familjen Grotesk (display/UI) + Space Mono (data/code).
// Both OFL — download STATIC weights (not the variable TTF) and drop them in
// Sources/Resources/Fonts/. FontRegistrar registers them at launch, so NO
// Info.plist / UIAppFonts surgery is required.
//
// Required files:
//   FamiljenGrotesk-Regular.ttf  / -Medium.ttf / -SemiBold.ttf / -Bold.ttf
//   SpaceMono-Regular.ttf        / SpaceMono-Bold.ttf
//
// ⚠️ PostScript names below must match the actual fonts. Verify in Font Book
//    (right-click → "Show in Finder" → Get Info, or `fc-scan file.ttf`).
//    A wrong name fails SILENTLY to system font.

enum LoupeFont {

    // PostScript family names
    private enum PS {
        static let groteskRegular  = "FamiljenGrotesk-Regular"
        static let groteskMedium   = "FamiljenGrotesk-Medium"
        static let groteskSemiBold = "FamiljenGrotesk-SemiBold"
        static let groteskBold     = "FamiljenGrotesk-Bold"
        static let monoRegular     = "SpaceMono-Regular"
        static let monoBold        = "SpaceMono-Bold"
    }

    private static func grotesk(_ size: CGFloat, _ weight: Font.Weight) -> Font {
        let name: String
        switch weight {
        case .bold, .heavy, .black: name = PS.groteskBold
        case .semibold:             name = PS.groteskSemiBold
        case .medium:               name = PS.groteskMedium
        default:                    name = PS.groteskRegular
        }
        return .custom(name, size: size)
    }

    private static func mono(_ size: CGFloat, bold: Bool) -> Font {
        .custom(bold ? PS.monoBold : PS.monoRegular, size: size)
    }

    // MARK: Semantic styles (match node 210:18465)
    // Display — Familjen Grotesk
    static let largeTitle = grotesk(30, .bold)   // "Inbox"
    static let title      = grotesk(22, .bold)   // ticket title
    static let workstation = grotesk(18, .semibold) // Anands-Mac-mini.local
    static let headline   = grotesk(17, .semibold)
    static let body       = grotesk(15, .regular)
    static let bodyMedium = grotesk(15, .medium)
    static let label      = grotesk(13, .medium) // "Workstation:" / section labels
    static let caption    = grotesk(12, .medium)
    static let button     = grotesk(16, .bold)   // "Dispatch"

    // Data — Space Mono
    static let code       = mono(13.5, bold: false) // GH-101, file names, repo path
    static let codeStrong = mono(13.5, bold: true)
    static let ringValue  = mono(13, bold: true)    // confidence number
    static let metric     = mono(15, bold: true)    // folder/siren counts
}

// MARK: - Launch-time registration (no Info.plist needed)
enum FontRegistrar {
    /// Call once at app launch (e.g. in App.init).
    static func register(bundle: Bundle = .main) {
        let names = [
            "FamiljenGrotesk-Regular", "FamiljenGrotesk-Medium",
            "FamiljenGrotesk-SemiBold", "FamiljenGrotesk-Bold",
            "SpaceMono-Regular", "SpaceMono-Bold",
        ]
        for name in names {
            guard let url = bundle.url(forResource: name, withExtension: "ttf")
                ?? bundle.url(forResource: name, withExtension: "otf") else {
                #if DEBUG
                print("⚠️ Loupe font missing from bundle: \(name)")
                #endif
                continue
            }
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                #if DEBUG
                print("⚠️ Failed to register \(name): \(String(describing: error))")
                #endif
            }
        }
    }
}
