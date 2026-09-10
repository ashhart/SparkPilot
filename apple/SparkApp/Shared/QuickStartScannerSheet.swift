#if os(iOS)
    import SwiftUI
    import UIKit
    import VisionKit

    /// QA-01: the Quick Start sheet, which draws a camera only when one can answer and otherwise says why and offers the way on.
    struct QuickStartScannerSheet: View {
        let onPayload: (String) -> Void
        let onEnterDetailsManually: () -> Void
        let onCancel: () -> Void
        @State private var startError: String?

        private var availability: QuickStartScannerAvailability {
            .resolve(
                isSupported: DataScannerViewController.isSupported,
                isAvailable: DataScannerViewController.isAvailable,
                startError: startError
            )
        }

        var body: some View {
            NavigationStack {
                content
                    .navigationTitle("Scan Quick Start Code")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel", action: onCancel)
                        }
                    }
            }
        }

        @ViewBuilder
        private var content: some View {
            if availability.showsCamera {
                QuickStartScanner(
                    onPayload: onPayload,
                    onStartFailure: { startError = $0 }
                )
                .ignoresSafeArea()
            } else {
                cannotScan
            }
        }

        private var cannotScan: some View {
            VStack(spacing: 18) {
                Image(systemName: "camera.metering.unknown")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Nothing to scan with")
                    .font(.title3.bold())
                Text(availability.explanation)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = availability.detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("Enter details manually", action: onEnterDetailsManually)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
            .frame(maxWidth: 420)
            .padding(28)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The live data scanner; a refusal to start is reported rather than swallowed.
    private struct QuickStartScanner: UIViewControllerRepresentable {
        let onPayload: (String) -> Void
        let onStartFailure: (String) -> Void

        func makeCoordinator() -> Coordinator {
            Coordinator(onPayload: onPayload, onStartFailure: onStartFailure)
        }

        func makeUIViewController(context: Context) -> DataScannerViewController {
            let scanner = DataScannerViewController(
                recognizedDataTypes: [.barcode(symbologies: [.qr])],
                qualityLevel: .balanced,
                recognizesMultipleItems: false,
                isHighFrameRateTrackingEnabled: false,
                isPinchToZoomEnabled: true,
                isGuidanceEnabled: true,
                isHighlightingEnabled: true
            )
            scanner.delegate = context.coordinator
            do {
                try scanner.startScanning()
            } catch {
                context.coordinator.reportStartFailure(error)
            }
            return scanner
        }

        func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

        static func dismantleUIViewController(
            _ controller: DataScannerViewController,
            coordinator: Coordinator
        ) {
            controller.stopScanning()
        }

        final class Coordinator: NSObject, DataScannerViewControllerDelegate {
            let onPayload: (String) -> Void
            let onStartFailure: (String) -> Void

            init(
                onPayload: @escaping (String) -> Void,
                onStartFailure: @escaping (String) -> Void
            ) {
                self.onPayload = onPayload
                self.onStartFailure = onStartFailure
            }

            /// Report after this view update rather than inside it, so SwiftUI is not asked to change state mid-render.
            func reportStartFailure(_ error: any Error) {
                let message =
                    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                Task { @MainActor in onStartFailure(message) }
            }

            func dataScanner(
                _ dataScanner: DataScannerViewController,
                didAdd addedItems: [RecognizedItem],
                allItems: [RecognizedItem]
            ) {
                for item in addedItems {
                    guard case .barcode(let barcode) = item,
                        let payload = barcode.payloadStringValue
                    else { continue }
                    onPayload(payload)
                    return
                }
            }
        }
    }
#endif
