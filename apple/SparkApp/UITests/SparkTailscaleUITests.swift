import XCTest

@MainActor
extension SparkUITests {
    func testSparkTailscaleControlsConfirmPauseAndPreserveDNS() {
        familyPreview()
        tap("Tailscale controls")
        let vpn = app.switches["spark.tailscale.vpn"]
        let dns = app.switches["spark.tailscale.dns"]
        XCTAssertTrue(vpn.waitForExistence(timeout: 8))
        for _ in 0..<5 where !dns.isHittable { app.swipeUp() }
        XCTAssertEqual(vpn.value as? String, "1")
        XCTAssertEqual(dns.value as? String, "1")
        dns.tap()
        expectSwitch(dns, "0")
        for _ in 0..<5 where !vpn.isHittable { app.swipeDown() }
        vpn.tap()
        let pause = app.alerts["Pause the Spark's VPN?"]
        XCTAssertTrue(pause.waitForExistence(timeout: 5))
        capture("tailscale-pause-confirmation")
        pause.buttons["Keep VPN On"].tap()
        expectSwitch(vpn, "1")
        vpn.tap()
        pause.buttons["Pause VPN"].tap()
        expectSwitch(vpn, "0")
        expectSwitch(dns, "0")
        capture("tailscale-paused")
        vpn.tap()
        expectSwitch(vpn, "1")
        expectSwitch(dns, "0")
        for _ in 0..<5 where !dns.isHittable { app.swipeUp() }
        dns.tap()
        expectSwitch(dns, "1")
        capture("tailscale-resumed-dns-restored")
    }

    private func expectSwitch(_ control: XCUIElement, _ value: String) {
        let expected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@ AND enabled == true", value),
            object: control
        )
        XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 8), .completed)
    }

}
