import Foundation
import UserNotifications

/**
 * [INPUT]: 依赖 UserNotifications 调度阅读倒计时完成提醒，依赖阅读计时记录 ID 做请求去重
 * [OUTPUT]: 对外提供 ReadingTimerCountdownNotificationScheduler，支持安排、取消单段阅读倒计时完成通知
 * [POS]: Infra/Notifications 系统通知桥接层，被 ReadingTimerViewModel 在倒计时运行、暂停、停止、保存与放弃时调用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

@MainActor
/// 阅读倒计时本地通知调度器，复刻 Android 倒计时完成后发出系统提醒的业务语义。
final class ReadingTimerCountdownNotificationScheduler {
    static let shared = ReadingTimerCountdownNotificationScheduler()

    private let center: UNUserNotificationCenter

    private init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    /// 安排倒计时完成通知；如果用户尚未授权，会先请求 alert/sound/badge 权限。
    /// 并发语义：方法运行在 MainActor，由 UserNotifications 异步完成权限读取与请求写入；调用方取消任务时不会改变计时数据库状态。
    func scheduleCompletion(recordId: Int64, bookTitle: String, remainingSeconds: Int64) async {
        guard remainingSeconds > 0 else { return }
        let identifier = notificationIdentifier(recordId: recordId)
        center.removePendingNotificationRequests(withIdentifiers: [identifier])

        guard await hasNotificationAuthorization() else { return }

        let content = UNMutableNotificationContent()
        content.title = String(localized: "计时结束")
        content.body = String(localized: "《\(bookTitle)》本次阅读计时已完成，请保存阅读记录。")
        content.sound = .default
        content.userInfo = ["readTimeRecordId": recordId]

        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: max(1, TimeInterval(remainingSeconds)),
            repeats: false
        )
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: trigger
        )
        try? await center.add(request)
    }

    /// 取消指定阅读计时的完成通知，避免暂停、手动停止或保存后继续弹出过期提醒。
    func cancelCompletion(recordId: Int64) {
        let identifier = notificationIdentifier(recordId: recordId)
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    private func notificationIdentifier(recordId: Int64) -> String {
        "reading-timer-countdown-\(recordId)"
    }

    private func hasNotificationAuthorization() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        case .denied:
            return false
        @unknown default:
            return false
        }
    }
}
