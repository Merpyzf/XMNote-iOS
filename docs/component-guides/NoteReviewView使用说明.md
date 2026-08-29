# NoteReviewView 使用说明

## 组件定位
- 源码路径：`xmnote/Views/Note/NoteReviewView.swift`
- 角色：笔记 Tab 回顾页核心页面，承载书摘回顾卡组、加载态、空态、刷新、卡片菜单、标签编辑和分享反馈。
- 适用场景：`NoteContainerView` 中的“回顾”二级页。
- 边界：页面不直接访问数据库，所有数据读取和写入均委托 `NoteReviewViewModel`。

## 快速接入
```swift
NoteReviewView(
    viewModel: noteReviewViewModel,
    onOpenContentViewer: { source, itemID in
        openContentViewer(source, itemID)
    },
    onOpenSettings: {
        isReviewSettingsPresented = true
    }
)
```

## 参数说明
| 参数 | 类型 | 说明 |
| --- | --- | --- |
| `viewModel` | `NoteReviewViewModel` | 回顾页状态源，提供卡片数据、设置、加载态、标签编辑和分享动作。 |
| `onOpenContentViewer` | `(ContentViewerSourceContext, ContentViewerItemID) -> Void` | 点击卡片后的详情查看路由。 |
| `onOpenSettings` | `() -> Void` | 顶部设置入口或无结果状态中的“调整范围”动作触发设置 Sheet。 |

## 示例

### 示例 1：在 NoteContainerView 中接入
```swift
NoteReviewView(
    viewModel: reviewViewModel,
    onOpenContentViewer: onOpenContentViewer,
    onOpenSettings: {
        isReviewSettingsPresented = true
    }
)
.sheet(isPresented: $isReviewSettingsPresented) {
    NoteReviewSettingsSheet(viewModel: reviewViewModel)
}
```

### 示例 2：打开通用内容查看器
```swift
private func openContentViewer(
    source: ContentViewerSourceContext,
    itemID: ContentViewerItemID
) {
    router.presentContentViewer(source: source, initialItemID: itemID)
}
```

## 常见问题

### 1. 页面如何区分读取失败和没有可回顾内容？

首次读取失败使用页面级 `XMContentStateView(.failure)`，显示“暂时无法加载回顾”和纯文字“重试”。读取成功但当前范围没有结果时使用 `.noResults`，显示“暂无可回顾书摘”和“调整范围”；该动作修改真实筛选条件，不是装饰性引导。

### 2. 为什么页面里有 `LoadingGate`？
回顾页首次读取属于读取类加载，项目规范要求延迟显示与最短驻留，避免瞬时闪烁。`LoadingGate` 只在首屏空数据加载时显示。

### 3. 刷新和换一组有什么区别？
文案跟随排序规则：随机回顾时显示“换一组”，顺序回顾时显示“刷新”。底层都调用 `viewModel.refresh()` 重新读取当前范围。

### 4. 为什么分享图不直接复用屏幕卡片？
分享图需要固定 1240px 高分辨率 PNG，屏幕卡片需要适配设备宽度和交互动效。两者目标不同，所以分享图由 `NoteReviewShareImageRenderer` 独立离屏渲染。

### 5. 页面可以绕过 ViewModel 直接读 Repository 吗？
不可以。数据访问必须通过 ViewModel 调用 Repository，页面只消费可观察状态和触发用户动作。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
