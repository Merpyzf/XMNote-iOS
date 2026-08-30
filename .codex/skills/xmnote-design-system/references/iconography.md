# 图标设计与使用

本参考是 XMNote App 内 interface icon/glyph 的唯一设计入口，覆盖 Reicon、SF Symbols、Filled/Outline、图标资源接入、视觉校准、颜色、交互与可访问性。App Store App Icon、书籍封面、插画、照片和其他业务图片不在此范围。

Apple Human Interface Guidelines 是平台基线；真实生产 owner、设计系统语义色、机器目录与本参考共同决定项目实现。单个页面、Debug 实验或一枚已经存在的图标不能单独升级为全局规范。

## 设计目标

界面图标服务识别和操作，不负责制造装饰性“设计感”。每枚图标应表达一个清楚概念，并满足：

- 使用熟悉、简化、能快速识别的隐喻；避免把多个动作或对象塞进同一图形。
- 同一组保持一致的细节密度、线条重量、透视、圆角语言和光学尺寸。
- 图标与文字共同出现时，图标不比主文字更亮、更饱和或更大。
- 先通过语义、位置、文字和系统控件行为建立可理解性，不用颜色或 Filled 形态替代信息层级。
- 允许依据黑色面积、轮廓密度和重心逐枚校准；数值相同不代表视觉重量相同。

Apple 官方依据：

- [Icons](https://developer.apple.com/design/human-interface-guidelines/icons)：图标应简洁、可识别，并在尺寸、细节、weight 与透视上保持一致；可以按视觉重量调整个体尺寸。
- [SF Symbols](https://developer.apple.com/design/human-interface-guidelines/sf-symbols)：Outline 适合工具栏、列表和文字旁，Filled 更适合 Tab、选中态和需要强调的操作。
- [Tab bars](https://developer.apple.com/design/human-interface-guidelines/tab-bars)：Tab 使用简短标签，并优先采用 Filled 图标以符合平台表达。
- [Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)：控件需要清楚标签、充分点击空间，状态不能依赖单一感知通道。
- [Right to left](https://developer.apple.com/design/human-interface-guidelines/right-to-left)：方向性图标需要随阅读方向适配，通用标记、品牌和非方向性实物不翻转。

## 先判定角色，再选择图标库

图标库按用户认知角色分工，不按页面或个人偏好统一。选择顺序固定为：

1. 先确认用户看到的是业务对象/入口，还是系统操作/平台约定。
2. 查询 catalog，确认现有 canonical 组件是否已经持有该图标与交互语义。
3. 业务身份、领域入口和产品专属概念优先 Reicon；系统行为和平台约定优先 SF Symbols。
4. 两者都无法准确表达时，才设计 feature 私有图标；没有两个独立生产场景的相同证据，不建立跨功能图标组件或常量仓库。

| 用户可见角色 | 默认来源 | 典型场景 | 选择理由 |
| --- | --- | --- | --- |
| 业务身份与一级领域 | Reicon | 在读、书籍、笔记、我的等业务 Tab | 建立 XMNote 自有业务识别，保持业务图标家族一致 |
| 功能入口与领域对象 | Reicon | 阅读日历、网页端、书摘导入、书籍来源、AI 助手 | 表达产品业务语义，不与系统命令混淆 |
| 系统导航与层级关系 | SF Symbols / 系统组件 | back、close、chevron、disclosure、dismiss | 保留平台熟悉度、自动适配和系统交互行为 |
| 标准系统动作 | SF Symbols / 系统控件 | add、more、search、share、delete、edit、checkmark | 用户已经形成稳定平台认知，优先使用原生 Button、Menu、Tab 等入口 |
| 系统状态与控件附件 | SF Symbols / canonical owner | selection、warning、error、info、排序、筛选 | 由系统或已有组件统一状态、渲染和可访问性 |
| 品牌或独占业务标记 | Reicon 或 feature 私有资产 | 会员皇冠、专项认证标记 | 必须有明确 owner，不推广为普通入口样式 |

### 允许与禁止的混用

- 同一页面可以同时使用 Reicon 与 SF Symbols，但必须由角色分工解释，而不是为了找“更好看”的单枚图标。
- 同一组同权业务入口保持同一来源和 weight；不得在同一列表里随机混合 Reicon Outline、Reicon Filled 与 SF Symbols。
- 同一控件不拼接两套图标语言。Reicon 业务前导图标配 SF Symbols 尾部 chevron 是允许组合，因为两者分别表达业务对象和系统导航关系。
- 平台熟悉度高于形式统一。不能为了“全站 Reicon”替换返回、关闭、分享、删除、搜索或系统选择标记。
- Apple 产品、设备与受限制的 Apple 功能标记只使用 Apple 允许的 SF Symbols 或 Design Resources，不使用近似 Reicon 重绘。

## Reicon MCP 工作流

新增 Reicon 必须通过已安装的 Reicon MCP 获取。MCP 是名称、weight 与 SVG 的事实来源；禁止凭记忆猜图标名、从网页手工复制、使用截图描摹或自行修改路径来伪造 Reicon。

### 1. 搜索

- 用英文业务语义调用 `search_icons`，并指定 `Outline` 或 `Filled`；查询词描述用户理解的对象或动作，不直接从期望外形反推名称。
- 默认先使用短而明确的语义词；结果不准确时补充对象、方向或动作限定词重新搜索。
- 以排名第一的结果为首选。如果首选语义不成立，改写查询使首选结果成立，不任意跳过高分结果挑选“更好看”的候选。
- 只有语义还不清楚、需要探索图标族时才调用 `list_categories`，不把分类浏览作为每次接入的固定步骤。

### 2. 检查

- 名称和 weight 已明确时直接进入生成。
- 需要检查细节、比较 Filled/Outline、确认小尺寸辨识度或与相邻图标的视觉重量时调用 `view_icon`。
- 轮廓区分不足时优先更换语义隐喻或优化查询，不通过加颜色、底板或任意放大掩盖问题。

### 3. 生成

确认精确名称和 weight 后调用：

```text
apply_icon(
    framework: "svg",
    name: "<kebab-case-name>",
    weight: "Outline" | "Filled",
    size: 24,
    color: "currentColor"
)
```

- 直接使用 MCP 返回的 SVG 路径，不手工重绘、平滑或改变 stroke/圆角。
- 只有真实状态或两个已确认场景需要两种 weight 时才分别生成 Outline 与 Filled；不为“以后可能使用”批量导入配对资源。
- MCP 不可用时只允许复用仓库中已经验证的精确同名、同 weight 资源；不存在时停止接入并报告阻塞。

### 4. 资产接入

- 资源位于 `xmnote/Assets.xcassets/Reicon/`，imageset 命名为 `Reicon<Name><Outline|Filled>`，其中 `<Name>` 使用 PascalCase。
- SVG 保持 24×24 `viewBox` 和矢量路径；imageset 设置 `template-rendering-intent: template` 与 `preserves-vector-representation: true`。
- SwiftUI 使用类型安全 `ImageResource`、`.renderingMode(.template)`、`.resizable()` 与 `.scaledToFit()`；最终视觉尺寸由真实组件或 feature `Layout/Metrics` owner 决定。
- Reicon 使用许可保留在 `Vendor/Reicon/LICENSE`；引入资源时不得删除或绕过现有许可文件。

## Reicon 与 SF Symbols 的样式决策

### Outline

以下场景默认使用 Outline：

- Settings、列表、卡片行和与文字并列的业务入口。
- 顶部栏中的产品专属业务动作；系统标准动作仍使用 SF Symbols。
- 同一信息层级内需要降低黑色面积、让内容文字保持主角的辅助图标。

Outline 不等于“更弱到不可见”。如果 16–18pt 下细节丢失，先选轮廓更清楚的隐喻，再做有限光学校准，不直接切换 Filled。

### Filled

Filled 只用于：

- 主 Tab 的业务图标。
- 明确选中态、强状态或已经建立 owner 的品牌/业务强调。
- 会员皇冠等经产品确认的局部例外。

普通入口不得因为可点击、希望“更精致”或需要与文字抢层级而使用 Filled。同一控件只有在选中态确实需要形态变化且不会造成跳动时才允许 Outline/Filled 切换；系统组件能自动管理变体时不手动覆盖。

## 当前 App Shell 基线

以下是已经由当前首页 owner 建立、并与 HIG 方向一致的参考。它们证明角色关系，不是可跨页面复制的全局 token：

| 场景 | 当前表达 | 边界 |
| --- | --- | --- |
| 在读、书籍、笔记、我的 Tab | Reicon Filled，24pt 源画布、当前 22pt 视觉 frame | 选中与未选中保持同一图形；选中通过 `appTint` 表达 |
| 搜索 Tab | 系统 `magnifyingglass` 与 search role | 不替换为 Reicon，保留系统搜索语义和行为 |
| 我的页顶部设置 | Reicon `settings4` Outline，当前 18pt 视觉 frame、44pt 点击区 | 它是产品设置入口；同区 `+` 仍是 SF Symbols 标准动作 |
| 我的页常用功能 | Reicon Outline，24pt 对齐画布、当前 18pt 图形 | 图标低于标题层级，不增加彩色底板 |
| 我的页列表入口 | Reicon Outline，24pt 对齐画布、当前 16pt 图形 | 尾部 chevron 使用 SF Symbols，分工不同不视为混用错误 |
| 会员皇冠 | Reicon Filled，当前 30pt 与黄色局部强调 | 属于 Personal 会员 owner 的显式例外，不推广为全局 warning 或业务入口样式 |

新场景先从所属组件的现有 owner 和相邻文字层级出发。不能因上表已有 16/18/22/30pt 就复制数字；需要新尺寸时保留在组件或 feature `Layout/Metrics`，并通过真实渲染证明。

## 尺寸、对齐与视觉重量

- 24pt 是 Reicon 源画布，不等于所有场景都显示 24pt。显示 frame、对齐画布和点击区是三个不同概念。
- 同组先统一对齐画布和中心线，再比较实际黑色面积、外轮廓、负空间和视觉重心。
- Filled 通常比 Outline 黑色面积更大；不能只设置相同 frame 后就认定视觉重量一致。
- 图标可以按 HIG 做小范围光学尺寸补偿，但必须留在真实 owner，并与相邻图标以截图比较；不要裁切、拉伸、非等比缩放或修改路径粗细。
- 与文字并列时检查 baseline、图标中心、正文起始线和 divider 起点。前导槽位由页面/组件统一，不能让每枚图标拥有不同布局宽度。
- SF Symbols 优先使用系统字体与组件决定的 weight/variant；除已登记的 `TopBarActionIcon` 等 owner 外，不散落自定义 point size 与 weight 追平 Reicon。

## 颜色与表层

颜色规则读取 [颜色、表层与材质](color-surfaces-and-material.md)，图标使用以下语义：

- 普通首要图标使用 `iconPrimary`，次级和辅助图标使用 `iconSecondary`；不得用 `textPrimary` 或字面量颜色绕过图标语义。
- 当前选中、页面唯一主操作或明确品牌识别才使用 `appTint`；普通图标不因可点击而变绿。
- 删除/错误、警告和成功分别使用 `feedbackError`、`feedbackWarning`、`feedbackSuccess`，并同时提供文案、形状或控件状态，不能只靠颜色。
- 默认使用单色 template 渲染。普通业务入口不增加浅灰圆角底板、渐变、高饱和彩色、发光、阴影或多层 palette。
- 业务确需多色、层级或原色渲染时必须有独立 Appearance/组件 owner 和运行态证据；不能从 SF Symbols 的多色能力推导出 App 应当彩色化。

## 交互、可访问性与本地化

- 独立图标按钮默认达到 `InteractionMetrics.minimumTouchTarget` 的 44pt 有效点击区；紧凑视觉与点击区分离，受控例外读取 [组件与交互](components-and-interaction.md)。
- 标准动作优先使用带文字语义的 `Button`、`Label`、`Menu`、`NavigationLink` 或 `Tab` API。图标不能成为唯一语义。
- 独立图标操作必须提供可理解的 accessibility label；有当前值或状态时补充 value/selected trait。不要只朗读图标文件名或 SF Symbol 名称。
- 图标旁已有文字并由父控件完整朗读时，将图标标记为装饰并对 VoiceOver 隐藏，避免重复朗读。
- 状态不能只通过颜色、Filled/Outline 或方向变化表达；同时提供文案、控件状态或可访问性 trait。
- SF Symbols 优先依赖系统的本地化和 RTL 变体。Reicon 中表达前进/后退、阅读方向、文字对齐或界面方向的图标必须验证 RTL，并由 owner 提供镜像或本地化资源。
- checkmark、品牌标记、通用符号和不表达方向的真实物体不翻转；含文字或字母的图标只有在文字不可替代时使用，并提供本地化版本。

## Owner 与复用边界

- canonical 组件已经持有图标时，调用方不覆盖其来源、weight、尺寸、颜色、渲染模式或选中逻辑。
- 同一 feature 有一组稳定业务入口时，可以用页面私有语义 enum 集中映射 Reicon；enum 表达业务角色，不只是资源名集合。
- 单点 SF Symbol 且语义清楚可以局部保留；重复业务语义先查询已有 owner。`DSR001` 是人工观察项，不要求为了清零建立全局常量仓库。
- 跨功能图标组件仍遵守公共组件准入：至少两个独立生产场景具有相同语义、状态与验证方式，并完成 catalog 登记。
- Domain 只保存状态、类型和数值；图标来源、资源名、颜色与 Filled/Outline 映射留在 UIComponents 或具体页面 presentation owner。

## 直接阻断

- 用 Reicon 替换系统返回、关闭、搜索、分享、删除、编辑、更多、checkmark 或 chevron，只为追求“统一”。
- 在同一组随机混用不同图标库、Outline/Filled、透视、细节密度或颜色。
- 未经 Reicon MCP 搜索与确认就猜测图标名、复制第三方 SVG、手画近似资源或修改官方路径。
- 为普通入口增加浅灰圆角底板、彩色圆形底板、高饱和渐变、发光或阴影来制造完成度。
- 用更大图标、更粗图标和品牌色同时强调普通功能，导致图标抢过标题或核心内容。
- 只因数值相同就宣称视觉重量一致，或没有截图便断言“太重、太轻、太灰、太绿”。
- 通过批量导入 Filled/Outline、建立全局资源 enum 或新增万能 Icon 组件囤积尚无生产场景的能力。

## 验证清单

每次新增或替换图标至少确认：

1. 业务语义、系统语义和 owner 已明确，来源符合角色分工。
2. Reicon 已通过 MCP 确认精确名称与 weight，imageset 保持 template 和 vector。
3. 同组来源、weight、透视、细节密度、对齐画布和视觉重量一致。
4. 在真实显示尺寸下与相邻 Reicon、SF Symbols 和文字比较，不只查看 24pt SVG 原图。
5. 浅色、深色、相关高对比度、选中、未选中、禁用与反馈状态的 tint 正确。
6. 默认字号、Accessibility 字号和最长本地化文本下，图标不挤压、裁切或抢占文字层级。
7. 独立操作达到有效点击区并拥有 VoiceOver label/value/trait；装饰图标不重复朗读。
8. RTL 下方向性图标语义正确，非方向性图标没有被误翻转。
9. 需要判断视觉重量、密度或颜色观感时记录 Simulator/Preview 的设备、尺寸、外观和状态截图；没有运行态证据只报告“视觉风险，需截图验证”。
