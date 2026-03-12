#if DEBUG
import SwiftUI

/**
 * [INPUT]: 依赖 BookDoubanLoginScreen 承载正式豆瓣登录流程，供 Debug 页复用同一登录实现
 * [OUTPUT]: 对外提供 DoubanLoginWebViewScreen（Debug 豆瓣登录页包装）
 * [POS]: Debug 网页抓取测试页的豆瓣登录入口，复用书籍模块正式登录页完成共享会话回流
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

struct DoubanLoginWebViewScreen: View {
    let title: String
    let onClose: () -> Void
    let onLoginDetected: () -> Void

    var body: some View {
        BookDoubanLoginScreen(
            title: title,
            onClose: onClose,
            onLoginDetected: onLoginDetected
        )
    }
}
#endif
