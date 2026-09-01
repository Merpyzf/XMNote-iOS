# 业务 Sheet

本参考只约束 XMNote 业务 Sheet 的系统级骨架与跨场景设计语言，不规定业务内容必须使用相同的 `VStack` 间距、Section 数量、表单结构、列表形式或文本组合。新增、修改或审查 Sheet 时读取本文件；任务同时涉及骨架之外的组件归位、通用颜色或固定圆角 token 时，再组合读取 [组件与交互](components-and-interaction.md)、[颜色、表层、图标与材质](color-surfaces-and-material.md) 或 [排版、间距与布局](typography-and-layout.md)。

## 事实来源与判断顺序

- 普通 Sheet 工作先读取当前工作区的 `XMSheetScaffold`、`CardContainer`、`XMScrollEdgeChrome` 真实 owner，再核对 catalog 和场景最接近的成熟生产消费者；只有修改或晋升长期规则时，才要求至少两个独立生产场景及 Preview/运行证据。
- 旧提交、组件指南、单个业务页面和 Debug 验证宿主只提供线索；与当前 owner 冲突时不能覆盖已落地骨架。
- 平台原则只校验项目实现是否明显偏离 iOS，不借 HIG 重新设计已成熟且合理的 XMNote 视觉语言。优先级为：当前成熟实现 > 项目设计语言 > Apple 平台原则 > 新的设计推导。
- 骨架没有覆盖某个业务布局时，选择用户任务、信息密度和交互关系最接近的成熟生产 Sheet，复用其组织逻辑，不复制孤立尺寸或从空白重新发明布局。
- Apple API、可用性与系统行为必须通过 `apple-doc-mcp` 重新确认；本参考不替代当前 SDK 文档。

## 先选择正确的呈现入口

| 场景 | 默认入口 | 边界 |
| --- | --- | --- |
| 单层、短时且与当前上下文直接相关的业务任务 | `XMSheetScaffold` | 标准标题、关闭/确认、滚动内容和可选固定栏 |
| 中心确认、警告、风险决策或轻量输入 | `XMSystemAlert` | 不用业务 Sheet 模拟中心弹窗 |
| 系统照片、文件、分享、日期等原生流程 | 对应系统入口或已登记桥接 | 不为统一外观再套 `XMSheetScaffold` |
| Sheet 内需要稳定 navigation path 或后续页面 | 专项 `NavigationStack` owner | 不在 `XMSheetScaffold` 内嵌第二个导航栈；后续页使用系统 Back |
| 原生 `List/Form` 必须成为主滚动 owner，或存在特殊流式/安全区行为 | 已验证的专项 Sheet 骨架 | 仍延续本文件的系统标题、toolbar placement、背景和交互锁语言 |

手工系统骨架是有证据的例外，不是绕过 scaffold 后重新自绘 Header、关闭按钮、滚动边缘或 Sheet 外壳的许可。

同一任务在 Sheet 内继续深入时，优先在现有导航上下文 push 后续页面，不叠加第二个 Sheet。只有后续任务确实是独立模态关系且已有场景证据时，才允许再次呈现 Sheet。

## 标准骨架合同

普通单层业务 Sheet 使用 `XMSheetScaffold`，由它统一持有：

- 系统 `NavigationStack`、inline `navigationTitle` 与 toolbar。
- `surfaceSheet` 内容底板；调用方不重复根背景，也不在内容层叠加自定义 material。系统外层 presentation 材质保持由呈现宿主持有，覆盖它需要明确场景证据。
- `.cancellationAction` 中的标准关闭入口，以及需要提交时 `.confirmationAction` 中的标准确认入口。
- 单一 `ScrollView`、隐藏滚动条、全轴回弹和标题区后的标准内容顶部距离。
- 保存中或业务显式锁定时的内容禁用与交互式收起保护。
- 可选 `contentTopBar` / `bottomBar` 与 `XMScrollEdgeChrome` 协同。

调用方继续持有业务内容组合、校验与保存状态、焦点、错误恢复、横向/底部内容边距、Detent、drag indicator 和 presentation 关系。不得把 Repository、ViewModel、领域 phase 或业务枚举下沉到 scaffold。

页面不得重复 scaffold 已经持有的导航栈、标题栏、关闭按钮、根背景、普通内容顶部 padding、滚动回弹、交互锁或固定栏边缘效果。发现重复时先修到真实 owner，不把遗留调用方式晋升为规范。

## 标题与顶部操作

- 静态副标题使用 scaffold 的 `subtitle`，由系统 `navigationSubtitle` 呈现；页面不重建字体、颜色或标题—副标题间距。
- 只有动态或可交互的短辅助信息才考虑类型安全 `titleSubtitle` 槽位。它是已验证的专项槽位，不是静态 subtitle 的通用替代；新增语义先核对当前生产消费者。该槽位是单行导航 chrome，不承载长说明、错误或复杂状态。
- 默认关闭位于 `.cancellationAction`，确认位于 `.confirmationAction`；不要按物理左右位置自造按钮壳层。
- 单步 Sheet 有确认操作时必须同时有关闭或取消路径。多步流程后续页由 Back 替代 Cancel，避免同时出现 Back、Cancel、Done 三种退出语义。
- 标题文本区不放 spinner、长错误、双行操作说明或保存状态；标准确认控件可以在原位短时显示加载反馈。
- 图标按钮必须提供可理解的无障碍 label；不能只依赖 xmark、checkmark 的图形含义。
- 标准 checkmark 只表达标题上下文已经清楚的“完成编辑/接受选择”等可逆完成语义。恢复、删除、开始、解析、加入等结果特定或不可逆动作必须保留明确动词及 destructive/业务角色；不能为复用标准确认入口把它们抹平成绿色“确认”。当前 scaffold 接口无法表达时报告组件缺口，使用已验证的系统/专项入口，不扩展错误范例。
- 新调用方通过 scaffold 的 `confirmationAction` initializer 使用标准确认，不直接消费未在 catalog 登记的内部确认 View。现存手工系统 Sheet 的直接消费按 [组件与交互](components-and-interaction.md) 的未登记能力隔离流程处理。

## 提交与保存反馈

先判断数据何时生效，再选择唯一提交层级：

| 数据关系 | 入口 | 约束 |
| --- | --- | --- |
| Binding 或行操作即时生效，关闭不丢草稿 | close-only scaffold | 不添加“保存/完成”制造伪提交 |
| Sheet 持有普通、可逆，且标题已能说明结果的独立编辑草稿 | `confirmationAction` initializer | 传入 `isConfirmationDisabled` 与 `isConfirming`，由 scaffold 统一 checkmark、原位 loading 和交互锁 |
| 符合上一行标准确认语义的独立草稿，同时需要固定搜索或筛选 | `confirmationAction + contentTopBar` initializer | 提交仍在系统 confirmation placement，不下移复制 |
| 主操作确需全宽常驻，或复杂进度、禁用原因、失败必须与操作保持空间关系 | `bottomBar` | 作为有证据的例外；内容尾部和 toolbar 不再复制提交入口 |
| 标准关闭/确认无法表达真实的双侧动作语义 | 自定义 `leadingAction/trailingAction` | 严格 opt-in，使用原生控件与系统 placement，不复制普通取消/保存模式 |

- 同一 Sheet 只保留一个保存入口。业务状态决定能否提交，视觉禁用和确认中反馈交给标准入口表达。
- 表单较长本身不是选择 `bottomBar` 的依据；标准确认入口能够持续表达提交、禁用和原位加载时，继续使用 confirmation placement。
- `bottomBar` 只是 scaffold 的可选固定栏能力，不自动提供成熟的按钮、错误或进度组合处方；其内部业务布局保持 feature 私有，并在复制前取得运行证据。
- 保存开始后立即阻止重复提交以及会丢失草稿的关闭/交互收起；成功通过 dismiss 或内容变化表达，不额外增加成功 Toast。
- 标准确认入口的 loading 在原位呈现。长错误、失败原因或重试操作进入字段附近、滚动内容或与操作有空间关系的固定区域，不挤入导航标题。
- 字段可修复错误紧邻对应字段，允许换行；重新编辑时清除已经过期的提交错误。整体提交失败时保留草稿、选择和继续编辑路径。
- Scaffold 不定义通用异步字段校验视觉、debounce 时序或成功勾选；这些仍由 feature 状态 owner 管理。

## 内容、边距与滚动

- Scaffold 的 `content` 槽传入内容组合，不传入第二个 `ScrollView`。需要原生 `List/Form` 自持滚动时改用已验证的专项骨架。
- 没有 `contentTopBar` 时，scaffold 自动提供标题安全区后的标准顶部距离；调用方不再增加普通 `.padding(.top, ...)`。
- 存在 `contentTopBar` 时，scaffold 将普通内容顶部距离归零。固定搜索、筛选或摘要栏自行持有内部垂直节奏，避免双重间距。
- 自由内容通常在根组合施加一次 `Spacing.screenEdge` 横向安全边距；原生 `List/Form`、全宽内容或已经持有 inset 的 canonical 组件不再重复 padding。
- 底部内容空间按固定栏、Detent、键盘和内容关系选择语义 Spacing；不把一个业务 Sheet 的固定数值写成全局规则。
- `contentTopBar` / `bottomBar` 只用于滚动时必须固定的控件或状态。普通标题、说明和业务分区继续放在滚动内容中。
- 固定栏使用 `XMScrollEdgeChrome`。由其 owner 选择 contained/overlay 与系统 scroll-edge 风格；页面不默认强制 soft，也不叠加 blur、gradient、material 或硬分隔遮罩。

## 骨架统一，业务内容自由

Scaffold 不规定业务内部的 stack 数量、间距组合、Section 数量、表单结构、列表形式、文本排版或领域组件组合。内容 owner 应先明确主任务、信息组和操作关系，再选择最简单的现有组合。

- 配置 Sheet 不嵌套 `XMSettingsPage`，避免第二层滚动、重复背景和页面边距。
- 具有真实设置语义的分组使用 `XMSettingsSection/XMSettingsGroup`；业务输入、说明、错误、破坏性操作和领域组件仍可按场景私有组合。
- 简单说明、图例或只读标签流可以只使用排版、留白和对齐，不因没有卡片而被视为完成度不足。
- 原生 `List/Form/Section` 已经表达分组时，不为每行增加自定义卡片。
- 同质重复行默认使用系统列表、留白或 Divider；标准“封面/图标 + 主副文案 + 单一导航或选择动作”仍是普通媒体行，不因元素数量成为复合预览。只有额外独立预览区、共同反馈、多个独立操作或自包含摘要使单行真正形成第二层语义时才考虑卡片。现有页面已逐行用卡时先以截图核对其边界价值，不因抽象规则无证据地批量移除。
- 相近成熟实现只提供局部组合证据；不得把它的固定高度、私有 stack spacing 或 Section 数量复制成 Sheet 骨架要求。

## 白色卡片容器

Sheet 自身已经是容器。增加 `surfaceCard` 前必须说明它承担哪一种实际语义：独立信息组、复合控件边界、共同操作边界，或摘要/预览焦点。无法说明时不加卡片。

优先不使用卡片的场景：

- 简单说明、单一路径的帮助内容或短图例。
- 通过留白、标题、`Section`、系统分隔关系已经清楚的简单列表。
- 普通单组表单；“只有一组”或“页面很空”本身都不构成卡片理由。
- 原生 `List/Form`，以及已经持有背景或边界的 canonical 组件。

适合使用卡片的场景：

- 多个字段、计数、选择或局部说明共同构成一个复合输入/选择控件边界。
- 一组内容需要作为独立摘要、预览或主要焦点与周围信息区分。
- 多个元素共享同一操作、反馈或选择关系，拆开会破坏 Gestalt 分组。
- 多组内容确实具有独立语义；按语义成组，而不是把同一语义切成多个等权卡片。

容器选择与限制：

- Settings 语义使用 `XMSettingsGroup`；普通内容表层在核对 catalog 与真实 owner 后使用 `CardContainer`。Catalog 对“业务复合卡”的排除表示它不能成为业务组件 owner 或跨场景复合卡模板；feature 私有内容仍可把它用作纯表层/Shape 原语，业务语义、状态和交互全部留在内容 owner。两者不能因为都是白色圆角表层而互换或相互套用。
- `CardContainer` 只拥有表层、Shape 与可选边界；业务状态和交互仍由其内容 owner 持有。
- `XMCompactStateView(style: .card)` 等已经拥有卡片表层的组件不再外套 `CardContainer`。
- `surfaceNested` 只用于卡片内确有独立第二层语义的内容，不作为默认“更高级”皮肤，不连续嵌套。
- 普通内容卡不默认添加描边或阴影。背景差、边框、阴影、玻璃和渐变同时出现时，先收缩为能解释关系的最少手段。
- Liquid Glass 属于系统导航与功能控制层，不是 Sheet 白色内容卡、列表、表单或 Settings 分组的主题。

## iOS 26 圆角

- Sheet 外轮廓与系统 presentation shape 由系统持有。普通业务调用方不设置固定 `.presentationCornerRadius`，也不绘制相似外壳覆盖系统形状。
- 同时满足“承担 Sheet 主要任务表层、内部组合两个以上协同区域、边界与 Sheet 外缘形成平行关系”的容器级复合面板，必须显式使用 `CardContainer(shape: ConcentricRectangle.xmSheetContentPanel)`。
- `xmSheetContentPanel` 是当前项目的 Sheet 面板 Shape owner；它逐角读取系统容器关系并保留项目曲率下限。调用方只消费语义 Shape，不复制 minimum 数值或手算内外半径。
- Sheet 中的普通独立内容卡仍可使用 `CardContainer` 默认初始化，但调用方必须能说明其单一 block 角色；默认 Shape 只代表 `CornerRadius.blockLarge`，不代表 Sheet 面板圆角。
- 小型输入框、列表行、按钮、chip、inlay 和不依赖外容器关系的普通 block 继续使用自身组件或 `CornerRadius` token owner；同心面板不是新版通用圆角。
- 不修改 `CardContainer` 全局默认值，也不让组件自动读取 Sheet 环境；容器无法仅凭所处层级判断自己是主复合面板还是普通内容块，Shape 语义必须由真实调用方显式选择。
- 嵌套边界与外容器明显平行、距离接近时保持同心和连续；不通过给内外层写相同半径制造“统一”。不形成外缘关系时，使用元素自己的 block/container 角色。
- 系统 Sheet/Popover 已提供 container shape。只有 feature 自建外容器时，才在核对当前 SDK 后使用 `containerShape(_:)` 建立容器语义；不要为了相似观感硬编码半径。

## Detent、键盘与退出

- Sheet 含任何文本输入、搜索、富文本或 UIKit first responder 时，必须同时读取 [软键盘与输入焦点](keyboard-and-focus.md)；键盘收起模式、两级手势、焦点生命周期和避让策略以该文件为唯一 owner。
- Detent、drag indicator 和 presentation 配置不由 scaffold 持有。仅与当前呈现上下文有关时由调用点决定；内容固有且需要跨多个调用点保持一致时由专项 Sheet wrapper 持有。
- 优先使用系统 detent。固定数字高度只允许给内容封闭、文本边界明确且经过尺寸与 Dynamic Type 矩阵验证的局部 owner。
- 包含输入、多行文本、错误或动态内容时，确保键盘和辅助功能字号下所有内容与操作可达；使用 `.large` 或由专项 owner 按内容计算，不把任一方案推广为所有 Sheet 的统一规则。
- 输入型 Sheet 验证键盘出现、交互收起、提交前失焦、失败后继续编辑及固定操作可达性；不用硬编码 keyboard padding 补偿结构问题。
- `interactiveDismissDisabled` 只用于保存中、明确交互锁定，或配套未保存内容退出保护的场景，不作为所有 Sheet 默认。
- 下拉关闭会丢失草稿时提供明确退出确认；保存失败不自动 dismiss。

## 验证矩阵

按任务覆盖真实存在的状态，不为了矩阵虚构功能：

- close-only 与 confirmation 两类骨架；确认的 enabled、disabled、loading 和失败恢复。
- 静态 subtitle、动态 `titleSubtitle`，以及没有副标题的长标题边界。
- 普通内容与 `contentTopBar` 两类顶部关系，确认没有重复 top padding 或固定栏遮挡。
- 简单无卡内容、原生 `List/Form`、Settings 分组、容器级同心面板和普通 block 行，确认卡片与圆角没有被机械统一。
- 浅色、深色、默认与至少一个辅助功能字号、最长本地化文本、紧凑与规则宽度。
- 输入焦点、键盘、交互收起、未保存退出、重复提交、VoiceOver label/顺序和主操作状态。
- 结构审查确认只有一个导航/滚动/保存 owner，没有重复背景、标题、关闭入口、固定栏材质或 presentation 圆角覆盖。

代码只能确认 owner、API、token、状态和结构风险。密度、卡片层级、同心关系和材质观感仍需 Preview、Simulator 或实际运行证据；没有渲染时标记为“视觉风险，需截图验证”。

## Apple 平台校验入口

- [Sheets HIG](https://developer.apple.com/design/human-interface-guidelines/sheets)
- [Materials HIG](https://developer.apple.com/design/human-interface-guidelines/materials)
- [ConcentricRectangle](https://developer.apple.com/documentation/swiftui/concentricrectangle)
- [safeAreaBar](https://developer.apple.com/documentation/swiftui/view/safeareabar%28edge%3Aalignment%3Aspacing%3Acontent%3A%29)

这些链接用于重新核对平台事实，不代表 Apple 示例优先于当前项目已验证且不违背平台原则的实现。
