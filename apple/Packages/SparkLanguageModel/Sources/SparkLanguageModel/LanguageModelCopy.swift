import Foundation

/// Declare actionable provider-failure copy in compiler-extracted catalogue files.
extension LocalizedStringResource {
    static func toolDefinitionsUnsupported(_ count: Int) -> Self {
        .init(
            "provider.tools.unsupported",
            defaultValue: """
                This Spark model is reached over the allowlisted chat proxy, which \
                carries role and content messages only. The \(count) tool \
                definitions in these instructions cannot be offered to the model, \
                so it would answer as though the tools did not exist.
                """,
            comment: "The prompt offered tools the chat proxy cannot carry."
        )
    }

    static var guidedGenerationUnsupported: Self {
        .init(
            "provider.guided.unsupported",
            defaultValue: """
                This prompt asks for guided generation against a schema, and the \
                allowlisted chat proxy cannot carry one. The model would answer in \
                free-form text that does not match the type you asked for.
                """,
            comment: "The prompt asked for structured output the proxy cannot request."
        )
    }

    static var constrainedSamplingUnsupported: Self {
        .init(
            "provider.sampling.unsupported",
            defaultValue: """
                This Spark model is reached over the allowlisted chat proxy, which \
                carries temperature and a token limit only. Constrained sampling \
                cannot be expressed, and generating without it would not be what \
                was asked for. Use greedy sampling or a temperature instead.
                """,
            comment: "The prompt asked for top-k, top-p or a seed the proxy cannot send."
        )
    }
}
