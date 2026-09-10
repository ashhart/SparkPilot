import Foundation
import SparkDesignSystem
import SwiftUI
import UniformTypeIdentifiers

#if os(iOS)
    import UIKit
#elseif os(macOS)
    import AppKit
#endif

@MainActor
struct SparkAssistantMessageView: View {
    let message: SparkChatMessage
    let showsActions: Bool
    let onRevealActions: () -> Void
    let onReply: () -> Void
    let onReadAloud: () -> Void
    let onActions: () -> Void
    let onInspectReasoning: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if message.hasReasoning {
                SparkChatThinkingView(message: message, onInspect: onInspectReasoning)
            }
            if message.hasAnswer {
                SparkChatMarkdownView(content: message.content)
                    .contentShape(Rectangle())
                    .simultaneousGesture(TapGesture().onEnded { _ in onRevealActions() })
            } else if message.responsePhase == .waiting {
                HStack(spacing: 9) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for Spark").font(.callout).foregroundStyle(.secondary)
                }
                .frame(minHeight: 32)
            } else if message.responsePhase == .complete {
                Text("No answer was returned.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if message.hasAnswer,
                message.responsePhase == .cancelled || message.responsePhase == .failed
            {
                Text(message.responsePhase == .cancelled ? "Stopped" : "Partial response")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if message.wasCutShortByContext {
                Label("Cut short by the context limit", systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.orange)
            }
            if !message.sources.isEmpty {
                DisclosureGroup(String(localized: "Sources")) {
                    ForEach(Array(message.sources.enumerated()), id: \.offset) { _, source in
                        if let url = URL(string: source.url), url.scheme == "https" {
                            Link(destination: url) {
                                Label(source.title ?? url.host() ?? source.url, systemImage: "link")
                                    .font(.footnote).padding(.vertical, 6)
                            }
                        }
                    }
                }
            }
            if message.hasAnswer, message.responsePhase != .answering, showsActions {
                HStack(spacing: 4) {
                    Button(action: onReply) {
                        Image(systemName: "arrowshape.turn.up.left")
                            .font(.callout)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Reply")
                    SparkChatCopyButton(
                        content: message.content,
                        label: String(localized: "Copy response")
                    )
                    ShareLink(item: message.content) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.callout)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Share response")
                    Button(action: onReadAloud) {
                        Image(systemName: "speaker.wave.2")
                            .font(.callout)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Read aloud")
                    Button(action: onActions) {
                        Image(systemName: "checklist").frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Use response for personal actions")
                    Spacer(minLength: 8)
                    // Two short lines rather than one that truncates whichever number loses.
                    VStack(alignment: .trailing, spacing: 1) {
                        if let usage = SparkChatUsageFormat.responseFooter(for: message) {
                            Text(usage).monospacedDigit().lineLimit(1)
                        }
                        if let modelName = message.modelName {
                            Text(modelName).lineLimit(1)
                        }
                    }
                    .font(.caption2)
                }
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("spark.chat.reply.\(message.id.uuidString)")
        .accessibilityActions {
            if message.hasAnswer, message.responsePhase != .answering {
                if !showsActions {
                    Button("Show response actions", action: onRevealActions)
                }
                Button("Reply", action: onReply)
            }
        }
        .contextMenu {
            if message.hasAnswer, message.responsePhase != .answering {
                Button("Reply", systemImage: "arrowshape.turn.up.left", action: onReply)
                if !showsActions {
                    Button("Show response actions", action: onRevealActions)
                }
            }
        }
    }
}

@MainActor
struct SparkChatThinkingView: View {
    let message: SparkChatMessage
    let onInspect: () -> Void
    @State private var isExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                onInspect()
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    if message.responsePhase == .thinking {
                        ProgressView().controlSize(.mini)
                    }
                    if message.responsePhase == .thinking {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            thinkingLabel(at: context.date)
                        }
                    } else {
                        thinkingLabel(at: .now)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(isExpanded ? "Hide model reasoning" : "Show model reasoning")
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            if isExpanded {
                SparkChatMarkdownView(content: message.reasoning, isReasoning: true)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 16)
                    .padding(.vertical, 4)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(ChatStyle.border).frame(width: 2)
                    }
            }
        }
    }

    @ViewBuilder
    private func thinkingLabel(at date: Date) -> some View {
        if message.responsePhase == .thinking {
            HStack(spacing: 6) {
                Text("Thinking")
                if let elapsed = duration(at: date) {
                    Text(elapsed).monospacedDigit().foregroundStyle(.tertiary)
                }
            }
        } else if message.responsePhase == .cancelled, !message.hasAnswer {
            Text("Thinking stopped")
        } else if message.responsePhase == .failed, !message.hasAnswer {
            Text("Thinking interrupted")
        } else if let seconds = message.reasoningElapsed(at: date), seconds < 1 {
            Text("Thought briefly")
        } else if let elapsed = duration(at: date) {
            Text(.chatThoughtFor(elapsed))
        } else {
            Text("Thought process")
        }
    }

    private func duration(at date: Date) -> String? {
        guard let elapsed = message.reasoningElapsed(at: date), elapsed >= 1 else { return nil }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.zeroFormattingBehavior = .dropAll
        return formatter.string(from: elapsed.rounded(.down))
    }
}

struct SparkChatMarkdownView: View {
    let content: String
    var isReasoning = false
    @State private var chartedTables: Set<Int> = []

    private var bodyFont: Font { isReasoning ? .callout : .body }

    var body: some View {
        VStack(alignment: .leading, spacing: isReasoning ? 10 : 14) {
            ForEach(Array(SparkChatMarkdown.blocks(in: content).enumerated()), id: \.offset) {
                offset,
                block in
                switch block {
                case .paragraph(let text):
                    paragraph(text, at: offset)
                case .heading(let level, let text):
                    inline(text)
                        .font(
                            isReasoning
                                ? .callout.weight(.semibold)
                                : (level <= 2 ? .title3.weight(.semibold) : .headline)
                        )
                        .padding(.top, 5)
                        .accessibilityAddTraits(.isHeader)
                case .listItem(let marker, let text):
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(marker).foregroundStyle(.secondary)
                        inline(text).font(bodyFont).lineSpacing(4)
                    }
                case .quote(let text):
                    inline(text)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 14)
                        .overlay(alignment: .leading) {
                            Rectangle().fill(ChatStyle.border).frame(width: 2)
                        }
                case .code(let language, let text):
                    codeBlock(text, language: language)
                case .chart(.ready(let spec)):
                    SparkChatChartView(spec: spec)
                case .chart(.pending(let source)):
                    refusedChart(source, note: String(localized: "The chart is still arriving."))
                case .chart(.invalid(let source, let reason)):
                    refusedChart(
                        source,
                        note: String(localized: .chartShownAsText(reason.message))
                    )
                case .divider:
                    Divider().padding(.vertical, 4)
                }
            }
        }
        .font(bodyFont)
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    private func inline(_ text: String) -> Text {
        Text(SparkChatMarkdown.inline(text))
    }

    /// A table is drawn as a table, and a table of numbers can be charted without asking again.
    @ViewBuilder
    private func paragraph(_ text: String, at offset: Int) -> some View {
        if let table = text.contains("|") ? SparkChatTable.first(in: text) : nil,
            table.rows.count <= SparkChatTable.renderedRows
        {
            let lines = text.components(separatedBy: "\n")
            prose(lines[..<table.lines.lowerBound])
            SparkChatTableView(table: table)
            prose(lines[table.lines.upperBound...])
            chartAction(SparkChatTable.chart(table), at: offset)
        } else {
            inline(text).font(bodyFont).lineSpacing(5)
        }
    }

    @ViewBuilder
    private func prose(_ lines: ArraySlice<String>) -> some View {
        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { inline(text).font(bodyFont).lineSpacing(5) }
    }

    @ViewBuilder
    private func chartAction(_ chart: SparkChartSpec?, at offset: Int) -> some View {
        if let chart {
            Button {
                if chartedTables.contains(offset) {
                    chartedTables.remove(offset)
                } else {
                    chartedTables.insert(offset)
                }
            } label: {
                Label(
                    chartedTables.contains(offset)
                        ? String(localized: "Hide chart") : String(localized: "Chart this"),
                    systemImage: "chart.xyaxis.line"
                )
                .font(.callout)
                .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            if chartedTables.contains(offset) { SparkChatChartView(spec: chart) }
        }
    }

    /// A chart the app would not draw keeps every character the model wrote, and says why in one line.
    private func refusedChart(_ source: String, note: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            codeBlock(source, language: SparkChatChartFence.info)
            Text(note).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func codeBlock(_ code: String, language: String?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? String(localized: "Code"))
                    .font(.caption.weight(.medium))
                Spacer()
                SparkChatCopyButton(content: code, label: String(localized: "Copy code"))
            }
            .foregroundStyle(.secondary)
            .padding(.leading, 16)
            .padding(.trailing, 4)
            Divider().overlay(ChatStyle.border)
            ScrollView(.horizontal) {
                Text(code)
                    .font(.system(.callout, design: .monospaced))
                    .lineSpacing(4)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(16)
            }
        }
        .background(ChatStyle.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(ChatStyle.border))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

@MainActor
struct SparkChatCopyButton: View {
    let content: String
    let label: String
    var showsLabel = false
    @State private var copied = false

    var body: some View {
        Button {
            #if os(iOS)
                UIPasteboard.general.string = content
            #elseif os(macOS)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(content, forType: .string)
            #endif
            copied = true
        } label: {
            HStack {
                Image(systemName: copied ? "checkmark" : "document.on.document")
                    .font(.callout)
                    .frame(width: 44, height: 44)
                if showsLabel { Text(verbatim: copied ? String(localized: "Copied") : label) }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(copied ? Text("Copied") : Text(label))
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}
