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

## 2. Android → iOS 迁移铁律
- 本仓库是 Android → iOS 迁移项目，优先做“业务意图对齐”，禁止机械翻译实现。
- Android 参考工程路径：`/Users/wangke/Workspace/AndroidProjects/XMNote`。
- 迁移对齐边界（强制）：Android 或其他平台经验只能帮助理解业务意图，不能直接当作当前平台事实；涉及平台行为判断时，必须回到 iOS 端实际代码、最小实验或官方文档。
- 数据库对齐铁律（强制）：凡属于 Android → iOS 功能对齐/迁移需求，iOS 端数据库实现必须与 Android 端严格一致；覆盖范围至少包括 schema、migration 版本与执行顺序、seed 数据、外键与级联策略、事务边界、冲突策略、读写 SQL 条件（含 `is_deleted` 语义）。
- 偏离审批（强制）：如确需偏离 Android 数据库实现，必须先提交双端对照（Android/iOS 代码路径、行为差异、风险评估、回滚方案），并获得用户明确确认后方可落地。
- 数据访问铁律（强制）：所有本地/网络数据获取必须经 Repository；`ViewModel` 禁止直接访问 `AppDatabase`、`WebDAVClient`、`NetworkClient`。
- Apple 开发文档 MCP（强制触发）：涉及 Apple API/框架行为、可用性、弃用、参数语义、平台差异、官方推荐实现路径时，必须使用 `apple-doc-mcp` 查证。
- Apple 文档查询优先级：
  - 已知符号：`choose_technology -> get_documentation`
  - 未知符号但技术栈明确：`choose_technology -> search_symbols -> get_documentation`
  - 技术栈不明确：`discover_technologies -> choose_technology -> search_symbols -> get_documentation`
- iOS26 参考入口：涉及液态玻璃与 iOS26 新特性时，优先查阅 `docs/learning/iOS26液态玻璃与高相关新特性开发参考.md`。
- 页面状态参考入口：涉及页面状态恢复、导航路径恢复、scene 级状态持久化时，优先查阅 `docs/architecture/页面状态基建与开发模式.md`。
- 加载状态参考入口：涉及加载态策略、读写反馈分级、Loading 门闩接入时，优先查阅 `docs/architecture/加载状态反馈基建设计.md`。

## 3. 开发阶段与收口阶段
### 开发阶段
- 默认仅允许代码实现与编译校验。
- 未被明确要求时，不执行单元测试、不执行 UI Test、不主动编写测试用例。
- 未收到用户明确“任务已完成”前，禁止写入任何仓库文档文件；包括 `docs/feature/`、`docs/component-guides/`、`docs/learning/`、`AGENTS.md` 等治理文档。
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
- 返回按钮复用约束（强制）：顶部 `leading` 返回按钮统一使用 `TopBarBackButton`；禁止在页面内手写 `Button + chevron.left` 作为导航返回入口。
- 顶部图标职责约束（强制）：`TopBarActionIcon` 只用于普通顶部 action icon，不承载返回语义。
- 导航栏玻璃禁令（强制）：已处于系统导航栏上下文的按钮，禁止再显式增加 `.glassEffect(...)`、`.buttonStyle(.glass)`、`.buttonStyle(.glassProminent)` 或等价 glass/material 包装。
- 弹窗实现约束（强制）：生产路径中心弹窗统一使用 `XMSystemAlert`（UIKit `UIAlertController` 桥接），禁止新增 SwiftUI `.alert` 作为中心弹窗实现。
- 弹窗按钮颜色规范（强制）：仅 warning/destructive 操作使用警告语义颜色，其余按钮必须使用系统默认语义颜色，禁止使用品牌色按钮。
- 书籍封面渲染约束（强制）：所有书籍封面渲染必须使用 `XMBookCover`（`xmnote/UIComponents/Foundation/XMBookCover.swift`），禁止手写重复封面渲染组合。
- 结构性 UI 变化必须带过渡动画，优先 `.snappy`、`.smooth`、`.spring`。
- 异步操作必须提供可感知反馈，避免点击无响应。
- 加载反馈分级（强制）：读取类加载采用“延迟显示 + 最短驻留”策略，默认阈值 `delay=150ms`、`minimumVisible=200ms`；写操作反馈必须即时显示并禁用重复触发入口。
- 加载组件边界（强制）：生产页面读取加载统一使用 `LoadingGate + LoadingStateView` 或 `LoadPhaseHost`；禁止新增裸 `ProgressView` 作为读取加载主态。
- 底部沉浸滚动约束（强制）：涉及 `ScrollView`、`safeArea` 与底部导航/手势区时，内容在底部圆角区域必须平滑过渡，禁止生硬裁切。

### 字体与设计令牌
- 生产文本统一走 `xmnote/Utilities/DesignTokens.swift` 中的 `AppTypography`；`SemanticTypography` 与 `BrandTypography` 仅作为底层排版基础设施存在，不作为页面层默认入口。
- 生产路径禁止直接新增 `.font(.system(size: ...))`、`UIFont.systemFont(ofSize:)`、`UIFont.boldSystemFont(ofSize:)` 等固定字号写法。
- 新增文本前先判定对象是 `生产文本 / 品牌数字与品牌标题 / 图标或装饰 glyph`；生产文本优先使用 `AppTypography`，品牌强调位使用 `AppTypography.brandDisplay(...)` 与相关裁切能力。
- 涉及文本宽度、行高、baseline、截断测量时，测量字体必须与渲染字体同源。
- 跨组件重复出现的文本层级必须沉淀到 `DesignTokens.swift` 的 `AppTypography` 或其组合 token；禁止散落魔法数字。

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
- `xcodebuild -project xmnote.xcodeproj -scheme xmnote -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build`：默认交付验证命令。
- `xcodebuild -project xmnote.xcodeproj -scheme xmnote clean`：清理构建产物。

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
- 提交前必须先执行 `git status --short` 与 `git diff --stat` 自检；发现无关改动时需先和用户确认是否纳入本次提交。

### 提交前 / 收口后必须执行的脚本
- `bash scripts/verify_glossary.sh`
- `bash scripts/verify_ui_glossary_scope.sh`
- `bash scripts/verify_view_component_boundaries.sh`
- `bash scripts/verify_l3_protocol_headers.sh`
- `bash scripts/verify_arch_docs_sync.sh`
- `bash scripts/verify_component_guides.sh`
