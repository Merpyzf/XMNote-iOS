# iOS 设计系统工程规范

## 1. 目标与适用范围

本规范定义 XMNote iOS 生产界面的设计基础设施、依赖方向、公共组件准入、机器检查与 AI 修改路径。目标不是把所有页面做成同一种外观，而是让相同语义只有一个稳定实现入口，同时保留业务页面必要的局部表达。

适用范围：

- `xmnote/` 下的生产 Swift / SwiftUI / UIKit 界面代码。
- 设计令牌、跨模块公共 UI、页面私有 UI 与页面壳层。
- 配置类页面、业务 Sheet、字体、颜色、间距、圆角、交互尺寸与基础状态反馈。
- 人工开发、Codex 及其他 AI 协作者的新增、修改、评审与收口流程。

排除范围：

- `xmnote/Views/Debug/**` 的视觉实验不进入 enforced UI lint，但仍受目录边界、L3 契约和通用工程规则约束。
- Vendor、生成代码和第三方依赖。
- 单一业务场景的领域状态、文案和布局组合；这些内容不因视觉相似自动晋升为公共能力。

## 2. 当前健康基线

设计系统已经形成三个相互配合的约束层：

1. 代码真相源：分责设计令牌、Settings 组件、Sheet scaffold 与既有基础组件。
2. 机器真相源：`scripts/design-system/policy.json`、`component-catalog.json` 与 SwiftSyntax 规则实现。
3. 协作真相源：`AGENTS.md`、本规范、模块 `CLAUDE.md` 和组件使用说明。

2026-08-26 治理验收基线为：

- 全量扫描 626 个 Swift 文件，`DS001`–`DS011` enforced 违规为 0，历史 baseline 命中为 0。
- `component-catalog.json` schema v3 登记 60 项公共能力，其中 canonical 51 项、support 9 项；所有非 Vendor `UIComponents` Swift 文件均有明确 owner。
- `UIComponents` 对 Repository、ViewModel、AppDatabase、网络客户端的反向依赖为 0；SwiftUI、UIKit、桥接与仅字体测量边界均已登记。
- `DSR002` 保留 14 个 owner、19 条动画时长软观察候选。观察项不是失败，只有证明相同结构变化、时序和修复模式后才允许沉淀公共 motion token。

后续变更不得通过扩大排除范围、降低规则级别或写入新 baseline 来恢复绿色状态。

## 3. 分层与依赖方向

```text
Views/<Feature> ──> ViewModels / Presentation ──> Domain / Repository 协议
       │
       ├──> Views/<Feature>/Components（页面私有组合）
       │
       └──> UIComponents（跨模块稳定 UI） ──> Utilities/DesignSystem
                         └──────────────> 少量稳定 Domain 展示值
```

约束：

- `Utilities/DesignSystem` 不依赖 Domain、ViewModel 或业务页面。
- Domain 不导入 SwiftUI/UIKit，不持有 `Color`、`Image`、字体或视图类型。
- 领域值到颜色、图标和展示文案的映射由 `UIComponents` 或具体页面持有。例如热力等级保持纯值，`HeatmapPresentation` 在 UI 层完成展示映射。
- `UIComponents` 不访问 Repository，不保存业务配置，不成为业务状态 owner。
- 页面可以组合公共组件并保留局部布局；不得复制已经存在的公共能力。
- 公共组件只能依赖更底层的设计能力，不反向依赖具体业务页面。

### 3.1 `UIComponents` 目录拓扑

| 目录 | 职责 | 禁止内容 |
| --- | --- | --- |
| `Business/` | 已证明跨功能复用、具有明确领域语义的复合组件 | Repository、ViewModel、网络或数据库 owner |
| `Charts/` | 图表、图例与领域值到图表展示的适配层 | 页面导航、数据请求与业务写入 |
| `Controls/` | Button、Menu、Rating、Search、Selection 等原子交互语义 | 页面壳层与业务流程枚举 |
| `Feedback/` | Alert、Empty、Loading、Toast 等反馈基础设施 | 页面级错误恢复编排 |
| `Foundation/` | Card、BookCover、文本高亮等无业务或低业务视觉基础 | 为单页差异建立的万能容器 |
| `Media/` | 附件、图片、图库和只读富文本的媒体展示/桥接 | 富文本编辑流程与媒体 Repository |
| `Navigation/` | 返回保护、滚动边缘、Tab 与 TopBar 导航表达 | Feature 路由状态和页面私有子页壳层 |
| `Settings/` | 已验证的配置页语法与少量稳定行型 | 参数膨胀的万能设置行 |
| `Sheet/` | 通用业务 Sheet scaffold 与跨功能选择器 | 业务状态 owner 与持久化策略 |
| `System/` | 系统能力的窄桥接，例如分享面板 | 自建系统组件替代品 |

页面壳层只放在 `Views/<Feature>/`；页面私有子视图只放在 `Views/<Feature>/Components/`；业务 Sheet 只放在 `Views/<Feature>/Sheets/`。组件是否公共以 `component-catalog.json` 为机器真相，不以文件名或视觉相似度推断。

### 3.2 SwiftUI / UIKit 边界

- SwiftUI 是默认组合层。纯 SwiftUI 组件不得为了复用引入 `UIViewRepresentable`、`AnyView` 或 UIKit 生命周期。
- UIKit 仅用于系统 Alert、分享面板、GIF、JXPhotoBrowser、附件横向列表、只读富文本及命中测试等 SwiftUI 当前不能稳定表达的窄边界。
- `framework = bridge` 表示 SwiftUI 对 UIKit 的生命周期桥接；`framework = uikit` 表示 UIKit owner；两者都必须在组件目录登记具体依赖。
- `CalendarHeatmap`、`HeatmapChart`、`MonthlyReadingChart` 与 `XMSearchHistorySection` 仍由 SwiftUI 持有视图生命周期，只使用 `UIKit.UIFont` 做与渲染同源的文本测量，不归类为 bridge。

## 4. 设计令牌真相源

| 职责 | 唯一入口 | 页面使用边界 |
| --- | --- | --- |
| 通用排版 | `xmnote/Utilities/DesignSystem/AppTypography.swift` | 生产文本默认入口；禁止页面直接构造固定系统字号 |
| 跨组件组合排版 | `SharedContentTypography.swift` | 仅承载已证明跨组件复用的阅读或功能层级 |
| 语义颜色 | `SemanticColors.swift` | 页面使用角色名称，不按当前色值选 token |
| 颜色构造 | `ColorConstruction.swift` | 仅设计系统 owner 与确有独立调色板 owner 的功能层使用；普通页面禁止直接构色 |
| 间距 | `Spacing.swift` | 通用节奏使用 token；单页几何使用页面级语义常量 |
| 圆角 | `CornerRadius.swift` | 按 inlay / block / container 角色选择，并保留 continuous 轮廓 |
| 描边 | `StrokeWidth.swift` | `hairline` 只表达多个独立组件共享的轻量边界语义 |
| 触控尺寸 | `InteractionMetrics.swift` | `minimumTouchTarget` 是 44pt 最小热区唯一入口 |

标准容器圆角的稳定映射为：纯展示领域标签复用 `inlaySmall`（4pt），标准内容卡片复用 `blockLarge`（12pt），大型设置分组由 `XMSettingsGroup` 固定消费 `containerXXL`（24pt）。这些值按基础角色命名，不追加 `tagContainer`、`contentItem`、`settingsGroup` 等组件同值别名。

新增 token 的准入条件：

- 至少两个独立生产场景具有相同语义，而不只是数值恰好相同。
- 两处场景需要相同的变更原因和相同的未来演进方向。
- 现有 token 无法准确表达该角色。
- 变更说明包含目标场景、与现有 token 的差异和 Dynamic Type / 外观行为。

不满足准入条件时，使用页面级 `Layout` / `Metrics` 私有常量；不要用全局 token 收藏每一个数字。

## 5. 公共组件边界

### 5.1 配置类页面

卡片式配置页使用以下组合语法：

```swift
XMSettingsPage {
    XMSettingsSection("分区标题") {
        XMSettingsGroup {
            // 已证明复用的行，或页面私有业务组合
        }
    }
}
```

职责：

- `XMSettingsPage`：滚动、全轴回弹、页面背景、横向边距、底部空间和 640pt 最大内容宽度。
- `XMSettingsSection`：分区标题排版、内容对齐和标题—内容亲密性。
- `XMSettingsGroup`：卡片表层、分组/单项轮廓、内部留白与形态过渡；grouped 形态固定使用 24pt continuous 轮廓，页面不得覆盖。
- `XMSettingsDivider`：同组内弱分割线。
- `XMSettingsToggleRow`：单一标题与开关组成的稳定行型。
- `XMSettingsValueMenuRow`：离散值通过菜单选择的稳定行型，普通菜单使用中性色。

边界：

- 不提供万能行。图标、双行说明、异步状态、凭证编辑、账号卡片等差异由页面私有组合表达。
- 组件只表达布局和交互语义，不读取或持久化设置。
- 行视觉可以小于 44pt，但按钮、菜单和开关的有效热区不得小于 `InteractionMetrics.minimumTouchTarget`。
- Dynamic Type 下允许内容自然增高，不用固定高度裁剪多行文本。

### 5.2 业务 Sheet

业务 Sheet 根内容优先使用 `XMSheetScaffold`：

- 统一标题、副标题、关闭或双侧操作布局。
- 统一滚动容器与 `.scrollBounceBehavior(.always)`。
- 按需提供固定内容顶栏或底栏，并通过既有 scroll-edge 能力连接安全区。
- 槽位保留具体 `View` 泛型类型，禁止 `AnyView` 类型擦除。

`XMSheetScaffold` 不负责业务状态、保存策略、Repository 访问或领域校验。仅为系统选择器、单一确认弹窗等不符合业务 Sheet 关系的界面，不应强行套用 scaffold。

### 5.3 领域标签

纯展示的领域标签使用 `XMTagLabel`，由组件统一消费 `AppTypography.caption2`、`Color.tagBackground`、标准内边距与 `CornerRadius.inlaySmall`（4pt）连续圆角。

以下场景不使用 `XMTagLabel`：筛选或选择控件、状态标签、评分、指标、搜索历史以及可点击操作型 Capsule。这些元素即使外形相近，也具有不同交互状态和演进方向，应由各自真实 owner 管理。

### 5.4 公共组件准入

新增 `xmnote/UIComponents` 组件前依次确认：

1. `python3 scripts/design-system/ds.py catalog --symbol <关键词>` 中没有已有入口。
2. 至少两个独立模块存在相同语义、相同状态边界与相同修复模式。
3. 接口能限制不合规实现，不需要大量样式开关或业务枚举。
4. 组件可以放在稳定底层，不反向依赖具体功能。
5. 收口时同步术语表、组件文档清单、使用说明和模块 `CLAUDE.md`。

仅复用一段布局代码、只服务一个页面或需要大量参数才能覆盖差异时，保留为 `Views/<Feature>/Components` 页面私有子视图。

### 5.5 交互语义与 44pt 非视觉侵入

- 普通点击优先使用 `Button`、`Toggle`、`NavigationLink`、`Menu` 等原生语义控件，不用 `onTapGesture` 模拟按钮。
- 图标、标签或胶囊的视觉尺寸可以小于 44pt；不得为了满足点击区直接放大图标、背景、行高、间距或卡片占位。
- SwiftUI 紧凑控件使用 `xmMinimumHitTarget(anchor:)` 只扩展 `.interaction` content shape；UIKit 紧凑按钮使用 `XMMinimumHitTargetButton` 覆写命中测试。两者共享 `InteractionMetrics.minimumTouchTarget`，不改变原有 frame、constraints、bounds 或绘制。
- 位于屏幕或容器边缘时使用 anchor 把扩展量导向可命中区域；相邻目标扩展后重叠、祖先裁断或系统控件已经合规时不得机械接入。
- `.frame(minWidth:minHeight:)` 只用于视觉容器本就应达到该尺寸的场景，不能作为所有 44pt 治理的默认修复。

### 5.6 组件状态、可访问性与展示入口

- `component-catalog.json` 的 `stateCoverage` 从 `normal`、`pressed`、`focused`、`selected`、`disabled`、`loading`、`error`、`empty`、`editing` 等实际状态中登记；组件不需要为了表格完整而虚构无业务意义的状态。
- 生产文本使用 Dynamic Type 同源 token；语义色解析浅色、深色与高对比度；结构运动读取 Reduce Motion 并由真实运动 owner 提供降级。
- 可交互组件必须有自然的 VoiceOver label/value/hint、合理元素分组和至少 44pt 可命中区域；装饰图标从可访问性树隐藏。
- `DesignSystemGalleryView` 是 DEBUG 组件展厅，由 `DebugCenterView` 进入；它只持有演示状态，不进入生产导航或业务数据流。
- 展厅提供默认、深色、辅助功能字号、320pt 紧凑宽度与 768pt 规则宽度 Preview。`colorSchemeContrast` 和 `accessibilityReduceMotion` 反映系统环境与系统偏好，当前 SDK 中不是可写 Preview 环境值；高对比度与 Reduce Motion 必须在 Simulator 系统设置下做运行态验证，不建立伪环境覆盖层。
- 目录中的 `previewPolicy` 只有三种：`required` 表示组件同文件 Preview；`hosted` 表示由展厅或专项 Debug 场景承载；`notApplicable` 仅用于纯值或内部支撑能力，并必须写明原因。

## 6. 机器约束

### 6.1 规则等级

| 规则 | 等级 | 约束 |
| --- | --- | --- |
| `DS001` | enforced | 生产文本必须使用排版 token；SF Symbol glyph 不按文本处理 |
| `DS002` | enforced | padding、stack spacing 与 line spacing 必须具有语义 |
| `DS003` | enforced | 页面和组件不得绕过集中入口直接构造颜色 |
| `DS004` | enforced | 表面圆角使用 `CornerRadius` 或页面级语义 owner |
| `DS005` | enforced | App 自有滚动容器保持有效轴向始终回弹 |
| `DS006` | enforced | 生产路径中心弹窗使用 `XMSystemAlert` |
| `DS007` | enforced | Domain 不依赖 SwiftUI/UIKit |
| `DS008` | enforced | `UIComponents` 不持有 Repository、ViewModel 或业务编排 owner，只接收展示值与动作 |
| `DS009` | enforced | 普通点击使用原生语义控件；复杂手势仅允许声明级、可失效例外 |
| `DS010` | enforced | 44pt 交互尺寸只由 `InteractionMetrics.minimumTouchTarget` 声明，视觉尺寸归真实布局 owner |
| `DS011` | enforced | 每个非 Vendor `UIComponents` 文件完整登记分类、层级、复用范围、状态、边界与 Preview 策略 |
| `DSR001` | report | 字面量 SF Symbol 需要人工确认语义 owner |
| `DSR002` | report | 字面量动画时长需要人工确认局部或公共运动语义 |
| `DSR003` | report | 裸 `ProgressView` 需要按读取、写入或局部进度语义判断 |

enforced 规则失败必须修正实现。report 观察项不自动等同缺陷，不得为了清零观察数制造无复用证据的 token 或组件。

### 6.2 baseline 生命周期

- `ui-lint-baseline.json` 只用于规则首次落地时锁定历史债务，不是永久豁免清单。
- 当前 baseline 为 0；新增违规不能写入 baseline。
- 若规则误报，先提供最小复现和工具测试，再修正规则匹配边界。
- 只有经明确批准的全仓迁移窗口才允许重新评估 baseline 策略。

### 6.3 接入位置

- `make -f Makefile.parallel-ios ai-build` 在构建前检查工作区变更。
- `.githooks/pre-commit` 检查暂存 Swift 文件。
- 本地全量收口使用 `python3 scripts/design-system/ds.py audit`。
- 不新增 GitHub Actions；本仓库当前采用本地确定性闭环。

## 7. AI 唯一执行路径

### 修改前

```bash
python3 scripts/design-system/ds.py context --paths xmnote/Views/Feature/ExampleView.swift
python3 scripts/design-system/ds.py catalog --symbol Settings
```

AI 必须先读取命令返回的设计入口和候选组件，再读取目标页面、同模块生产页面及对应 L2 `CLAUDE.md`。Android 只用于理解业务意图，不作为 iOS 视觉事实。

### 实现中

```bash
python3 scripts/design-system/ds.py lint --changed
python3 scripts/design-system/ds.py explain DS002
```

正确顺序是修正 owner 或使用路径，而不是改变规则以迎合当前代码。无法确认视觉结果时，标记“待模拟器验证”，不得从代码推断实际密度或颜色观感。

### 收口

```bash
python3 scripts/design-system/ds.py audit
make -f Makefile.parallel-ios ai-ui-lint-test
make -f Makefile.parallel-ios ai-build
```

随后执行 `AGENTS.md` 列出的术语、目录、L3、文档、滚动与知识闸门。App 单元测试与 UI Test 仍只在用户明确要求时运行。

## 8. 例外与变更流程

1. 先记录可复现路径和真实 owner。
2. 判断是单点业务差异、工具误报还是规范缺口。
3. 单点差异保留局部语义常量或私有组件。
4. 工具误报补充最小工具测试并修正规则，不添加文件级静默豁免。
5. 规范缺口必须给出两个独立场景证据、依赖影响和迁移范围，再修改公共 token、组件或 policy。
6. 规则、目录或输出格式变化同步更新 `scripts/CLAUDE.md`、根治理入口和本规范。

## 9. 验收矩阵

| 变更类型 | 必须验证 |
| --- | --- |
| token / 颜色 / 排版 | changed lint、全量 audit、浅色/深色、相关 Dynamic Type 场景、专用构建 |
| Settings 公共组件 | 四类配置页代表场景、44pt 热区、分组节奏、浅色/深色、较大动态字体 |
| Sheet scaffold | 标题操作、滚动回弹、固定栏、安全区、Reduce Motion、专用构建 |
| 44pt 命中基础设施 | SwiftUI/UIKit 几何测试、视觉 bounds 不变量、边缘 anchor、禁用态、运行态 A/B 点击证据 |
| 组件目录或归位 | schema 审计、非 Vendor 文件全覆盖、真实生产使用范围、Preview 策略、Repository/ViewModel 反向依赖扫描 |
| Preview / Debug 展厅 | 默认、深色、辅助功能字号、紧凑/规则宽度；高对比度与 Reduce Motion 使用系统设置运行态验证 |
| 规则实现 | SwiftSyntax 工具测试、全量 audit、正确样例与误报回归样例 |
| 公共组件新增/重大重构 | 术语表、组件清单、使用说明、目录边界、L3、专用构建 |

模拟器证据应使用当前任务 worktree 分配的精确 UDID，不得使用 `booted` 模糊选择器。截图放入已忽略的 `artifacts/`，避免把运行证据混入正式产品资源。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
