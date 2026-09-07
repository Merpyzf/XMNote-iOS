# 书摘导入预览与可恢复写入：Compose 到 SwiftUI 迁移总结

更新日期：2026-09-07

Android 导入页常将网络获取、目标匹配和数据库写入收在 Presenter/Job 中；迁移到 SwiftUI 时，应先把“准备预览”和“最终提交”拆为两个边界。用户可以安全地改变选择、资料和筛选，只有确认后才由 Repository 写库。

| Compose/Android | SwiftUI/iOS | 迁移要点 |
| --- | --- | --- |
| `Job.cancel()` 停止导入任务 | `Task` 与 `Task.checkCancellation()` 停止未提交异步工作 | 取消后不要把旧结果写回新的页面状态。 |
| Presenter 直接维护候选列表 | `@MainActor @Observable` ViewModel 拥有会话副本 | UI 状态只在主线程变更，Repository 不持有页面选择。 |
| 后台补全目标书 | `assessmentRevision` / ticket 丢弃迟到回调 | 每次选择变化都要让旧请求失效。 |
| 整批导入反馈 | 逐组 `CommitGroupResult` | 把成功、跳过、失败拆开，允许用户理解部分完成。 |

示例：当用户在筛选后点击“全选”，ViewModel 应保存当前可见项的稳定 ID；随后用户再改变筛选，隐藏项仍保留原选择。不要用当前渲染数组覆盖整个选择集合。

检查清单：

- 页面层不直接读写 `AppDatabase` 或网络客户端。
- 外部文件在安全作用域内读取，并在取消后停止继续工作。
- 空内容不自动创建书籍。
- 文案区分“获取候选”和“导入写入”。
