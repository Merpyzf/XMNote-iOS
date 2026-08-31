# 提示词令牌编辑与可取消试运行：Compose 到 SwiftUI 迁移总结

## 背景

Android 已通过 `PromptEditActivity`、`PromptEditViewModel` 和 `MarkedTextField` 支持三类 AI 任务的 System/User Prompt 编辑与变量高亮。iOS 迁移不能只把 Compose 页面逐控件翻译成 SwiftUI，还要保持变量契约、未保存退出和正式请求语义一致，并处理 TextKit 选区、结构化并发和原子持久化。

本次实现把页面拆成五个 owner：Domain 负责变量与校验，ViewModel 负责草稿和异步身份，TextKit 桥接负责编辑器行为，Repository 负责请求构建与网络边界，Actor Store 负责持久化。

## iOS 关键知识点

### 1. 变量是领域数据，不是富文本附件

- 持久化始终保存 `${变量名}` 纯字符串，避免把 UIKit 属性、颜色或附件写入配置。
- `AIPromptVariableCatalog` 为每类任务提供唯一白名单和必需/推荐语义。
- `AIPromptValidator` 只接收字符串、字段和任务类型，因此页面提示、保存和正式请求可以复用同一规则。
- TextKit 只把已识别范围投影成令牌视觉；选区变化必须在“原始文本范围”和“展示文本范围”之间显式转换。

Compose 的 `AnnotatedString` 与 TextKit attributed text 都适合展示标记，但业务真相仍应是稳定的纯文本，而不是平台渲染对象。

### 2. 编辑状态与派生结果分离

`AIPromptEditorViewModel` 持有两个层级的状态：

- 真相状态：当前草稿、已持久化快照、活动字段。
- 派生状态：校验问题、预览、试运行结果、优化建议和错误。

文本变化时立即清除旧预览、旧试运行和旧优化建议。保存发起时锁定双字段快照；保存完成后若用户又输入了内容，页面仍保持 dirty，不因较早的保存成功而错误退出。

### 3. 可取消 Task 还需要结果身份

仅调用 `Task.cancel()` 不足以证明远端响应不会晚到。试运行和优化同时使用：

- Sheet 持有结构化 Task，在关闭或字段切换时取消。
- ViewModel 记录 request ID、字段和草稿快照。
- 响应返回后再次检查取消、request ID 与输入快照，只有仍属于当前编辑现场才发布。

这与 Compose 中 `viewModelScope.launch` 配合 job cancel、请求 token 和输入 revision 的思路一致。

### 4. Actor 内做“读取最新值 + 局部替换 + 一次写回”

提示词编辑页只拥有一个任务的 Prompt，不拥有供应商、模型、开关和其他任务草稿。保存时不能把页面进入时的整份旧配置写回。

`AIConfigurationStore` 在 Actor 隔离内读取最新 v2 快照，只替换当前任务的 System/User 组合，然后一次持久化。这样可以避免设置页与提示词页并发编辑时互相覆盖无关字段。

### 5. 返回保护必须覆盖所有退出入口

只拦截自定义返回按钮会漏掉系统边缘返回手势。页面通过 `navigationPopGuard` 统一表达：

- 无脏草稿且未保存中：允许系统返回。
- 有脏草稿：阻断按钮和交互式返回，呈现同一保存/放弃/继续编辑决策。
- 交互式返回取消：恢复页面出现状态和编辑焦点。
- 真正退出前：先收起键盘与悬浮编辑栏，再执行导航返回。

## Compose 与 SwiftUI 对照

| Android Compose | iOS 实现 | 迁移重点 |
| --- | --- | --- |
| `mutableStateOf` / `TextFieldValue` | `@Observable` + `@State` / `@Bindable` | ViewModel 持有业务草稿，View 持有焦点、选区和 Sheet 等瞬态 |
| `AnnotatedString` / `MarkedTextField` | `UIViewRepresentable` + TextKit | 平台编辑器只负责投影与输入行为，原始字符串仍是领域真相 |
| `HorizontalPager` | 分段 Picker + 单编辑器 | 对齐双字段业务意图，不机械复制 Android 页面结构 |
| `BackHandler` | `navigationPopGuard` + 系统 Alert | 覆盖顶部返回与交互式返回，不丢失 iOS 原生手势 |
| `viewModelScope.launch` + Job | Sheet Task + request ID + 输入快照 | 取消网络之外还要拒绝晚到结果 |
| 多个 SharedPreferences setter | Actor 内局部替换完整快照 | 防止 System/User 半保存和跨页面旧快照覆盖 |

## 最小示例：快照安全的异步建议

下面的骨架展示“请求身份 + 输入快照”如何阻止旧响应覆盖新文本：

```swift
import Foundation
import Observation

protocol PromptSuggesting: Sendable {
    func suggest(for text: String) async throws -> String
}

@MainActor
@Observable
final class PromptDraftModel {
    var text = ""
    private(set) var suggestion: String?
    private(set) var isLoading = false

    private let service: any PromptSuggesting
    private var activeRequestID: UUID?

    init(service: any PromptSuggesting) {
        self.service = service
    }

    func requestSuggestion() async {
        let requestID = UUID()
        let source = text
        activeRequestID = requestID
        isLoading = true
        defer {
            if activeRequestID == requestID {
                isLoading = false
            }
        }

        do {
            let result = try await service.suggest(for: source)
            try Task.checkCancellation()
            guard activeRequestID == requestID, text == source else { return }
            suggestion = result
        } catch is CancellationError {
            return
        } catch {
            guard activeRequestID == requestID else { return }
            suggestion = nil
        }
    }

    func cancelSuggestion() {
        activeRequestID = nil
        isLoading = false
    }
}
```

Compose 中对应的关键不是把代码逐行改写，而是在协程返回后同时检查当前 Job/请求 token 和输入 revision；只检查 `isActive` 无法覆盖输入已经变化但旧协程仍完成的情况。

## 迁移检查清单

- 变量目录、默认 Prompt 与 Android 业务含义是否一致？
- 原始配置是否保持纯字符串，平台富文本是否只作为投影？
- 页面校验、保存和正式请求是否复用同一规则？
- 预览是否使用正式请求构建器，而不是复制一套字符串拼装？
- 保存是否只替换当前页面真正拥有的字段？
- 异步响应是否同时检查取消、请求身份和输入快照？
- 系统返回手势、按钮返回、Sheet 关闭是否都不会遗失草稿或发布旧结果？
- 业务 Sheet、页面私有组件与 ViewModel 是否分别归位到项目约定目录？

## 结论

提示词编辑迁移的核心不是“让变量看起来像 Chip”，而是保持一个可验证的纯文本合同。领域层定义变量和请求语义，平台编辑器只负责输入体验，异步结果绑定快照，持久化只写页面拥有的最小范围。这样才能同时获得跨端一致性、iOS 原生交互和可回滚的数据边界。
