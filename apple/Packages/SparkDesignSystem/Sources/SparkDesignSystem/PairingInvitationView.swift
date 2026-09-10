import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// Return nil for unencodable invitation payloads so the caller cannot present a blank QR code.
public enum SparkQRCodeRenderer {
    /// Bound QR payload size to avoid producing an impractically dense pairing code.
    public static let maximumPayloadBytes = 1_500

    public static func makeCGImage(payload: String, scale: CGFloat = 10) -> CGImage? {
        let data = Data(payload.utf8)
        guard !data.isEmpty, data.count <= maximumPayloadBytes else { return nil }

        let filter = CIFilter.qrCodeGenerator()
        filter.message = data
        // Use medium QR recovery for angled screen capture without excessive symbol density.
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return CIContext().createCGImage(scaled, from: scaled.extent)
    }
}

/// A scannable pairing invitation or an actionable explanation when sharing is unavailable.
public struct SparkPairingQRCode: View {
    private let payload: String
    private let size: CGFloat

    public init(payload: String, size: CGFloat = 240) {
        self.payload = payload
        self.size = size
    }

    public var body: some View {
        Group {
            if let image = SparkQRCodeRenderer.makeCGImage(payload: payload) {
                Image(decorative: image, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size, height: size)
                    .padding(12)
                    .background(.white, in: RoundedRectangle(cornerRadius: 16))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Pairing invitation code")
                    .accessibilityHint("Scan this with the Apple device you are adding.")
            } else {
                Label(
                    String(
                        localized: "This invitation could not be shown as a code."
                    ),
                    systemImage: "qrcode"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(width: size, height: size)
            }
        }
    }
}
