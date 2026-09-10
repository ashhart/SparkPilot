import Foundation

/// What the app tells a model about drawing a chart: the fence, the shape and the limits.
enum SparkChartInstruction {
    static let sectionName = "charts"

    static var section: SparkChatInstructionSection {
        SparkChatInstructionSection(name: sectionName, text: instruction)
    }

    // The worked example below is read by the same parser the app uses, so this text cannot drift from what the app accepts.
    static let instruction = """
        When the owner asks for a chart, a graph or a plot, or when the answer is a short table of \
        numbers that is easier to see than to read, draw it as well as describing it. Write the \
        chart as a fenced block whose info string is exactly spark-chart, holding one JSON object \
        and nothing else, like this:

        ```spark-chart
        {"type":"line","title":"Requests answered","x":{"label":"Day","kind":"date"},
        "y":{"label":"Requests","unit":"req"},"series":[{"name":"Spark","points":[
        {"x":"2026-03-01","y":128},{"x":"2026-03-02","y":143},{"x":"2026-03-03","y":97}]}],
        "annotations":[{"x":"2026-03-03","text":"Model reload"}]}
        ```

        type is line, bar, area, pie, donut or scatter, and stacked:true is allowed on bar and \
        area only. title is required. x.kind is number, date or category and every x must match \
        it: a number as a JSON number, a date as an ISO-8601 string, anything else as a category \
        string. Every y is a plain number. pie and donut take one series of categories whose \
        values are not negative. Stay within 8 series, 500 points per series, 2000 points and 12 \
        annotations, and use no keys beyond the ones shown: the app refuses a whole chart rather \
        than guessing at it, and shows your JSON as text instead. Say in words what the chart \
        shows; never reply with a chart alone.
        """
}
