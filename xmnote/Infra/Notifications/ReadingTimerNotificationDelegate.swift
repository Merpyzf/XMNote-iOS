/**
 * [INPUT]: 依赖 UIKit App 生命周期与 UserNotifications 响应回调，读取倒计时通知携带的书籍/记录 ID
 * [OUTPUT]: 对外提供 ReadingTimerNotificationDelegate、ReadingTimerSystemHandoff 与系统交接事件
 * [POS]: Infra/Notifications 系统交接层，把通知点击和 Live Activity 停止动作统一转换为可跨冷启动消费的阅读计时深链
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import UIKit
import UserNotifications

extension Notification.Name {
    /// 系统入口已写入新的阅读计时交接，根层应立即尝试消费。
    nonisolated static let readingTimerSystemHandoffDidChange = Notification.Name(
        "readingTimerSystemHandoffDidChange"
    )
}

/// 持久化系统入口的精确计时路由，保证冷启动和回前台都不会丢失待保存记录。
nonisolated enum ReadingTimerSystemHandoff {
    static let recordIdUserInfoKey = "readTimeRecordId"
    static let bookIdUserInfoKey = "bookId"
    private static let appGroupIdentifier = "group.com.merpyzf.xmnote"
    private static let pendingURLKey = "xmnote.readingTimer.pendingSystemHandoffURL"

    private static var sharedDefaults: UserDefaults {
        UserDefaults(suiteName: appGroupIdentifier) ?? .standard
    }

    /// 写入一次精确交接并通知当前进程；无效 ID 不产生路由。
    static func save(recordId: Int64, bookId: Int64, defaults: UserDefaults? = nil) {
        guard recordId > 0, bookId > 0,
              let url = makeURL(recordId: recordId, bookId: bookId) else { return }
        let defaults = defaults ?? sharedDefaults
        defaults.set(url.absoluteString, forKey: pendingURLKey)
        NotificationCenter.default.post(name: .readingTimerSystemHandoffDidChange, object: nil)
    }

    /// newest-wins 消费持久化路由；读取后立即清除，避免场景恢复时重复打开。
    static func consumeURL(defaults: UserDefaults? = nil) -> URL? {
        let defaults = defaults ?? sharedDefaults
        guard let rawURL = defaults.string(forKey: pendingURLKey) else { return nil }
        defaults.removeObject(forKey: pendingURLKey)
        return URL(string: rawURL)
    }

    /// 从通知 userInfo 读取 Android/iOS 共用的记录与书籍主键。
    static func save(userInfo: [AnyHashable: Any], defaults: UserDefaults? = nil) {
        guard let recordId = int64Value(userInfo[recordIdUserInfoKey]),
              let bookId = int64Value(userInfo[bookIdUserInfoKey]) else { return }
        save(recordId: recordId, bookId: bookId, defaults: defaults)
    }

    private static func makeURL(recordId: Int64, bookId: Int64) -> URL? {
        URL(string: "xmnote://reading-timer/\(bookId)?recordId=\(recordId)")
    }

    private static func int64Value(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber {
            return number.int64Value
        }
        if let string = value as? String {
            return Int64(string)
        }
        return nil
    }
}

/// 应用通知代理，在用户点击倒计时完成通知后写入持久化交接并唤醒根路由。
final class ReadingTimerNotificationDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    /// 尽早注册通知中心代理，确保冷启动与已运行场景都能收到响应回调。
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    /// 用户点击通知后保存精确交接；完成回调不等待界面初始化，根层会在就绪后消费。
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        ReadingTimerSystemHandoff.save(userInfo: response.notification.request.content.userInfo)
        completionHandler()
    }
}
