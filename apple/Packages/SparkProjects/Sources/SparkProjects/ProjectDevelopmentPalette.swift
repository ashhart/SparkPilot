import SwiftUI

/// Terminal and surrounding controls inherit the same appearance as the rest of the app.
public struct ProjectDevelopmentPalette {
    public let canvas: Color
    public let foreground: Color
    public let accent: Color
    public let onAccent: Color

    public init(_ scheme: ColorScheme) {
        #if os(macOS)
            canvas = Color(nsColor: .windowBackgroundColor)
        #else
            canvas = Color(uiColor: .systemBackground)
        #endif
        foreground = .primary
        accent = .accentColor
        onAccent = .white
    }
}
