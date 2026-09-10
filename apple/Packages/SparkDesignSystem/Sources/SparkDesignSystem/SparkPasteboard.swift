#if os(iOS)
    import UIKit
#elseif os(macOS)
    import AppKit
#endif

/// Write-only clipboard access, so §52.3's no-clipboard-reading rule holds by construction.
public enum SparkPasteboard {
    public static func copy(_ value: String) {
        #if os(iOS)
            UIPasteboard.general.string = value
        #elseif os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
        #endif
    }
}
