import CoreText
import Foundation

/// Bundled Space Grotesk + Space Mono (OFL, in Resources/Fonts). Registered
/// for the process at launch so `.custom` lookups and the tray icon resolve.
enum Fonts {
    static func register() {
        for name in [
            "SpaceGrotesk-Regular", "SpaceGrotesk-Medium", "SpaceGrotesk-SemiBold",
            "SpaceMono-Regular", "SpaceMono-Bold",
        ] {
            // SPM may flatten processed resources to the bundle root instead
            // of preserving the Fonts/ subdirectory; accept either layout.
            let url = Bundle.module.url(
                forResource: name, withExtension: "ttf", subdirectory: "Fonts")
                ?? Bundle.module.url(forResource: name, withExtension: "ttf")
            guard let url else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}
