import Foundation
import SparkCore
import SwiftUI

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

/// Decodes the static product photograph once instead of reloading it during view updates.
enum SparkProductImage {
    static let shared: Image = load()

    private static func load() -> Image {
        guard let url = Bundle.module.url(forResource: "dgx-spark", withExtension: "png") else {
            return Image(systemName: "shippingbox.fill")
        }

        #if canImport(UIKit)
            guard let image = UIImage(contentsOfFile: url.path) else {
                return Image(systemName: "shippingbox.fill")
            }
            return Image(uiImage: image)
        #elseif canImport(AppKit)
            guard let image = NSImage(contentsOf: url) else {
                return Image(systemName: "shippingbox.fill")
            }
            return Image(nsImage: image)
        #else
            return Image(systemName: "shippingbox.fill")
        #endif
    }
}

/// Uses the same product photograph for list cards and onboarding artwork.
public struct SparkProductMark: View {
    private let size: CGFloat

    public init(size: CGFloat = 44) {
        self.size = size
    }

    public var body: some View {
        SparkProductImage.shared
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

public struct SparkProductArtwork: View {
    private let isConnected: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    public init(isConnected: Bool) {
        self.isConnected = isConnected
    }

    public var body: some View {
        ZStack {
            if isConnected {
                Circle()
                    .stroke(Color.green.opacity(pulse ? 0 : 0.42), lineWidth: 3)
                    .frame(width: pulse ? 290 : 190, height: pulse ? 290 : 190)
                    .scaleEffect(pulse ? 1.06 : 0.72)
                    .opacity(pulse ? 0 : 1)
            }

            productImage
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 310, maxHeight: 210)
                .shadow(color: .black.opacity(0.18), radius: 18, y: 10)

            if isConnected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 54, weight: .semibold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .green)
                    .background(Circle().fill(.white).padding(5))
                    .offset(x: 116, y: 70)
                    .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
            }
        }
        .frame(height: 230)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isConnected ? "Connected to DGX Spark" : "NVIDIA DGX Spark")
        .onAppear {
            updatePulse(reduceMotion: reduceMotion)
        }
        .onChange(of: reduceMotion) { _, newValue in
            updatePulse(reduceMotion: newValue)
        }
    }

    private var productImage: Image { SparkProductImage.shared }

    private func updatePulse(reduceMotion: Bool) {
        guard
            SparkProductArtworkMotion.shouldPulse(
                isConnected: isConnected,
                reduceMotion: reduceMotion
            )
        else {
            withAnimation(nil) { pulse = false }
            return
        }
        withAnimation(.easeOut(duration: 1.25).repeatForever(autoreverses: false)) {
            pulse = true
        }
    }
}

enum SparkProductArtworkMotion {
    static func shouldPulse(isConnected: Bool, reduceMotion: Bool) -> Bool {
        isConnected && !reduceMotion
    }
}

enum RetailOnboardingFeedback {
    static func shouldPlaySuccess(
        from oldPhase: RetailOnboardingPhase,
        to newPhase: RetailOnboardingPhase
    ) -> Bool {
        oldPhase != newPhase && (newPhase == .sparkConnected || newPhase == .ready)
    }
}

/// Manual setup derives a local hostname; QR setup may supply its own address.
public enum SparkSetupAddress {
    public static func hostname(for ssid: String) -> String? {
        let value = ssid.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let label = value.hasSuffix(".local") ? String(value.dropLast(6)) : value
        guard !label.isEmpty, label.utf8.count <= 63,
            label.first != "-", label.last != "-",
            label.utf8.allSatisfy({ $0 == 45 || (48...57).contains($0) || (97...122).contains($0) })
        else { return nil }
        return "\(label).local"
    }
}
