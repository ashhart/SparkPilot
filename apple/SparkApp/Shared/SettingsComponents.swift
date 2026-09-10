import Foundation
import Observation
import CoreImage.CIFilterBuiltins
import Network
import SparkAPI
import SparkBootstrap
import SparkCore
import SparkDesignSystem
import SparkDiscovery
import SparkSecurity
import SwiftUI

func encodeRuntimeRelease(
    _ release: RuntimeUpdateBundle
) async -> GeneratedAPI.RuntimeReleaseBundle {
    await Task.detached(priority: .userInitiated) {
        GeneratedAPI.RuntimeReleaseBundle(
            releaseId: release.releaseID,
            manifestBase64: release.manifest.base64EncodedString(),
            packageBase64: release.package.base64EncodedString(),
            signatureBase64: release.detachedSignature.base64EncodedString()
        )
    }.value
}

struct SettingsCard<Content: View>: View {
    let title: String
    let symbol: String
    let help: String?
    let content: Content

    init(
        title: String,
        symbol: String,
        help: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.symbol = symbol
        self.help = help
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(title, systemImage: symbol)
                    .font(.title3.bold())
                    .foregroundStyle(.primary)
                Spacer()
                if let help {
                    SparkTooltipButton(title: title, message: help)
                }
            }
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.32), in: RoundedRectangle(cornerRadius: 16))
    }
}

struct SettingsHeader: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 42, height: 42)
                .background(.tint.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.title2.bold())
                Text(detail).foregroundStyle(.secondary)
            }
        }
    }
}

struct PasswordField: View {
    let title: String
    @Binding var text: String
    @Binding var reveals: Bool

    var body: some View {
        HStack {
            Group {
                if reveals {
                    TextField(title, text: $text)
                } else {
                    SecureField(title, text: $text)
                }
            }
            .textContentType(.password)
            Button {
                reveals.toggle()
            } label: {
                Image(systemName: reveals ? "eye.slash" : "eye")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                reveals ? String(localized: "Hide password") : String(localized: "Show password")
            )
        }
        // Hide administrator passwords from App Switcher snapshots and recordings.
        .privacySensitive()
        .sparkField()
    }
}

struct TravelQRCode: View {
    let ssid: String
    let password: String

    var body: some View {
        if let image = qrImage {
            VStack(alignment: .leading, spacing: 8) {
                Image(decorative: image, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 156, height: 156)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    // Encodes the hotspot passphrase: keep it out of snapshots.
                    .privacySensitive()
                Text("Scan to join from another device.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var qrImage: CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data("WIFI:T:WPA;S:\(ssid);P:\(password);;".utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: .init(scaleX: 10, y: 10)) else {
            return nil
        }
        return CIContext().createCGImage(output, from: output.extent)
    }
}

struct IdlePolicyRow: View {
    @Bindable var model: SparkSettingsModel
    let modelID: String
    let profile: SparkModelProfile
    @State private var setting = SparkModelIdleSetting()
    @State private var validationError: String?

    var body: some View {
        NavigationLink(profile.displayName) {
            Form {
                SparkModelIdleControls(setting: $setting, profile: profile)
                    .disabled(model.activeMutation != nil)
                if let error = validationError ?? model.errorMessage {
                    Text(error).foregroundStyle(.red)
                }
                if let success = model.successMessage { Text(success).foregroundStyle(.secondary) }
                Button("Save unload setting") {
                    do {
                        let request = try setting.request(modelID: modelID, profile: profile)
                        validationError = nil
                        Task {
                            await model.saveIdlePolicy(
                                modelID: modelID,
                                profileID: profile.id,
                                policy: request.idlePolicy,
                                idleTimeoutSeconds: request.idleTimeoutSeconds
                            )
                        }
                    } catch { validationError = error.localizedDescription }
                }
                .disabled(model.activeMutation != nil)
            }
            .navigationTitle("Unload when idle")
            .onAppear {
                let saved = model.settings?.modelIdlePolicies.first {
                    $0.modelId == modelID && $0.profileId == profile.id
                }
                if let saved {
                    switch saved.idlePolicy {
                    case .keepReady, .manualOnly: setting.minutes = nil
                    case .unloadAfter15M: setting.minutes = (saved.idleTimeoutSeconds ?? 900) / 60
                    case .unloadAfter30M: setting.minutes = (saved.idleTimeoutSeconds ?? 1800) / 60
                    case .unloadAfter60M: setting.minutes = (saved.idleTimeoutSeconds ?? 3600) / 60
                    }
                } else {
                    setting = SparkModelIdleSetting(profile: profile)
                }
            }
        }
    }
}

/// Expose numeric threshold labels for tests so interpolation errors cannot hide memory-safety settings.
enum SparkMemoryGuardPresentation {
    enum Rung {
        case warning
        case critical
        case emergency

        var name: String {
            switch self {
            case .warning: String(localized: "Warning")
            case .critical: String(localized: "Critical")
            case .emergency: String(localized: "Emergency")
            }
        }
    }

    static func label(_ rung: Rung, gibFree: Int) -> String {
        let free = Measurement(value: Double(gibFree), unit: UnitInformationStorage.gibibytes)
        return String(
            localized: .cleanupRungAtFree(
                name: rung.name,
                free: free.formatted(.measurement(width: .abbreviated, usage: .asProvided))
            )
        )
    }
}

/// Format watts with the device locale, including its decimal separator.
func watts(_ value: Double, places: Int) -> String {
    Measurement(value: value, unit: UnitPower.watts)
        .formatted(
            .measurement(
                width: .abbreviated,
                numberFormatStyle: .number.precision(.fractionLength(places))
            )
        )
}
