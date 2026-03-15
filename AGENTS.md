# Repository Guidelines

## 协作与决策原则
- 统一使用中文沟通，结论直接、可执行。
- 先理解再实现：先读现有代码与文档，再动手改动。
- 坚持第一性原理与建设性对抗：发现需求或实现有明显问题时，必须说明风险并给出替代方案。
- 本仓库是 Android → iOS 迁移项目，优先做“业务意图对齐”，禁止机械翻译实现。
- Android 参考工程路径：`/Users/wangke/Workspace/AndroidProjects/XMNote`。
- 规范分层：本文件是执行摘要；完整背景与细则以 `CLAUDE.md` 为准。
- 学习输出约定：每完成一个功能开发并收到用户“任务已完成”信号后，必须补充本次涉及的 iOS 知识点总结，并给出面向 Android Compose 开发者的学习示例（含对照思路与可运行代码片段）；学习文档统一存放在 `docs/learning/`。
- 组件文档机制：重要 UI 组件（`docs/architecture/UI核心组件白名单.md` 白名单组件 + `xmnote/UIComponents` 下新增/重大重构组件）在收到用户“任务已完成”信号后，必须新增或更新组件使用文档（`docs/component-guides/`），并登记到 `docs/architecture/UI组件文档清单.md`；白名单组件必须被清单全量覆盖。
- 对齐情况文档机制（强制）：对 Android → iOS 迁移功能，在收到用户“任务已完成”信号后，必须在 `docs/feature/功能名/对齐情况.md` 生成或更新对齐情况文档；该文档属于高优先级决策输入，不得省略。
- iOS26 参考入口：涉及液态玻璃与 iOS26 新特性时，优先查阅 `docs/learning/iOS26液态玻璃与高相关新特性开发参考.md`，并据此执行“Android 业务意图对齐 + iOS 原生表达”。

## 执行优先级（与 CLAUDE.md 融合）
- 优先级顺序：用户当次明确要求 > `AGENTS.md` > `CLAUDE.md`。
- 默认执行策略：实现完成后默认只做编译校验；未被明确要求时，不执行单元测试、不执行 UI Test，不主动编写任何测试用例。
- 命令执行默认策略（强制）：对 `xcodebuild`、访问系统缓存/模拟器服务、网络下载、打开 GUI 等非删除类命令，默认直接执行，不额外做口头确认。
- 命令提权策略（强制）：若上述非删除类命令因运行环境限制需要额外权限，直接发起权限请求，不再额外先用自然语言征求一次同意。
- 危险操作审批边界（强制）：凡涉及删除或不可逆覆盖的操作，一律先获得用户批准再执行；包括 `rm`、`git rm`、`git reset --hard`、`git checkout --`、覆盖式移动/替换、批量清理目录，以及其他会隐式删除文件的命令。
- 平台边界说明：仓库规则只约束协作默认行为；沙箱、系统服务、网络能力等平台级限制仍以运行环境的实际权限模型为准。
- 文档触发策略（强制）：仅当用户明确发出“任务已完成”后，才允许生成或更新文档（含 `docs/feature/`、`docs/component-guides/`、`docs/learning/`、L1/L2/L3 同构文档）。
- 对齐情况文档触发策略（强制）：仅对 Android → iOS 迁移功能生效；在“任务已完成”前禁止写入 `docs/feature/功能名/对齐情况.md`，在“任务已完成”后必须与其他文档一次性补齐。
- 在“任务已完成”前：默认仅允许代码实现与编译校验；仅当用户明确要求测试时才执行测试；禁止文档写入与文档校验脚本执行。
- 在“任务已完成”后：必须一次性补齐文档，并执行文档相关闸门脚本。
- 用户明确要求测试时：优先单元测试（ViewModel、迁移、服务异常路径）；UI 测试仅在需求明确且收益大于耗时时执行。
- 数据访问铁律：所有本地/网络数据获取必须经 Repository，`ViewModel` 禁止直接访问 `AppDatabase`、`WebDAVClient`、`NetworkClient`。

## Apple 开发文档 MCP（分级强制，性能优先）
- MCP 标识：`apple-doc-mcp`；固定版本：`apple-doc-mcp-server@1.9.1`（项目内 wrapper 启动）。
- 触发规则（混合）：
  - 显式强制触发：用户明确要求“请使用 apple-doc-mcp / 使用 MCP 查询官方文档”时，必须调用。
  - 自动触发：涉及 Apple API/框架行为判定、可用性/弃用、参数语义、平台差异、Apple 官方推荐实现路径时，必须调用。
  - 可跳过：纯文案调整、纯样式微调、与 Apple API 无关的重构。
- 调用路径（按最小成本优先）：
  - 已知符号或文档路径：`choose_technology` → `get_documentation`（禁止先全量搜索）。
  - 未知符号但技术栈明确：`choose_technology` → `search_symbols` → `get_documentation`。
  - 技术栈不明确或跨框架：`discover_technologies` → `choose_technology` → `search_symbols` → `get_documentation`。
- 性能约束：
  - 默认软预算：单任务先以 2 次调用完成首轮结论（直达优先）；证据不足或高风险结论再扩展调用。
  - 会话内锁定 technology，禁止重复 discover。
- 输出要求：
  - 关键结论必须给出：技术栈 + 符号/文档路径 + 该证据支持的实现决策。
  - MCP 无结果或失败时，必须明确原因，并降级到 Apple 官方文档直链检索后再下结论。
- 禁止事项：
  - 未查证时凭记忆断言 Apple API 细节。
  - 为了流程合规机械执行完整链路，造成无效慢查询。
- 触发提示词模板（优先使用）：
  - `请使用 apple-doc-mcp 查询 <技术栈> 的 <符号/能力>，输出文档路径和结论。`
  - `请仅使用 apple-doc-mcp，按 choose -> search -> get 流程查 <问题>，未命中要说明原因。`
  - `请使用 apple-doc-mcp，先锁定 <SwiftUI/UIKit>，再查 <符号> 的可用性与平台差异。`

## 术语对照机制（强制）
- 术语总表：`docs/architecture/术语对照表.md`。
- UI 核心组件白名单：`docs/architecture/UI核心组件白名单.md`。
- 触发更新：
  - 新增/重命名核心类（如 `*Repository`、`*ViewModel`、`*Service`、`*Client`、`*Manager`、`*Container`、`*Payload`、`*Input`）必须更新术语表。
  - `xmnote/UIComponents` 下新增跨模块复用 UI 组件必须更新术语表（类别：`UI-复用`）。
  - `xmnote/Views/<Feature>/Components` 下页面私有子视图必须更新术语表（类别：`UI-页面私有`）。
  - 白名单内新增/调整核心页面组件必须同步更新白名单与术语表（类别：`UI-核心页面`）。
- 提交前强制执行：
  - `bash scripts/verify_glossary.sh`
  - `bash scripts/verify_ui_glossary_scope.sh`
  - `bash scripts/verify_view_component_boundaries.sh`
  - `bash scripts/verify_l3_protocol_headers.sh`
  - `bash scripts/verify_arch_docs_sync.sh`
  - `bash scripts/verify_component_guides.sh`

## UI组件归位规则（阻塞级）
- 页面壳层（`*View` 页面入口/容器）唯一归属目录：`xmnote/Views/<Feature>/`。
- ViewModel（`*ViewModel`）唯一归属目录：`xmnote/ViewModels/<Feature>/`；`xmnote/Views/**` 禁止放置 `*ViewModel.swift`。
- 跨模块复用 UI 组件唯一归属目录：`xmnote/UIComponents`。
- 新增组件前必须先扫描现有实现可复用性；若已有可复用组件，优先复用，仅在跨模块复用成立时才迁入 `xmnote/UIComponents`。
- 书籍封面渲染约束（强制）：所有书籍封面渲染必须使用 `XMBookCover`（`xmnote/UIComponents/Foundation/XMBookCover.swift`），禁止手写 `XMRemoteImage` + `aspectRatio` + `clipped` + `clipShape` + `overlay(stroke)` 的重复组合；统一宽高比 `XMBookCover.aspectRatio = 0.7`，统一 `.fill` Crop 裁切行为。
- `xmnote/Views/<Feature>/Components` 仅允许页面私有子视图（服务当前 Feature），不得作为跨模块公共组件。
- 业务 Sheet 必须放在 `xmnote/Views/<Feature>/Sheets/`，禁止与页面壳层混在同一文件。
- `UIComponents` 只允许放置无业务状态、无数据访问、副作用可控的跨模块复用组件。
- 禁止在 `xmnote/Utilities`、`xmnote/Services` 中新增跨模块公共组件。
- `xmnote/RichTextEditor` 属于功能模块，不整体迁入 `UIComponents`；仅纯展示且跨页面复用的子组件允许抽取到 `UIComponents`。
- 违反本规则视为阻塞级问题：必须先完成组件归位整改，再继续开发与提交流程。

## 分形文档系统执行约束（GEB）
- The map IS the terrain. The terrain IS the map.
- 代码与文档必须同构：在用户明确“任务已完成”后，任何一相变化，另一相必须同步更新，否则视为未完成。
- 三层分形映射：
  - L1：`/CLAUDE.md`，负责项目宪法与全局地图（触发：顶级模块/架构变化）。
  - L2：`/{module}/CLAUDE.md`，负责模块地图与成员清单（触发：文件增删、重命名、接口变更）。
  - L3：文件头部注释，负责 INPUT/OUTPUT/POS 契约（触发：依赖、导出、职责变化）。
- 强制回环（代码→文档）：仅在用户明确“任务已完成”后启动，按 `L3 -> L2 -> L1` 依次检查。
- 进入新目录前置检查：先读目标目录 `CLAUDE.md`，再读目标文件 L3 头部契约。
- 固定协议语句（L2/L3 必须保留原文）：`[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md`。
- 发现业务文件缺少 L3 头部注释时，必须先补齐后继续，属于阻塞级优先事项。
- 禁止孤立变更：改代码不检查文档、删文件不更新 L2、新模块不创建 L2 均视为严重违规。
- 文档回环触发门槛：收到“任务已完成”信号前不执行文档落盘；收到后必须完整回环并通过文档闸门。
- 双文档同构约束：`CLAUDE.md` 与 `AGENTS.md` 的项目结构、全局配置、工具链描述必须保持一致。变更任一文件的手工维护区域时，必须同步检查并更新另一文件对应内容，否则视为 SEVERE-005 违规。
- 本节为执行摘要；模板、禁令与完整回环流程以根目录 `CLAUDE.md` 的 GEB 完整版为准。

## 项目结构与模块组织
- `XMNote.xcodeproj`：工程入口（scheme: `xmnote`）。
- `xmnote/Localizable.xcstrings`：String Catalog，统一字符串管理（sourceLanguage: zh-Hans，含 en 占位）。
- `xmnote/AppState`：应用级全局状态目录（SwiftUI Environment 注入）。
- `xmnote/Views`、`xmnote/Navigation`：SwiftUI 页面与路由（按功能模块组织）。
- `xmnote/ViewModels`：页面状态与业务编排（按 Feature 镜像 `xmnote/Views/<Feature>/` 分层）。
- `xmnote/Domain`：Repository 协议与跨层模型。
- `xmnote/Data`：Repository 实现与依赖组装。
- `xmnote/Infra`：底层桥接与技术实现支持。
- `xmnote/Database`、`xmnote/Database/Records`：GRDB schema、迁移、Record 映射（仅 Repository 访问）。
- `xmnote/Services`、`xmnote/Networking`：网络、WebDAV、备份恢复（仅 Repository 访问）。
- `xmnote/RichTextEditor`：富文本编辑模块。
- `xmnote/Views/<Feature>/Components`：页面私有子视图目录（仅当前 Feature 内复用）。
- `xmnote/Views/<Feature>/Sheets`：业务弹层目录（按功能模块组织）。
- `xmnote/UIComponents`：跨模块复用 UI 组件唯一归属模块（按 Foundation/TopBar/Tabs/Charts 分层）。
- `xmnote/Utilities`：设计令牌与非 UI 工具（禁止新增跨模块公共组件）。
- `scripts/`：架构术语与 UI 组件范围校验脚本。
- `docs/feature/`：功能文档（需求 + 设计）。
- `docs/component-guides/`：重要 UI 组件使用文档（参数说明 + 接入示例 + 常见问题）。

## 自动同步模块清单（脚本生成）
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

## 构建与验证命令
- `open XMNote.xcodeproj`：用 Xcode 打开工程。
- `xcodebuild -project XMNote.xcodeproj -scheme xmnote -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build`：默认交付验证命令。
- `xcodebuild -project XMNote.xcodeproj -scheme xmnote clean`：清理构建产物。

## UI 与交互约束
- 遵循 iOS HIG，保持品牌与信息层级一致，避免无意义视觉修饰。
- 文本字号治理（强制）：先区分 `生产文本 / 品牌数字与品牌标题 / 图标或装饰 glyph`；生产文本在页面层统一走 `DesignTokens.swift` 中的 `AppTypography`，品牌强调位也统一从 `AppTypography.brandDisplay(...)` / `AppTypography.brandTrim(...)` 进入，图标尺寸不得伪装成文本字号规则。
- 语义化目标（强制）：补齐 Dynamic Type 与语义层级，不得让页面默认态整体变大；需要保留现有视觉基线时，统一通过 `AppTypography.fixed(..., minimumPointSize: baseSize)` 或 `AppTypography.uiFixed(..., minimumPointSize: baseSize)` 实现。
- 文本硬编码禁令（强制）：生产文本禁止新增 `.font(.system(size: ...))`、`UIFont.systemFont(ofSize:)`、`UIFont.boldSystemFont(ofSize:)` 等固定字号写法；图标尺寸、装饰性 symbol、Debug/Prototype 不在此禁令内。
- 文本测量同步（强制）：涉及文本宽度、行高、baseline、截断测量时，测量字体必须与渲染字体同源；系统语义文本统一使用 `AppTypography.uiSemantic(...)` 或 `AppTypography.uiFixed(...)`，品牌文本统一使用 `UIFont.brandDisplay(...)` 或 `AppTypography.brandTrim(...)` 配套链路。
- 品牌字体边界（强制）：品牌字体只用于品牌标题、关键数字、日期锚点等强调位；中文正文、密集说明、完整中文单位不得整段使用品牌字体，必要时以系统字体承接单位与说明。
- 新增字体规则（强制）：跨组件重复出现的文本层级必须沉淀到 `DesignTokens.swift` 的 `AppTypography` 或其组合 token；页面私有一次性层级允许局部 helper，但 helper 仍必须由 `AppTypography` 组合得到，禁止把固定字号散落在页面实现中。
- 字体入口边界（强制）：生产路径禁止直接新增 `.font(.body/.headline/...)`、`SemanticTypography.*`、`.brandDisplay(...)`、`BrandTypography.verticalTrim(...)` 等字体入口；这些底层能力只允许出现在 `DesignTokens.swift` 或排版基础设施中。
- 字体 token 收敛（强制）：禁止新增“模块 token 组”或页面级字体族；新增字体语义默认补到 `AppTypography`，只有跨页面稳定复用的组合样式才允许在 `DesignTokens.swift` 内增加极少量别名，且必须引用 `AppTypography`。
- 语义化后的适配顺序（强制）：出现显示不下时，先修布局、容器高度、换行策略、测量链路与 token 归位，禁止为了适配字号缩写业务文案、压缩中文单位或回退到固定字号。
- 结构性 UI 变化必须带过渡动画，优先 `.snappy`、`.smooth`、`.spring`。
- 异步操作必须立即反馈（加载态/按钮禁用/错误提示），避免“点击无响应”。
- 底部沉浸滚动约束（强制）：涉及 `ScrollView`、`safeArea` 与底部导航/手势区时，内容在底部圆角区域必须平滑过渡，禁止“生硬裁切”；允许底部沉浸延展，但不得破坏顶部工具栏的裁切边界与可读性。
- 迁移 Android 功能时，保证体验与业务一致，但采用 iOS 原生表达。
- 视觉要求：简洁、克制、现代，避免 Android 视觉直译。

## 编码风格与命名规范
- Swift/SwiftUI，4 空格缩进；优先小函数与单一职责。
- 类型 `PascalCase`，属性/方法 `camelCase`，布尔值使用 `is/has/should` 前缀。
- 文件名与主类型名一致：`BookDetailView.swift` → `BookDetailView`。
- 约定后缀：View 用 `View`，ViewModel 用 `ViewModel`，数据实体用 `Record`。
- 大文件用 `// MARK:` 与 `extension` 分组。
- 文档注释范围（强制）：默认仅编写类/结构体/枚举与方法/函数文档注释（Swift `///` 或等价 Doc Comment）。
- 文档注释目标（强制）：注释必须说明业务场景作用与调用价值，禁止复述类型名或方法名。
- 类文档注释（强制）：说明职责、使用位置与边界（负责什么/不负责什么）。
- 方法文档注释（强制）：至少说明业务动作、主要输入输出与调用方价值；若存在副作用、异步流程或错误语义，必须补充行为预期。
- 方法轻量契约（强制）：复杂方法按 `业务意图/前置条件/副作用/失败语义` 四要素描述。
- 并发语义注释（强制）：涉及 `async/await`、Task、Actor 时，必须说明线程归属、取消行为与竞态保护策略。
- 废话注释禁令（强制）：禁止使用或变体表达 `用于承载...`、`执行 XXX 逻辑`、`初始化当前类型实例`、`读取...所需数据 以异步方式执行`、`更新...相关状态并应用变更`、`清理...相关数据或运行状态`、`表示...数据结构与配置语义`、`描述...状态与分支类型，统一业务判定语义`。
- 非文档注释策略（默认）：实现内行注释、分支注释、布局技巧注释默认不要求；仅在用户单独提出时补充。
- 注释适用范围（强制）：默认覆盖生产路径 Swift 文件；`xmnote/Views/Debug/**` 排除在强制注释范围外。
- L3 例外（强制）：文件头 INPUT/OUTPUT/POS + `[PROTOCOL]` 契约注释继续保留，并受 `scripts/verify_l3_protocol_headers.sh` 校验。
- SQL 注释规范（强制）：所有原生 SQL（含 `SELECT/INSERT/UPDATE/DELETE/PRAGMA/CTE`）必须在语句上方补充详细注释，至少说明：查询目的、涉及表与关联关系、关键过滤条件（含 `is_deleted` 约束）、时间字段单位/时区处理、返回字段或副作用用途。
- SQL 变更同步（强制）：修改 SQL 时必须同步更新对应注释；SQL 与注释语义不一致视为缺陷。
- 注释语义同步（强制）：方法或查询行为发生变更时，必须同步更新对应文档注释；代码与注释冲突视为缺陷。
- 双文档同构（强制）：`AGENTS.md` 与 `CLAUDE.md` 的注释约束条款必须保持语义一致。
- GRDB `Record` 必须通过 `CodingKeys` 做 camelCase → snake_case 映射，并与表结构保持一致。
- 设计令牌使用规范（详见 `CLAUDE.md` §6）：
  - 新增文本前先判定对象是 `生产文本 / 品牌强调 / 图标`；生产文本优先选 `AppTypography.body/headline/subheadline/...` 等常量，只有要保留视觉基线或需要 UIKit 测量同步时才使用 `AppTypography.fixed(...)` / `AppTypography.uiFixed(...)`。
  - 生产文本若需保留现有默认点数，优先使用 `AppTypography.semantic(...)`、`AppTypography.semanticFont(...)` 或 `SemanticTypography.defaultPointSize(for:)` 推导系统基线，禁止手抄系统默认字号。
  - 品牌数字/品牌标题使用 `AppTypography.brandDisplay(...)`，若存在光学行盒偏移再配合 `AppTypography.brandTrim(...)` / `brandVerticalTrim(...)`，禁止把品牌字体铺到正文与密集说明。
  - `SemanticTypography` 与 `BrandTypography` 是底层排版基础设施，不是生产视图默认入口；生产路径默认不直接调用。
  - Spacing 先按「是不是留白问题 → Inline / Block / Container / Page 层级」选型，再优先使用默认档：`half / cozy / base / screenEdge / contentEdge / section / double`。
  - `compact / tight / comfortable / hairline / tiny / micro` 仅作为补位档使用；`actionReserved(44)` 属于点击热区/操作预留，不属于常规 spacing。
  - CornerRadius 二维命名：`inlay`（嵌入零件）/ `block`（独立单元）/ `container`（外壳）× `tiny~large`，按「角色→体量」两步选择。
  - 全局 token 定义在 `DesignTokens.swift`，组件语义别名必须引用全局 token，禁止硬编码魔法数字；字体治理默认只允许扩展 `AppTypography`，禁止继续拆分模块级字体 token 组。
  - 圆角角色映射（强制）：页面级主面板/核心背景卡使用 `container*`；内容主卡使用 `block*`；热力图/图例等密集小单元使用 `inlay*`。
  - 形状边界（强制）：`Capsule` 仅用于胶囊标签与按钮；`Circle` 仅用于点状状态与环形进度，禁止用于页面/内容卡片外壳。

## 提交与 PR 规范
- 提交信息必须使用中文，且统一格式：`type(功能模块): 动作 + 结果`（`type` 仅允许：`feat`/`fix`/`refactor`/`chore`/`docs`/`test`/`build`/`ci`/`revert`）。
- 禁止模糊标题：严禁使用 `提交本地全部改动`、`更新代码`、`修复问题` 等无信息提交说明。
- 提交标题必须明确三要素：变更对象、关键动作、结果/目的；避免“只描述动作不描述结果”。
- 单次提交只做一个逻辑变更，避免混入无关改动；跨模块且相互独立的改动必须拆分提交。
- 当用户要求“提交本地所有改动”时，允许合并提交，但必须在提交正文逐条写明改动点、影响范围与验证结果。
- 当改动涉及多个文件，或包含配置/脚本/依赖变更时，提交正文必填，至少包含：`变更点`、`影响范围`、`验证命令与结果`。
- 提交前必须先执行 `git status --short` 与 `git diff --stat` 自检；发现无关改动时需先和用户确认是否纳入本次提交。
- PR 必须包含：变更摘要、影响模块、验证证据（默认提供 build 命令与结果；如当次明确执行测试，再补充测试命令与结果）、关联任务/Issue。

## 文档与安全规范
- 以下文档规范仅在用户明确“任务已完成”后触发执行；此前允许准备草案，但禁止写入仓库文档文件。
- 治理文档触发策略（强制）：`AGENTS.md`、`CLAUDE.md` 等规范文档的更新同样受“任务已完成”信号约束，需在收口阶段统一同步，避免单边失构。
- 新功能文档统一放在 `docs/feature/功能名/`，至少包含《需求文档》《设计文档》。
- Android → iOS 迁移功能在文档收口时，必须补齐《对齐情况.md》（`docs/feature/功能名/对齐情况.md`，存在则更新，不存在则新增）。
- 《对齐情况.md》必须以列表形式逐项罗列每项功能点，并包含：功能点、iOS 行为、Android 行为、对齐状态（已对齐/未对齐/有意差异）、双端代码证据（文件路径 + 行号）。
- 对未对齐项必须给出评估结论：属于“功能优化”还是“设计倒退”；并给出反向指导 Android 端优化的建议（是否吸收、建议优先级、风险）。
- 重要 UI 组件使用文档统一放在 `docs/component-guides/`，并同步维护 `docs/architecture/UI组件文档清单.md`。
- 在文档收口阶段，代码实现与文档冲突时，先更新文档再改代码。
- 严禁提交真实账号、密码、Token、服务器地址；示例配置必须脱敏。
