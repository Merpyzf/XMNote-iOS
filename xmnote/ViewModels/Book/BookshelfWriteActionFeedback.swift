/**
 * [INPUT]: 依赖 BookshelfPendingAction、BookshelfBookListEditAction 与 BookshelfActionFeedback 表达书架写操作反馈
 * [OUTPUT]: 对外提供写操作反馈文案构造工具，供首页书架与二级列表复用处理中、成功与错误反馈语义
 * [POS]: Book 模块 ViewModel 辅助类型，收敛书架写操作反馈状态的重复构造逻辑
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// 可生成书架写操作反馈的动作描述，避免不同 ViewModel 重复拼接处理中提示。
protocol BookshelfWriteActionDescribing {
    var title: String { get }
}

extension BookshelfPendingAction: BookshelfWriteActionDescribing {}

extension BookshelfBookListEditAction: BookshelfWriteActionDescribing {}

/// 构造书架写操作反馈，确保一级书架与二级列表使用一致的反馈语义。
enum BookshelfWriteActionFeedback {
    /// 生成写操作开始时的即时处理中反馈。
    static func processing(for action: some BookshelfWriteActionDescribing) -> BookshelfActionFeedback {
        BookshelfActionFeedback(kind: .processing, message: "\(action.title)处理中...")
    }

    /// 生成写操作成功后的短驻留反馈。
    static func success(_ message: String) -> BookshelfActionFeedback {
        BookshelfActionFeedback(kind: .success, message: message)
    }

    /// 生成写操作失败后的错误反馈。
    static func error(_ message: String) -> BookshelfActionFeedback {
        BookshelfActionFeedback(kind: .error, message: message)
    }
}
