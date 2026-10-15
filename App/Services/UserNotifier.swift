import Foundation
import os
@preconcurrency import UserNotifications
import WakeUpCore

@MainActor
final class UserNotifier: NSObject, Notifier, UNUserNotificationCenterDelegate {
    private static let endingSoonID = "ending-soon"
    private static let categoryID = "ENDING_SOON"

    var onExtend: ((Int) -> Void)?
    private let center = UNUserNotificationCenter.current()
    private let log = Logger(subsystem: "io.github.alexsarva.WakeUp", category: "ui")

    override init() {
        super.init()
        center.delegate = self
        let actions = [
            UNNotificationAction(identifier: "extend30", title: String(localized: "+30 min"), options: []),
            UNNotificationAction(identifier: "extend60", title: String(localized: "+1 h"), options: []),
        ]
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.categoryID, actions: actions, intentIdentifiers: [], options: [])
        ])
    }

    func post(_ n: WakeNotification) {
        let content = UNMutableNotificationContent()
        var id = UUID().uuidString
        switch n {
        case .endingSoon:
            id = Self.endingSoonID
            content.title = String(localized: "WakeUp ends soon")
            content.body = String(localized: "Your Mac will be allowed to sleep in 5 minutes.")
            content.categoryIdentifier = Self.categoryID
        case .sessionEnded:
            content.title = String(localized: "WakeUp turned off")
            content.body = String(localized: "Your Mac can sleep again.")
        case .lidModeSuspended:
            content.title = String(localized: "Closed-lid mode suspended")
            content.body = String(localized: "A safety rule turned it off.")
        case .assertionFailed:
            content.title = String(localized: "WakeUp could not start")
            content.body = String(localized: "The sleep assertion failed.")
        }
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        let center = self.center
        let log = self.log
        center.getNotificationSettings { settings in
            let add: @Sendable () -> Void = {
                center.add(request) { error in
                    if let error { log.error("notification add failed: \(error.localizedDescription, privacy: .public)") }
                }
            }
            if settings.authorizationStatus == .notDetermined {
                center.requestAuthorization(options: [.alert, .sound]) { granted, error in
                    if let error { log.error("notification authorization failed: \(error.localizedDescription, privacy: .public)") }
                    if granted { add() } else { log.info("notification authorization not granted") }
                }
            } else {
                add()
            }
        }
    }

    func cancelEndingSoon() {
        center.removePendingNotificationRequests(withIdentifiers: [Self.endingSoonID])
        center.removeDeliveredNotifications(withIdentifiers: [Self.endingSoonID])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let minutes: Int?
        switch response.actionIdentifier {
        case "extend30": minutes = 30
        case "extend60": minutes = 60
        default: minutes = nil
        }
        guard let minutes else { return }
        await MainActor.run { self.onExtend?(minutes) }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
