#if os(macOS)
    import AppKit
    import Foundation
    import Network
    import Observation
    import SparkAPI
    import SparkCore
    import SparkSecurity
    @_spi(SparkInternal) import SparkTransport

    struct GatewayHTTPRequest {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data

        var authorizationToken: String? {
            guard let value = headers["authorization"], value.hasPrefix("Bearer ") else {
                return nil
            }
            return String(value.dropFirst("Bearer ".count))
        }

        var accept: String? { headers["accept"] }

        static func parse(_ data: Data) -> GatewayHTTPRequest? {
            let delimiter = Data("\r\n\r\n".utf8)
            guard let boundary = data.range(of: delimiter),
                let head = String(data: data[..<boundary.lowerBound], encoding: .utf8)
            else { return nil }
            let lines = head.components(separatedBy: "\r\n")
            guard let first = lines.first else { return nil }
            let requestLine = first.split(separator: " ", maxSplits: 2).map(String.init)
            guard requestLine.count == 3,
                ["GET", "POST"].contains(requestLine[0]),
                let components = URLComponents(string: requestLine[1])
            else { return nil }
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                headers[name] = value
            }
            guard let contentLength = Int(headers["content-length"] ?? "0"), contentLength >= 0
            else { return nil }
            let bodyStart = boundary.upperBound
            guard data.count >= bodyStart + contentLength else { return nil }
            return GatewayHTTPRequest(
                method: requestLine[0],
                path: components.path,
                headers: headers,
                body: Data(data[bodyStart..<(bodyStart + contentLength)])
            )
        }
    }

#endif
