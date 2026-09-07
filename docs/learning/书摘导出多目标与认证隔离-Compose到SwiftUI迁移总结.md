# 书摘导出多目标与认证隔离：Compose 到 SwiftUI 迁移总结

更新日期：2026-09-07

导出并不只是把文本写成文件。它同时涉及选择范围、格式生成、认证、远端请求、系统文档交付和可恢复的错误反馈。Android 中常把这些步骤集中在 Presenter；SwiftUI 更适合将页面状态、Repository、生成器和认证服务拆开。

| Android/Compose | SwiftUI/iOS | 迁移要点 |
| --- | --- | --- |
| Presenter 根据 target 分支执行所有工作 | `ExportViewModel` 编排，Repository/Generator/Service 各自执行 | target 分派不能让 View 直接连接网络或数据库。 |
| Activity 发起 OneNote/Notion 认证 | 独立认证服务持有 SDK 与回调 | token 不进入页面状态，认证失败可独立显示。 |
| 写入 app 目录后返回路径 | `UIDocumentPickerViewController(forExporting:)` 交给用户选位置 | iOS 文件交付应使用系统 picker，而不是猜测用户目录。 |
| 循环里更新进度 | 可取消任务 + 明确任务状态 | 取消时停止尚未开始的工作，避免旧回调刷新新页面。 |

对于 Compose 开发者，最关键的迁移检查是：认证 SDK 依赖 Activity 不等于整个导出流程都要放在 UI 层。把“取得令牌”限制在认证服务，把“怎样导出”限制在生成器或 Repository，把“用户看到什么”留在 ViewModel。

字体也是交付物的一部分：若 PDF 使用嵌入字体，工程注册、二进制文件与许可证必须同步存在；只验证编译通过不足以证明许可证合规。
