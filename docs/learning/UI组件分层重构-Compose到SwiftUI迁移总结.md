# UI组件分层重构 - Compose 到 SwiftUI 迁移总结

## 1. 本次 iOS 知识点
- `PBXFileSystemSynchronizedRootGroup` 项目下，文件移动后无需手改 `project.pbxproj`，Xcode 会按目录自动同步源码。
- SwiftUI 同模块跨目录访问无需 import 子模块；类型可直接使用，适合按职责拆目录。
- 可复用 UI 应与工具类解耦：
  - `UIComponents/` 只放 `View` 及与 UI 强相关的样式扩展。
  - `Utilities/` 保留 Design Token 与非 UI 工具，避免职责漂移。
- 架构守护要自动化：通过脚本校验“新增组件 -> 术语表同步”比人工约束更稳定。

## 2. Android Compose 对照思路
- Compose 的 `ui-components` 模块，对应 SwiftUI 的 `UIComponents/` 目录。
- Compose 的 `design system`（spacing/color/shape token），对应 iOS 的 `DesignTokens.swift`。
- Compose 页面不应直接拼装底层样式实现，SwiftUI 同理，页面应组合 `UIComponents`。

## 3. 可运行对照示例
### 3.1 Android Compose
```kotlin
@Composable
fun TopBarScaffold(
    title: String,
    onAddBook: () -> Unit,
    onAddNote: () -> Unit,
    content: @Composable () -> Unit
) {
    Column {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 8.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Text(text = title, style = MaterialTheme.typography.titleLarge)
            IconButton(onClick = onAddBook) { Icon(Icons.Default.Add, contentDescription = "添加") }
        }
        content()
    }
}
```

### 3.2 SwiftUI
```swift
import SwiftUI

struct TopBarScaffold<Content: View>: View {
    let title: String
    let onAddBook: () -> Void
    let onAddNote: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            TopSwitcher(title: title) {
                AddMenuCircleButton(
                    onAddBook: onAddBook,
                    onAddNote: onAddNote,
                    usesGlassStyle: true
                )
            }
            content()
        }
    }
}
```

## 4. 迁移结论
- 不要把 UI 组件塞进 `Utilities`：这会把“复用 UI 语义”和“工具函数语义”混成一层。
- 推荐结构：`UIComponents/Foundation + TopBar + Tabs`，页面层只做组合，不做重复实现。
- 当组件规模增长时，继续演进为“一组件一文件”，避免聚合文件再次膨胀。
- 每次新增核心组件都要同时更新术语表与校验脚本规则，确保团队描述与代码一致。
