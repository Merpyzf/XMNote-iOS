# UIComponents/
> L2 | 父级: /CLAUDE.md

可复用 UI 组件唯一归属目录。公共组件只承载已证明稳定的视觉、交互或领域展示语义；不得持有 Repository、ViewModel、数据库、网络客户端或页面路由状态。

依赖方向：`Views/<Feature> -> UIComponents -> Utilities/DesignSystem`。页面私有组件放回 `Views/<Feature>/Components`，业务 Sheet 放回 `Views/<Feature>/Sheets`。

## 分层目录

- `Business/`: 单书评分、阅读计时附件、标签展示与标签选择等跨功能业务 UI；只接收值与动作。
- `Charts/`: 热力图、月度阅读与排行等图表，以及领域值到图表展示的适配。
- `Controls/`: Button、Menu、Rating、Search、Selection 原子交互；`XMMinimumHitTarget` 提供非视觉侵入 44pt 命中区。
- `Feedback/`: 系统 Alert 桥接、空态、加载门闩/加载视图、StatePresentation 组件族与全局 Toast。
- `Foundation/`: `CardContainer`、`XMBookCover` 与文本高亮等低业务视觉基础。
- `Media/`: 附件、图库、静态/GIF 图片和只读富文本；UIKit 只保留在明确桥接 owner 内。
- `Navigation/`: 返回保护、ScrollEdge、Tabs 与 TopBar；不得持有 Feature 路由状态。
- `Settings/`: 配置页 Page、Section、Group、Divider 与两类已验证稳定行型；禁止万能设置行。
- `Sheet/`: `XMSheetScaffold` 与跨功能年月选择器；不负责业务保存或 Repository 访问。
- `System/`: 分享面板等系统能力窄桥接。

### StatePresentation 约束

- 生产路径的完整空态、无搜索结果和无内容失败统一使用 `XMContentStateView`；禁止在该目录外直接构造 `ContentUnavailableView`。
- 卡片、分区和局部容器使用 `XMCompactStateView`；已有可信内容的刷新或写入失败使用 `XMInlineStatusBanner`。
- 状态标题保持 Regular，动作使用 `stateActionForeground` 的纯文字无边框样式，Banner 保持中性表层，仅由图标承载警告或错误语义色。
- `StatePresentation` 只统一展示，不持有 Repository、ViewModel 或全局业务状态机；新公共视觉须由两个独立生产场景证明相同语义与结构。
- 新公共组件必须加入 `StatePresentationCatalogView`，并同步机器目录、术语表、组件文档清单与指南。

## 发现与验收

- 机器目录：`scripts/design-system/component-catalog.json` schema v3；当前登记 canonical 55 项、support 9 项。
- 查询：`python3 scripts/design-system/ds.py catalog [--symbol <名称>]`。
- 修改前上下文：`python3 scripts/design-system/ds.py context --paths <Swift 路径>`。
- 所有非 Vendor Swift 文件必须登记分类、层级、复用范围、状态、依赖边界与 Preview 策略。
- `DesignSystemGalleryView` 只在 DEBUG 中提供组件状态、尺寸与外观验收，不进入生产导航。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
