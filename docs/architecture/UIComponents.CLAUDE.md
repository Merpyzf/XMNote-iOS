# UIComponents/
目录拓扑
- `Business/`: 跨功能业务 UI，只接收展示值与动作。
- `Charts/`: 图表与 UI 展示适配。
- `Controls/`: Button、Menu、Rating、Search、Selection 原子交互。
- `Feedback/`: Alert、Empty、Loading、StatePresentation、Toast；完整状态、紧凑状态与 Inline Banner 统一由 StatePresentation 组件族提供。
- `Foundation/`: Card、BookCover 与文本基础。
- `Media/`: 附件、图库、图片和只读富文本桥接。
- `Navigation/`: 返回保护、ScrollEdge、Tabs、TopBar。
- `Settings/`: 配置页组合语法与稳定行型。
- `Sheet/`: 通用业务 Sheet 与跨功能选择器。
- `System/`: 系统能力窄桥接。

约束
- 公共组件不得依赖 Repository、ViewModel、数据库、网络客户端或具体 Feature 页面。
- 页面私有组件归属 `Views/<Feature>/Components`，不因已有使用文档而成为公共组件。
- 组件发现、分类、状态、UIKit/SwiftUI 边界与 Preview 策略以 `scripts/design-system/component-catalog.json` schema v3 为真相；当前登记 60 项。
- 使用 `python3 scripts/design-system/ds.py catalog` 查询，禁止根据旧目录或文件名猜测入口。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
