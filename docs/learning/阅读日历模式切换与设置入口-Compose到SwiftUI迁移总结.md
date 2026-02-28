# 阅读日历模式切换与设置入口（Compose -> SwiftUI）迁移总结

## 1. 本次 iOS 知识点
- 页面级设置入口应放在导航栏 `toolbar`，内容级切换放在组件内部，避免控制层级混杂。
- `Picker(.segmented)` 适合承载同级“视图模式”切换；在空间受限时可使用图标分段。
- 将月份选择与模式切换收敛到同一行，可显著减少顶部纵向占用。
- 顶部月份触发器在沉浸型内容页应优先无背景文本样式，避免“控件悬浮层”打断阅读节奏。
- 多交互入口要收敛到单一状态源：
  - 月份切换收敛到 `pagerSelection`
  - 模式切换收敛到 `displayMode`

## 2. Compose -> SwiftUI 思维对照
| 目标 | Android Compose 常见做法 | SwiftUI 本次做法 | 迁移原则 |
|---|---|---|---|
| 模式切换 | `TabRow` / `SegmentedButtonRow` | `Picker` + `.segmented` | 同级模式用同级控件 |
| 页面设置入口 | `TopAppBar` 右侧 `IconButton` | `toolbar(.topBarTrailing)` + `sheet` | 全局入口放导航层 |
| 模式状态共享 | `rememberSaveable` + hoisted state | `@State` + `Binding` | 单一状态源，跨组件透传 |
| 月份直达 | `DropdownMenu` | `Menu` 挂在月份标题 | 降低跨月导航成本 |

## 3. 可运行 SwiftUI 示例
```swift
import SwiftUI

enum CalendarDisplayMode: String, CaseIterable, Hashable {
    case heatmap = "热力图"
    case activity = "活动事件"
    case cover = "书籍封面"
}

struct CalendarDemoView: View {
    @State private var mode: CalendarDisplayMode = .activity
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 16) {
            Picker("显示模式", selection: $mode) {
                ForEach(CalendarDisplayMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Text("当前模式：\(mode.rawValue)")
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer()
        }
        .padding()
        .navigationTitle("阅读日历")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                Form {
                    Picker("默认模式", selection: $mode) {
                        ForEach(CalendarDisplayMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                }
                .navigationTitle("阅读日历设置")
            }
        }
    }
}
```

## 4. Compose 对照示例（核心意图）
```kotlin
@Composable
fun CalendarScreen() {
    var mode by rememberSaveable { mutableStateOf("activity") }
    var showSettings by rememberSaveable { mutableStateOf(false) }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("阅读日历") },
                actions = {
                    IconButton(onClick = { showSettings = true }) {
                        Icon(Icons.Default.Settings, contentDescription = null)
                    }
                }
            )
        }
    ) { padding ->
        Column(Modifier.padding(padding)) {
            // 伪代码：可替换为 SegmentedButtonRow
            Text("mode = $mode")
        }
    }
}
```

## 5. 迁移结论
- 月份导航、模式切换、设置入口必须分层：月份和模式属于内容控制，设置属于页面控制。
- 多入口状态如果不收敛，会出现 UI 同步延迟和回写冲突；单一状态源是稳定关键。
- “先做 UI 交互稿，再逐步接业务”是 Android -> iOS 迁移中降低回归风险的有效路径。
