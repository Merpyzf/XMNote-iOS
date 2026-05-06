# XMYearMonthPickerSheet 使用说明

## 组件定位
- 源码路径：`xmnote/UIComponents/Foundation/XMYearMonthPickerSheet.swift`
- 角色：项目级年月/年份随机访问选择 Sheet，统一承接“选择年月”和“选择年份”两类轻量跳转任务。
- 边界：组件只负责 Sheet 内 UI、草稿年份状态、可选项禁用与选择回调；业务状态提交、Sheet 呈现、dismiss 后动画切换由宿主页面负责。

## 快速接入
```swift
@State private var isPickerPresented = false
@State private var pendingMonthSelection: Date?

.sheet(isPresented: $isPickerPresented, onDismiss: {
    guard let month = pendingMonthSelection else { return }
    pendingMonthSelection = nil
    withAnimation(.snappy(duration: 0.3)) {
        pagerSelection = month
    }
}) {
    XMYearMonthPickerSheet(
        availableMonths: availableMonths,
        selectedMonth: pagerSelection,
        currentMonth: Calendar.current.startOfDay(for: Date()),
        calendar: Calendar.current,
        onSelectMonth: { month in
            pendingMonthSelection = month
        },
        onCancel: {
            pendingMonthSelection = nil
        }
    )
    .presentationDetents([.height(XMYearMonthPickerSheet.preferredPresentationHeight(for: dynamicTypeSize, mode: .yearMonth))])
    .presentationDragIndicator(.hidden)
    .presentationBackground(.regularMaterial)
}
```

## 参数说明
### 年月模式初始化
| 参数 | 类型 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `title` | `String` | `选择年月` | Sheet 顶部居中标题，可由业务覆盖。 |
| `availableMonths` | `[Date]` | 无 | 可选择月份集合；组件会归一到月份首日、去重并排序。 |
| `selectedMonth` | `Date` | 无 | 当前已选月份，用于强选中态。 |
| `currentMonth` | `Date` | 无 | 当前自然月份，用小圆点标识。 |
| `calendar` | `Calendar` | 无 | 日期归一、年月拆解与月份生成所用日历。 |
| `onSelectMonth` | `(Date) -> Void` | 无 | 用户点击可用月份后的回调；组件随后 dismiss。 |
| `onCancel` | `() -> Void` | `{}` | 点击右上 X 时清理宿主 pending 状态。 |

### 年份模式初始化
| 参数 | 类型 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `title` | `String` | `选择年份` | Sheet 顶部居中标题，可由业务覆盖。 |
| `availableYears` | `[Int]` | 无 | 可选择年份集合；组件保持调用方顺序并去重。 |
| `selectedYear` | `Int` | 无 | 当前已选年份，用于强选中态。 |
| `currentYear` | `Int` | 无 | 当前自然年份，用小圆点标识。 |
| `calendar` | `Calendar` | 无 | 保留统一签名，便于未来扩展日历语义。 |
| `onSelectYear` | `(Int) -> Void` | 无 | 用户点击年份后的回调；组件随后 dismiss。 |
| `onCancel` | `() -> Void` | `{}` | 点击右上 X 时清理宿主 pending 状态。 |

### 高度入口
| 方法 | 说明 |
| --- | --- |
| `preferredPresentationHeight(for:mode:)` | 根据 Dynamic Type 与模式返回固定 detent；年月模式为较高内容，年份模式为轻量内容。 |

## 示例
### 示例 1：阅读日历月份随机访问
```swift
XMYearMonthPickerSheet(
    availableMonths: props.availableMonths,
    selectedMonth: props.pagerSelection,
    currentMonth: Self.monthStart(of: Date(), using: Calendar.current),
    calendar: Calendar.current,
    onSelectMonth: { monthStart in
        pendingYearMonthPickerSelection = monthStart
    },
    onCancel: {
        pendingYearMonthPickerSelection = nil
    }
)
```

### 示例 2：阅读日历年度模式年份选择
```swift
XMYearMonthPickerSheet(
    availableYears: props.availableYears,
    selectedYear: props.selectedYear,
    currentYear: Calendar.current.component(.year, from: Date()),
    calendar: Calendar.current,
    onSelectYear: { year in
        pendingYearPickerSelection = year
    },
    onCancel: {
        pendingYearPickerSelection = nil
    }
)
```

### 示例 3：时间线远距离月份跳转
```swift
func commitPendingSheetMonthSelection() {
    guard let monthStart = pendingSheetMonthSelection else { return }
    pendingSheetMonthSelection = nil
    performCalendarLongJump(
        selectedDay: monthStart,
        monthStart: monthStart
    )
}
```

## 常见问题
### 1) 为什么组件不直接修改业务状态？
年月选择属于随机访问。Sheet 的选择过程和主内容切换应该分层，宿主在 dismiss 后提交真实状态，可以避免底层日历动画与弹层生命周期叠加。

### 2) 为什么保留 `pending` 状态？
`pending` 表示“用户在 Sheet 内已经做出选择，但业务内容还没切换”。这能让关闭动作、取消动作和最终提交形成清晰状态边界。

### 3) 为什么年份模式保持调用方顺序？
有些业务希望年份倒序展示，有些业务希望正序浏览。组件不替业务重新排序，只做去重和空集合兜底。

### 4) 什么时候不应该使用这个组件？
完整日期选择、时间选择、左右相邻月份浏览不属于随机访问场景，应继续使用对应业务控件或系统 DatePicker，不要强行套用这个 Sheet。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
