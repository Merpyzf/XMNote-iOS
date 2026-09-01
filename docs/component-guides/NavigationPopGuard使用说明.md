# NavigationPopGuard 使用说明

## 组件定位

- 源码路径：`xmnote/UIComponents/Navigation/NavigationPopGuard.swift`。
- 入口：`View.navigationPopGuard(canPop:onAllowedPopStart:onDidAppear:onBlockedAttempt:)`。
- 角色：页面使用自定义返回入口时，继续保留系统交互式返回手势，并把允许返回、阻断尝试和页面重新出现回调交给业务 owner。
- 边界：组件只桥接 `UINavigationController` 生命周期和手势决策，不持有草稿、保存状态、Alert 或路由。

## 快速接入

```swift
EditorContent()
    .navigationBarBackButtonHidden(true)
    .navigationPopGuard(
        canPop: !hasUnsavedChanges && !isSaving,
        onAllowedPopStart: prepareForExit,
        onDidAppear: restoreEditingFocus,
        onBlockedAttempt: presentUnsavedChangesAlert
    )
```

自定义顶部返回按钮必须调用与 `onBlockedAttempt` 相同的业务退出入口，避免按钮返回和边缘返回出现两套判断。

## 参数说明

| 参数 | 说明 |
| --- | --- |
| `canPop` | 当前是否允许系统导航栈返回；应由页面业务状态派生。 |
| `onAllowedPopStart` | 已允许的交互式或程序化返回开始前回调，用于同步收起焦点、键盘和临时 chrome。 |
| `onDidAppear` | 页面首次完整出现或交互式返回取消后回调，用于恢复页面级可见状态。 |
| `onBlockedAttempt` | 用户尝试返回但 `canPop == false` 时回调，由页面决定是否呈现保存/放弃确认。 |

所有回调均为 UI 生命周期入口，不应在其中直接访问数据库或网络客户端。

## 示例

```swift
struct DraftEditor: View {
    @State private var text = ""
    @State private var persistedText = ""
    @State private var showsExitConfirmation = false

    var body: some View {
        TextEditor(text: $text)
            .navigationBarBackButtonHidden(true)
            .navigationPopGuard(
                canPop: text == persistedText,
                onBlockedAttempt: {
                    showsExitConfirmation = true
                }
            )
    }
}
```

生产页面仍需使用项目统一 Alert 入口处理退出决策；示例只展示返回条件与阻断信号的归属。

## 常见问题

### 没有未保存状态也需要接入吗？

不需要。普通 `NavigationStack` 页面优先保留系统返回按钮和默认手势；只有自定义返回且确实需要阻断时才使用本组件。

### 为什么需要 `onAllowedPopStart`？

交互式返回的转场在导航栈真正移除页面前开始。页面若有键盘、悬浮工具栏或其他临时 chrome，可在允许返回的起点同步收起，避免它们参与逆转场。

### `onDidAppear` 会在什么时候调用？

页面首次完整出现以及交互式返回被用户取消后都会进入。调用方应让处理幂等，不要在这里重复创建不可取消任务或重复提交业务写入。

### 能否在组件内部直接弹未保存确认？

不能。不同页面的脏状态、动作文案、保存条件和失败恢复不同；组件只报告阻断尝试，决策继续由业务页面持有。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
