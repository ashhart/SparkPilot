import SparkDesignSystem
import SwiftUI

struct ExistingSparkSetupView: View {
    @Bindable var model: RetailOnboardingModel
    @State private var existingSparkHost = ""

    var body: some View {
        List {
            Section {
                Text(
                    "Connect this device to the same network as your Spark, then choose it below or enter its address."
                )
                Text(
                    "Spark Runtime is included in SparkPilot. Sign in with your Spark’s administrator account to review what is installed before adding SparkPilot features."
                )
                .foregroundStyle(.secondary)
                Text(
                    "Your Spark does not need a factory reset or its setup Wi-Fi. Custom setups may not be compatible; review the check before installing."
                )
                .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Nearby devices") {
                if model.bootstrapDiscovery.candidates.isEmpty {
                    Label(
                        "Looking for your Spark…",
                        systemImage: "antenna.radiowaves.left.and.right"
                    )
                    .foregroundStyle(.secondary)
                    Text(
                        "If it does not appear, enter its address below and make sure SSH is enabled on the Spark."
                    )
                    .font(.footnote).foregroundStyle(.secondary)
                }
                AddSparkDiscoveryResults(model: model, showsSetupCandidates: true)
            }
            Section {
                TextField("IP address or hostname", text: $existingSparkHost)
                    .textContentType(.URL)
                    #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    #endif
                    .sparkField()
                Button("Check This Spark") {
                    guard let target = ExistingSparkAddress.bootstrap(existingSparkHost) else {
                        return
                    }
                    model.chooseBootstrapSpark(target)
                }
                .disabled(ExistingSparkAddress.bootstrap(existingSparkHost) == nil)
            } header: {
                Text("Enter an address")
            } footer: {
                Text(
                    "Use your Spark’s network address, such as spark-abcd.local or 192.168.1.50; a custom SSH port can be added after a colon."
                )
            }
        }
    }

}
