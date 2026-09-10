#if os(macOS)
    import Foundation
    import Testing
    @testable import SparkAppComposition

    struct SparkIntegrationRequestAdapterTests {
        private func convert(_ input: [String: Any], vision: Bool = false) throws -> [String: Any] {
            let body = try JSONSerialization.data(withJSONObject: input)
            let output = try SparkIntegrationRequestAdapter.requestBody(
                body,
                path: "/v1/messages",
                modelID: "spark-model",
                visionSupported: vision
            )
            return try #require(JSONSerialization.jsonObject(with: output) as? [String: Any])
        }

        private func messages(_ output: [String: Any]) throws -> [[String: Any]] {
            try #require(output["messages"] as? [[String: Any]])
        }

        /// Tool results answer the assistant turn, so they must precede any user text in the same message (A4).
        @Test func toolResultsPrecedeUserTextInTheSameTurn() throws {
            let output = try convert([
                "model": "claude",
                "messages": [
                    ["role": "user", "content": "list files"],
                    [
                        "role": "assistant",
                        "content": [
                            [
                                "type": "tool_use", "id": "call_1", "name": "ls",
                                "input": ["path": "."],
                            ]
                        ],
                    ],
                    [
                        "role": "user",
                        "content": [
                            ["type": "text", "text": "thanks, now summarise"],
                            ["type": "tool_result", "tool_use_id": "call_1", "content": "a.txt"],
                        ],
                    ],
                ],
            ])
            let roles = try messages(output).map { $0["role"] as? String }
            #expect(roles == ["user", "assistant", "tool", "user"])
            let tool = try messages(output)[2]
            #expect(tool["tool_call_id"] as? String == "call_1")
            #expect(tool["content"] as? String == "a.txt")
        }

        /// An image for a model without vision is refused, never silently dropped (A3).
        @Test func imagesAreRefusedWithoutVision() throws {
            let input: [String: Any] = [
                "messages": [
                    [
                        "role": "user",
                        "content": [
                            ["type": "text", "text": "what is this"],
                            [
                                "type": "image",
                                "source": [
                                    "type": "base64", "media_type": "image/png", "data": "AAAA",
                                ],
                            ],
                        ],
                    ]
                ]
            ]
            #expect(throws: SparkDeveloperToolLaunchError.self) { try convert(input) }
        }

        /// With vision the image travels as an OpenAI image part, including one inside a tool result.
        @Test func imagesAreMappedWithVision() throws {
            let output = try convert(
                [
                    "messages": [
                        [
                            "role": "user",
                            "content": [
                                ["type": "text", "text": "what is this"],
                                [
                                    "type": "image",
                                    "source": [
                                        "type": "base64", "media_type": "image/png",
                                        "data": "AAAA",
                                    ],
                                ],
                            ],
                        ],
                        [
                            "role": "assistant",
                            "content": [
                                [
                                    "type": "tool_use", "id": "shot", "name": "screenshot",
                                    "input": [:],
                                ]
                            ],
                        ],
                        [
                            "role": "user",
                            "content": [
                                [
                                    "type": "tool_result", "tool_use_id": "shot",
                                    "content": [
                                        [
                                            "type": "image",
                                            "source": [
                                                "type": "base64", "media_type": "image/jpeg",
                                                "data": "BBBB",
                                            ],
                                        ]
                                    ],
                                ]
                            ],
                        ],
                    ]
                ],
                vision: true
            )
            let first = try #require(try messages(output)[0]["content"] as? [[String: Any]])
            #expect(first[0]["type"] as? String == "text")
            #expect(
                (first[1]["image_url"] as? [String: Any])?["url"] as? String
                    == "data:image/png;base64,AAAA"
            )
            let roles = try messages(output).map { $0["role"] as? String }
            #expect(roles == ["user", "assistant", "tool", "user"])
            let shot = try #require(try messages(output)[3]["content"] as? [[String: Any]])
            #expect(
                (shot[0]["image_url"] as? [String: Any])?["url"] as? String
                    == "data:image/jpeg;base64,BBBB"
            )
        }

        /// Sampling controls the harness asked for reach the runtime (A11).
        @Test func samplingControlsAreForwarded() throws {
            let output = try convert([
                "messages": [["role": "user", "content": "hi"]],
                "top_p": 0.5,
                "stop_sequences": ["END"],
                "metadata": ["user_id": "alex"],
                "thinking": ["type": "enabled"],
            ])
            #expect(output["top_p"] as? Double == 0.5)
            #expect(output["stop"] as? [String] == ["END"])
            #expect(output["user"] as? String == "alex")
            #expect(output["thinking"] == nil)
        }
    }
#endif
