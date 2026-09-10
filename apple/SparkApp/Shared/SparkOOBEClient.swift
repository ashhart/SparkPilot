import Foundation
import SparkTransport

public struct SparkOOBELanguage: Identifiable, Sendable, Equatable {
    public let index: Int
    public let countryCode: String
    public let languageCode: String
    public let displayName: String
    public let locale: String

    public var id: Int { index }
}

public struct SparkOOBERegionalOptions: Sendable, Equatable {
    public let languages: [SparkOOBELanguage]
    public let timeZones: [String]
}

public struct SparkOOBEWiFiNetwork: Identifiable, Sendable, Equatable {
    public let index: Int
    public let ssid: String
    public let strength: Int
    public let isProtected: Bool

    public var id: Int { index }
}

public struct SparkOOBENetworkOptions: Sendable, Equatable {
    public let ethernetHasInternet: Bool
    public let wifiNetworks: [SparkOOBEWiFiNetwork]

    public init(
        ethernetHasInternet: Bool,
        wifiNetworks: [SparkOOBEWiFiNetwork]
    ) {
        self.ethernetHasInternet = ethernetHasInternet
        self.wifiNetworks = wifiNetworks
    }
}

public enum SparkOOBEClientError: Error, Sendable, Equatable {
    case invalidResponse
    /// Keeps a bounded setup response body for diagnostics without displaying unauthenticated server text as app copy.
    case server(statusCode: Int, diagnosticDetail: String)
    case decoding(String)
    case updateTimedOut
    /// The Spark reported that its firmware update did not finish.
    case firmwareUpdateFailed
}

public protocol SparkOOBEServicing: Sendable {
    func regionalOptions() async throws -> SparkOOBERegionalOptions
    func configureRegion(languageIndex: Int, timeZoneIndex: Int) async throws
    func licenceText() async throws -> String
    func acceptLicence() async throws
    func createAccount(username: String, password: String) async throws
    func configureTelemetry(functional: Bool, technical: Bool) async throws
    func networkOptions() async throws -> SparkOOBENetworkOptions
    func wifiNetworks() async throws -> [SparkOOBEWiFiNetwork]
    func connectWiFi(index: Int, password: String) async throws
    func finishSetup() async throws
}

extension SparkOOBEServicing {
    public func networkOptions() async throws -> SparkOOBENetworkOptions {
        SparkOOBENetworkOptions(
            ethernetHasInternet: false,
            wifiNetworks: try await wifiNetworks()
        )
    }
}

public actor SparkOOBEClient: SparkOOBEServicing {
    private struct LanguageResponse: Decodable {
        let countryCode: String
        let languageCode: String
        let displayName: String
        let locale: String

        enum CodingKeys: String, CodingKey {
            case countryCode = "CountryCode"
            case languageCode = "LanguageCode"
            case displayName = "DisplayName"
            case locale = "Locale"
        }
    }

    private struct WiFiResponse: Decodable {
        let ssid: String
        let strength: Int
        let isProtected: Bool

        enum CodingKeys: String, CodingKey {
            case ssid = "Ssid"
            case strength = "Strength"
            case isProtected = "Protected"
        }
    }

    private struct WiFiRequest: Encodable {
        let wifi: Int
        let psk: String
    }

    private struct OTAPolicy: Decodable {
        let enforceOTA: Bool

        enum CodingKeys: String, CodingKey {
            case enforceOTA = "enforceOta"
        }
    }

    private struct UpdateProgress: Decodable {
        let done: Bool
    }

    private struct FirmwareProgress: Decodable {
        let status: String
    }

    private let baseURL: URL
    deinit { session.finishTasksAndInvalidate() }

    private let session: URLSession
    private let decoder = JSONDecoder()

    /// Uses an ephemeral session for pre-runtime NVIDIA setup so Wi-Fi credentials do not enter process-wide caches or cookie stores.
    public init(baseURL: URL) {
        self.init(baseURL: baseURL, interceptingWith: [])
    }

    /// For tests that drive a stubbed `URLProtocol`.
    @_spi(SparkTestSupport)
    public init(baseURL: URL, interceptingWith protocolClasses: [AnyClass]) {
        self.baseURL = baseURL
        // The setup page is unpinned, so a redirect would carry the admin password to another host.
        self.session = URLSession(
            configuration: SparkURLSessionConfiguration.hardened(
                interceptingWith: protocolClasses
            ),
            delegate: SparkRedirectRefusingSessionDelegate(),
            delegateQueue: nil
        )
    }

    public func regionalOptions() async throws -> SparkOOBERegionalOptions {
        async let languageResponse: [LanguageResponse] = get("/langs")
        async let timeZones: [String] = get("/tz")
        let rawLanguages = try await languageResponse
        return try await SparkOOBERegionalOptions(
            languages: rawLanguages.enumerated().map { index, language in
                SparkOOBELanguage(
                    index: index,
                    countryCode: language.countryCode,
                    languageCode: language.languageCode,
                    displayName: language.displayName,
                    locale: language.locale
                )
            },
            timeZones: timeZones
        )
    }

    public func configureRegion(languageIndex: Int, timeZoneIndex: Int) async throws {
        // Submit NVIDIA first-boot steps sequentially to preserve their required order.
        try await post("/langs", json: ["lang": languageIndex])
        try await post("/tz", json: ["tz": timeZoneIndex])
    }

    public func licenceText() async throws -> String {
        async let oem = getText("/eula_oem")
        async let nvidia = getText("/eula")
        let sections = try await [oem, nvidia]
        return sections.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    public func acceptLicence() async throws {
        try await post("/eula")
    }

    public func createAccount(username: String, password: String) async throws {
        try await post(
            "/user",
            json: [
                "digits_fullname": username,
                "digits_username": username,
                "digits_password": password,
            ]
        )
    }

    public func configureTelemetry(functional: Bool, technical: Bool) async throws {
        try await post(
            "/telemetry",
            json: ["functional": functional, "technical": technical]
        )
    }

    public func wifiNetworks() async throws -> [SparkOOBEWiFiNetwork] {
        let networks: [WiFiResponse] = try await get("/wifi")
        return networks.enumerated().map { index, network in
            SparkOOBEWiFiNetwork(
                index: index,
                ssid: network.ssid,
                strength: network.strength,
                isProtected: network.isProtected
            )
        }
    }

    public func networkOptions() async throws -> SparkOOBENetworkOptions {
        do {
            return SparkOOBENetworkOptions(
                ethernetHasInternet: false,
                wifiNetworks: try await wifiNetworks()
            )
        } catch let error as SparkOOBEClientError {
            // Accept older NVIDIA images reporting an internet-connected wired Wi-Fi skip as a conflict.
            if case .server(statusCode: 409, let detail) = error {
                let normalized = detail.lowercased()
                if normalized.contains("skipped wi-fi")
                    || normalized.contains("skipped wifi")
                {
                    return SparkOOBENetworkOptions(
                        ethernetHasInternet: true,
                        wifiNetworks: []
                    )
                }
            }
            throw error
        }
    }

    public func connectWiFi(index: Int, password: String) async throws {
        do {
            try await post("/wifi", json: WiFiRequest(wifi: index, psk: password))
        } catch let error as URLError where error.code == .networkConnectionLost {
            // Confirm Wi-Fi success through handoff when hotspot loss prevents receipt of the HTTP reply.
            return
        }
    }

    public func finishSetup() async throws {
        let policy: OTAPolicy = try await get("/ota-policy")
        guard policy.enforceOTA else {
            try await post("/complete-without-ota")
            return
        }

        try await post("/wrapup")
        try await waitUntilDone(path: "/update")
        try await waitUntilDone(path: "/upgrade")
        try await waitForFirmware()
    }

    private func waitUntilDone(path: String) async throws {
        for _ in 0..<600 {
            let progress: UpdateProgress = try await get(path)
            if progress.done { return }
            try await Task.sleep(for: .seconds(1))
        }
        throw SparkOOBEClientError.updateTimedOut
    }

    private func waitForFirmware() async throws {
        for _ in 0..<600 {
            let progress: FirmwareProgress = try await get("/fwstatus")
            if progress.status == "done" || progress.status == "not_needed" { return }
            if progress.status == "error" {
                throw SparkOOBEClientError.firmwareUpdateFailed
            }
            try await Task.sleep(for: .seconds(1))
        }
        throw SparkOOBEClientError.updateTimedOut
    }

    private func get<Response: Decodable>(_ path: String) async throws -> Response {
        let data = try await request(path: path)
        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw SparkOOBEClientError.decoding(String(describing: error))
        }
    }

    private func getText(_ path: String) async throws -> String {
        let data = try await request(path: path, accept: "text/plain")
        return String(decoding: data, as: UTF8.self)
    }

    private func post(_ path: String) async throws {
        _ = try await request(path: path, method: "POST")
    }

    private func post<Body: Encodable>(_ path: String, json body: Body) async throws {
        let data = try JSONEncoder().encode(body)
        _ = try await request(path: path, method: "POST", body: data)
    }

    private func request(
        path: String,
        method: String = "GET",
        body: Data? = nil,
        accept: String = "application/json"
    ) async throws -> Data {
        guard let url = URL(string: "api/v1\(path)", relativeTo: normalizedBaseURL)?.absoluteURL
        else { throw SparkOOBEClientError.invalidResponse }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 10
        request.setValue(accept, forHTTPHeaderField: "Accept")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SparkOOBEClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw SparkOOBEClientError.server(
                statusCode: http.statusCode,
                diagnosticDetail: String(decoding: data.prefix(1_000), as: UTF8.self)
            )
        }
        return data
    }

    private var normalizedBaseURL: URL {
        baseURL.absoluteString.hasSuffix("/")
            ? baseURL : baseURL.appendingPathComponent("")
    }
}
