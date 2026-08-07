# XMActivityShareSheet 使用说明

## 组件定位

- 源码路径：`xmnote/UIComponents/Foundation/XMActivityShareSheet.swift`
- 角色：统一承接文本、文件 URL 等系统分享载荷，并桥接 `UIActivityViewController`。
- 适用场景：内容查看、列表上下文菜单、导出结果等需要打开系统活动面板的跨模块页面。
- 边界：组件只负责系统面板桥接，不生成分享文案、图片或临时文件，也不管理业务写入。

## 快速接入

页面使用 `XMActivitySharePayload?` 保存一次分享会话，并把 Sheet 挂在持续存活的页面宿主上：

```swift
@State private var sharePayload: XMActivitySharePayload?

var body: some View {
    content
        .sheet(item: $sharePayload) { payload in
            XMActivityShareSheet(activityItems: payload.activityItems)
        }
}

private func share(_ text: String) {
    sharePayload = XMActivitySharePayload(activityItems: [text])
}
```

## 示例

### 上下文菜单接入

上下文菜单只写入页面级 payload，不要把 `ShareLink` 或 `XMActivityShareSheet` 直接嵌在菜单内容中。菜单关闭与新 presentation 会竞争 UIKit 呈现通道；页面级 item-driven Sheet 可以在稳定宿主上承接状态变化。

```swift
.contextMenu {
    Button {
        sharePayload = XMActivitySharePayload(activityItems: [shareText])
    } label: {
        XMMenuLabel("分享", systemImage: "square.and.arrow.up")
    }
}
```

## 参数说明

| 类型 | 字段 | 说明 |
| --- | --- | --- |
| `XMActivitySharePayload` | `activityItems` | 本次分享的文本、URL、文件 URL 或其他 UIKit 支持的 activity item。 |
| `XMActivitySharePayload` | `id` | 每次会话自动生成的新身份，用于 `.sheet(item:)`。 |
| `XMActivityShareSheet` | `activityItems` | 创建 `UIActivityViewController` 时使用的不可变会话快照。 |

## 使用约束

- 创建 payload 前先锁定本次分享对象，避免列表选择或 Viewer 翻页后分享错内容。
- 分享图等临时文件由业务 owner 负责生命周期和失败清理。
- 分享面板打开后不更新同一会话的 items；需要新内容时创建新的 payload。
- 普通分享菜单项使用系统默认色或 `XMMenuLabel` 中性色，不使用品牌色强调可点击性。

## 常见问题

### 为什么必须挂在持续存活的页面宿主上？

上下文菜单、Viewer 翻页或列表 cell 都可能在动作后立即消失。让页面级 `.sheet(item:)` 持有不可变 payload，才能避免 UIKit presentation 竞争和分享错对象。

### 分享图片由组件生成吗？

不生成。阅读日历分享卡等业务内容由对应 ViewModel 生成文件，组件只把最终文本或 URL 交给系统分享面板。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
