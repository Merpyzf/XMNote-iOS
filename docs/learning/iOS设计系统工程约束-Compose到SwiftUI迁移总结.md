# iOS 设计系统工程约束：Compose 到 SwiftUI 迁移总结

## 1. 本次建设解决了什么

视觉相似不等于存在设计系统。只有当规则具备稳定 owner、唯一使用入口、自动发现路径和可执行闸门时，新增页面才不会依赖开发者或 AI 的临场审美。

XMNote 本次把设计基建收敛为四个层次：

1. `Utilities/DesignSystem` 持有字体、颜色、间距、圆角和交互尺寸。
2. `UIComponents` 持有经过多个生产场景证明的 Settings 与 Sheet 组合能力。
3. `Views` 只组合业务界面，保留没有复用证据的局部差异。
4. `scripts/design-system` 用 SwiftSyntax、policy 和 component catalog 把“建议”变成可发现、可阻断的工程路径。

核心经验是：先收敛 owner，再抽象组件，最后增加机器约束。若先写 lint、但仓库没有正确入口，工具只会告诉开发者“不能这样做”，却无法告诉他“应该去哪做”。

## 2. 设计令牌：从集中大文件到职责稳定的 owner

Compose 项目常用一个 `object Dimens`、`MaterialTheme` 或集中 token 文件。文件规模小时很直接，但字体、颜色、业务主题和构造 helper 混在一起后，任何修改都容易扩大影响面。

SwiftUI 侧按职责拆分：

```text
DesignSystem/
├── AppTypography.swift
├── SharedContentTypography.swift
├── SemanticColors.swift
├── ColorConstruction.swift
├── Spacing.swift
├── CornerRadius.swift
└── InteractionMetrics.swift
```

对应 Compose 可以理解为：

```kotlin
object AppTypography
object ContentTypography
object AppColors
object Spacing
object Shapes
object InteractionMetrics
```

关键不在于拆成多少文件，而在于每个入口回答一个明确问题：

- 这段文字属于什么阅读层级？
- 这个颜色表达什么业务角色？
- 这个距离是通用节奏还是页面几何？
- 这个圆角属于内嵌元素、内容块还是外层容器？
- 视觉尺寸与触控热区是否被混为一谈？

## 3. 语义 token 不等于数字字典

下面两段代码数值可能相同，但语义并不相同：

```swift
.padding(.horizontal, Spacing.screenEdge)
.frame(minHeight: InteractionMetrics.minimumTouchTarget)
```

一个表达页面内容边界，一个表达触控安全。即使当前都是相近数值，也不能互换。

Compose 同理：

```kotlin
Modifier.padding(horizontal = AppSpacing.screenEdge)
Modifier.minimumInteractiveComponentSize()
```

成熟的 token 准入需要同时满足：

- 至少两个独立生产场景。
- 相同语义，而不是数值相同。
- 相同的变化原因和演进方向。
- 现有 token 无法准确表达。

单页特殊值应使用页面私有 `Layout` / `Metrics` 常量。把每一个数字塞进全局 `Spacing` 会降低而不是提高一致性，因为调用方无法从名称判断真正用途。

## 4. Settings：组合语法优于万能 Row

四个配置页面已经证明页面、分区、分组、菜单值行和开关行具有稳定语义，因此公共层只提供这些能力：

```swift
XMSettingsPage {
    XMSettingsSection("模型服务") {
        XMSettingsGroup {
            VStack(spacing: Spacing.none) {
                XMSettingsToggleRow(
                    title: "启用 AI 功能",
                    isOn: $viewModel.isEnabled
                )
                XMSettingsDivider()
                providerRow
            }
        }
    }
}
```

Compose 的对应表达可以是：

```kotlin
SettingsPage {
    SettingsSection(title = "模型服务") {
        SettingsGroup {
            SettingsToggleRow(
                title = "启用 AI 功能",
                checked = state.enabled,
                onCheckedChange = onEnabledChange,
            )
            SettingsDivider()
            ProviderRow(...)
        }
    }
}
```

不要急于增加这样的接口：

```swift
UniversalSettingsRow(
    icon: ..., title: ..., subtitle: ..., value: ...,
    toggle: ..., menu: ..., loading: ..., error: ...,
    accessory: ..., onTap: ...
)
```

参数越多，越说明组件正在吞噬不同业务状态。图标双行、凭证输入、账号摘要和异步状态应保留为页面私有组合；只有后续两个独立页面证明相同边界后再新增专用行型。

## 5. Sheet：slot API 与类型安全

`XMSheetScaffold` 使用泛型 `ViewBuilder` 槽位组合标题操作、内容顶栏、滚动内容和底部操作：

```swift
XMSheetScaffold(
    title: "选择书籍",
    onClose: { dismiss() },
    contentTopBar: { scopeSelector },
    bottomBar: { confirmButton }
) {
    bookList
}
```

这与 Compose 的 slot API 很接近：

```kotlin
SheetScaffold(
    title = "选择书籍",
    topBar = { ScopeSelector(...) },
    bottomBar = { ConfirmButton(...) },
) {
    BookList(...)
}
```

SwiftUI 侧应保持具体泛型类型，不用 `AnyView`。类型擦除会隐藏真实结构、削弱 diff 身份，也让 AI 更难从接口判断哪些结构被允许。

Scaffold 只统一：

- 标题与操作位置。
- 滚动和全轴回弹。
- 固定顶栏/底栏与 scroll edge 的连接。
- 页面背景与安全区关系。

业务状态、保存逻辑、Repository 和校验规则仍留在功能模块。

## 6. Domain 与 UI 映射

领域层不应为了“方便显示”持有 SwiftUI `Color`。正确做法是保留纯值：

```swift
enum HeatmapLevel: Sendable {
    case none, veryLess, less, more, veryMore
}
```

在 UI 层映射：

```swift
extension HeatmapLevel {
    var presentation: HeatmapLevelPresentation {
        // 文案与语义色映射
    }
}
```

Compose 中也应避免 Domain model 直接持有 `Color`、`Painter` 或 `ImageVector`。领域值属于可测试、可序列化的业务层；主题色和图标属于 presentation。

## 7. SwiftSyntax 让规范真正可执行

简单文本搜索无法可靠区分：

- `Image.font(.system(...))` 的图标 glyph 尺寸与生产文本字体。
- padding 的直接魔法数字与嵌套索引计算。
- 颜色定义 owner 与页面旁路构色。
- Domain import 与注释、字符串中的同名文本。

SwiftSyntax 规则基于语法节点定位，并输出：

- 规则 ID。
- 文件、行列和所属声明。
- 触发证据。
- 正确实现入口。

规则分两类：

- enforced：证据明确且存在唯一正确路径，直接阻断。
- report：必须结合业务上下文判断，只提供审查线索。

例如字面量动画时长可能是合理的局部时序。把它直接设为 enforced 会诱导开发者创建没有语义的全局 motion token，因此当前只报告观察。

## 8. baseline 不是永久豁免

规则首次引入时可以用 baseline 锁定历史债务，让新增代码先受约束，再分阶段偿还旧问题。但 baseline 必须有退出条件：

- 记录 fingerprint、owner、原因和复查阶段。
- 新代码不能进入 baseline。
- 历史项迁移后立刻刷新。
- 清零后保持 0，不得为了“先过构建”重新写入。

若规则误报，应提供最小复现并修正规则，而不是对整个目录增加 exclude。

## 9. AI 友好的唯一修改路径

AI 在修改 UI 前不需要猜测规范文件，先执行：

```bash
python3 scripts/design-system/ds.py context --paths xmnote/Views/Personal/AIConfigurationView.swift
python3 scripts/design-system/ds.py catalog --symbol Settings
```

实现中执行：

```bash
python3 scripts/design-system/ds.py lint --changed
python3 scripts/design-system/ds.py explain DS003
```

收口执行：

```bash
python3 scripts/design-system/ds.py audit
make -f Makefile.parallel-ios ai-ui-lint-test
make -f Makefile.parallel-ios ai-build
```

这条路径同时提供“有什么规则”“为什么触发”“正确入口在哪里”和“已有组件能否复用”。文档、机器目录和代码 owner 三者必须同步；任何一层过期都会重新增加 AI 的自由发挥空间。

## 10. 验收经验

代码审计可以证明依赖方向、硬编码和 API 使用，不能证明真实视觉密度。配置类页面至少需要在专用模拟器检查：

- 浅色与深色语义色。
- 较大 Dynamic Type 下的自然增高和滚动可达性。
- 标准行与操作至少 44pt 热区。
- 分区标题、卡片、行和说明之间的亲密性。
- 底部导航、安全区与最后一项内容的关系。

本次四个配置页面表明：成熟设计系统不是让页面“长得完全一样”，而是让页面结构、文本层级、表层、控件热区和状态语义一致；业务内容仍然保有自己的信息组织。

## 11. 圆角分层：按角色复用，而不是按组件复制名称

截图测量得到 4pt、12pt、24pt 后，不能直接追加 `tagContainer`、`contentItem`、`settingsGroup` 三个同值 token。更稳定的做法是先判断轮廓角色：

```swift
CornerRadius.inlaySmall    // 4pt：纯展示领域标签
CornerRadius.blockLarge    // 12pt：标准内容卡片
CornerRadius.containerXXL  // 24pt：大型设置分组
```

Compose 侧可以对应理解为小型内嵌 Shape、内容 Card Shape 与大型 Settings Group Shape。关键不是两端名称完全一致，而是同一 token 的使用方具有相同变化原因。

`XMTagLabel` 进一步把 4pt 连续圆角、标签背景、caption2 排版和内边距锁在组件内部。筛选 Chip、状态、评分、指标与操作型 Capsule 不复用它，因为这些场景虽然外形相似，但具有不同状态边界和交互语义。

`XMSettingsGroup` 同样固定消费 24pt grouped 圆角，不再允许页面注入覆盖值。这类“接口收窄”比在文档中建议统一更有效：开发者和 AI 都只有一个合规实现入口。

## 12. 44pt 是默认风险基线，不是强迫布局变松的排版命令

触控热区的第一性目标是降低误触和获取成本，而不是让每个可点击元素都占据相同几何尺寸。主操作、导航与关闭、破坏性操作、高频交互、独立图标和表单控件都直接影响任务完成或错误成本，因此继续执行 44pt 默认基线。

副标题、状态、元数据等内联次级文字可能同时承担低频辅助入口。如果它以信息展示为主、操作非破坏性、不是完成主任务的必要入口，并且扩展热区反而会让整片标题空白响应点击，就可以保留文字自然命中范围。判断顺序必须是业务角色、操作后果、任务必要性和邻近命中关系；“低频”不能单独构成例外。

SwiftUI 侧仍使用原生语义控件：

```swift
// 该文本以副标题信息展示为主，管理入口低频且非破坏性；保留文字自然命中范围，避免标题栏空白响应点击。
Button("已选择 \(selectedCount) 本", action: openSelectedBooks)
    .buttonStyle(.plain)
    .accessibilityLabel("已选择 \(selectedCount) 本书")
    .accessibilityHint("查看并管理已选书籍")
```

这里不能退化为 `onTapGesture`，也不能新增 20pt、24pt 等“小点击区域 token”。例外描述的是业务语义，不是另一套尺寸系统；一旦该入口变成主要、独立、高频或高风险操作，就应恢复 `InteractionMetrics.minimumTouchTarget`。

Compose 迁移时同样先迁移业务角色，再按 Android 当前平台规范决定是否保留自然范围，不能机械复制 iOS 的 44pt 或例外尺寸：

```kotlin
Text(
    text = "已选择 $selectedCount 本",
    modifier = Modifier.clickable(
        role = Role.Button,
        onClick = onOpenSelectedBooks,
    ),
    style = MaterialTheme.typography.labelSmall,
    color = MaterialTheme.colorScheme.onSurfaceVariant,
)
```

双端共同的验收重点是语义明确、辅助技术可识别、点击文字有效、周围空白不误触、邻近控件不产生歧义；平台默认最小热区仍分别服从各自规范。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
