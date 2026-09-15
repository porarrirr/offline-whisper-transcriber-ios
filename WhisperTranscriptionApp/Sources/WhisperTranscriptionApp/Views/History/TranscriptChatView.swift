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

    private func chatBubble(_ message: TranscriptChatMessage) -> some View {
        Text(message.text)
            .font(Theme.sans(15))
            .foregroundStyle(message.role == .user ? Theme.onAmber : Theme.textPrimary)
            .padding(12)
            .background(message.role == .user ? Theme.amberFill : Theme.panel)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
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
