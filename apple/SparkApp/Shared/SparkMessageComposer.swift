#if os(iOS)
    import MessageUI
    import SwiftUI

    enum SparkMessageComposeOutcome { case sent, cancelled, failed }

    struct SparkMessageComposer: UIViewControllerRepresentable {
        let text: String
        let recipient: String
        let completion: (SparkMessageComposeOutcome) -> Void
        static var available: Bool { MFMessageComposeViewController.canSendText() }
        func makeUIViewController(context: Context) -> MFMessageComposeViewController {
            let controller = MFMessageComposeViewController()
            controller.messageComposeDelegate = context.coordinator
            controller.body = text
            let recipient = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
            if !recipient.isEmpty { controller.recipients = [recipient] }
            return controller
        }
        func updateUIViewController(_ controller: MFMessageComposeViewController, context: Context)
        {}
        func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }
        final class Coordinator: NSObject, MFMessageComposeViewControllerDelegate {
            let completion: (SparkMessageComposeOutcome) -> Void
            init(completion: @escaping (SparkMessageComposeOutcome) -> Void) {
                self.completion = completion
            }
            func messageComposeViewController(
                _ controller: MFMessageComposeViewController,
                didFinishWith result: MessageComposeResult
            ) {
                switch result {
                case .sent: completion(.sent)
                case .cancelled: completion(.cancelled)
                case .failed: completion(.failed)
                @unknown default: completion(.failed)
                }
            }
        }
    }
#endif
