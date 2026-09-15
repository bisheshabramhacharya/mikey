import Foundation
import UserNotifications

/// Posts macOS notifications confirming Session lifecycle events. Faked in tests.
public protocol NotificationPosting: Sendable {
    func post(title: String, body: String)
}

public final class UserNotificationPoster: NotificationPosting, @unchecked Sendable {
    public init() {}

    public func post(title: String, body: String) {
        // UNUserNotificationCenter requires a real .app bundle; when run as a
        // bare `swift run` binary there is no bundle identifier to attach to.
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { granted, _ in
                guard granted else { return }
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = body
                let request = UNNotificationRequest(
                    identifier: UUID().uuidString,
                    content: content,
                    trigger: nil
                )
                UNUserNotificationCenter.current().add(request)
            }
    }
}
