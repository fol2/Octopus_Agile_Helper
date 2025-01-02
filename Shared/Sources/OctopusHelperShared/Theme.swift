import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// A centralized place to define color palettes and text styles to unify the UI.
@available(iOS 17.0, *)
public struct Theme {
    
    // MARK: - Background Colors
    /// A main background color that adapts to light/dark (for entire screens).
    public static var mainBackground: Color {
        Color("MainBackground", bundle: nil)
    }
    
    /// A secondary background color (for cards, sections, etc.).
    public static var secondaryBackground: Color {
        Color("SecondaryBackground", bundle: nil)
    }
    
    // MARK: - Text Colors
    /// Primary text color for prominent text (e.g., large rate numbers).
    public static var mainTextColor: Color {
        Color("MainTextColor", bundle: nil)
    }
    
    /// Secondary text color for subtitles, smaller elements, icons, etc.
    public static var secondaryTextColor: Color {
        Color("SecondaryTextColor", bundle: nil)
    }
    
    // MARK: - Additional Colors (not yet used)
    /// A main accent color (e.g., for interactive or highlight elements).
    public static var mainColor: Color {
        Color("MainUseColor", bundle: nil)
    }
    
    /// A secondary accent color (e.g., for complementary highlights).
    public static var secondaryColor: Color {
        Color("SecondaryUseColor", bundle: nil)
    }
    
    // MARK: - Icon Color
    /// New: unify the icon color referencing IconColor asset
    public static var icon: Color {
        Color("IconColor", bundle: nil)
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