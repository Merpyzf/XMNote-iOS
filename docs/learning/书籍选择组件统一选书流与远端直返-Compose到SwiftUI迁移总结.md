# 书籍选择组件统一选书流与远端直返（Compose -> SwiftUI）迁移总结

## 1. 本次 iOS 知识点

- 选书组件不要只设计成“列表 + 回调”，而要设计成“统一配置 + 状态机 + 结果语义”的完整任务流。
- SwiftUI 里做跨页面复用的业务组件时，先沉淀 `Configuration` 和 `Result`，比先拆一堆 View 子组件更重要。
- 当一个选择器既能返回本地对象、又能返回在线结果时，最稳妥的做法是先用枚举统一结果类型，而不是让调用方自己猜当前回调返回什么。
- 多选场景如果需要稳定回流顺序，不能只存 `selectedItems` 集合，还要显式维护用户选择顺序。
- 在线结果如果点击后还要异步补详情，界面必须有阻塞态反馈，否则用户会连续点击把状态机打乱。

## 2. Compose -> SwiftUI 思维对照

| 目标 | Android / Compose 常见做法 | SwiftUI 本次做法 | 迁移原则 |
| --- | --- | --- | --- |
| 统一入口配置 | `BookSearchSheetFragment.Builder()` 逐项设参数 | `BookPickerConfiguration` 一次性描述全部能力 | 先收口配置，再接页面 |
| 结果回流 | EventBus / listener 返回 `Book` 或集合 | `BookPickerResult` 返回 `single / multiple / cancelled / addFlowRequested` | 先统一结果语义，再谈消费 |
| 本地 + 在线混合 | Fragment + 子搜索页/子选择器联动 | `BookPickerViewModel` 单状态机管理 `visibleScope`、搜索、选中和补齐 | 把状态 owner 收紧到一个 ViewModel |
| 在线点击补详情 | 点击后临时抓取详情，再发消息 | `BookPickerRemoteSelection` 统一携带 `result + seed` | 补齐结果要能复用，不要临时对象飞来飞去 |
| 场景对齐验证 | 多个页面分散验证 | `BookSelectionTestViewModel` 集中登记 20 个 Android 场景 | 迁移先做样板中心，再做正式接线 |

## 3. 这次做对的关键点

### 3.1 先统一结果模型，再开放远端能力

如果直接让某些页面回 `Book`、某些页面回 `BookSearchResult`、某些页面回 `BookEditorSeed`，调用方很快就会失控。

这次先把返回值统一成：

- `BookPickerResult`
- `BookPickerSelection`

好处是：

- 单选和多选共用一套语义。
- 本地书和远端结果共用一套消费入口。
- 调用方看到 `.remote(...)` 时，能明确知道自己在消费在线直返结果，而不是被迫猜测类型来源。

### 3.2 空集合确认必须是显式策略，不要靠约定

Android 老方案里，多选确认默认要求至少选中一项；但过滤场景经常需要“空集合 = 全部 / 未限制”。

这次 iOS 没有把它写成“某几个页面偷偷特判”，而是单独抽成：

- `BookPickerMultipleConfirmationPolicy.requiresSelection`
- `BookPickerMultipleConfirmationPolicy.allowsEmptyResult`

这会让后续调用方更安全：

- 只要配置里没声明 `allowsEmptyResult`，页面就不会误把空集合当成有效结果。
- 一旦声明了，UI 也会配套显示“未限制”，而不是让用户看到一个意义不明的 `0`。

### 3.3 混合多选一定要维护顺序

如果多选里同时有：

- 本地书
- 在线结果

那么只用两个数组分别存本地和在线是不够的，因为最后确认时会丢掉用户真实点击顺序。

这次 `BookPickerViewModel` 额外维护了 `selectionOrder`，再在确认时按顺序解析：

- 本地书直接回流
- 在线结果补齐后按原顺序插回集合

这类做法和 Compose 里单独维护 `List<SelectionKey>` 是同一个思路。

### 3.4 调试中心是迁移工具，不是临时页面

`BookSelectionTestView` 看起来像 Debug 页面，但它的价值不是“临时试试”，而是：

- 给 20 个 Android 入口提供统一配置样板
- 让 `.local` / `.remote` / 混合多选 / 空集合确认都有可视化结果预览
- 把“能力是否已收口”和“正式页面是否已接线”分开

这能明显降低迁移时的误判：我们不会因为能力做好了，就误以为所有业务页也都完成了。

## 4. SwiftUI 可运行示例

```swift
import SwiftUI

struct DemoBook: Identifiable, Hashable {
    let id: Int64
    let title: String
}

struct DemoRemoteSelection: Hashable {
    let title: String
    let source: String
}

enum DemoSelection: Hashable {
    case local(DemoBook)
    case remote(DemoRemoteSelection)
}

enum DemoResult: Hashable {
    case cancelled
    case single(DemoSelection)
    case multiple([DemoSelection])
}

struct BookPickerResultDemo: View {
    @State private var result: DemoResult = .cancelled

    var body: some View {
        VStack(spacing: 16) {
            Button("返回本地书") {
                result = .single(.local(.init(id: 1, title: "三体")))
            }

            Button("返回在线结果") {
                result = .single(.remote(.init(title: "活着", source: "douban")))
            }

            Text(description(for: result))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
    }

    private func description(for result: DemoResult) -> String {
        switch result {
        case .cancelled:
            return "已取消"
        case .single(.local(let book)):
            return "本地书：\\(book.title)"
        case .single(.remote(let remote)):
            return "在线结果：\\(remote.title) @ \\(remote.source)"
        case .multiple(let selections):
            return "已选择 \\(selections.count) 项"
        }
    }
}
```

## 5. Compose 对照示例

```kotlin
data class DemoBook(val id: Long, val title: String)
data class DemoRemoteSelection(val title: String, val source: String)

sealed interface DemoSelection {
    data class Local(val book: DemoBook) : DemoSelection
    data class Remote(val remote: DemoRemoteSelection) : DemoSelection
}

sealed interface DemoResult {
    data object Cancelled : DemoResult
    data class Single(val selection: DemoSelection) : DemoResult
    data class Multiple(val selections: List<DemoSelection>) : DemoResult
}
```

## 6. 给 Android Compose 开发者的迁移提醒

- 不要把 Builder 时代的参数散落习惯直接搬进 SwiftUI 页面。SwiftUI 更适合先做一个清晰的 `Configuration`，再把页面视图当成配置的投影。
- 不要让调用方去猜“这次返回的是本地书还是在线结果”。只要结果语义开始分叉，就应该尽早上枚举。
- 不要在页面里临时拼远端补详情流程。补齐逻辑如果会被单选、多选、创建链路复用，就应该沉到统一 ViewModel。
- 不要把调试中心当成可删的临时产物。迁移复杂组件时，调试中心本身就是降低回归风险的基础设施。

## 7. 最终结论

- 这次最重要的不是“把 Android 的选书弹层画成 SwiftUI”，而是把 Android 分散在 Builder、EventBus、子页面和页面消费方里的语义，重新组织成一个更清晰的 iOS 任务流。
- 迁移这类业务组件时，先统一配置、状态和结果，再谈页面扩散，通常会比“先接业务页、后补抽象”稳得多。
