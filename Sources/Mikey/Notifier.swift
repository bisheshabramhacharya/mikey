import AppKit
import Foundation
import UserNotifications

/// Posts macOS notifications confirming Session lifecycle events. Faked in tests.
public protocol NotificationPosting: Sendable {
    func post(title: String, body: String)
    /// Posts a notification carrying a file to reveal — the poster puts the
    /// path in `userInfo` and activating the notification reveals it in
    /// Finder (SPEC §6). `nil` behaves like `post(title:body:)`.
    func post(title: String, body: String, reveal url: URL?)
}

public extension NotificationPosting {
    /// Default: drop the payload so existing posters/fakes keep working.
    func post(title: String, body: String, reveal url: URL?) {
        post(title: title, body: body)
    }
}

/// `userInfo` key carrying the transcript path a "Transcript ready"
/// notification reveals on activation.
public enum NotificationUserInfo {
    public static let filePath = "filePath"
}

public final class UserNotificationPoster: NSObject, NotificationPosting, UNUserNotificationCenterDelegate, @unchecked Sendable {
    public override init() {
        super.init()
    }

    public func post(title: String, body: String) {
        post(title: title, body: body, reveal: nil)
    }

    public func post(title: String, body: String, reveal url: URL?) {
        // UNUserNotificationCenter requires a real .app bundle; when run as a
        // bare `swift run` binary there is no bundle identifier to attach to.
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            if let url {
                content.userInfo[NotificationUserInfo.filePath] =
                    url.path(percentEncoded: false)
            }
            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request)
        }
    }

    /// Activation → reveal the file the notification carries (SPEC §6).
    nonisolated public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        guard let path = response.notification.request.content
            .userInfo[NotificationUserInfo.filePath] as? String
        else { return }
        let url = URL(fileURLWithPath: path)
        Task { @MainActor in
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    /// Show banners even while the app is frontmost — a menu-bar agent counts
    /// as frontmost whenever its menu is open.
    nonisolated public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
