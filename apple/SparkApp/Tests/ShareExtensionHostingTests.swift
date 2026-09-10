import Foundation
import Testing

private func shareViewControllerSource() throws -> String {
    let testFile = URL(fileURLWithPath: #filePath)
    let appRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
    return try String(
        contentsOf: appRoot.appending(path: "ShareExtension/ShareViewController.swift"),
        encoding: .utf8
    )
}

/// QA-09: adopting a child hosting controller's own view as `self.view` installs a second view delegate on it and UIKit raises, aborting the extension on every launch.
@Test func theShareExtensionNeverAdoptsItsHostingControllersViewAsItsOwn() throws {
    let source = try shareViewControllerSource()

    #expect(!source.contains("view = host.view"))
    #expect(!source.contains("self.view = host.view"))
}

/// QA-09: the UIKit branch embeds the hosting controller the way UIKit expects: own container, child added, view constrained inside, then `didMove`.
@Test func theShareExtensionEmbedsItsHostingControllerAsAChild() throws {
    let source = try shareViewControllerSource()

    #expect(source.contains("addChild(host)"))
    #expect(source.contains("host.didMove(toParent: self)"))
    #expect(source.contains("addSubview(host.view)"))
    #expect(source.contains("translatesAutoresizingMaskIntoConstraints = false"))
    #expect(source.contains("NSLayoutConstraint.activate"))
}
