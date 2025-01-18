import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Helper extension that points to your main app’s bundle.
/// Update `com.jamesto.Octopus_Agile_Helper` to match your actual main app’s CFBundleIdentifier.
extension Bundle {
    static var mainAppBundle: Bundle {
        // Attempt to load the main app bundle by its identifier;
        // if not found, default to `.main`.
        return Bundle(identifier: "com.jamesto.octopus-agile-helper") ?? .main
    }
}

/// A centralized place to define color palettes and text styles to unify the UI.
@available(iOS 17.0, *)
public struct Theme {
    
    // MARK: - Background Colors
    /// A main background color that adapts to light/dark (for entire screens).
    public static var mainBackground: Color {
        Color("MainBackground", bundle: .mainAppBundle)
    }
    
    /// A secondary background color (for cards, sections, etc.).
    public static var secondaryBackground: Color {
        Color("SecondaryBackground", bundle: .mainAppBundle)
    }
    
    // MARK: - Text Colors
    /// Primary text color for prominent text (e.g., large rate numbers).
    public static var mainTextColor: Color {
        Color("MainTextColor", bundle: .mainAppBundle)
    }
    
    /// Secondary text color for subtitles, smaller elements, icons, etc.
    public static var secondaryTextColor: Color {
        Color("SecondaryTextColor", bundle: .mainAppBundle)
    }
    
    // MARK: - Additional Colors (not yet used)
    /// A main accent color (e.g., for interactive or highlight elements).
    public static var mainColor: Color {
        Color("MainUseColor", bundle: .mainAppBundle)
    }
    
    /// A secondary accent color (e.g., for complementary highlights).
    public static var secondaryColor: Color {
        Color("SecondaryUseColor", bundle: .mainAppBundle)
    }
    
    // MARK: - Icon Color
    /// New: unify the icon color referencing IconColor asset
    public static var icon: Color {
        Color("IconColor", bundle: .mainAppBundle)
    }
    
    // MARK: - System Accent
    /// SwiftUI's global accent color, typically used in buttons, etc.
    public static var accent: Color {
        Color.accentColor
    }
    
    // MARK: - Font Styles
    public static func titleFont() -> Font {
        .title3.weight(.semibold)
    }
    
    public static func mainFont() -> Font {
        .largeTitle.weight(.semibold)
    }

    public static func mainFont2() -> Font {
        .title2.weight(.semibold)
    }

    public static func secondaryFont() -> Font {
        .body
    }
    
    public static func subFont() -> Font {
        .subheadline
    }
} 