#if canImport(CarPlay)
    import CarPlay
    import UIKit

    /// UIKit creates this for the car; everything it needs from the app comes through the bridge.
    @objc(SparkCarPlaySceneDelegate)
    public final class SparkCarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
        private var interface: SparkCarPlayInterface?
        private var monitor: SparkDrivingMonitor?

        public func templateApplicationScene(
            _ templateApplicationScene: CPTemplateApplicationScene,
            didConnect interfaceController: CPInterfaceController
        ) {
            let bridge = SparkCarPlayBridge.shared
            SparkVoiceAudioSession.routesThroughCar = true
            bridge.carPlayConnected(true)
            let conversation = bridge.conversation ?? SparkCarPlayConversation(bridge: bridge)
            bridge.conversation = conversation
            let interface = SparkCarPlayInterface(
                controller: interfaceController,
                conversation: conversation,
                bridge: bridge
            )
            self.interface = interface
            interface.start()
            let monitor = SparkDrivingMonitor(bridge: bridge)
            self.monitor = monitor
            monitor.start()
        }

        public func templateApplicationScene(
            _ templateApplicationScene: CPTemplateApplicationScene,
            didDisconnectInterfaceController interfaceController: CPInterfaceController
        ) {
            let bridge = SparkCarPlayBridge.shared
            interface?.stop()
            interface = nil
            monitor?.stop()
            monitor = nil
            bridge.conversation?.disconnect()
            bridge.conversation = nil
            SparkVoiceAudioSession.routesThroughCar = false
            bridge.carPlayConnected(false)
        }
    }
#endif

/// What the app calls so the car can find it: register models, and keep the delegate linked.
public enum SparkCarPlayComposition {
    /// Reference the scene delegate so the static link never drops the class UIKit looks up by name.
    public static func prepare() {
        #if canImport(CarPlay)
            _ = SparkCarPlaySceneDelegate.self
        #endif
    }

    @MainActor public static func register(onboarding: RetailOnboardingModel, appLock: AppLockModel)
    {
        SparkCarPlayBridge.shared.register(onboarding: onboarding, appLock: appLock)
    }
}
