#if os(macOS)
    import AppKit
    import Foundation
    import Network
    import Observation
    import SparkAPI
    import SparkCore
    import SparkSecurity
    @_spi(SparkInternal) import SparkTransport

    enum SparkIntegrationRequestAdapter {
        static func wantsStream(_ body: Data) -> Bool {
            (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["stream"] as? Bool
                ?? false
        }

        static func requestBody(
            _ body: Data,
            path: String,
            modelID: String,
            visionSupported: Bool = false
        ) throws -> Data {
            guard var object = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                throw SparkDeveloperToolLaunchError.invalidGatewayRequest
            }
            object["model"] = modelID
            if path == "/v1/messages" {
                object = try anthropicToOpenAI(object, visionSupported: visionSupported)
            }
            return try JSONSerialization.data(withJSONObject: object)
        }

        private static func anthropicToOpenAI(
            _ input: [String: Any],
            visionSupported: Bool
        ) throws -> [String: Any] {
            var messages: [[String: Any]] = []
            if let system = textContent(input["system"]), !system.isEmpty {
                messages.append(["role": "system", "content": system])
            }
            for raw in input["messages"] as? [[String: Any]] ?? [] {
                let role = raw["role"] as? String ?? "user"
                if let text = raw["content"] as? String {
                    messages.append(["role": role, "content": text])
                    continue
                }
                let blocks = raw["content"] as? [[String: Any]] ?? []
                if role == "assistant" {
                    let text = textContent(blocks) ?? ""
                    var assistant: [String: Any] = ["role": role, "content": text]
                    let toolCalls = blocks.compactMap { block -> [String: Any]? in
                        guard block["type"] as? String == "tool_use" else { return nil }
                        return [
                            "id": block["id"] as? String ?? "tool_\(UUID().uuidString)",
                            "type": "function",
                            "function": [
                                "name": block["name"] as? String ?? "tool",
                                "arguments": jsonString(block["input"] ?? [:]),
                            ],
                        ]
                    }
                    if !toolCalls.isEmpty { assistant["tool_calls"] = toolCalls }
                    if !text.isEmpty || !toolCalls.isEmpty { messages.append(assistant) }
                    continue
                }
                // Tool results answer the previous assistant turn, so they precede any new user text.
                for block in blocks where block["type"] as? String == "tool_result" {
                    let content = try content(block["content"], visionSupported: visionSupported)
                    messages.append([
                        "role": "tool",
                        "tool_call_id": block["tool_use_id"] as? String ?? "tool",
                        "content": content.text,
                    ])
                    if !content.images.isEmpty {
                        messages.append(["role": "user", "content": content.images])
                    }
                }
                let content = try content(
                    blocks.filter { $0["type"] as? String != "tool_result" },
                    visionSupported: visionSupported
                )
                if let parts = content.parts {
                    messages.append(["role": role, "content": parts])
                }
            }
            var output: [String: Any] = [
                "model": input["model"] as? String ?? "spark-model",
                "messages": messages,
                "stream": input["stream"] as? Bool ?? false,
            ]
            if let maxTokens = input["max_tokens"] { output["max_tokens"] = maxTokens }
            if let temperature = input["temperature"] { output["temperature"] = temperature }
            if let topP = input["top_p"] { output["top_p"] = topP }
            if let stops = input["stop_sequences"] as? [String], !stops.isEmpty {
                output["stop"] = stops
            }
            if let user = (input["metadata"] as? [String: Any])?["user_id"] as? String {
                output["user"] = user
            }
            // thinking, cache_control and tool_choice have no equivalent on the runtime's chat route and are not forwarded.
            if let tools = input["tools"] as? [[String: Any]] {
                output["tools"] = tools.map { tool in
                    [
                        "type": "function",
                        "function": [
                            "name": tool["name"] as? String ?? "tool",
                            "description": tool["description"] as? String ?? "",
                            "parameters": tool["input_schema"] as? [String: Any] ?? [:],
                        ],
                    ]
                }
            }
            return output
        }

        private struct Content {
            var text: String
            var images: [[String: Any]]

            // A string when only text was present, an OpenAI parts array when images were, nil when empty.
            var parts: Any? {
                if images.isEmpty { return text.isEmpty ? nil : text }
                var parts: [[String: Any]] = []
                if !text.isEmpty { parts.append(["type": "text", "text": text]) }
                return parts + images
            }
        }

        private static func content(_ value: Any?, visionSupported: Bool) throws -> Content {
            if let text = value as? String { return Content(text: text, images: []) }
            guard let blocks = value as? [[String: Any]] else {
                return Content(text: "", images: [])
            }
            var texts: [String] = []
            var images: [[String: Any]] = []
            for block in blocks {
                switch block["type"] as? String {
                case "text":
                    if let text = block["text"] as? String { texts.append(text) }
                case "image":
                    // Refuse rather than drop: a silently missing image yields confident answers about nothing.
                    guard visionSupported else {
                        throw SparkDeveloperToolLaunchError.unsupportedContent(
                            String(
                                localized:
                                    "This model cannot read images because vision is not enabled; remove the image or choose a vision model."
                            )
                        )
                    }
                    guard let url = imageURL(block["source"]) else {
                        throw SparkDeveloperToolLaunchError.unsupportedContent(
                            String(
                                localized:
                                    "The request carried an image in a form Spark cannot read."
                            )
                        )
                    }
                    images.append(["type": "image_url", "image_url": ["url": url]])
                default:
                    continue
                }
            }
            return Content(text: texts.joined(separator: "\n"), images: images)
        }

        private static func imageURL(_ source: Any?) -> String? {
            guard let source = source as? [String: Any] else { return nil }
            switch source["type"] as? String {
            case "base64":
                guard let mediaType = source["media_type"] as? String,
                    mediaType.hasPrefix("image/"),
                    let data = source["data"] as? String, !data.isEmpty
                else { return nil }
                return "data:\(mediaType);base64,\(data)"
            case "url":
                guard let url = source["url"] as? String, url.lowercased().hasPrefix("https://")
                else { return nil }
                return url
            default:
                return nil
            }
        }

        private static func textContent(_ value: Any?) -> String? {
            if let text = value as? String { return text }
            guard let blocks = value as? [[String: Any]] else { return nil }
            return blocks.compactMap { block in
                guard block["type"] as? String == "text" else { return nil }
                return block["text"] as? String
            }.joined(separator: "\n")
        }

        private static func jsonString(_ value: Any) -> String {
            guard JSONSerialization.isValidJSONObject(value),
                let data = try? JSONSerialization.data(withJSONObject: value)
            else { return "{}" }
            return String(decoding: data, as: UTF8.self)
        }
    }

#endif
