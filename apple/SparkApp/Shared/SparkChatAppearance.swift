import Foundation
import SparkDesignSystem
import SwiftUI
import UniformTypeIdentifiers

#if os(iOS)
    import UIKit
#elseif os(macOS)
    import AppKit
#endif

enum ChatStyle {
    static let readingWidth: CGFloat = 760
    static let horizontalInset: CGFloat = 20
    static let surface = Color.primary.opacity(0.055)
    static let border = Color.primary.opacity(0.09)
    static var canvas: Color {
        #if os(iOS)
            Color(uiColor: .systemBackground)
        #else
            Color(nsColor: .textBackgroundColor)
        #endif
    }
}

struct PersonalActionContext: Identifiable {
    let id = UUID()
    let text: String
}
