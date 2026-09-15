import SwiftUI

struct TranscriptChatView: View {
    let record: TranscriptionRecord
    @Environment(\.dismiss) private var dismiss
    @State private var messages: [TranscriptChatMessage] = []
    @State private var question = ""
    @State private var isResponding = false
    @State private var errorMessage: String?

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
                    .onChange(of: messages.count) { _, _ in
                        if let id = messages.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                    }
                }

                HStack(alignment: .bottom, spacing: 10) {
                    TextField("Ask a question…", text: $question, axis: .vertical)
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
        question = ""
        errorMessage = nil
        let priorConversation = messages
        messages.append(TranscriptChatMessage(role: .user, text: submitted))
        isResponding = true
        Task {
            do {
                let answer = try await AppleIntelligenceService.shared.answer(
                    question: submitted,
                    transcript: record.text,
                    conversation: priorConversation
                )
                await MainActor.run {
                    messages.append(TranscriptChatMessage(role: .assistant, text: answer))
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
}
