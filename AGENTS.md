# Repository Guidelines

本文件是本仓库唯一执行规范，目标是帮助协作者稳定完成 Android → iOS 重构交付。
根目录 `CLAUDE.md` 当前不作为执行真相源；仅为兼容现有 L3 协议语句，仓库仍保留 `[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md` 这句固定文案。

## 1. 协作原则与优先级
- 统一使用中文沟通，结论直接、可执行。
- 优先级顺序：用户当次明确要求 > `AGENTS.md`。
- 先理解再实现：先读现有代码、文档和脚本，再动手改动。
- 坚持建设性对抗：发现需求、实现或审美方向明显有问题时，必须指出风险并给出更优替代方案。
- 事实先于抽象（强制）：先验证事实，再解释原因，再设计方案；禁止先有结论、再补证据。
- 归因先于方案（强制）：一旦涉及行为判断、根因判断、架构判断，必须先找到真实 owner、真实写入点与真实触发时机。
- 问题分层（强制）：单点现象默认按单点问题排查；没有证据时，禁止直接上升为“架构问题”“框架缺能力”或“需要基建”。
- 最小事实闭环（强制）：推动任何抽象或系统性改造前，至少完成可复现路径、真实 owner、真实写入点、生命周期/调用时机、平台事实来源这五项核对。
- 抽象准入（强制）：只有同类问题在多个独立场景中被证明具备相同根因和相同修复模式后，才允许上升为公共方案或基础设施。
- 止损机制（强制）：一旦发现最初前提可能错误，优先收缩问题定义并重建判断；禁止边怀疑前提边继续推进大方案。

### AI Bug 经验闭环（强制）
- 仅对存在可重复错误行为、日志或明确人工观察路径的“证据化生产缺陷”启用经验闭环；纯视觉微调、重构、功能增强和泛化优化不得仅因提交类型为 `fix` 自动入库。
- 处理真实 Bug 时，首次修改相关生产范围前必须使用仓库 `xmnote-bug-knowledge` Skill，执行 `python3 scripts/ai-knowledge/kb.py search --query "<现象或错误>" --paths <相关路径>`，并核对案例、模式、项目规则、学习资料与 Git 历史。
- 诊断必须确认最小复现、真实 owner、真实写入点、生命周期/触发时机和平台事实来源；开发期仅在已忽略的 `artifacts/ai-knowledge/` 维护草稿，不得绕过文档冻结写入正式案例。
- 收到用户明确“任务已完成”后，符合准入条件的草稿才可发布到 `docs/knowledge/bugs/cases/`，并执行 `validate`、`audit`、`eval`、知识工具测试及仓库文档闸门；无法确认根因或验证结果的条目不得为凑数发布。
- 模式晋升必须至少有两个独立案例证明根因指纹和修复策略一致，适用/不适用边界明确；用户批准后才可从 `candidate` 进入 `active`，只有被必执行测试、静态脚本或构建路径覆盖时才可标为 `enforced`。
- `.codex/hooks.json` 只提供工作流护栏，项目 Hook 需用户审查并信任；Git Hook 在 30 天试运行期对缺少 `Knowledge-Case` trailer 的 `fix` 仅告警，严格阻断升级必须再次获得用户批准。
- 权威模型、生命周期、命令和状态定义以 `docs/knowledge/bugs/问题库说明.md` 与 `docs/architecture/AI Bug经验闭环设计.md` 为准。

## 2. Android → iOS 迁移铁律
- 本仓库是 Android → iOS 迁移项目，优先做“业务意图对齐”，禁止机械翻译实现。
- Android 参考工程路径：`/Users/wangke/Workspace/AndroidProjects/XMNote`。
- 迁移对齐边界（强制）：Android 或其他平台经验只能帮助理解业务意图，不能直接当作当前平台事实；涉及平台行为判断时，必须回到 iOS 端实际代码、最小实验或官方文档。
- iOS 设计真相源（强制）：涉及迁移、新页面或组件扩展时，以当前 iOS 项目已有生产页面、导航模式、设计令牌与公共组件为视觉和交互真相源；Android 界面仅用于理解信息结构与业务意图，未经用户明确批准禁止自行引入新的视觉语言。
- 数据库对齐铁律（强制）：凡属于 Android → iOS 功能对齐/迁移需求，iOS 端数据库实现必须与 Android 端严格一致；覆盖范围至少包括 schema、migration 版本与执行顺序、seed 数据、外键与级联策略、事务边界、冲突策略、读写 SQL 条件（含 `is_deleted` 语义）。
- 偏离审批（强制）：如确需偏离 Android 数据库实现，必须先提交双端对照（Android/iOS 代码路径、行为差异、风险评估、回滚方案），并获得用户明确确认后方可落地。
- 全局硬删除铁律（用户已明确批准的跨端偏离，强制）：用户删除、批量删除以及业务关系的移除/替换必须在事务内执行物理 `DELETE`；除下一条列明的兼容例外外，禁止业务代码新增 `is_deleted = 1` 写入或创建 tombstone。`is_deleted` 字段与读取过滤仅为 Android Room v44 物理 schema、旧备份和恢复前兼容保留。
- 硬删除兼容例外（强制）：系统根记录，以及仍被有效 `collection_book` 或 `category_content.content_book_id` 引用的引用占位书允许保留；最后一个有效引用移除后必须物理清理对应占位书。Android 历史 Room migration 可按原版顺序瞬时写入删除标记，但紧随其后的 iOS 数据整理迁移必须完成物理清理，并保持 `user_version` 与 Room identity 不变。
- 数据访问铁律（强制）：所有本地/网络数据获取必须经 Repository；`ViewModel` 禁止直接访问 `AppDatabase`、`WebDAVClient`、`NetworkClient`。
- Apple 开发文档 MCP（强制触发）：涉及 Apple API/框架行为、可用性、弃用、参数语义、平台差异、官方推荐实现路径时，必须使用 `apple-doc-mcp` 查证。
- Apple 文档查询优先级：
  - 已知符号：`choose_technology -> get_documentation`
  - 未知符号但技术栈明确：`choose_technology -> search_symbols -> get_documentation`
  - 技术栈不明确：`discover_technologies -> choose_technology -> search_symbols -> get_documentation`
- iOS26 参考入口：涉及液态玻璃与 iOS26 新特性时，优先查阅 `docs/learning/iOS26液态玻璃与高相关新特性开发参考.md`。
- 页面状态参考入口：涉及页面状态恢复、导航路径恢复、scene 级状态持久化时，优先查阅 `docs/architecture/页面状态基建与开发模式.md`。
- 加载状态参考入口：涉及加载态策略、读写反馈分级、Loading 门闩接入时，优先查阅 `docs/architecture/加载状态反馈基建设计.md`。
- 消息提示参考入口：涉及 Toast、Banner、Alert、Undo、删除反馈、手动排序反馈时，优先查阅 `docs/architecture/消息提示设计规范.md`。

## 3. 开发阶段与收口阶段
### 开发阶段
- 默认仅允许代码实现与编译校验。
- 未被明确要求时，不执行单元测试、不执行 UI Test、不主动编写测试用例。
- 未收到用户明确“任务已完成”前，禁止写入任何仓库文档文件；包括 `docs/feature/`、`docs/component-guides/`、`docs/learning/`、`AGENTS.md` 等治理文档。
- 证据化 Bug 可在已忽略的 `artifacts/ai-knowledge/` 中维护本地草稿与检索状态；该目录不属于仓库文档，正式案例仍受上一条冻结规则约束。
- 未收到“任务已完成”前，禁止执行文档校验脚本。

### 收口阶段
- 收到用户明确“任务已完成”后，必须一次性补齐本次变更涉及的文档与治理产物。
- 若本次为 Android → iOS 迁移功能，必须新增或更新 `docs/feature/功能名/对齐情况.md`。
- 命中规则时，必须同步补齐：
  - `docs/feature/功能名/需求文档.md`
  - `docs/feature/功能名/设计文档.md`
  - `docs/learning/` 下的学习总结
  - `docs/component-guides/` 下的重要 UI 组件使用文档
  - `docs/architecture/术语对照表.md`
  - `docs/architecture/UI组件文档清单.md`
  - `docs/architecture/UI核心组件白名单.md`
- 收口阶段必须执行文档闸门与必要构建校验。

### 命令与审批边界
- 命令执行默认策略（强制）：对 `xcodebuild`、访问系统缓存/模拟器服务、网络下载、打开 GUI 等非删除类命令，默认直接执行，不额外做口头确认。
- 危险操作审批边界（强制）：凡涉及删除或不可逆覆盖的操作，一律先获得用户批准再执行；包括 `rm`、`git rm`、`git reset --hard`、`git checkout --`、覆盖式移动/替换、批量清理目录，以及其他会隐式删除文件的命令。
- 平台边界说明：仓库规则只约束协作默认行为；沙箱、系统服务、网络能力等平台级限制仍以运行环境的实际权限模型为准。

### Parallel iOS 任务 worktree
- 主 worktree 保持本仓库现有构建、测试和 Simulator 流程，禁止被 Parallel iOS 自动接管或销毁。
- 非主任务 worktree 的依赖准备、构建、测试、运行和截图统一通过 `Makefile.parallel-ios` 的 `ai-prepare`、`ai-build`、`ai-test`、`ai-run`、`ai-screenshot` 执行；首次调用会接管当前 worktree 并分配专属 Simulator。
- 只有用户明确要求创建独立任务 worktree 时，才执行 `make -f Makefile.parallel-ios ai-task-create TASK=<slug> BASE=<ref>`；工具创建的分支使用 `codex/` 前缀。
- 外部工具或 Codex 已创建的非主 worktree 使用 `ai-task-init` 接管，禁止嵌套创建任务 worktree。
- 构建、测试、安装、启动和截图只能使用 `.parallel-ios-env` 记录的精确 Simulator UDID；禁止使用 `booted` 选择器及任何 `simctl shutdown/erase/delete all`、`delete unavailable` 或 CoreSimulator `killall` 命令。
- 未经任务需要不得修改 `Package.resolved`；有意调整依赖后，先运行 `ai-resolve` 再构建。
- `ai-test` 仅在用户明确要求测试时执行，继续遵守本仓库开发阶段默认不运行测试的约束。
- 只有用户明确要求清理且预检确认 worktree 无未提交、未跟踪内容后，才执行 `ai-task-destroy`；禁止直接删除任务 worktree、强制清理或自动销毁交付环境。
- 任务分支、共享 Package 下载缓存和 Xcode CAS 始终保留；禁止自动归档、签名、上传或部署到真实设备。
- 交付时报告 worktree、分支、Simulator 名称与 UDID、执行命令、`.xcresult`/截图路径、依赖锁或工程设置变化及未验证事项。

## 4. 架构 / UI / 编码硬约束
### 目录与组件归位
- 页面壳层（`*View` 页面入口/容器）唯一归属目录：`xmnote/Views/<Feature>/`。
- ViewModel（`*ViewModel`）唯一归属目录：`xmnote/ViewModels/<Feature>/`；`xmnote/Views/**` 禁止放置 `*ViewModel.swift`。
- 跨模块复用 UI 组件唯一归属目录：`xmnote/UIComponents`。
- `xmnote/Views/<Feature>/Components` 仅允许页面私有子视图，不得承载跨模块公共组件。
- 业务 Sheet 必须放在 `xmnote/Views/<Feature>/Sheets/`。
- 禁止在 `xmnote/Utilities`、`xmnote/Services` 中新增跨模块公共组件。
- `xmnote/RichTextEditor` 属于功能模块，不整体迁入 `UIComponents`；仅纯展示且跨页面复用的子组件允许抽取到 `UIComponents`。
- 新增组件前必须先扫描现有实现可复用性；若已有可复用组件，优先复用，仅在跨模块复用成立时才迁入 `xmnote/UIComponents`。

### UI 与交互
- 遵循 iOS Human Interface Guidelines，保证业务一致，但采用 iOS 原生表达。

#### 设计系统工程入口（强制）
- 设计系统架构、依赖方向、组件边界与例外流程以 `docs/architecture/iOS设计系统工程规范.md` 为权威说明；代码真相源位于 `xmnote/Utilities/DesignSystem/`、`xmnote/UIComponents/Settings/` 与 `xmnote/UIComponents/Sheet/`。
- 修改生产 UI 前，先执行 `python3 scripts/design-system/ds.py context --paths <相关 Swift 路径>` 获取当前规则与正确入口；查找公共组件使用 `python3 scripts/design-system/ds.py catalog [--symbol <名称>]`，禁止仅凭文件名猜测或新建同类实现。
- 开发中执行 `python3 scripts/design-system/ds.py lint --changed`；规则不清楚时执行 `python3 scripts/design-system/ds.py explain <规则ID>`；收口执行 `python3 scripts/design-system/ds.py audit`。`Makefile.parallel-ios` 的 `ai-build` 与 Git pre-commit 已接入变更范围检查，不得绕过。
- `DS001`–`DS007` 为阻断规则；`DSR001`–`DSR003` 为需结合上下文判断的观察项。当前 enforced 基线必须保持 0；禁止用扩大排除范围、降级规则或写入新 baseline 的方式消除失败。规则误报必须以最小复现补充工具测试后修正规则。
- 配置类页面使用 `XMSettingsPage + XMSettingsSection + XMSettingsGroup` 组合，已证明复用的行仅使用 `XMSettingsToggleRow` 与 `XMSettingsValueMenuRow`；业务差异保留在页面私有组合中，禁止新增参数膨胀的万能设置行。
- 通用业务 Sheet 使用 `XMSheetScaffold`；标题栏、滚动回弹、固定顶栏/底栏由 scaffold 统一，业务状态与业务控件仍由功能模块持有，禁止 `AnyView` 类型擦除。
- 新增全局 token 或跨模块组件前，必须证明至少两个独立生产场景具有相同语义、相同根因与相同复用方式；单页差异优先使用页面级组合常量或私有子视图。

#### 产品文案与标点（强制）
- 规范依据：组件语义与写作原则以 Apple Human Interface Guidelines 的 [Writing](https://developer.apple.com/design/human-interface-guidelines/writing)、[Buttons](https://developer.apple.com/design/human-interface-guidelines/buttons)、[Alerts](https://developer.apple.com/design/human-interface-guidelines/alerts)、[Notifications](https://developer.apple.com/design/human-interface-guidelines/notifications) 为平台基线，简体中文标点以现行 [GB/T 15834-2011](https://openstd.samr.gov.cn/bzgk/std/newGbInfo?hcno=22EA6D162E4110E752259661E1A0D0A8) 为语言基线；组件专项规则优先于通用短文案规则。
- 适用范围：所有用户可见文本均须遵守本节，包括生产与 Debug 界面、字符串目录、可访问性文案，以及 Domain、Repository、Service 中最终会展示给用户的错误或状态信息。
- 排除范围：代码注释、日志、断言、协议值、URL、文件名与扩展名、代码或命令、用户输入内容、外部原文和仅用于展示排版能力的样例正文不得机械套用本节规则。
- 无句末标点场景：按钮、菜单项、导航标题、分区标题、字段标签、placeholder、选项、角标与短状态标签不加句末标点；单句且简短、独立展示的辅助说明、设置描述、空状态、Toast、Banner、行内提示与 Sheet 补充说明不加结尾 `。` 或 `.`。
- Alert 文案：标题为片语时不加句末标点，标题为问句时保留 `？`；补充消息必须使用完整句子和恰当的句末标点。按钮标题使用简短、结果明确的动作词，不加句末标点。
- 通知文案：通知标题简短且不加句末标点；通知正文使用完整句子和恰当标点。多句说明、长段落、法律或风险说明、App Intent 完整描述同样保持完整书面标点。
- 中文符号：中文语境使用全角 `，。；：？！“”‘’（）`，中文标点前后不加空格；代码、URL、时间、小数、版本号及其他内部语法保留对应 ASCII 标点，不因周围存在中文而改写其内部结构。
- 省略号：进行中状态统一使用单个 `…`，禁止使用 `...`；正文中的语义省略按中文规则使用 `……`。不得用省略号代替可明确表达的操作或状态。
- 引号、书名号与冒号：中文界面术语使用 `“”`，书名使用 `《》`；中文说明关系使用 `：`。标签和值已由布局分隔时不机械追加冒号，禁止在同一中文语义单元中混用全角与半角标点。
- 本地化边界：日期、时间、数字与单位优先使用本地化格式化 API；标点应随完整可本地化语句进入字符串目录，禁止在调用处拼接跨语言标点。修改源文案键时必须同步更新 `Localizable.xcstrings` 并保留现有元数据。
- 可访问性文案：片语型 label 不加句末标点；包含多个信息单元的 announcement 或完整说明使用自然停顿与完整标点，确保 VoiceOver 朗读语义清楚。
- 人工检查清单：新增或修改文案时，依次确认展示组件、片语或完整句子、语言环境、本地化归属与同类组件既有风格；提交前检索 Swift 与字符串目录中的句末标点、`...`、中英文冒号和引号候选，逐项按 UI 上下文判断，禁止全局机械替换。

#### 滚动回弹与系统边缘效果
- 全轴回弹约束（强制）：应用自有的 SwiftUI `ScrollView`、`List`、`Form` 等滚动容器，无论内容是否超过一屏，都必须继承全局或显式使用 `.scrollBounceBehavior(.always)`；禁止使用 `.basedOnSize`。
- UIKit 回弹约束（强制）：应用自有的 UIKit 滚动容器必须按实际滚动轴设置 `alwaysBounceVertical = true` 或 `alwaysBounceHorizontal = true`，禁止显式关闭有效轴向的 `bounces` / `alwaysBounce…`。
- 例外边界：图片缩放画布、明确禁用滚动的静态骨架视图与第三方 Vendor 组件不按列表处理，不得为了满足本规范改变其缩放或静态展示物理。
- 系统边缘效果约束（强制）：顶部与底部渐进模糊必须依赖 iOS 原生 scroll-edge effect，可使用系统自动策略或 `.scrollEdgeEffectStyle(...)` 明确语义；禁止用自定义 blur、gradient、material 遮罩模拟，禁止额外添加 toolbar 常驻背景干扰系统效果。
- 主滚动视图识别约束（强制）：需要系统 scroll-edge effect 的页面，内容状态下的主滚动容器必须保持为页面根内容的直接滚动主体；固定反馈优先通过 `safeAreaBar` 等系统安全区 API 接入，禁止用额外布局容器隔断系统对主滚动视图的识别。

#### 导航 API 选择
- 导航实现前必须先判定页面关系，再选择 API：当前 Tab 内继续深入，用该 Tab 的 `NavigationStack + route enum + NavigationPath`；需要覆盖 `TabView` 且返回时保留底层现场，用根视图 `.fullScreenCover(item:)`，cover 内如需二级跳转再放独立 `NavigationStack`；只为当前页面补充参数、选择、确认或短信息展示，才用 `sheet` / `popover` / `alert`。
- 判定口诀：属于当前 Tab 浏览路径就 push；必须保住底层现场就 cover；只是辅助当前任务就 sheet/popover/alert。三者都不匹配时，先重审交互关系，禁止直接自造 overlay/navigation 动画系统。

- 返回按钮复用约束（强制）：顶部 `leading` 返回按钮统一使用 `TopBarBackButton`；禁止在页面内手写 `Button + chevron.left` 作为导航返回入口。
- 顶部图标职责约束（强制）：`TopBarActionIcon` 只用于普通顶部 action icon，不承载返回语义。
- 导航栏玻璃禁令（强制）：已处于系统导航栏上下文的按钮，禁止再显式增加 `.glassEffect(...)`、`.buttonStyle(.glass)`、`.buttonStyle(.glassProminent)` 或等价 glass/material 包装。
- 弹窗实现约束（强制）：生产路径中心弹窗统一使用 `XMSystemAlert`（UIKit `UIAlertController` 桥接），禁止新增 SwiftUI `.alert` 作为中心弹窗实现。
- 弹窗按钮颜色规范（强制）：仅 warning/destructive 操作使用警告语义颜色，其余按钮必须使用系统默认语义颜色，禁止使用品牌色按钮。
- 弹出菜单颜色规范（强制）：上下文菜单、长按菜单、更多菜单等各类弹出菜单应克制使用品牌色；普通操作使用系统默认色或 `menuActionForeground` 等中性色，只有删除、警告等具有明确语义的操作才使用对应的语义色，禁止用品牌色强调普通菜单项的可点击性。
- 书籍封面渲染约束（强制）：所有书籍封面渲染必须使用 `XMBookCover`（`xmnote/UIComponents/Foundation/XMBookCover.swift`），禁止手写重复封面渲染组合。
- 结构性 UI 变化必须带过渡动画，优先 `.snappy`、`.smooth`、`.spring`。
- 异步操作必须提供可感知反馈，避免点击无响应。
- 加载反馈分级（强制）：读取类加载采用“延迟显示 + 最短驻留”策略，默认阈值 `delay=150ms`、`minimumVisible=200ms`；写操作反馈必须即时显示并禁用重复触发入口。
- 加载组件边界（强制）：生产页面读取加载统一使用 `LoadingGate + LoadingStateView` 或 `LoadPhaseHost`；禁止新增裸 `ProgressView` 作为读取加载主态。
- 成功反馈优先通过界面状态变化表达，禁止默认新增“已完成/已更新”类轻提示。
- 失败、不可执行、需要用户决策的操作必须给出可感知反馈。
- 手动排序成功不弹成功提示；失败必须回滚或解释，搜索/筛选/非手动排序等不可排序场景必须前置阻断。
- 底部沉浸滚动约束（强制）：涉及 `ScrollView`、`safeArea` 与底部导航/手势区时，内容在底部圆角区域必须平滑过渡，禁止生硬裁切。

### 字体与设计令牌
- 生产文本统一走 `xmnote/Utilities/DesignSystem/AppTypography.swift` 中的 `AppTypography` 或页面级组合 token；`SemanticTypography` 与 `BrandTypography` 仅作为底层排版基础设施存在，不作为页面层默认入口。
- 生产路径禁止直接新增 `.font(.system(size: ...))`、`UIFont.systemFont(ofSize:)`、`UIFont.boldSystemFont(ofSize:)` 等固定字号写法；禁止在页面层随手 `.weight(...)` 或散落 `lineSpacing(...)` 魔法数字。
- 新增文本前先判定对象是 `生产文本 / 品牌数字与品牌标题 / 图标或装饰 glyph`；生产文本优先使用 `AppTypography`，品牌强调位使用 `AppTypography.brandDisplay(...)` 与相关裁切能力，书架首页优先使用 `BookshelfTypography`，书摘列表优先使用 `NoteExcerptTypography`。
- 文字层级必须遵循以下已定稿 token，不得因单个功能迭代随意改变字号、字重、行距或使用场景：

  | Token | 字号 | 字重 | 行距/行高 | 使用场景 |
  | --- | --- | --- | --- | --- |
  | `BookshelfTypography.topSelected` | 20pt | semibold | SwiftUI `title3` 默认动态行高 | 首页顶部选中 tab |
  | `BookshelfTypography.topUnselected` | 18pt | medium | SwiftUI `title3` 默认动态行高 | 首页顶部未选中 tab |
  | `BookshelfTypography.searchField` | 15pt | regular | SwiftUI `body` 默认动态行高 | 首页搜索输入、placeholder 与取消按钮 |
  | `BookshelfTypography.gridTitle` | 12pt | medium | SwiftUI `caption` 默认动态行高 | 书架网格书名、聚合卡标题 |
  | `BookshelfTypography.gridSubtitle` | 11pt | regular | SwiftUI `caption2` 默认动态行高 | 书架作者、副标题、列表次级说明 |
  | `NoteExcerptTypography.body` | 15pt | regular | `lineSpacing = 7pt` | 书摘正文预览，默认第一阅读层级 |
  | `NoteExcerptTypography.idea` | 13pt | regular | `lineSpacing = 4pt` | 书摘想法、引用说明、正文的补充层 |
  | `NoteExcerptTypography.footer` | 11pt | regular | SwiftUI `caption2` 默认动态行高 | 书摘时间、来源等辅助信息，颜色优先 `Color.textSecondary` |

- 首页文本层级规则：顶部 tab 必须弱于页面品牌/主标题但强于搜索与书架网格；搜索文案不得回退到 17pt `AppTypography.body`；书名保持 12pt medium，长标题优先通过现有截断、换行或跑马灯能力处理，不通过放大字号制造层级。
- 书摘列表文本层级规则：正文是第一阅读层级，保持 15pt regular 并通过 7pt 行距形成稳定阅读节奏；想法区低于正文一层；footer 必须可读但不抢正文，主要辅助信息禁止使用过淡的 `.tertiary`。
- 标题、正文、辅助信息、按钮文案边界：标题优先使用页面专用 token 或 `AppTypography.headline/title*`，不得为了强调直接加粗或放大；正文优先使用 `AppTypography.body/callout/subheadline` 或专用阅读 token，长文本必须同时明确行距与截断策略；辅助信息优先 11-12pt 并使用 `Color.textSecondary` / `Color.textHint` 等语义色；按钮文案使用所在页面 token，普通按钮不得默认使用品牌展示字体或自定义固定字号。
- 涉及文本宽度、行高、baseline、截断测量时，测量字体必须与渲染字体同源；例如书架标题跑马灯必须同步使用 `BookshelfTypography.gridTitle` 与对应 UIKit 测量字体。
- 跨组件重复出现的文本层级必须沉淀到 `DesignSystem/AppTypography.swift` 的 `AppTypography` 或其组合 token；禁止散落魔法数字。
- 后续新增页面或功能必须优先复用现有设计 token；如确需新增文本样式，必须在代码变更说明中写明新增原因、目标场景、与现有 token 的差异，并保持字号、字重、行距和阅读舒适度与当前文字系统一致。

### 编码与注释
- Swift/SwiftUI，4 空格缩进；优先小函数与单一职责。
- 类型 `PascalCase`，属性/方法 `camelCase`，布尔值使用 `is/has/should` 前缀。
- 文件名与主类型名一致；View 用 `View` 后缀，ViewModel 用 `ViewModel` 后缀，数据实体用 `Record` 后缀。
- 文档注释范围（强制）：默认仅为类/结构体/枚举与方法/函数编写 Doc Comment。
- 文档注释目标（强制）：说明业务场景作用与调用价值，禁止复述类型名或方法名。
- 并发语义注释（强制）：涉及 `async/await`、Task、Actor 时，必须说明线程归属、取消行为与竞态保护策略。
- 注释适用范围（强制）：默认覆盖生产路径 Swift 文件；`xmnote/Views/Debug/**` 排除在强制注释范围外。
- L3 例外（强制）：文件头 INPUT/OUTPUT/POS + `[PROTOCOL]` 契约注释继续保留，并受 `scripts/verify_l3_protocol_headers.sh` 校验。
- SQL 注释规范（强制）：所有原生 SQL 必须在语句上方补充详细注释，至少说明查询目的、涉及表与关联关系、关键过滤条件、时间字段单位/时区处理、返回字段或副作用用途。
- GRDB `Record` 必须通过 `CodingKeys` 做 camelCase → snake_case 映射，并与表结构保持一致。

## 5. 文档与对齐产物要求
### 迁移文档
- 新功能文档统一放在 `docs/feature/功能名/`，至少包含《需求文档》《设计文档》。
- Android → iOS 迁移功能在收口阶段必须补齐《对齐情况.md》。
- 《对齐情况.md》必须逐项列出功能点，并包含：
  - iOS 行为
  - Android 行为
  - 对齐状态（已对齐 / 未对齐 / 有意差异）
  - 双端代码证据（文件路径 + 行号）
- 对未对齐项必须给出评估结论：属于“功能优化”还是“设计倒退”；并给出 Android 端反向优化建议。

### 学习与组件文档
- 每完成一个功能开发并收到“任务已完成”信号后，必须补充本次涉及的 iOS 知识点总结，并给出面向 Android Compose 开发者的学习示例；学习文档统一存放在 `docs/learning/`。
- 重要 UI 组件（`docs/architecture/UI核心组件白名单.md` 白名单组件 + `xmnote/UIComponents` 下新增/重大重构组件）在收口阶段必须新增或更新使用文档，并登记到 `docs/architecture/UI组件文档清单.md`。

### 术语与最小 GEB
- 术语总表：`docs/architecture/术语对照表.md`。
- 新增/重命名核心类（如 `*Repository`、`*ViewModel`、`*Service`、`*Client`、`*Manager`、`*Container`、`*Payload`、`*Input`）必须更新术语表。
- `xmnote/UIComponents` 下新增跨模块复用 UI 组件必须更新术语表（类别：`UI-复用`）。
- `xmnote/Views/<Feature>/Components` 下页面私有子视图必须更新术语表（类别：`UI-页面私有`）。
- 白名单内新增/调整核心页面组件必须同步更新白名单与术语表（类别：`UI-核心页面`）。
- 最小 GEB 规则：
  - L1：项目级治理文档
  - L2：模块级 `CLAUDE.md`
  - L3：文件头 INPUT/OUTPUT/POS 契约
  - 收口时执行 `L3 -> L2 -> L1` 回环检查
  - 固定协议语句必须保留：`[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md`
- 进入新目录前，优先读取该目录下的 `CLAUDE.md`；若目标业务文件缺少 L3 头部注释，先补齐再继续。

## 6. 提交与校验清单
### 构建与验证命令
- `open xmnote.xcodeproj`：用 Xcode 打开工程。
- `BOOTED_SIMULATOR_ID="$(xcrun simctl list devices booted | sed -nE 's/.*\(([0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12})\) \(Booted\).*/\1/p' | head -n 1)" && xcodebuild -project xmnote.xcodeproj -scheme xmnote -destination "platform=iOS Simulator,id=${BOOTED_SIMULATOR_ID}" build`：默认交付验证命令，直接使用当前已启动的 iOS 模拟器。
- `xcodebuild -project xmnote.xcodeproj -scheme xmnote clean`：清理构建产物。
- 默认交付目标不再绑定模拟器名称；默认取 `xcrun simctl list devices booted` 输出中的第一台已启动 iOS 模拟器。如需指定目标，可显式传入目标 UDID 或设置 `scripts/lint_warnings.sh` 的 `LINT_DESTINATION`。后续如调整默认目标选择策略，必须同步更新本节默认命令与 `scripts/lint_warnings.sh`。

### 自动同步模块清单（脚本生成）
<!-- AUTO_SYNC_MODULES_START -->
- 由 `scripts/sync_arch_docs.sh` 自动维护，请勿手工修改。
- `xmnote/AppState`
- `xmnote/Data`
- `xmnote/Database`
- `xmnote/Domain`
- `xmnote/Infra`
- `xmnote/Navigation`
- `xmnote/Resources`
- `xmnote/RichTextEditor`
- `xmnote/Services`
- `xmnote/UIComponents`
- `xmnote/Utilities`
- `xmnote/ViewModels`
- `xmnote/Views`
- `xmnote/zh-Hans.lproj`
<!-- AUTO_SYNC_MODULES_END -->
- 同步命令：`bash scripts/sync_arch_docs.sh`
- 校验命令：`bash scripts/verify_arch_docs_sync.sh`

### 提交规范
- 提交信息必须使用中文，格式为 `type(功能模块): 动作 + 结果`。
- `type` 仅允许：`feat` / `fix` / `refactor` / `chore` / `docs` / `test` / `build` / `ci` / `revert`。
- 具体命名流程与复用规则以 `docs/architecture/Git提交风格规范.md` 为准。
- 括号中的功能名优先复用历史提交已有名称，保持原有中文写法一致，不自行发明近义词。
- 只有在历史里找不到语义等价的功能名时，才允许新增新的功能名。
- 严禁使用 `提交本地全部改动`、`更新代码`、`修复问题` 等无信息标题。
- 单次提交只做一个逻辑变更；跨模块且相互独立的改动必须拆分提交。
- 当改动涉及多个文件，或包含配置/脚本/依赖变更时，提交正文必填，至少包含：`变更点`、`影响范围`、`验证命令与结果`。
- 证据化缺陷修复在正式案例发布后，应在提交正文添加 `Knowledge-Case: IOS-BUG-YYYYMMDD-NNN` trailer；30 天试运行期缺少 trailer 只告警，案例/模式格式错误仍阻止提交。
- 提交前必须先执行 `git status --short` 与 `git diff --stat` 自检；发现无关改动时需先和用户确认是否纳入本次提交。

### 提交前 / 收口后必须执行的脚本
- `python3 scripts/design-system/ds.py audit`
- `make -f Makefile.parallel-ios ai-ui-lint-test`
- `bash scripts/verify_glossary.sh`
- `bash scripts/verify_ui_glossary_scope.sh`
- `bash scripts/verify_view_component_boundaries.sh`
- `bash scripts/verify_l3_protocol_headers.sh`
- `bash scripts/verify_arch_docs_sync.sh`
- `bash scripts/verify_component_guides.sh`
- `bash scripts/verify_scroll_ux.sh`
- `bash scripts/verify_ai_bug_knowledge.sh`
