# 年月选择 Sheet 状态隔离 - Compose 到 SwiftUI 迁移总结

## 1. 本次 iOS 知识点
- 随机访问型选择器适合用 Sheet 承载，而不是让菜单浮层直接驱动底层主内容结构切换。
- SwiftUI 的 `.contentTransition(.numericText())` 需要有明确动画事务承载；选择器关闭后的宿主提交更容易保证标题数字过渡和主内容切换同节奏。
- Sheet 内状态与页面业务状态要分层：Sheet 只维护草稿年份和可选项 UI，页面用 `pending` 暂存选择结果，在 `onDismiss` 中提交真实业务状态。
- 远距离跳转不应模拟跨多页滑动。对日历这类分页内容，随机访问可以用标题数字过渡 + 网格淡出/定位/淡入，避免跨多月拖影。
- Dynamic Type 下，固定标题栏应脱离滚动区；内容区滚动、标题和关闭按钮保持稳定，有利于可访问性和任务聚焦。

## 2. Android Compose 对照思路
| Android Compose | SwiftUI | 迁移策略 |
| --- | --- | --- |
| `ModalBottomSheet` | `.sheet` + `presentationDetents` | 用底部 Sheet 承载聚焦选择任务。 |
| `rememberSaveable` 草稿状态 | `@State` 草稿状态 | Sheet 内局部状态不直接写业务 ViewModel。 |
| `onDismissRequest` | `.sheet(onDismiss:)` | 关闭后再提交 pending 选择，避免动效叠层。 |
| `LazyVerticalGrid` | `LazyVGrid` | 年/月选项按网格表达，Dynamic Type 下切换列数。 |
| `AnimatedContent` 数字变化 | `.contentTransition(.numericText())` | 年月标题在宿主动画事务里滚动过渡。 |

## 3. 可运行对照示例
### 3.1 Android Compose
```kotlin
@Composable
fun YearMonthPickerHost(
    selectedMonth: YearMonth,
    availableMonths: List<YearMonth>,
    onMonthSelected: (YearMonth) -> Unit
) {
    var showSheet by rememberSaveable { mutableStateOf(false) }
    var pendingMonth by rememberSaveable { mutableStateOf<YearMonth?>(null) }

    Button(onClick = { showSheet = true }) {
        Text("${selectedMonth.year}年${selectedMonth.monthValue}月")
    }

    if (showSheet) {
        ModalBottomSheet(
            onDismissRequest = {
                showSheet = false
                pendingMonth?.let(onMonthSelected)
                pendingMonth = null
            }
        ) {
            LazyVerticalGrid(columns = GridCells.Fixed(3)) {
                items(availableMonths) { month ->
                    Button(
                        onClick = {
                            pendingMonth = month
                            showSheet = false
                        }
                    ) {
                        Text("${month.monthValue}月")
                    }
                }
            }
        }
    }
}
```

### 3.2 SwiftUI
```swift
struct YearMonthPickerHost: View {
    @State private var isPickerPresented = false
    @State private var pendingMonth: Date?
    @State private var selectedMonth: Date

    let availableMonths: [Date]

    var body: some View {
        Button {
            pendingMonth = nil
            isPickerPresented = true
        } label: {
            Text(selectedMonth, format: .dateTime.year().month())
                .contentTransition(.numericText())
        }
        .sheet(isPresented: $isPickerPresented, onDismiss: {
            guard let pendingMonth else { return }
            self.pendingMonth = nil
            withAnimation(.snappy(duration: 0.3)) {
                selectedMonth = pendingMonth
            }
        }) {
            XMYearMonthPickerSheet(
                availableMonths: availableMonths,
                selectedMonth: selectedMonth,
                currentMonth: Date(),
                calendar: .current,
                onSelectMonth: { month in
                    pendingMonth = month
                },
                onCancel: {
                    pendingMonth = nil
                }
            )
        }
    }
}
```

## 4. 迁移结论
- Compose 和 SwiftUI 都应避免“浮层还在关闭、底层主内容已经开始重排”的交互叠层。
- Sheet 选择器的通用边界是“选择 UI + 草稿状态 + 回调”，不是“操作 ViewModel”。
- 年月/年份这种随机访问控件应优先沉淀为项目级基础组件，页面层只负责数据范围、当前值和 dismiss 后提交。
- 当同一选择模式出现在多个页面时，优先统一交互生命周期，再统一视觉细节；这比在每个页面里微调 delay 更稳定。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
