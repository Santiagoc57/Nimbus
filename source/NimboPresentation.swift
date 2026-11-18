import Foundation

/// Google timestamps may include fractional seconds. Both variants occur in
/// Drive metadata, so UI formatting must not assume only whole seconds.
enum NimboPresentation {
    static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
    static func isRoutineActivity(operation: String, detail: String) -> Bool {
        operation == "Auto Unsync" && detail == "Liberación automática desactivada."
    }
}
