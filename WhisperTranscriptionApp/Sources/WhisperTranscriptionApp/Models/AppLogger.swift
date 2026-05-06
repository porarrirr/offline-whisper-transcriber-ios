import Foundation
import Combine

final class AppLogger: ObservableObject {
    static let shared = AppLogger()

    @Published private(set) var entries: [LogEntry]

    private static let storageKey = "appLogs"
    private let maxEntries = 200

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let entries = try? JSONDecoder().decode([LogEntry].self, from: data) {
            self.entries = entries
        } else {
            self.entries = []
        }
    }

    var exportText: String {
        guard !entries.isEmpty else {
            return "ログはありません"
        }
        return entries.map(\.formatted).joined(separator: "\n")
    }

    var latestPreview: String {
        entries.suffix(20).map(\.formatted).joined(separator: "\n")
    }

    static func info(_ message: String, context: String? = nil) {
        write(level: .info, message: message, context: context)
    }

    static func error(_ message: String, context: String? = nil, error: Error? = nil) {
        let detail = error.map { "\($0.localizedDescription)".isEmpty ? message : "\(message): \($0.localizedDescription)" } ?? message
        write(level: .error, message: detail, context: context)
    }

    func clear() {
        entries.removeAll()
        persist()
    }

    private static func write(level: LogLevel, message: String, context: String?) {
        DispatchQueue.main.async {
            shared.append(level: level, message: message, context: context)
        }
    }

    private func append(level: LogLevel, message: String, context: String?) {
        let entry = LogEntry(date: Date(), level: level, context: context, message: message)
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
        print(entry.formatted)
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}

struct LogEntry: Codable, Identifiable {
    let id: UUID
    let date: Date
    let level: LogLevel
    let context: String?
    let message: String

    init(id: UUID = UUID(), date: Date, level: LogLevel, context: String?, message: String) {
        self.id = id
        self.date = date
        self.level = level
        self.context = context
        self.message = message
    }

    var formatted: String {
        let timestamp = Self.formatter.string(from: date)
        let contextText = context.map { " [\($0)]" } ?? ""
        return "\(timestamp) \(level.rawValue)\(contextText) \(message)"
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()
}

enum LogLevel: String, Codable {
    case info = "INFO"
    case error = "ERROR"
}
