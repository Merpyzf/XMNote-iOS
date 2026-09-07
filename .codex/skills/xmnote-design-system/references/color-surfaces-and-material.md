# 颜色、表层与材质

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
| 页面唯一主提交 | `primaryActionFill` + `primaryActionForeground` | 仅表达主操作语义归属；使用前仍须验证实际前景—背景对比度，不用于普通可点击项 |
| 品牌强调表面上的内容 | `onBrandForeground` | 普通外观为不透明纯白，高对比度遵循 owner；不是中性表面上的选中强调色 |
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

## 品牌表面前景

XMNote 的产品默认是：普通外观下，已获准采用品牌强调填充的控件，其内容使用不透明纯白，避免自行叠加灰色、透明白或同品牌色前景。白色没有饱和度；规范使用“不透明纯白”，不使用“高饱和度白色”。这是产品选择，不是 Apple 强制要求，也不是对比度合格证明。

- `onBrandForeground` 表达品牌强调表面上的文字或图标；主操作继续消费角色入口 `primaryActionForeground`，后者为前者的别名。品牌填充选择标记消费 `onBrandForeground`，底色消费 `selectionAccent`。
- `selectionForeground` 仍用于中性表面上的选中文案与图标；`selectionInactive` 用于未选中描边。不能因名称含 Foreground 就把前者叠到品牌填充上，也不能用普通 `iconSecondary` 代替品牌表面内容色。
- 规则不推广到弱填充、透明背景、正文链接、危险操作、禁用态或系统 toolbar。已存在的 canonical owner 不由调用处覆盖，不触发无关页面迁移。
- 当前普通浅色、深色及增强对比度浅色采用白色，增强对比度深色采用黑色；具体解析以 `SemanticColors.swift` 为准。页面不得硬编码白色抵消辅助功能分支。
- 品牌染色玻璃可以使用对应语义，但不是实心填充；仍需在真实背景、外观和状态下验证，不从实心表面的测量推定玻璃达标。

### 已确认的局部对比度例外

三联中读导入页 `LifeWeekRememberPasswordToggleStyle` 的选中 Checkbox，普通浅色和深色保留当前品牌绿 `#2ECF77` 与纯白对勾，配对约为 `2.04:1`，低于关键图标 `3:1` 的通用目标。用户已明确选择保留绿色并使用白色对勾；此项仅记录该页面、该控件、普通外观下的产品例外，不等于可访问性达标。高对比度分支继续适配。

不得把此例外推广给其他选择器或按钮，不据此宣称现有导入主按钮已经全部达标，也不降低通用阈值或静态策略。其他配对不足时报告真实 owner、状态与最小调整方案；例外需要明确授权，不能通过换 token 名称自动放行。

## 操作按钮前景—背景配对

本节只约束执行动作的 `Button`，不把规则扩展到 Toggle、Picker、选择器、标签、状态徽记或纯展示内容；这些控件继续使用各自的选择、状态或内容语义。

按钮角色与材质选择统一读取 [按钮样式与主操作](buttons-and-primary-actions.md)。本节继续持有配色和对比度，不因采用交互式 Liquid Glass 放宽要求。

按钮颜色必须按“前景 + 表层 + 状态”成对判断，不能只看到某个 token 名称就认定合规：

| 按钮角色 | 前景 | 表层 | 约束 |
| --- | --- | --- | --- |
| 经场景审查采用实心填充的唯一主操作 | 经验证的中性前景，语义入口为 `primaryActionForeground` | 品牌主操作填充，语义入口为 `primaryActionFill` | 只用于提交、创建或确认；不是所有主操作的默认材质，token 成对命名不代表已经通过对比度验证 |
| 符合功能控制层条件的玻璃主操作 | 保留系统 owner；自定义品牌主操作采用 `primaryActionForeground` 的普通纯白默认及辅助功能适配 | `.regular.tint(Color.appTint)` 玻璃表面 | 染色玻璃不等于实心填充；实际背景、外观和状态分别验证 |
| 普通次级操作 | `textPrimary/textSecondary`、对应中性图标或系统默认前景 | 透明表层或 `controlFillSecondary` 等中性弱表层 | 必须隔离根级品牌 tint，不因可点击而产生品牌弱填充 |
| 品牌文字型操作 | 经过测量的品牌派生前景；优先使用已有正文动作语义而不是 `appTint` | 透明或中性表层 | 仅在确有稀缺主语义时使用；不得同时放到品牌派生表层上 |
| 删除/警告 | `feedbackError` / `feedbackWarning` 或系统对应 role | 中性/透明表层，或经验证的反馈语义填充与中性前景 | 不得被 `appTint` 覆盖；状态必须同时由文案、图标或 role 表达 |
| 禁用 | `buttonDisabledForeground` | `buttonDisabled` | 前景与表层同时进入禁用态，不能只降低单侧透明度 |

以下组合直接禁止：

- 品牌派生文字或图标叠加在品牌派生实心、描边弱填充或透明度派生表层上；这里的“品牌派生”按真实颜色来源判断，包括 `appTint`、`primaryActionFill`、`selectionAccent`、`feedbackSuccess` 及从品牌色派生的文字语义，不能靠改名规避。
- 原生 `.buttonStyle(.bordered)` 未显式隔离 tint。它会消费环境 tint，根层 `.tint(Color.appTint)` 可能同时生成品牌前景与品牌弱填充；`role: .destructive` 也不能代替实际渲染检查。
- 用 `.opacity(...)`、自定义 overlay 或相近品牌色阶制造“看起来更淡”的同品牌配对；降低饱和度或透明度不会自动建立层级与可读性。

品牌实心表层配合中性前景并非默认违规，但仅允许给页面唯一主操作，且必须提供实际测量结果。当前 `primaryActionFill + primaryActionForeground` 只证明语义配对，不证明浅色、深色和高对比度下均已达标；在完成测量前不得以 token 名称为依据复制新的突出按钮。

染色玻璃会受到下层内容与系统显示设置影响；不能把实心按钮、另一种玻璃样式或旧截图中的前景—背景比例套用到当前表面。`primaryActionForeground` 继承品牌表面的普通纯白默认与辅助功能适配，不代表所有绿底都必须白字。出现不足时回到真实 owner 提出最小调整，不在单页擅自硬编码前景或顺带更改全局颜色。

对比度验证必须记录前景、背景、控件状态和外观模式：普通按钮文字至少 `4.5:1`，大字号按钮文字至少 `3:1`，关键图标与控件可辨边界至少 `3:1`。动态 `Color` 无法仅凭静态源码得出比例；机器报告只标记结构和 token 风险，最终结论必须来自实际解析颜色或运行态截图测量。

## 图标颜色边界

图标来源、Reicon/SF Symbols 分工、Filled/Outline、资源接入、视觉校准、交互与可访问性统一读取 [图标设计与使用](iconography.md)。本文件只持有图标颜色边界：普通图标使用 `iconPrimary/iconSecondary`，菜单和顶部辅助操作使用对应的中性 tint 入口，反馈图标使用真实反馈语义；普通操作不因可点击而使用 `appTint`。

## Liquid Glass 与系统材质

Liquid Glass 是导航层和功能层的交互材质，不是内容背景主题。

- 系统导航栏、Tab、toolbar、popover、Sheet 等已有系统材质时，优先让系统提供外观。
- 系统导航栏中的按钮禁止再次包裹 `.glassEffect`、`.buttonStyle(.glass/.glassProminent)` 或自定义 material。
- 顶部独立 action 或同权 action 组合只有在机器目录返回对应 TopBar glass owner 时才使用项目封装。
- 阅读正文、普通数据卡、设置分组、状态卡和列表行不使用玻璃作为“升级皮肤”。
- 多个玻璃元素需要交互融合、过渡或共享容器时，按 [动效与手势](motion.md) 判断运动关系；平台 API、可用性和参数语义遵守 `AGENTS.md` 的 Apple 查证顺序及官方来源降级规则。
- 不用 blur、gradient 或 material 遮罩模拟系统 scroll-edge effect。
- [按钮样式与主操作](buttons-and-primary-actions.md) 已明确的交互式玻璃主按钮是项目设计选择，可在适用场景通过原生 API 和功能内组合实现；这不等于允许跨模块依赖某个 feature 私有类型。现存直接 `glassEffect` 及其尺寸、颜色和状态分支仍只是局部证据，公共入口继续以 catalog 为准。

## 颜色与材质验证

- 至少验证浅色、深色；涉及语义色调整时验证系统高对比度。
- 对比度结论写清前景、背景、状态、外观模式和测量结果。正文目标至少 4.5:1，大字号或强调标题至少 3:1；代码 token 名称不能替代测量。
- 检查根级 tint 是否意外传播到 Button、toolbar、Menu、Picker、Toggle 和 SF Symbol；操作按钮按本文件的前景—背景配对规则单独判断。
- 状态不得只靠颜色区分；同时检查文案、图标、形状或控件状态。
- 没有截图或实际渲染时，只能报告 token/结构风险；“太灰、太绿、太脏、层级弱”等结论标记为“视觉风险，需截图验证”。
