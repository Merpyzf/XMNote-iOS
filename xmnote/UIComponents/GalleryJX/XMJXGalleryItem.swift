import Foundation
import OSLog

/**
 * [INPUT]: 依赖 Foundation 值语义模型与 OSLog 日志能力
 * [OUTPUT]: 对外提供 XMJXGalleryItem（JX 图片墙输入模型）
 * [POS]: UIComponents/GalleryJX 的数据契约，统一缩略图与原图地址输入，供 SwiftUI 墙面与 UIKit 浏览器桥接层共享
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
/// XMJXGalleryItem 定义图片墙单张图片的稳定标识和双地址输入，供墙面与浏览器共享。
struct XMJXGalleryItem: Identifiable, Hashable {
    let id: String
    let thumbnailURL: String
    let originalURL: String

    /// 初始化图片墙条目，要求提供稳定 ID 与双地址输入。
    init(id: String, thumbnailURL: String, originalURL: String) {
        self.id = id
        self.thumbnailURL = thumbnailURL
        self.originalURL = originalURL
    }
}

/// XMJXGalleryLogLevel 控制图片墙调试日志颗粒度，便于只在问题定位时放大输出。
enum XMJXGalleryLogLevel: Int {
    case off = 0
    case essential = 1
    case verbose = 2
}

/// XMJXGalleryLogger 收口图片墙桥接链路的调试输出，避免散落 `print` 污染业务代码。
enum XMJXGalleryLogger {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.merpyzf.xmnote",
        category: "GalleryJX"
    )
    private static let userDefaultsKey = "XMJXGalleryLogLevel"
    private static let environmentKey = "XMJX_GALLERY_LOG_LEVEL"

    /// 输出默认级别的重要日志，覆盖关键加载与转场节点。
    static func essential(_ message: @autoclosure () -> String) {
        log({ message() }, level: .essential)
    }

    /// 输出高颗粒度调试日志，供定位缩略图注册与布局问题。
    static func verbose(_ message: @autoclosure () -> String) {
        log({ message() }, level: .verbose)
    }

    /// 输出错误日志，保留加载失败等需要排查的问题信号。
    static func error(_ message: @autoclosure () -> String) {
        #if DEBUG
        guard currentLevel != .off else { return }
        let line = prefixed(message())
        logger.error("\(line, privacy: .public)")
        #endif
    }

    private static func log(_ message: () -> String, level: XMJXGalleryLogLevel) {
        #if DEBUG
        guard shouldLog(level) else { return }
        let line = prefixed(message())
        logger.debug("\(line, privacy: .public)")
        #endif
    }

    private static func prefixed(_ message: String) -> String {
        "[jx.gallery.trace] \(message)"
    }

    private static func shouldLog(_ level: XMJXGalleryLogLevel) -> Bool {
        currentLevel.rawValue >= level.rawValue && currentLevel != .off
    }

    private static var currentLevel: XMJXGalleryLogLevel {
        #if DEBUG
        if let rawValue = ProcessInfo.processInfo.environment[environmentKey],
           let intValue = Int(rawValue),
           let level = XMJXGalleryLogLevel(rawValue: intValue) {
            return level
        }
        if let intValue = UserDefaults.standard.object(forKey: userDefaultsKey) as? Int,
           let level = XMJXGalleryLogLevel(rawValue: intValue) {
            return level
        }
        return .essential
        #else
        return .off
        #endif
    }
}
