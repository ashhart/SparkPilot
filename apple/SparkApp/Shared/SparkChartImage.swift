import CoreTransferable
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

#if os(iOS)
    import UIKit
#elseif os(macOS)
    import AppKit
#endif

/// Renders a chart to a PNG only when the owner actually shares or copies it, never while scrolling.
struct SparkChartTransfer: Transferable {
    let spec: SparkChartSpec
    var scheme: ColorScheme = .light

    static let size = CGSize(width: 900, height: 560)

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { transfer in
            await transfer.png() ?? Data()
        }
        .suggestedFileName { transfer in
            let name = transfer.spec.title.replacingOccurrences(
                of: "/",
                with: " "
            )
            return "\(name.prefix(60)).png"
        }
    }

    @MainActor
    func png() -> Data? {
        let renderer = ImageRenderer(
            content: SparkChartCard(spec: spec, isCompact: false)
                .frame(width: Self.size.width, height: Self.size.height)
                .padding(24)
                .background(scheme == .dark ? Color.black : Color.white)
                .environment(\.colorScheme, scheme)
        )
        renderer.scale = 2
        guard let image = renderer.cgImage else { return nil }
        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                data,
                UTType.png.identifier as CFString,
                1,
                nil
            )
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

@MainActor
enum SparkChartPasteboard {
    @discardableResult
    static func copy(_ transfer: SparkChartTransfer) -> Bool {
        guard let data = transfer.png() else { return false }
        #if os(iOS)
            UIPasteboard.general.setData(data, forPasteboardType: UTType.png.identifier)
        #elseif os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setData(data, forType: .png)
        #endif
        return true
    }
}
