import SwiftUI

/// Publisher glyph and colour with an install badge; unknown publishers retain the state symbol.
public enum ModelPublisherArtwork {
    /// Publisher names as recipes state them, mapped to the bundled image key.
    public static let keys: [String: String] = [
        "nvidia": "nvidia",
        "qwen": "qwen", "alibaba": "qwen", "alibabacloud": "qwen",
        "deepseek": "deepseek",
    ]

    /// Each publisher's brand colour behind its white glyph.
    public static let tints: [String: Color] = [
        "nvidia": Color(red: 0.463, green: 0.725, blue: 0),
        "qwen": Color(red: 0.38, green: 0.36, blue: 0.93),
        "deepseek": Color(red: 0.30, green: 0.42, blue: 0.996),
    ]

    /// The bundled image key for a publisher, or nil when this build carries none for it.
    public static func key(forPublisher publisher: String?) -> String? {
        guard let publisher else { return nil }
        let normalised = publisher.lowercased().filter { $0.isLetter || $0.isNumber }
        if let exact = keys[normalised] { return exact }
        return keys.first { normalised.hasPrefix($0.key) }?.value
    }

    /// Whether the asset catalogue holds a glyph for this key.
    public static func hasGlyph(_ key: String) -> Bool {
        #if canImport(UIKit)
            return UIImage(named: "publisher-" + key, in: .module, compatibleWith: nil) != nil
        #elseif canImport(AppKit)
            return Bundle.module.image(forResource: "publisher-" + key) != nil
        #else
            return false
        #endif
    }

    public static func image(forPublisher publisher: String?) -> Image? {
        guard let key = key(forPublisher: publisher), hasGlyph(key) else { return nil }
        return Image("publisher-" + key, bundle: .module).renderingMode(.template)
    }

    public static func tint(forPublisher publisher: String?) -> Color {
        key(forPublisher: publisher).flatMap { tints[$0] } ?? Color.accentColor
    }
}

/// A model card's leading mark.
public struct ModelPublisherMark: View {
    private let publisher: String?
    private let stateSymbol: String
    private let stateTint: Color

    public init(publisher: String?, stateSymbol: String, stateTint: Color) {
        self.publisher = publisher
        self.stateSymbol = stateSymbol
        self.stateTint = stateTint
    }

    public var body: some View {
        if let glyph = ModelPublisherArtwork.image(forPublisher: publisher) {
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(ModelPublisherArtwork.tint(forPublisher: publisher))
                    .frame(width: 36, height: 36)
                    .overlay {
                        glyph
                            .resizable()
                            .scaledToFit()
                            .foregroundStyle(.white)
                            .padding(8)
                    }
                Image(systemName: stateSymbol)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(stateTint)
                    .padding(2)
                    .background(Circle().fill(.background))
                    .offset(x: 5, y: 5)
            }
            .frame(width: 36, height: 36)
            .accessibilityHidden(true)
        } else {
            Image(systemName: stateSymbol)
                .font(.title2)
                .foregroundStyle(stateTint)
                .frame(width: 34)
        }
    }
}
