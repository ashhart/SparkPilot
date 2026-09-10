import Foundation
import SparkAPI
import SparkCore
import SparkDesignSystem
import SwiftUI

struct SparkSettingsStorageSection: View {
    @Bindable var model: SparkSettingsModel
    @Binding var confirmsStorageCleanup: Bool

    var body: some View {
        SettingsCard(
            title: String(localized: "Disk and storage"),
            symbol: "internaldrive",
            help: String(
                localized: "See where space is used and reclaim only the selected unused data."
            )
        ) {
            if let storage = model.storage {
                LabeledContent("Models", value: bytes(storage.modelsBytes))
                LabeledContent("Downloads", value: bytes(storage.downloadsBytes))
                LabeledContent("Blobs", value: bytes(storage.blobsBytes))
                LabeledContent("Containers", value: bytes(storage.containersBytes))
                LabeledContent("Free", value: bytes(storage.freeBytes))
                LabeledContent("Reclaimable", value: bytes(storage.reclaimableBytes))
            }
            Divider()
            Toggle("Partial downloads", isOn: $model.cleanPartialDownloads)
            Toggle("Unused model blobs", isOn: $model.cleanUnusedBlobs)
            Toggle("Stopped containers", isOn: $model.cleanStoppedContainers)
            Toggle("Unused container images", isOn: $model.cleanUnusedImages)
            Button("Clean Selected Storage", role: .destructive) {
                confirmsStorageCleanup = true
            }
            .buttonStyle(.bordered)
        }

    }
    private func bytes(_ value: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file)
    }
}
