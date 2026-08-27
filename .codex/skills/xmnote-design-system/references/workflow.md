# 工作流

## 修改前发现

先确认用户任务、目标路径、真实 owner 和现有证据，再选择实现：

```bash
python3 scripts/design-system/ds.py context --paths <相关 Swift 路径>
python3 scripts/design-system/ds.py catalog --symbol <已知符号名子串>
python3 scripts/design-system/ds.py catalog
```

`--symbol` 只匹配 catalog 的 `symbols`，不搜索中文 `useWhen/avoidWhen`。已知组件名时使用第一种 catalog 命令；不知道组件名时读取完整 catalog，再按用途、禁用边界和层级筛选。不得因为中文关键词返回空结果就断言没有公共能力。

读取命令返回的规则与候选组件，然后检查：

- 目标页面及其状态 owner、写入点和触发时机。
- 同模块已经上线且完成度较高的生产页面。
- 相关 `Utilities/DesignSystem` token owner。
- 候选 `UIComponents` 的 `useWhen`、`avoidWhen`、状态覆盖、Preview 和生产消费者。
- 目标目录的模块说明及任务涉及的专项架构文档。

Android 只帮助理解业务意图和信息结构；iOS 视觉、导航、交互与平台事实必须回到当前 iOS 实现或 Apple 官方资料。

`context` 的目录启发式只提供附近候选，不能替代专项查询。例如 Book/Note/Reading 下的配置 Sheet 也必须显式查询 Settings 与 Sheet 组件。catalog 缺席的文件视为未登记能力，不能凭 `XM` 前缀、所在目录或生产消费者推断为 canonical。

目标路径缺失时，先用功能名、路由和现有符号定位候选 owner。只有一个明确生产 owner 时继续；存在多个可能页面、用户任务或呈现关系时，先给出条件式决策并请求用户确认，禁止任选一个页面直接实施。

用户明确限制证据范围时，遵守限制并记录未执行的发现项：

- “只读/只审查”限制写入，不限制安全的只读发现，除非用户同时限定可读取文件。
- “只读这个文件”时不越界读取其他源码或运行页面，只能确认该文件内的结构事实。
- 未核对 catalog、token owner、生产消费者或渲染证据时，不得声称“符合/违反完整设计系统”；输出受限审查和下一步所需证据。
- 用户要求直接修改但关键页面、状态或导航关系仍有多个解释时，先确认，不用设计系统规则替用户猜产品意图。

### 设计决策底稿

对任务实际涉及的维度建立简短底稿；不涉及的维度不要为了格式完整而虚构：

| 维度 | 必须回答 |
| --- | --- |
| 用户任务 | 当前页面的主任务、次级任务和退出方式是什么 |
| 信息层级 | 主内容、结构信息、支撑信息和元数据分别是什么 |
| 排版 | 每类文本的角色、选用 Typography owner，以及为什么不选相邻档位 |
| 布局 | 哪些距离表达行内、内容块、容器或页面关系；非 Spacing 数字归哪个局部 owner |
| 表层 | 页面、卡片、嵌套表层和固定栏各自是否真的需要边界 |
| 组件 | catalog 返回的候选、采用/拒绝原因及其 `avoidWhen` |
| 状态 | 正常、加载、空、失败、禁用、编辑和写入中哪些真实存在 |
| 证据 | 代码可确认什么，哪些观感仍需 Preview/Simulator |

底稿不是另建文档的要求；它用于防止直接进入 modifier 微调。实现或评审结论应能追溯到其中的 owner 和证据。

## 四类任务

### 新增

1. 明确主任务、信息优先级、导航关系和页面容器。
2. 读取相关设计参考，为文本、间距、表层、操作和反馈选择语义角色。
3. 从机器目录选择已有页面语法与 canonical 组件，并核对 `avoidWhen`。
4. 业务差异优先保留为页面级组合，不先设计公共 API。
5. 同时覆盖正常、加载、空、失败、禁用和写入中的真实状态，不为了表格完整虚构状态。

### 修改

1. 找到问题真实 owner，区分 token、公共组件、页面组合、业务状态或平台行为。
2. 明确修改前必须保持的排版、布局、状态、导航和可访问性不变量。
3. 单点问题修到局部 owner，保持无关页面行为不变。
4. 只有独立场景证明同根因时，才把修复上升到公共层。

### 重构

1. 先记录必须保持的视觉、交互、状态、可访问性和导航不变量。
2. 优先收紧数据流、目录归位和组件边界，不顺手改视觉语言。
3. 需要改变外观或交互时，把它作为显式设计变更单独验证。

### 审查

1. 默认只读，不因发现问题自动修改代码。
2. 根据审查范围读取对应细粒度参考，不用一组通用审美词覆盖所有维度。
3. 按证据、用户影响和真实 owner 排序，不输出主观分数。
4. 代码无法证明的观感结论标记为“视觉风险，需截图验证”。
5. 用户要求实现时，再回到新增、修改或重构流程。

受限审查在结论开头列出“已读范围 / 未核对范围 / 结论上限”。例如只有代码时可以报告 token 绕过、固定尺寸和状态缺口；密度、颜色观感与最终层级只能报告风险。

## 实现中

```bash
python3 scripts/design-system/ds.py lint --changed
python3 scripts/design-system/ds.py explain <规则ID>
```

- enforced 失败修正真实实现或使用入口，不调整规则迎合当前代码。
- report 项是人工观察候选，不为清零而创建无复用证据的 token 或组件。
- 规则疑似误报时先构造最小复现并补工具测试，再修规则匹配边界。
- 涉及生产 SwiftUI 实现时同时使用 `swiftui-expert-skill`；涉及专项运动时同时使用 `ios-motion-design`。
- 每次新增 modifier 前先问：现有组件或 token 是否已经持有该语义；不要在调用处覆盖 canonical 组件内部排版、间距、颜色和圆角。
- 如果需要字面量，明确它属于业务数据、绘图算法、组件尺寸、视觉校准还是页面私有组合；只有留白才进入 `Spacing`。

## 视觉与行为验证

根据改动范围选择最小充分矩阵：

- 浅色、深色和相关高对比度状态。
- 默认字号、辅助功能字号、长文本与本地化。
- 紧凑和规则宽度、iPhone/iPad、横竖屏与安全区。
- 正常、按压、聚焦、选中、禁用、加载、失败、空内容和编辑中的真实状态。
- VoiceOver 语义、有效点击区和 Reduce Motion。
- 导航返回、Sheet 收起、重复触发、异步取消和失败恢复。

按改动维度追加检查：

- 排版：token 与角色匹配、字体/行距成对、SwiftUI 与 UIKit 测量同源。
- 间距与圆角：关系层级正确，未把点击区、线宽或尺寸塞进 Spacing，组件内部几何未被页面覆盖。
- 颜色与材质：真实前景/背景组合、根 tint 传播、状态双通道、玻璃只位于允许层级。
- 组件：catalog 的 `useWhen/avoidWhen`、真实状态覆盖、Preview 策略和依赖方向。
- 反馈：读取/写入意图、内容是否保留、是否需要用户决策，以及成功提示是否多余。

代码只能证明结构风险。需要判断密度、颜色、亲密性或最终层级时，必须使用 Preview、Simulator 截图或实际运行证据，并记录设备、尺寸、外观和状态。

## 开发期与收口期

- 开发期遵守仓库测试和文档冻结要求：默认执行 changed lint 与必要构建，不擅自运行 App 单元测试或 UI Test，不写正式治理文档。
- 公共组件必须按机器目录要求提供 `required`、`hosted` 或有理由的 `notApplicable` Preview 策略。
- catalog 数量和文档统计只属于快照，不进入 Skill；每次以实时 catalog 为准。
- 目录与文档脚本只证明其已覆盖规则通过，不等于所有页面归位、可访问性和视觉关系都正确；仍需人工核对真实 owner 与运行证据。
- 收到用户明确“任务已完成”后，按实际变更补齐组件指南、术语、组件清单和模块说明，再执行：

```bash
python3 scripts/design-system/ds.py audit
make -f Makefile.parallel-ios ai-ui-lint-test
bash scripts/verify_glossary.sh
bash scripts/verify_ui_glossary_scope.sh
bash scripts/verify_view_component_boundaries.sh
bash scripts/verify_component_guides.sh
bash scripts/verify_state_presentations.sh
bash scripts/verify_scroll_ux.sh
```

构建、Simulator 和 worktree 验证继续服从仓库当前任务环境，不使用模糊设备选择器替代任务分配的精确 UDID。
