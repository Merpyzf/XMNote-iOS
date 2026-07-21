/**
 * [INPUT]: 依赖 Foundation 与阅读日历当日汇总领域模型
 * [OUTPUT]: 对外提供 ReadCalendarRoute，定义阅读日历二级与三级导航目的地
 * [POS]: Navigation 模块的阅读日历专属路由，可被在读与个人两个入口的 NavigationStack 共同消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// 阅读日历内部导航路径，保证两个入口共享“日期 → 单书记录”的原生 push 语义。
enum ReadCalendarRoute: Hashable {
    case daily(date: Date)
    case dailyBook(date: Date, summary: DailyReadingBookSummary)
    case share(monthStart: Date, initialType: ReadCalendarShareType)
}
