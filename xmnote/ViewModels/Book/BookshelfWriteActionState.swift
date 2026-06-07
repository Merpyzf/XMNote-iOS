/**
 * [INPUT]: 依赖 BookshelfWriteActionDescribing 与 BookshelfActionFeedback 表达书架写操作 UI 状态
 * [OUTPUT]: 对外提供 BookshelfWriteActionState，统一承载当前写入动作、错误文本与内联反馈
 * [POS]: Book 模块 ViewModel 辅助状态值对象，收敛一级书架与二级列表重复的写操作状态字段
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// 书架写操作 UI 状态，避免不同 ViewModel 重复维护忙碌动作、错误文本与反馈提示。
struct BookshelfWriteActionState<Action: BookshelfWriteActionDescribing> {
    var activeAction: Action?
    var error: String?
    var feedback: BookshelfActionFeedback?

    /// 面向 UI 的临时提示文案；设置后使用 warning 语义，读取时返回当前反馈文案。
    var notice: String? {
        get { feedback?.message }
        set { setWarningNotice(newValue) }
    }

    /// 标记指定写动作进入处理中状态，同时清理上一轮错误。
    mutating func start(_ action: Action) {
        activeAction = action
        feedback = BookshelfWriteActionFeedback.processing(for: action)
        error = nil
    }

    /// 标记写操作成功并返回需要短驻留展示的成功反馈。
    mutating func finishSuccess(_ message: String) -> BookshelfActionFeedback {
        activeAction = nil
        let successFeedback = BookshelfWriteActionFeedback.success(message)
        feedback = successFeedback
        return successFeedback
    }

    /// 标记写操作失败，错误文本与 UI 错误反馈保持同源。
    mutating func finishFailure(_ failure: Error) {
        let message = failure.localizedDescription
        activeAction = nil
        error = message
        feedback = BookshelfWriteActionFeedback.error(message)
    }

    /// 仅当当前反馈仍是目标成功反馈时清除，避免异步延迟任务误清新反馈。
    mutating func clearFeedback(ifMatches expectedFeedback: BookshelfActionFeedback) {
        guard feedback == expectedFeedback else { return }
        feedback = nil
    }

    private mutating func setWarningNotice(_ message: String?) {
        feedback = message.map {
            BookshelfActionFeedback(kind: .warning, message: $0)
        }
    }
}
