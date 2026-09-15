import SwiftUI
import SwiftData

struct TranscriptChatView: View {
    let record: TranscriptionRecord
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var messages: [TranscriptChatMessage] = []
    @State private var question = ""
    @State private var questionFieldID = UUID()
    @State private var isResponding = false
    @State private var errorMessage: String?
    @FocusState private var isQuestionFocused: Bool

    init(record: TranscriptionRecord) {
        self.record = record
        _messages = State(initialValue: record.chatMessages)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            if messages.isEmpty {
                                ContentUnavailableView(
                                    "Ask about this transcript",
                                    systemImage: "sparkles",
                                    description: Text("Apple Intelligence answers from the transcription context.")
                                )
                                .padding(.top, 60)
                            }
                            ForEach(messages) { message in
                                chatBubble(message)
                                    .id(message.id)
                            }
                            if isResponding { ProgressView().padding() }
                            if let errorMessage {
                                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                                    .font(.footnote)
                                    .foregroundStyle(Theme.rec)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding()
                    }
                    .contentShape(Rectangle())
                    .simultaneousGesture(
                        TapGesture().onEnded {
                            isQuestionFocused = false
                        }
                    )
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: messages.count) { _, _ in
                        if let id = messages.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                    }
                }

                HStack(alignment: .bottom, spacing: 10) {
                    TextField("Ask a question…", text: $question, axis: .vertical)
                        .id(questionFieldID)
                        .focused($isQuestionFocused)
                        .lineLimit(1...5)
                        .textFieldStyle(.roundedBorder)
                        .submitLabel(.send)
                        .onSubmit(send)
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(Theme.amber)
                    }
                    .disabled(isResponding || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding()
                .background(.bar)
            }
            .background(Theme.background)
            .navigationTitle(record.displayTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
    }

    @ViewBuilder
    private func chatBubble(_ message: TranscriptChatMessage) -> some View {
        Group {
            if message.role == .assistant {
                ChatMarkdownView(source: message.text)
            } else {
                Text(message.text)
                    .font(Theme.sans(15))
            }
        }
            .foregroundStyle(message.role == .user ? Theme.onAmber : Theme.textPrimary)
            .padding(12)
            .background(message.role == .user ? Theme.amberFill : Theme.panel)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
            .textSelection(.enabled)
    }

    private func send() {
        let submitted = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !submitted.isEmpty, !isResponding else { return }

        // 日本語IMEの確定イベントが送信後に古い文字列を書き戻すことがあるため、
        // フォーカスを外したうえでTextField自体も新しいidentityで作り直す。
        isQuestionFocused = false
        question = ""
        questionFieldID = UUID()
        errorMessage = nil
        let priorConversation = messages
        let conversationWithQuestion = priorConversation + [
            TranscriptChatMessage(role: .user, text: submitted)
        ]
        guard persist(conversationWithQuestion) else { return }
        messages = conversationWithQuestion
        isResponding = true
        let transcript = record.text
        let duration = record.duration
        Task {
            do {
                let answer = try await AppleIntelligenceService.shared.answer(
                    question: submitted,
                    transcript: transcript,
                    duration: duration,
                    conversation: priorConversation
                )
                await MainActor.run {
                    let conversationWithAnswer = messages + [
                        TranscriptChatMessage(role: .assistant, text: answer)
                    ]
                    if persist(conversationWithAnswer) {
                        messages = conversationWithAnswer
                    }
                    isResponding = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isResponding = false
                }
            }
        }
    }

    @MainActor
    private func persist(_ updatedMessages: [TranscriptChatMessage]) -> Bool {
        let previousJSON = record.chatMessagesJSON
        do {
            try record.updateChatMessages(updatedMessages)
            try modelContext.save()
            return true
        } catch {
            record.chatMessagesJSON = previousJSON
            errorMessage = String(localized: "Failed to save chat history") + ": \(error.localizedDescription)"
            return false
        }
    }
}

struct ChatMarkdownView: View {
    let source: String

    private var blocks: [ChatMarkdownBlock] {
        ChatMarkdownParser.parse(source)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tint(Theme.amber)
    }

    @ViewBuilder
    private func blockView(_ block: ChatMarkdownBlock) -> some View {
        switch block {
        case .paragraph(let text):
            Text(inlineMarkdown(text))
                .font(Theme.sans(15))
                .fixedSize(horizontal: false, vertical: true)
        case .heading(let level, let text):
            Text(inlineMarkdown(text))
                .font(Theme.sans(headingSize(for: level), weight: .bold))
                .fixedSize(horizontal: false, vertical: true)
        case .unorderedItem(let indentation, let text):
            markdownListRow(marker: "•", indentation: indentation, text: text)
        case .orderedItem(let indentation, let number, let text):
            markdownListRow(marker: "\(number).", indentation: indentation, text: text)
        case .quote(let text):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Theme.textSecondary)
                    .frame(width: 3)
                Text(inlineMarkdown(text))
                    .font(Theme.sans(15))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .code(let language, let code):
            VStack(alignment: .leading, spacing: 5) {
                if let language, !language.isEmpty {
                    Text(language)
                        .font(Theme.sans(11, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
                ScrollView(.horizontal) {
                    Text(verbatim: code)
                        .font(.system(size: 13, design: .monospaced))
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .padding(10)
            .background(Theme.background.opacity(0.7))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        case .divider:
            Divider()
        }
    }

    private func markdownListRow(marker: String, indentation: Int, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(marker)
                .font(Theme.sans(15, weight: .semibold))
                .frame(minWidth: 14, alignment: .trailing)
            Text(inlineMarkdown(text))
                .font(Theme.sans(15))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, CGFloat(indentation) * 16)
    }

    private func inlineMarkdown(_ text: String) -> AttributedString {
        do {
            return try AttributedString(
                markdown: text,
                options: .init(
                    interpretedSyntax: .inlineOnlyPreservingWhitespace,
                    failurePolicy: .returnPartiallyParsedIfPossible
                )
            )
        } catch {
            return AttributedString("Markdown rendering failed: \(error.localizedDescription)")
        }
    }

    private func headingSize(for level: Int) -> CGFloat {
        switch level {
        case 1: 24
        case 2: 21
        case 3: 18
        default: 16
        }
    }
}

enum ChatMarkdownBlock: Equatable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case unorderedItem(indentation: Int, text: String)
    case orderedItem(indentation: Int, number: String, text: String)
    case quote(String)
    case code(language: String?, text: String)
    case divider
}

enum ChatMarkdownParser {
    static func parse(_ source: String) -> [ChatMarkdownBlock] {
        var blocks: [ChatMarkdownBlock] = []
        var paragraphLines: [String] = []
        var codeLines: [String] = []
        var codeLanguage: String?
        var codeFence: String?

        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            blocks.append(.paragraph(paragraphLines.joined(separator: "\n")))
            paragraphLines.removeAll(keepingCapacity: true)
        }

        for line in source.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if let activeFence = codeFence {
                if trimmed.hasPrefix(activeFence) {
                    blocks.append(.code(language: codeLanguage, text: codeLines.joined(separator: "\n")))
                    codeLines.removeAll(keepingCapacity: true)
                    codeLanguage = nil
                    codeFence = nil
                } else {
                    codeLines.append(line)
                }
                continue
            }

            if let fence = fencePrefix(in: trimmed) {
                flushParagraph()
                codeFence = fence
                let languageStart = trimmed.index(trimmed.startIndex, offsetBy: fence.count)
                let language = trimmed[languageStart...].trimmingCharacters(in: .whitespaces)
                codeLanguage = language.isEmpty ? nil : language
            } else if trimmed.isEmpty {
                flushParagraph()
            } else if let heading = heading(in: trimmed) {
                flushParagraph()
                blocks.append(.heading(level: heading.level, text: heading.text))
            } else if ["---", "***", "___"].contains(trimmed) {
                flushParagraph()
                blocks.append(.divider)
            } else if trimmed.hasPrefix("> ") {
                flushParagraph()
                blocks.append(.quote(String(trimmed.dropFirst(2))))
            } else if let item = unorderedItem(in: line) {
                flushParagraph()
                blocks.append(.unorderedItem(indentation: item.indentation, text: item.text))
            } else if let item = orderedItem(in: line) {
                flushParagraph()
                blocks.append(.orderedItem(
                    indentation: item.indentation,
                    number: item.number,
                    text: item.text
                ))
            } else {
                paragraphLines.append(line)
            }
        }

        flushParagraph()
        if codeFence != nil {
            blocks.append(.code(language: codeLanguage, text: codeLines.joined(separator: "\n")))
        }
        return blocks
    }

    private static func fencePrefix(in line: String) -> String? {
        if line.hasPrefix("```") { return "```" }
        if line.hasPrefix("~~~") { return "~~~" }
        return nil
    }

    private static func heading(in line: String) -> (level: Int, text: String)? {
        let markerCount = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(markerCount) else { return nil }
        let textStart = line.index(line.startIndex, offsetBy: markerCount)
        guard line[textStart...].hasPrefix(" ") else { return nil }
        return (markerCount, String(line[line.index(after: textStart)...]))
    }

    private static func unorderedItem(in line: String) -> (indentation: Int, text: String)? {
        let content = line.drop(while: { $0 == " " || $0 == "\t" })
        guard content.count >= 2,
              ["-", "*", "+"].contains(String(content.first!)),
              content.dropFirst().first == " " else { return nil }
        return (indentationLevel(in: line), String(content.dropFirst(2)))
    }

    private static func orderedItem(in line: String) -> (indentation: Int, number: String, text: String)? {
        let content = line.drop(while: { $0 == " " || $0 == "\t" })
        guard let dot = content.firstIndex(of: ".") else { return nil }
        let number = content[..<dot]
        guard !number.isEmpty,
              number.allSatisfy(\.isNumber),
              content[content.index(after: dot)...].hasPrefix(" ") else { return nil }
        let textStart = content.index(dot, offsetBy: 2)
        return (indentationLevel(in: line), String(number), String(content[textStart...]))
    }

    private static func indentationLevel(in line: String) -> Int {
        let whitespace = line.prefix(while: { $0 == " " || $0 == "\t" })
        let width = whitespace.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        return max(0, width / 2)
    }
}
