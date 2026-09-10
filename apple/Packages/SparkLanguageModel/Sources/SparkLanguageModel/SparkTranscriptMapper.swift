import Foundation
import FoundationModels
import SparkAPI

/// Map supported transcript content and options to the allowlisted request without silently dropping unsupported input (§39.6/§39.7).
public enum SparkTranscriptMapper {
    public static func map(
        transcript: Transcript,
        generationOptions: GenerationOptions
    ) throws -> ChatCompletionRequest {
        var mapped: [ChatMessage] = []
        // Honor generation options attached to the prompt being answered.
        var promptOptions: [GenerationOptions] = []
        for entry in transcript {
            mapped.append(contentsOf: try messages(forEntry: entry))
            if case .prompt(let prompt) = entry {
                promptOptions.append(prompt.options)
            }
        }
        guard !mapped.isEmpty else {
            throw SparkInferenceError.unsupportedContent(
                String(localized: "transcript contains no mappable entries")
            )
        }

        var request = ChatCompletionRequest(model: "", messages: mapped)
        request.stream = true
        request.streamOptionsIncludeUsage = true
        // Apply request defaults followed only by the current prompt's overrides, excluding historical turn settings.
        try apply(generationOptions: generationOptions, to: &request)
        if let current = promptOptions.last {
            try apply(generationOptions: current, to: &request)
        }
        return request
    }

    /// Use the caller's resolved proxy model identifier.
    public static func map(
        transcript: Transcript,
        generationOptions: GenerationOptions,
        modelID: String
    ) throws -> ChatCompletionRequest {
        var request = try map(
            transcript: transcript,
            generationOptions: generationOptions
        )
        request.model = modelID
        return request
    }

    // MARK: - Transcript entries (§39.6)

    private static func messages(forEntry entry: Transcript.Entry) throws -> [ChatMessage] {
        switch entry {
        case .instructions(let instructions):
            // Reject unsupported tool declarations before generation rather than waiting for a later tool call.
            guard instructions.toolDefinitions.isEmpty else {
                throw SparkInferenceError.unsupportedCapability(
                    String(
                        localized: .toolDefinitionsUnsupported(
                            instructions.toolDefinitions.count
                        )
                    )
                )
            }
            return [
                ChatMessage(
                    role: "system",
                    content: try text(of: instructions.segments, kind: "instructions")
                )
            ]
        case .prompt(let prompt):
            // Reject response schemas the proxy cannot represent instead of returning unconstrained prose.
            guard prompt.responseFormat == nil else {
                throw SparkInferenceError.unsupportedCapability(
                    String(localized: .guidedGenerationUnsupported)
                )
            }
            return [
                ChatMessage(
                    role: "user",
                    content: try text(of: prompt.segments, kind: "prompt")
                )
            ]
        case .response(let response):
            return [
                ChatMessage(
                    role: "assistant",
                    content: try text(of: response.segments, kind: "response")
                )
            ]
        case .toolCalls:
            // Reject structured tool calls that the role-and-content proxy cannot represent faithfully.
            throw SparkInferenceError.unsupportedContent(
                String(
                    localized:
                        "tool-call transcript entries require a tool-calling-capable proxy surface"
                )
            )
        case .toolOutput:
            throw SparkInferenceError.unsupportedContent(
                String(
                    localized:
                        "tool-output transcript entries require a tool-calling-capable proxy surface"
                )
            )
        @unknown default:
            throw SparkInferenceError.unsupportedContent(
                String(
                    localized: "transcript entry kind added by a newer Foundation Models revision"
                )
            )
        }
    }

    /// Reject structured content segments when plain-text mapping would lose information (§39.6).
    private static func text(of segments: [Transcript.Segment], kind: String) throws -> String {
        var parts: [String] = []
        for segment in segments {
            switch segment {
            case .text(let text):
                parts.append(text.content)
            case .structure:
                throw SparkInferenceError.unsupportedContent(
                    "structured \(kind) segments are not expressible over the chat proxy"
                )
            @unknown default:
                throw SparkInferenceError.unsupportedContent(
                    String(localized: "segment kind added by a newer Foundation Models revision")
                )
            }
        }
        return parts.joined(separator: "\n")
    }

    // MARK: - Generation options (§39.7)

    /// Reject unsupported sampling options rather than silently losing caller constraints at the allowlisted proxy (§39.7).
    public static func apply(
        generationOptions: GenerationOptions,
        to request: inout ChatCompletionRequest
    ) throws {
        if let temperature = generationOptions.temperature {
            request.temperature = temperature
        }
        if let sampling = generationOptions.sampling {
            // Accept only representable sampling modes and reject unknown future variants.
            guard sampling == .greedy else {
                throw SparkInferenceError.unsupportedCapability(
                    String(localized: .constrainedSamplingUnsupported)
                )
            }
            request.temperature = 0
        }
        if let maximum = generationOptions.maximumResponseTokens {
            request.maxTokens = maximum
        }
    }
}
