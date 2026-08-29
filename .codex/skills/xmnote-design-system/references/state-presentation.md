# 页面状态与反馈

本参考是 XMNote 页面状态任务的设计系统执行合同。它规定 AI 在实现、迁移、治理或评审状态展示前必须确认的事实、映射顺序和阻断条件；不复制组件参数、当前尺寸或生产消费清单。

实时事实按以下顺序取得：

1. 真实业务 owner、Repository 返回语义和生产调用点。
2. `scripts/design-system/component-catalog.json`、`policy.json` 与公共组件源码。
3. 独立生产消费路径、Preview、测试中心和运行截图。
4. [通用状态展示设计规范](../../../../docs/architecture/通用状态展示设计规范.md) 与 [XMStatePresentation 使用说明](../../../../docs/component-guides/XMStatePresentation使用说明.md)。

来源冲突时不得用本参考覆盖真实 owner，也不得在页面增加特例掩盖公共组件或 Design Token 的问题。

## 修改前必须确认的事实

状态任务不能从一个 `if items.isEmpty` 或一张截图开始设计。对每个调用点至少确认：

1. 数据状态由哪个 ViewModel 或业务 owner 写入，Repository 的首值、空值和异常分别代表什么。
2. 当前是否已经收到过可信快照；失败发生在首次读取、后续监听、刷新、分页还是写入。
3. 空集合代表数据源真实为空，还是请求尚未返回、搜索/筛选无匹配、内容失效或权限前置条件未满足。
4. 用户当前是否还能浏览可信内容，以及是否存在安全、直接、真实的恢复动作。
5. 状态替代整页、Sheet、列表背景、卡片、分区，还是只附着在已有内容旁。
6. 页面是否已经有新增、清除筛选、验证或其他等价入口，避免状态内部重复操作。

对目标路径先运行：

```bash
python3 scripts/design-system/ds.py context --paths <相关 Swift 路径>
python3 scripts/design-system/ds.py catalog --symbol XMContentStateView
python3 scripts/design-system/ds.py catalog --symbol XMCompactStateView
python3 scripts/design-system/ds.py catalog --symbol XMInlineStatusBanner
python3 scripts/design-system/ds.py catalog --symbol LoadingStateView
```

只查询任务涉及的组件；未知入口时读取完整 catalog，再按 `useWhen`、`avoidWhen`、`usageScope` 和 `stateCoverage` 选择。

## 状态映射顺序

按顺序判断，不得从期望的视觉反推业务状态：

1. **尚未返回数据**：使用 placeholder、业务骨架或受 `LoadingGate` / `LoadPhaseHost` 管理的 loading；不是 empty。
2. **搜索或筛选有效且没有匹配**：使用 `.noResults`；数据源本身可能不为空。
3. **读取已完成且数据源确实没有内容**：使用 `.empty`。
4. **没有任何可用主体内容且读取失败**：使用 `.failure`，只在确有恢复路径时提供重试。
5. **等待用户选择、授权、验证或完成其他前置条件**：使用 `.instruction`，不能伪装成 empty 或 failure。
6. **内容不存在、已删除或已失效**：这是业务 missing/unavailable 状态；映射为中性 `.instruction`，直接说明事实，不提供无效重试。
7. **已有可信内容后刷新、监听、分页或写入失败**：保留内容，使用 `XMInlineStatusBanner`；不能切换为整页或整块 failure。

`missing` 和 `retained-error` 是业务阶段，不是新的 `XMStateRole`。Loading、success、上传百分比、AI 流式阶段等也不得加入通用角色枚举。

## 组件层级

| 内容关系 | canonical 入口 | 约束 |
| --- | --- | --- |
| 页面、Sheet、列表背景没有可用主体内容 | `XMContentStateView` | 只承接完整 instruction、empty、noResults、failure |
| 卡片、分区或局部容器没有可用内容 | `XMCompactStateView` | `.card` 已拥有表层，外部不再套卡 |
| 已有可信内容仍可继续浏览 | `XMInlineStatusBanner` | 页面负责位置；Banner 不覆盖或替换内容 |
| 读取主态与完整加载阶段 | `LoadingGate + LoadingStateView` 或 `LoadPhaseHost` | gate 只管理视觉时间，不拥有业务状态 |

通用状态组件只接受展示值和单一动作，不访问 Repository、数据库、网络或 ViewModel，不推断数据是否为空，也不持有恢复策略。

UIKit、`UICollectionView` 或特殊容器适配器可以拥有布局和生命周期，但内部通用视觉仍组合 canonical 状态组件。`StatePresentation/` 外不直接构造 `ContentUnavailableView`，不新增近义 `EmptyView`、`ErrorView` 或私有通用状态视觉。

## 加载与切换

- 首个可信快照到达前保持 placeholder/loading，不从空数组提前进入 empty。
- 读取主态通过现有 gate/phase host 驱动；读取其 owner 获取延迟、最短驻留和 Reduce Motion 行为，不在页面复制时序数字。
- 页面出现、业务阶段变化、取消和离场时同步 gate；离场清理未完成的显隐任务。
- `LoadingStateView` 只是视觉，不能直接成为请求状态 owner。
- 写入中的 spinner、确定进度、上传、导入、扫描、AI 流式输出和内容骨架由真实业务 owner 持有。
- 裸 `ProgressView` 先按读取主态、局部写入或确定进度分类；不能只因未使用通用加载组件就判为缺陷。

## 视觉、动作与文案

- 调用方消费公共组件、`StatePresentationTypography`、`StatePresentationMetrics` 和语义颜色，不自行覆盖字体、字号、字重、图标尺寸、动作颜色、间距、表层或转场。
- 普通空态从一句事实标题开始；图标、说明和动作都必须有独立信息价值，不能把“图标 + 标题 + 描述 + 按钮”作为默认模板。
- 相同层级的状态标题保持 Regular 和中性信息层级；错误通过必要的语义图标表达，不通过粗标题、大图形或彩色背景放大。
- 每个状态最多一个真实动作。页面已有等价入口时状态内不重复；创建、提交或确认等页面主操作留在工具栏或页面操作区。
- 状态动作使用公共组件 owner 的 `stateActionForeground` 文字交互语义和非视觉点击热区。品牌填充色不能因“可点击”直接充当小字号文字前景；若 canonical owner 在标准浅色、深色或高对比模式下仍缺少可读性，报告设计系统缺口，不增加页面私有颜色参数。
- 标题直接陈述事实；说明只补充用户不可见的原因或必要下一步。短文案不堆叠句号、欢迎语、愿景词或重复解释。
- 不展示 `localizedDescription`、数据库、服务器、连接或其他实现细节；原始错误写日志，用户文案只说明任务结果和恢复动作。
- 状态正文属于内容层，不使用 Liquid Glass、渐变、阴影、装饰插画、嵌套卡片或品牌色填空。
- 装饰图标对 VoiceOver 隐藏；有动作时正文与按钮保持独立焦点。Dynamic Type、最长中文和 RTL 下允许自然换行或重排，不压缩关键文字。
- Reduce Motion 下取消非必要位移、缩放和装饰动画，但必须保留可识别的阶段切换。

文案、排版、颜色或动效是任务重点时，再按 `SKILL.md` 路由组合读取对应参考，不因状态任务默认加载全部设计文件。

## 业务专用状态

以下状态的业务 phase、异步任务和恢复路径继续由领域 owner 负责，不能为了测试中心或统一外观扩充 `XMStateRole`。业务 owner 仍可按真实内容关系把“完全无内容的失败”映射到既有 `XMContentStateView` / `XMCompactStateView(.failure)`；复用公共视觉不等于把领域阶段提升为通用角色。

- 应用启动或根数据库初始化阻断。
- OCR 权限、受限、设备不可用和相册回退。
- AI 连接、流式输出、空结果、部分结果失败和应用失败。
- 单个附件的上传、删除与重试任务由领域 ViewModel/Controller 持有；`XMAttachmentUploadStrip` 只持有条目级展示和交互。
- 批次导入的确定进度、成功、失败和批次语义。
- 与真实内容结构同构的骨架、扫码占位、时间线空行和批量选择行。

业务专用不等于可以绕过设计系统：它仍消费现有 typography、semantic color、点击热区和反馈边界。只有确有部分可信内容时才能使用 Banner；首个 token、首个结果或首个快照前的完全失败必须由业务局部或完整失败状态承载。

## 反馈边界与恢复

- 同一个错误只选择一个最清楚的载体，禁止同时叠加完整状态、Banner、Toast 和 Alert。
- 需要确认、风险决策或轻量输入时回到 `XMSystemAlert`；短驻留且不阻断任务时使用 `XMToast`。完整交界规则见 [组件与交互](components-and-interaction.md#消息反馈边界)。
- 重试必须重建真实失败 owner，并在执行期间防止重复触发；不能只刷新状态 View。
- 删除、失效或权限永久受限等没有直接恢复路径的状态不制造重试。
- 写入失败保留草稿、选择、输入焦点和可信内容；不能为展示错误丢弃用户现场。

## 公共能力与测试中心

现有组件不贴合时按以下顺序处理：配置现有组件、在同一容器语义下扩展稳定 Style、满足双生产场景证据后扩展公共能力、否则保留业务私有实现。不得用一个页面、Debug Demo 或未来可能复用作为公共抽象证据。

新增或扩展公共状态能力必须：

- 只依赖设计令牌和共享展示语义，不反向依赖业务模型或状态机。
- 在机器目录登记准确的 `useWhen`、`avoidWhen`、状态覆盖和 Preview 策略。
- 至少有两个不同生产 Swift 文件证明相同语义、结构和修复模式。
- 将真实场景加入共享状态目录；业务专用样例由 Debug 层组合真实 owner，不复制 Demo UI。
- 覆盖普通与紧凑宽度、浅色与深色、标准与辅助功能字号、最长文案、可用与禁用动作、RTL、VoiceOver、Increase Contrast、Reduce Transparency 和 Reduce Motion 中适用的组合。

页面状态直接在页面表层验收，局部状态只保留其真实容器，避免 Demo 卡片改变层级。代码只能证明结构、token 和状态分支；颜色观感、密度、位置和层级仍需真实渲染或截图证据。

完成治理后运行：

```bash
bash scripts/verify_state_presentations.sh
python3 scripts/design-system/ds.py lint --changed --reports all
```

不得通过扩大白名单、降低规则、增加 baseline 或删减测试目录场景来消除失败。

## 直接阻断清单

- 数据尚未返回便展示空态，或仅凭初始空数组、可选值为 nil 推断 empty。
- 搜索/筛选无匹配使用 `.empty`，内容失效使用可重试 `.failure`。
- 已有可信内容后因监听或刷新失败切换为整页失败。
- 没有任何可信内容时使用“保留内容 Banner”。
- 同一错误重复使用页面状态、Banner、Toast 或 Alert。
- 用户可见文案直接拼接 `localizedDescription` 或技术实现细节。
- 页面直接构造 `ContentUnavailableView`、近义公共状态组件或私有通用状态视觉。
- 为 loading、success、OCR、AI、上传或导入扩展 `XMStateRole`。
- 调用点覆盖公共状态的字体、图标尺寸、动作颜色、卡片、玻璃或动画。
- 绕过 `stateActionForeground`，将品牌填充色泛化为小字号动作文字，或用页面颜色特例修补公共 owner。
- 使用模板欢迎语、愿景文案、无意义说明或默认完整状态套装填充版面。
