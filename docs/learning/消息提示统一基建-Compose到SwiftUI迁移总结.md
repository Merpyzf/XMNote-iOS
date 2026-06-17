# 消息提示统一基建 - Compose 到 SwiftUI 迁移总结

## 1. 本次 iOS 知识点
- SwiftUI 可以用 `@Observable` 对象作为全局轻状态中心，并通过 `.environment(...)` 注入根视图树。
- 第三方呈现库应隐藏在基础设施层：业务代码调用 `XMToastCenter`，不直接依赖 `PopupView`。
- 轻提示适合用 newest-wins 策略：连续触发时只显示最新一条，避免队列堆叠遮挡内容。
- Toast 属于非阻塞反馈，不替代 `XMSystemAlert` 的确认/输入语义，也不替代 `LoadingGate` 的页面主加载语义。
- Reduce Motion 应在 Host 层统一处理，让业务调用方不需要理解动画细节。

## 2. Android Compose 对照思路
- Compose 的 `SnackbarHostState` 对应 iOS 的 `XMToastCenter`：页面只提交消息，Host 负责展示。
- Compose 的 `SnackbarHost` 对应 iOS 根部 `.xmToastHost(center:)`：统一控制位置、安全区、动画和 dismiss 行为。
- Android Toast / Snackbar 的业务意图是“轻量、短暂、不打断任务”，迁移到 iOS 时要避免中心弹窗化，也要避开顶部主信息区域。

## 3. 可运行对照示例
### 3.1 Android Compose
```kotlin
@Composable
fun ToastHostExample(
    snackbarHostState: SnackbarHostState = remember { SnackbarHostState() }
) {
    val scope = rememberCoroutineScope()

    Scaffold(
        snackbarHost = { SnackbarHost(snackbarHostState) }
    ) { padding ->
        Button(
            modifier = Modifier.padding(padding),
            onClick = {
                scope.launch {
                    snackbarHostState.currentSnackbarData?.dismiss()
                    snackbarHostState.showSnackbar("已保存")
                }
            }
        ) {
            Text("保存")
        }
    }
}
```

### 3.2 SwiftUI
```swift
@main
struct xmnoteApp: App {
    @State private var toastCenter = XMToastCenter()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(toastCenter)
                .xmToastHost(center: toastCenter)
        }
    }
}

struct SaveButton: View {
    @Environment(XMToastCenter.self) private var toastCenter

    var body: some View {
        Button("保存") {
            toastCenter.success("已保存")
        }
    }
}
```

## 4. 迁移结论
- 不要让页面直接接触底层 Toast 库；一旦业务散落 `.popup(...)` 参数，后续改样式或替换库会变成全局扫雷。
- SwiftUI 根 Host + 环境注入可以实现与 Compose `SnackbarHost` 类似的架构边界。
- 轻提示要保持短、稳、少：文案短，动效克制，显示一条，背景可继续操作。
- 处理中反馈必须由结果态收口，避免用户误判写操作已经完成。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
