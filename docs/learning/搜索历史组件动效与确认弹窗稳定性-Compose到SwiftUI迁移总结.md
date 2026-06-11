# 搜索历史组件动效与确认弹窗稳定性：Compose 到 SwiftUI 迁移总结

## 1. 本次知识点
- 搜索历史 chip 的编辑态不是“插入一个删除按钮”，而是同一个对象右侧操作槽连续展开。
- `Button` 的视觉尺寸和命中尺寸可以分离：32pt 视觉胶囊配 44pt 高度命中区，比把删除按钮横向拉到 44pt 更稳定。
- SwiftUI 动画应绑定到明确状态值；大范围父级动画容易把 header、flow、toggle 和 alert 时序一起带动。
- 中心确认弹窗是决策暂停点，弹窗出现后底层上下文只能被遮罩，不能继续发生可见数据写入或布局重排。
- `searchable` 激活时，UIKit alert 抢焦点会触发键盘退场；必须先稳定 responder，再呈现确认弹窗。

## 2. Compose -> SwiftUI 思维映射
- Compose 常见写法：
  - `AnimatedVisibility` 包住删除按钮。
  - `AlertDialog` 由当前 Composable 局部 state 控制。
  - `FlowRow` 根据 chip 内容自然重排。
- SwiftUI 迁移要点：
  - `if isEditing { deleteButton }` 会改变 view tree，容易让 chip 身份和宽度突变。
  - `XMSystemAlert` 使用 UIKit `UIAlertController`，挂载位置和系统搜索宿主/键盘焦点有关。
  - `Layout` 测量阶段要用和渲染同源的宽度模型，不能让透明命中区误导折行判断。

## 3. Chip 编辑态动效
错误心智：
```swift
HStack {
    Text(query)
    if isEditing {
        Button(action: onRemove) {
            Image(systemName: "xmark.circle.fill")
        }
        .transition(.opacity.combined(with: .scale))
    }
}
```

问题是编辑态改变了子树结构，按钮像凭空淡入，chip 宽度也会和 flow layout 同帧重算。用户看到的是“整组被推开”，不是“当前 chip 打开了一个操作位”。

正确心智：
```swift
HStack(spacing: 0) {
    Text(query)
    Color.clear.frame(width: isEditing ? removeSlotWidth : 0)
}
.animation(.smooth(duration: 0.26), value: isEditing)
```

删除图标始终属于同一个 chip 的内部覆盖层，只是跟随槽位位置移动。这样对象身份连续，动效也更接近 iOS 系统里“编辑操作浮出”的语义。

## 4. 弹窗时序
错误心智：
```swift
Button("清空") {
    isEditing = false
    recentQueries.removeAll()
    isAlertPresented = true
}
```

这个写法把破坏性写入、编辑态退出和弹窗呈现在同一帧。弹窗动画期间，用户会看到底层 chip 消失或页面回到空态。

正确心智：
```swift
Button("清空") {
    resignSearchResponder()
    requestClearConfirmation()
}

destructiveAction {
    viewModel.clearRecentQueries()
    resetHistoryManagementState()
}
```

确认前只做焦点稳定，不做数据写入。确认弹窗出现后，底层历史区仍保留原来的 chip、编辑按钮和滚动位置；只有 destructive action 才真正清空。

## 5. `searchable` 与 UIKit Alert 的 owner 边界
SwiftUI 的 `.searchable` 不是普通输入框，它会和系统搜索宿主、键盘、Tab 搜索激活策略协作。若把清空确认挂到 `MainTabView` 根层，同时根层还管理 `.searchable`，点击“清空”时很容易把键盘退场、搜索宿主同步和 alert 呈现压进同一帧。

本次修复采用：
- `MainTabView` 只提供 `dismissGlobalSearchKeyboard()`，不持有清空确认状态。
- `GlobalSearchView` 本地持有清空确认 request。
- 呈现前延后一个短窗口，让 responder 先完成退场。
- destructive 确认后才清空历史并发送 reset 信号。

这不是 `XMSystemAlert` 的全局架构问题，而是挂载位置和时序问题。

## 6. Reduce Motion
Reduce Motion 下不要把状态反馈完全拿掉。推荐做法：
- 删除槽位仍然展开/收起，但动画时间缩短。
- 删除图标减少位移和缩放。
- 保留清晰的编辑态按钮和删除图标可访问性标签。

## 7. 最小可运行示例
```swift
struct HistoryDemo: View {
    @State private var queries = ["ios", "swiftui", "search"]
    @State private var isExpanded = false
    @State private var isEditing = false
    @State private var isClearPresented = false

    var body: some View {
        XMSearchHistorySection(
            queries: queries,
            isExpanded: $isExpanded,
            isEditing: $isEditing,
            title: "最近搜索",
            emptyPresentation: .hidden,
            onSelect: { query in
                print("submit", query)
            },
            onRemove: { query in
                queries.removeAll { $0 == query }
            },
            onClearAll: {
                isClearPresented = true
            }
        )
        .xmSystemAlert(
            isPresented: $isClearPresented,
            descriptor: XMSystemAlertDescriptor(
                title: "清空搜索历史？",
                message: "这会移除全部最近搜索词，不影响你的本地内容。",
                actions: [
                    XMSystemAlertAction(title: "取消", role: .cancel) { },
                    XMSystemAlertAction(title: "清空", role: .destructive) {
                        queries.removeAll()
                        isEditing = false
                        isExpanded = false
                    }
                ]
            )
        )
    }
}
```

## 8. 迁移检查清单
- chip 的视觉宽度、命中宽度、文本测量是否同源。
- 编辑态是否通过同一对象的属性变化表达，而不是条件插入整块视图。
- 清空确认前是否只稳定焦点，不清空数据、不退出编辑态。
- 弹窗挂载 owner 是否会和键盘、sheet、cover、Tab 搜索宿主竞争。
- 取消后是否保留编辑态和原始历史列表。
- Reduce Motion 是否仍有清晰状态反馈。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
