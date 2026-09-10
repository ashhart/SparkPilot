import SwiftUI

#if os(iOS)
    import MessageUI
#elseif os(macOS)
    import AppKit
#endif

@MainActor
struct SparkBugReportReview: View {
    let report: SparkBugReport
    @Environment(\.dismiss) private var dismiss
    @State private var status: String?
    @State private var showsMail = false
    @State private var shareFiles: SparkBugShareFiles?
    #if os(macOS)
        @State private var mailService: NSSharingService?
    #endif

    var body: some View {
        NavigationStack {
            List {
                if let recipient = report.recipient {
                    Section {
                        LabeledContent("To", value: recipient).textSelection(.enabled)
                    } footer: {
                        Text(
                            "Email shares your report and your sender address with the developer so they can reply."
                        )
                    }
                }
                Section("Everything included") {
                    Text(report.body)
                        .font(.body)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .privacySensitive()
                    if let screenshot = report.screenshot {
                        SparkBugScreenshotPreview(screenshot: screenshot)
                        Text(
                            "Check that the screenshot does not reveal anything you want to keep private."
                        )
                        .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section {
                    if let recipient = report.recipient {
                        Button("Continue to email") { composeEmail(to: recipient) }
                    }
                    if let shareFiles {
                        ShareLink(items: shareFiles.urls, subject: Text(report.subject)) {
                            Label("Share report", systemImage: "square.and.arrow.up")
                        }
                    } else {
                        Button("Prepare report for sharing") { prepareShare() }
                    }
                    if let status {
                        Text(status).font(.footnote).foregroundStyle(.secondary)
                            .accessibilityIdentifier("bug-report-delivery-status")
                    }
                } footer: {
                    Text(
                        "You can edit or cancel in your email app; use Share report to choose another app, and your draft stays here if you need to try again."
                    )
                }
            }
            .navigationTitle("Review feedback")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Back to editing") { dismiss() }
                }
            }
        }
        .task { prepareShare() }
        #if os(macOS)
            .frame(minWidth: 440, idealWidth: 560, minHeight: 440, idealHeight: 640)
        #else
            .sheet(isPresented: $showsMail) {
                SparkBugMailComposer(report: report) { result in
                    showsMail = false
                    status = result
                }
            }
        #endif
    }

    private func composeEmail(to recipient: String) {
        #if os(iOS)
            guard MFMailComposeViewController.canSendMail() else {
                status = String(
                    localized:
                        "Mail is not set up on this device; use Share report to choose another app."
                )
                return
            }
            showsMail = true
        #elseif os(macOS)
            let items: [Any] =
                [report.body] + (shareFiles?.urls.dropFirst().map { $0 as Any } ?? [])
            guard report.screenshot == nil || shareFiles != nil,
                let service = NSSharingService(named: .composeEmail),
                service.canPerform(withItems: items)
            else {
                status = String(
                    localized: "Mail is unavailable; use Share report to choose another app."
                )
                return
            }
            service.recipients = [recipient]
            service.subject = report.subject
            mailService = service
            service.perform(withItems: items)
            status = String(
                localized: "Finish sending in Mail; your report draft is still saved in SparkPilot."
            )
        #endif
    }

    private func prepareShare() {
        guard shareFiles == nil else { return }
        do { shareFiles = try SparkBugShareFiles(report: report) } catch {
            status = String(
                localized:
                    "The report could not be prepared for sharing; your draft is safe, and you can try again."
            )
        }
    }
}

#if os(iOS)
    @MainActor
    private struct SparkBugMailComposer: UIViewControllerRepresentable {
        let report: SparkBugReport
        let completed: (String) -> Void

        func makeCoordinator() -> Coordinator { Coordinator(completed: completed) }

        func makeUIViewController(context: Context) -> MFMailComposeViewController {
            let controller = MFMailComposeViewController()
            controller.mailComposeDelegate = context.coordinator
            controller.setToRecipients(report.recipient.map { [$0] })
            controller.setSubject(report.subject)
            controller.setMessageBody(report.body, isHTML: false)
            if let screenshot = report.screenshot {
                controller.addAttachmentData(
                    screenshot.data,
                    mimeType: "image/png",
                    fileName: "Screenshot.png"
                )
            }
            return controller
        }

        func updateUIViewController(_ controller: MFMailComposeViewController, context: Context) {}

        final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
            let completed: (String) -> Void
            init(completed: @escaping (String) -> Void) { self.completed = completed }

            func mailComposeController(
                _ controller: MFMailComposeViewController,
                didFinishWith result: MFMailComposeResult,
                error: (any Error)?
            ) {
                guard error == nil else {
                    completed(
                        String(
                            localized:
                                "Mail could not prepare the report; your draft is saved, and you can try again or use Share report."
                        )
                    )
                    return
                }
                switch result {
                case .sent:
                    completed(
                        String(
                            localized:
                                "The report is queued in Mail; delivery depends on your email connection, and your draft remains available here."
                        )
                    )
                case .saved:
                    completed(
                        String(
                            localized:
                                "Saved in Mail drafts; finish sending there when you are ready."
                        )
                    )
                case .cancelled:
                    completed(
                        String(localized: "Email cancelled; your report draft is still here.")
                    )
                case .failed:
                    completed(
                        String(
                            localized:
                                "Mail could not send the report; your draft is saved, and you can try again or use Share report."
                        )
                    )
                @unknown default:
                    completed(
                        String(
                            localized: "Check Mail for the report; your draft remains saved here."
                        )
                    )
                }
            }
        }
    }
#endif
