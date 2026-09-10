#if os(macOS)
    import AppKit
    import Foundation
    import Network
    import Observation
    import SparkAPI
    import SparkCore
    import SparkSecurity
    @_spi(SparkInternal) import SparkTransport

    enum AnthropicResponseAdapter {
        static func responseBody(_ data: Data, modelID: String) throws -> Data {
            guard let input = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let choice = (input["choices"] as? [[String: Any]])?.first,
                let message = choice["message"] as? [String: Any]
            else { throw SparkDeveloperToolLaunchError.invalidGatewayRequest }
            var content: [[String: Any]] = []
            if let text = message["content"] as? String, !text.isEmpty {
                content.append(["type": "text", "text": text])
            }
            for call in message["tool_calls"] as? [[String: Any]] ?? [] {
                guard let function = call["function"] as? [String: Any] else { continue }
                let arguments = function["arguments"] as? String ?? "{}"
                let inputObject =
                    arguments.data(using: .utf8)
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? [:]
                content.append([
                    "type": "tool_use",
                    "id": call["id"] as? String ?? UUID().uuidString,
                    "name": function["name"] as? String ?? "tool",
                    "input": inputObject,
                ])
            }
            let usage = input["usage"] as? [String: Any] ?? [:]
            let result: [String: Any] = [
                "id": input["id"] as? String ?? "msg_\(UUID().uuidString)",
                "type": "message",
                "role": "assistant",
                "model": modelID,
                "content": content,
                "stop_reason": stopReason(choice["finish_reason"] as? String),
                "stop_sequence": NSNull(),
                "usage": [
                    "input_tokens": usage["prompt_tokens"] as? Int ?? 0,
                    "output_tokens": usage["completion_tokens"] as? Int ?? 0,
                ],
            ]
            return try JSONSerialization.data(withJSONObject: result)
        }

        static func stopReason(_ reason: String?) -> String {
            switch reason {
            case "length": "max_tokens"
            case "tool_calls": "tool_use"
            default: "end_turn"
            }
        }
    }

    final class AnthropicStreamAdapter {
        private let modelID: String
        private var buffer = Data()
        private var started = false
        private var openBlocks: Set<Int> = []
        private var toolBlockIndexes: [Int: Int] = [:]
        private var textBlockIndex: Int?
        private var nextBlockIndex = 0
        private var stopReason = "end_turn"
        private var outputTokens = 0

        init(modelID: String) { self.modelID = modelID }

        func append(_ data: Data) throws -> Data {
            buffer.append(data)
            var output = Data()
            let delimiter = Data("\n\n".utf8)
            while let boundary = buffer.range(of: delimiter) {
                let frame = Data(buffer[..<boundary.lowerBound])
                buffer.removeSubrange(..<boundary.upperBound)
                output.append(try convert(frame))
            }
            return output
        }

        func finish() -> Data {
            guard started else { return Data() }
            var output = Data()
            for index in openBlocks.sorted() {
                output.append(
                    event("content_block_stop", ["type": "content_block_stop", "index": index])
                )
            }
            output.append(
                event(
                    "message_delta",
                    [
                        "type": "message_delta",
                        "delta": ["stop_reason": stopReason, "stop_sequence": NSNull()],
                        "usage": ["output_tokens": outputTokens],
                    ]
                )
            )
            output.append(event("message_stop", ["type": "message_stop"]))
            started = false
            openBlocks.removeAll()
            return output
        }

        private func convert(_ frame: Data) throws -> Data {
            guard let text = String(data: frame, encoding: .utf8),
                let dataLine = text.components(separatedBy: "\n").first(where: {
                    $0.hasPrefix("data:")
                })
            else { return Data() }
            let payload = dataLine.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { return finish() }
            guard let data = payload.data(using: .utf8),
                let chunk = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return Data() }
            var output = Data()
            if !started {
                started = true
                output.append(
                    event(
                        "message_start",
                        [
                            "type": "message_start",
                            "message": [
                                "id": chunk["id"] as? String ?? "msg_\(UUID().uuidString)",
                                "type": "message",
                                "role": "assistant",
                                "model": modelID,
                                "content": [],
                                "stop_reason": NSNull(),
                                "stop_sequence": NSNull(),
                                "usage": ["input_tokens": 0, "output_tokens": 0],
                            ],
                        ]
                    )
                )
            }
            if let usage = chunk["usage"] as? [String: Any] {
                outputTokens = usage["completion_tokens"] as? Int ?? outputTokens
            }
            guard let choice = (chunk["choices"] as? [[String: Any]])?.first else {
                return output
            }
            if let reason = choice["finish_reason"] as? String {
                stopReason = AnthropicResponseAdapter.stopReason(reason)
            }
            let delta = choice["delta"] as? [String: Any] ?? [:]
            if let text = delta["content"] as? String, !text.isEmpty {
                let index = textBlockIndex ?? nextBlockIndex
                if textBlockIndex == nil {
                    textBlockIndex = index
                    nextBlockIndex += 1
                }
                if !openBlocks.contains(index) {
                    openBlocks.insert(index)
                    output.append(
                        event(
                            "content_block_start",
                            [
                                "type": "content_block_start",
                                "index": index,
                                "content_block": ["type": "text", "text": ""],
                            ]
                        )
                    )
                }
                output.append(
                    event(
                        "content_block_delta",
                        [
                            "type": "content_block_delta",
                            "index": index,
                            "delta": ["type": "text_delta", "text": text],
                        ]
                    )
                )
            }
            for call in delta["tool_calls"] as? [[String: Any]] ?? [] {
                let callIndex = call["index"] as? Int ?? 0
                let function = call["function"] as? [String: Any] ?? [:]
                let blockIndex: Int
                if let existing = toolBlockIndexes[callIndex] {
                    blockIndex = existing
                } else {
                    blockIndex = nextBlockIndex
                    nextBlockIndex += 1
                    toolBlockIndexes[callIndex] = blockIndex
                    openBlocks.insert(blockIndex)
                    output.append(
                        event(
                            "content_block_start",
                            [
                                "type": "content_block_start",
                                "index": blockIndex,
                                "content_block": [
                                    "type": "tool_use",
                                    "id": call["id"] as? String ?? "tool_\(UUID().uuidString)",
                                    "name": function["name"] as? String ?? "tool",
                                    "input": [:],
                                ],
                            ]
                        )
                    )
                }
                if let arguments = function["arguments"] as? String, !arguments.isEmpty {
                    output.append(
                        event(
                            "content_block_delta",
                            [
                                "type": "content_block_delta",
                                "index": blockIndex,
                                "delta": ["type": "input_json_delta", "partial_json": arguments],
                            ]
                        )
                    )
                }
            }
            return output
        }

        private func event(_ name: String, _ object: [String: Any]) -> Data {
            guard let data = try? JSONSerialization.data(withJSONObject: object) else {
                return Data()
            }
            var result = Data("event: \(name)\ndata: ".utf8)
            result.append(data)
            result.append(Data("\n\n".utf8))
            return result
        }
    }
#endif
