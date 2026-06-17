# XMToast 使用说明

## 组件定位
- 源码路径：`xmnote/UIComponents/Foundation/XMToast.swift`
- 角色：统一承接全局轻量消息提示的语义角色、展示时长、位置、动效、布局和交互策略。
- 边界：业务代码只调用 `XMToastCenter`；禁止在业务页面直接 `import PopupView` 或直接写 `.popup(...)`。

## 快速接入
### 1. App 根部挂载 Host
`xmnoteApp` 已在根容器创建并注入全局 `XMToastCenter`：

```swift
@State private var toastCenter = XMToastCenter()

Group {
    ContentView()
}
.environment(toastCenter)
.xmToastHost(center: toastCenter)
```

业务页面不需要再次挂载 `xmToastHost`。只有独立 Preview 或测试宿主需要自行创建 `XMToastCenter`。

### 2. 页面中展示 Toast
```swift
struct ExampleView: View {
    @Environment(XMToastCenter.self) private var toastCenter

    var body: some View {
        Button("保存") {
            toastCenter.success("已保存")
        }
    }
}
```

### 3. 处理中后切换结果
```swift
toastCenter.processing("正在更新排序...")

Task { @MainActor in
    do {
        try await submitOrder()
        toastCenter.success("排序已保存")
    } catch {
        toastCenter.error("排序失败，请稍后再试")
    }
}
```

## 参数说明
### `XMToastRole`
| 角色 | 默认时长 | 适用场景 |
| --- | --- | --- |
| `success` | 约 1.8 秒 | 保存成功、同步完成、轻量确认。 |
| `info` | 约 1.8 秒 | 不打断当前任务的信息说明。 |
| `warning` | 约 2.4 秒 | 可继续操作但需要注意的状态。 |
| `error` | 约 3.2 秒 | 不需要中心弹窗确认的轻量失败反馈。 |
| `processing` | 不自动隐藏 | 写入期间、排序提交中等需要即时反馈的状态。 |

### `XMToastPlacement`
| 值 | 说明 |
| --- | --- |
| `bottom` | 默认位置，避让底部 TabBar / 搜索浮层参照物。 |
| `top` | 主要用于 Debug 验证或确有顶部提示需求的特殊场景。 |

### `XMToastMessage`
| 字段 | 说明 |
| --- | --- |
| `role` | Toast 语义角色。 |
| `text` | 展示文案；应短、准，不重复页面已表达的信息。 |
| `placement` | 展示位置，默认 `.bottom`。 |
| `duration` | 可选自定义时长；`processing` 会忽略自动隐藏。 |

### `XMToastCenter`
| 方法 | 说明 |
| --- | --- |
| `show(_:)` | 展示完整 `XMToastMessage`。 |
| `show(_:_:duration:placement:)` | 按角色、文案、时长和位置展示。 |
| `success/warning/error/info/processing` | 常用语义便捷入口。 |
| `dismiss(id:)` | 关闭当前 Toast；传入 id 时只关闭匹配消息。 |

## 示例
### 示例 1：保存成功
```swift
toastCenter.success("已保存")
```

### 示例 2：失败但不打断任务
```swift
toastCenter.error("操作失败，请稍后再试")
```

### 示例 3：Debug 页面验证顶部位置与长文案
```swift
toastCenter.show(
    .warning,
    "当前网络较慢，内容会先保留在本机。",
    duration: 2.8,
    placement: .top
)
```

## 常见问题
### 1. 为什么不让业务页面直接使用 PopupView？
PopupView 是底层呈现能力。把它暴露给业务后，样式、动效、展示时长和安全区策略会散落到各页面，后续调整视觉或替换实现时需要逐个改业务代码。

### 2. Toast 和 `XMSystemAlert` 怎么区分？
Toast 用于短驻留、非阻塞、不需要确认的轻反馈；需要用户确认、危险操作确认或轻输入时继续使用 `XMSystemAlert`。

### 3. Toast 和读取加载态怎么区分？
读取类主态加载继续使用 `LoadingGate + LoadingStateView` 或 `LoadPhaseHost`。Toast 只用于轻量消息提示，不承载页面主加载骨架。

### 4. 连续触发多条消息会怎样？
`XMToastCenter` 采用 newest-wins：新消息直接替换当前消息，不排队、不堆叠，避免挡住内容或制造噪音。

### 5. 处理中态为什么不自动消失？
处理中代表写操作仍在进行。调用方应在成功或失败后用结果 Toast 替换，避免用户误以为操作已经结束。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
