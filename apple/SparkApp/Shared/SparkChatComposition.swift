import SparkLibrary

@MainActor
extension SparkChatModel {
    public convenience init(library: SparkLibrary) {
        let provider = LocalSparkChatTargetProvider(library: library)
        self.init(
            provider: provider,
            streamer: PinnedSparkChatStreamer(),
            modelLauncher: SignedSparkModelLauncher(library: library)
        )
    }

}
