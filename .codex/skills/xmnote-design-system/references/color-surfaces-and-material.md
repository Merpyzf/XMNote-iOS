# 颜色、表层、图标与材质

颜色必须按用户任务和语义角色选择，而不是按当前 RGB、个人偏好或“看起来像绿色”选择。具体色值、浅深色和高对比度解析始终读取 `xmnote/Utilities/DesignSystem/SemanticColors.swift`；底层构造与允许路径读取 `ColorConstruction.swift` 和 `scripts/design-system/policy.json`。

## 颜色选择顺序

1. 已有组件自己管理外观时，直接使用组件，不从页面读取其内部颜色。
2. 页面使用已存在的产品语义色。
3. 独立业务主题、算法色或导出渲染确有 owner 时，使用已登记的 feature/component Appearance。
4. 只有两个独立生产场景证明同一语义缺口后，才提议新增全局语义色。

禁止在业务文件新增 `Color(...)`、`UIColor(...)`、私有 hex/adaptive helper 或直接消费 `BaseColorPalette`。`xmHex/xmAdaptive/xmResolved/xmSRGB` 是受控构造与桥接入口，不代表页面可以自由散落色值；使用前检查 `DS003` 允许路径。`allowedPaths` 只授予构色权限，不证明该文件的视觉方案 canonical，更不能作为复制清单。

## 产品语义色矩阵

| 用户可见角色 | 默认入口 | 适用边界 |
| --- | --- | --- |
| 页面或分组流底板 | `surfacePage` | Tab 根页、分组列表和卡片流页面 |
| 页面底板上的主要内容容器 | `surfaceCard` | 普通内容卡片；不用于 Settings 分组之外再套卡 |
| 主卡片内部的次级表层 | `surfaceNested` | 确有第二层语义的局部模块，不是默认“更高级”皮肤 |
| 业务 Sheet 内容底板 | `surfaceSheet` | 由 `XMSheetScaffold` 根层持有；内部卡片按 [业务 Sheet](sheets.md) 的信息关系选择 |
| 弱控件填充 | `controlFillSecondary` | 轻量按钮、圆形选项和弱填充控件 |
| 批注/个人想法弱分组 | `surfaceAnnotation` | 阅读内容内的批注语义，不是通用卡片背景 |
| 主要文本 | `textPrimary` | 标题、正文和关键值 |
| 次要文本 | `textSecondary` | 副标题、说明和主要辅助信息 |
| 提示文本 | `textHint` | placeholder、极弱元数据；不能承载关键说明 |
| 正文链接 | `linkForeground` | 可跳转链接；不表示选中、成功或品牌装饰 |
| 搜索命中 | `keywordHighlight` | 关键字片段；优先使用 `XMKeywordHighlighting` |
| 普通图标 | `iconPrimary` / `iconSecondary` | 与相邻文字层级一致或更弱 |
| 普通菜单及选中标记 | `menuActionForeground` / `menuSelectedForeground` | 隔离根级品牌 tint，不替代 destructive 语义 |
| 主容器/普通/弱边界 | `surfaceBorderStrong/Default/Subtle` | 按实际表层层级选择，不按“越深越重要”机械套用 |
| 内容分隔 | `surfaceDividerDefault/Subtle` | 分节或卡片内部弱分组；不与卡片边框竞争 |
| 页面唯一主提交 | `primaryActionFill` + `primaryActionForeground` | 明确提交/确认动作，不用于普通可点击项 |
| 禁用主操作 | `buttonDisabled` + `buttonDisabledForeground` | 视觉必须同时体现不可用且保留可读性 |
| 选择 | `selectionAccent/Foreground/Inactive` | 选中状态，不替代链接、成功或普通品牌装饰 |
| 删除/错误、警告、成功 | `feedbackError/Warning/Success` | 必须同时有文案、图标或控件语义，不能只靠颜色 |

`Color.appTint` 是根级交互 tint，只用于明确主操作、当前选中态和品牌识别。普通导航、菜单、工具栏、列表辅助图标和装饰图标保持系统色或中性色。

token 存在不等于每个层级都必须使用。`surfaceBorderStrong`、`surfaceBorderDefault` 和 `surfaceDividerDefault` 的生产处方证据弱于其他语义；只有真实背景和边界需要它们时才使用，不能写成 page/card/nested 的机械配方。

## 表层与卡片决策

添加表层前先回答：它是否表达新的内容分组、交互边界或浮起层级？如果只是想让页面“更丰富”，不要加卡片。

- 页面通常从 `surfacePage` 开始，主要内容按需使用一层 `surfaceCard`。
- `surfaceNested` 只用于卡片内确有独立语义和边界的第二层内容；不得连续嵌套。
- Settings 使用 `XMSettingsGroup`，普通内容卡使用机器目录确认后的 `CardContainer`；两者不能因外观相近互换。
- `CardContainer` 只拥有普通内容表层、Shape 与可选轻描边；可以包裹 feature 私有业务组合，但不持有其交互、状态或保存逻辑。
- 同时出现背景差、边框、阴影、玻璃和渐变时，通常说明层级没有通过信息结构解决。保留能解释关系的最少手段。
- 阴影只表达真实浮起、堆叠或拖拽；普通列表项和阅读正文不默认投影。

卡片嵌套、等权指标卡矩阵、重阴影、霓虹、发光和多层透明材质属于高风险模式。只有截图证明它解决了明确层级问题，且没有更简单的亲密性/留白方案时才可保留。

业务 Sheet 自身已经是容器，不能从 `surfaceSheet` 推导出“内部必须再放白卡”。简单说明、列表、表单与系统分组何时保持无卡，以及复合面板何时使用 `surfaceCard`，统一读取 [业务 Sheet](sheets.md)；本文件不维护第二套 Sheet 卡片处方。

## 品牌与业务色边界

- 品牌绿色是稀缺焦点，不是“可点击”的通用标记。
- 当前选中态、页面唯一主操作和品牌识别可以使用品牌语义；普通次级动作使用系统或中性色。
- 删除、警告、错误、成功使用反馈语义，不因产品品牌改为绿色。
- `feedbackSuccess` 当前可能与 `appTint` 解析为同一颜色，但两者语义仍不同；不能因此把任意品牌绿色解释为成功反馈。
- 阅读状态、热力图、日历主题、评分、封面装饰等业务颜色由各自 catalog/Appearance owner 管理；页面不得把其颜色提升为全局 token。
- Domain 只保留状态、等级或数值，颜色与图标映射留在 UIComponents 或具体页面 presentation owner。

## 图标与 tint

- 先确认图标的业务语义和 owner，再选 SF Symbol。相同图形不等于相同业务角色。
- 与文字并列的辅助图标不得比主文本更亮、更饱和或更大。
- 普通菜单使用 `XMMenuLabel` 与 `xmMenuNeutralTint()`；顶部辅助操作在根级品牌 tint 环境中使用 `xmToolbarNeutralTint()` 或机器目录返回的等价入口。
- 选中菜单使用尾部 checkmark 与可访问性 selected trait，颜色仍保持中性。
- warning/destructive 图标使用对应反馈色；普通操作不因可点击而使用 `appTint`。
- 字面量 SF Symbol 属于 `DSR001` 人工观察项：单点且语义清楚可保留，重复业务语义应查询已有图标组件；不要为了清零建立图标常量仓库。
- glyph 可以由真实图标 owner 使用固定视觉尺寸；不要把它误判成生产文本的固定字号违规。

## Liquid Glass 与系统材质

Liquid Glass 是导航层和功能层的交互材质，不是内容背景主题。

- 系统导航栏、Tab、toolbar、popover、Sheet 等已有系统材质时，优先让系统提供外观。
- 系统导航栏中的按钮禁止再次包裹 `.glassEffect`、`.buttonStyle(.glass/.glassProminent)` 或自定义 material。
- 顶部独立 action 或同权 action 组合只有在机器目录返回对应 TopBar glass owner 时才使用项目封装。
- 阅读正文、普通数据卡、设置分组、状态卡和列表行不使用玻璃作为“升级皮肤”。
- 多个玻璃元素需要交互融合、过渡或共享容器时，交给 `ios-motion-design` 判断运动关系；平台 API、可用性和参数语义必须通过 `apple-doc-mcp` 查证。
- 不用 blur、gradient 或 material 遮罩模拟系统 scroll-edge effect。
- feature 内已经存在的直接 `glassEffect` 默认只是局部成立；除非机器目录明确登记为跨功能入口，不得复制到另一模块。

## 颜色与材质验证

- 至少验证浅色、深色；涉及语义色调整时验证系统高对比度。
- 对比度结论写清前景、背景、状态、外观模式和测量结果。正文目标至少 4.5:1，大字号或强调标题至少 3:1；代码 token 名称不能替代测量。
- 检查根级 tint 是否意外传播到 toolbar、Menu、Picker、Toggle 和 SF Symbol。
- 状态不得只靠颜色区分；同时检查文案、图标、形状或控件状态。
- 没有截图或实际渲染时，只能报告 token/结构风险；“太灰、太绿、太脏、层级弱”等结论标记为“视觉风险，需截图验证”。
