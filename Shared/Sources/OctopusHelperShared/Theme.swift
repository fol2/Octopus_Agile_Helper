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
        #if os(iOS)
        Color(uiColor: UIColor { traitCollection in
            traitCollection.userInterfaceStyle == .dark ? 
                UIColor(red: 0, green: 0, blue: 0, alpha: 1) :
                UIColor(red: 0.976, green: 0.976, blue: 0.980, alpha: 1)
        })
        #else
        Color.primary.opacity(0.1)
        #endif
    }
    
    /// A secondary background color (for cards, sections, etc.).
    public static var secondaryBackground: Color {
        #if os(iOS)
        Color(uiColor: UIColor { traitCollection in
            traitCollection.userInterfaceStyle == .dark ? 
                UIColor(red: 0.11, green: 0.11, blue: 0.11, alpha: 1) :
                UIColor(red: 1, green: 1, blue: 1, alpha: 1)
        })
        #else
        Color.primary.opacity(0.05)
        #endif
    }
    
    // MARK: - Text Colors
    /// Primary text color for prominent text (e.g., large rate numbers).
    public static var mainTextColor: Color {
        #if os(iOS)
        Color(uiColor: UIColor { traitCollection in
            traitCollection.userInterfaceStyle == .dark ? 
                UIColor(white: 1, alpha: 1) :
                UIColor(white: 0, alpha: 1)
        })
        #else
        Color.primary
        #endif
    }
    
    /// Secondary text color for subtitles, smaller elements, icons, etc.
    public static var secondaryTextColor: Color {
        #if os(iOS)
        Color(uiColor: UIColor { traitCollection in
            traitCollection.userInterfaceStyle == .dark ? 
                UIColor(white: 1, alpha: 0.6) :
                UIColor(white: 0, alpha: 0.6)
        })
        #else
        Color.secondary
        #endif
    }
    
    // MARK: - Additional Colors (not yet used)
    /// A main accent color (e.g., for interactive or highlight elements).
    public static var mainColor: Color {
        Color(red: 0.2, green: 0.4, blue: 0.8)
    }
    
    /// A secondary accent color (e.g., for complementary highlights).
    public static var secondaryColor: Color {
        Color(red: 0.15, green: 0.3, blue: 0.6)
    }
    
    // MARK: - Icon Color
    /// New: unify the icon color referencing IconColor asset
    public static var icon: Color {
        #if os(iOS)
        Color(uiColor: UIColor { traitCollection in
            traitCollection.userInterfaceStyle == .dark ? 
                UIColor(white: 1, alpha: 0.8) :
                UIColor(white: 0, alpha: 0.8)
        })
        #else
        Color.secondary
        #endif
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