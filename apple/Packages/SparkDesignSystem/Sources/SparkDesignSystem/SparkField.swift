import SwiftUI

/// Apply the shared platform-appropriate text-field style to inputs or their leading-symbol containers.
public struct SparkFieldModifier: ViewModifier {
    public init() {}

    public func body(content: Content) -> some View {
        #if os(iOS)
            content
                .padding(.horizontal, 12)
                .frame(minHeight: 50)
                .background(
                    .quaternary.opacity(0.45),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
        #else
            content.textFieldStyle(.roundedBorder)
        #endif
    }
}

extension View {
    /// The app's standard text-field treatment; see ``SparkFieldModifier``.
    public func sparkField() -> some View {
        modifier(SparkFieldModifier())
    }
}
