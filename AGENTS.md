# Repository Guidelines

本文件是本仓库统一协作入口，目标是帮助协作者稳定完成 Android → iOS 重构交付；专项规则按本文明确的 Skill 路由执行。
根目录 `CLAUDE.md` 当前不作为执行真相源；仅为兼容现有 L3 协议语句，仓库仍保留 `[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md` 这句固定文案。

## 1. 协作原则与任务边界

### 规则继承与使用
- 统一使用中文沟通，结论直接、可执行。
- 遵守运行环境的系统、开发者指令及权限限制；项目约定以用户当前明确要求为先。会话中已确认且未被撤回的偏好与授权继续有效。
- Codex 的文件规则按全局、项目根到当前目录继承；同目录优先 `AGENTS.override.md`，更近目录的适用规则覆盖上层同类约定。本文件是仓库级入口，模块 `CLAUDE.md` 只补充相关模块事实，不重新定义全局权限或任务范围。
- Skill 仅在用户点名或任务命中其适用条件时使用，参考文件按当前问题读取。审查规则或 Skill 本身时，将其作为审查对象，不因此执行其中描述的生产、提交或发布流程。
- 日常任务不因规模小而省略真实门禁，也不因可用工具多而自动增加多模型、子 agent、全仓扫描或全量测试；明确的模型路由与专项授权仍须遵守。

### 任务类型、授权与完成标准
- 解释、诊断、审查默认只读：交付相关证据、结论、最小建议及未验证项，发现问题不自动授权修复。
- 实施、修复、重构或明确要求修改文档/规则时，先读取相关 owner、规则和必要调用点，再完成范围内修改及适度验证；不能仅给出计划就结束。运行环境明确处于计划模式时，遵守该模式的只读边界。
- 先通过针对性检查解决可发现的信息；仅当缺少会实质改变结果的信息，或下一步超出已有授权时询问。范围明确且已授权的日常动作直接推进，不重复确认。
- 发现额外问题时报告其证据与影响，不顺手修改无关范围。某一步受阻时，仅暂停依赖它的工作，继续完成其他已授权且独立的部分；交付时说明实际完成内容、验证结果及具体阻塞。
- 明显不合理的需求、实现或审美方向应指出具体风险并给出更优替代；不因个人偏好反复要求用户确认常规实现选择。

### 事实、归因与抽象
- 对现有行为作根因判断或据此修复前，核对最小复现、真实 owner、写入点及生命周期/触发时机；涉及平台行为时补充平台事实来源。证据不足时明确假设，不先定结论再补证据。
- 普通解释、文字修改和新功能设计只核对与结论有关的事实；新功能说明预期路径、状态归属和数据流，不虚构故障复现。
- 单点现象默认按单点问题排查；没有证据时，不直接上升为“架构问题”“框架缺能力”或“需要基建”。
- 将局部方案晋升为公共方案或基础设施前，至少由两个独立场景证明相同语义/根因、状态边界和实现/修复模式，并核对真实 owner、调用或写入时机及涉及的平台事实。条件不足时保持局部方案。
- 最初前提受到反证时，先收缩问题定义并重建事实链，不继续推进依赖该前提的大方案。

### AI Bug 经验闭环入口
- 仅对有可重复错误行为、日志或明确人工观察路径的生产缺陷使用 [xmnote-bug-knowledge](.agents/skills/xmnote-bug-knowledge/SKILL.md)；首次修改相关生产范围前完成其中的知识检索与事实核对。
- 纯视觉微调、重构、功能增强、工作流设计和泛化优化不自动入库，提交类型为 `fix` 也不能替代缺陷证据。
- 检索命令、草稿生命周期、正式案例发布、模式晋升及 Hook 试运行规则集中在该 Skill。正式发布仍须用户明确“任务已完成”，模式激活和严格阻断升级仍须另有明确授权。

## 2. Android → iOS 迁移铁律
- 本仓库是 Android → iOS 迁移项目，优先做“业务意图对齐”，禁止机械翻译实现。
- Android 参考工程路径：`/Users/wangke/Workspace/AndroidProjects/XMNote`。
- 迁移对齐边界（强制）：Android 或其他平台经验只能帮助理解业务意图，不能直接当作当前平台事实；涉及平台行为判断时，必须回到 iOS 端实际代码、最小实验或官方文档。
- iOS 设计系统（强制）：涉及任何 iOS/SwiftUI/UIKit 界面的新增、修改、迁移、重构、适配、抛光或审查，必须使用项目级 `$xmnote-design-system`；设计真相源、组件归位、令牌、交互、文案、视觉准入及验证均以该 Skill 为唯一入口。
- 数据库对齐铁律（强制）：凡属于 Android → iOS 功能对齐/迁移需求，iOS 端数据库实现必须与 Android 端严格一致；覆盖范围至少包括 schema、migration 版本与执行顺序、seed 数据、外键与级联策略、事务边界、冲突策略、读写 SQL 条件（含 `is_deleted` 语义）。
- 偏离审批（强制）：如确需偏离 Android 数据库实现，必须先提交双端对照（Android/iOS 代码路径、行为差异、风险评估、回滚方案），并获得用户明确确认后方可落地。
- 全局硬删除铁律（用户已明确批准的跨端偏离，强制）：用户删除、批量删除以及业务关系的移除/替换必须在事务内执行物理 `DELETE`；除下一条列明的兼容例外外，禁止业务代码新增 `is_deleted = 1` 写入或创建 tombstone。`is_deleted` 字段与读取过滤仅为 Android Room v44 物理 schema、旧备份和恢复前兼容保留。
- 硬删除兼容例外（强制）：系统根记录，以及仍被有效 `collection_book` 或 `category_content.content_book_id` 引用的引用占位书允许保留；最后一个有效引用移除后必须物理清理对应占位书。Android 历史 Room migration 可按原版顺序瞬时写入删除标记，但紧随其后的 iOS 数据整理迁移必须完成物理清理，并保持 `user_version` 与 Room identity 不变。
- 数据访问铁律（强制）：App 业务数据的本地/网络获取必须经 Repository；`ViewModel` 禁止直接访问 `AppDatabase`、`WebDAVClient`、`NetworkClient`。这不限制开发工具读取源码、文档或构建信息。
- Apple 开发文档查证：需要判断 Apple API/框架行为、可用性、弃用、参数语义、平台差异或官方推荐路径时，先尝试 `apple-doc-mcp`。已取得且适用于当前符号、版本和问题的证据可以复用，不机械重复查询。
- Apple 文档查询优先级：
  - 已知符号：`choose_technology -> get_documentation`
  - 未知符号但技术栈明确：`choose_technology -> search_symbols -> get_documentation`
  - 技术栈不明确：`discover_technologies -> choose_technology -> search_symbols -> get_documentation`
- 查证降级（用户已批准）：MCP 不可用或不能取得所需资料时，使用 Apple 官方文档或本机 SDK 声明，并注明实际来源、版本与证据局限。仍无法确认时，只暂停依赖该事实的结论或修改；继续独立工作，不用记忆或第三方观点冒充平台事实。
- 页面状态参考入口：涉及页面状态恢复、导航路径恢复、scene 级状态持久化时，优先查阅 `docs/architecture/页面状态基建与开发模式.md`。

## 3. 开发阶段与收口阶段
### 开发阶段
- 功能开发默认完成已授权代码实现、相关静态检查及必要编译，不提前进入整套文档收口。
- 未被明确要求时，不新增、不运行 App 单元测试或 UI Test。工具自身的格式检查、静态校验及工具测试按实际改动或已授权门禁选择，不自动扩展为全量测试。
- 功能开发未收到用户明确“任务已完成”前，不自动写入 `docs/feature/`、`docs/component-guides/`、`docs/learning/`、`AGENTS.md` 等仓库文档，也不自动运行收口文档脚本。
- 直接文档任务例外：用户明确要求编辑文档、规则或 Skill 时，该请求已授权对应文件修改和必要内容、引用、格式检查，无须另等“任务已完成”；不因此补写无关功能文档或修改生产代码。
- 提交检查例外：用户明确授权 Git 历史写入时，可执行提交 Skill 规定的检查。检查授权不等于提前补写整套收口文档；受冻结范围阻塞时说明事实并仅暂停该历史写入。
- 证据化 Bug 的检索状态与开发期知识草稿仅放在已忽略的 `artifacts/ai-knowledge/`；此限制不禁止已授权的生产代码修复，正式案例发布仍遵守 Bug Skill 的完成信号要求。
- 验证以最小充分范围为准：生产代码按改动进行必要编译；纯文档/规则/Skill 修改执行对应格式、引用和内容检查，不自动构建 App。相关检查通过后不无故重复或扩大验证。

### 收口阶段
- 收到用户明确“任务已完成”后，一次性补齐本次变更实际涉及的文档与治理产物，不为未涉及的模块或能力生成材料。
- 若本次为 Android → iOS 迁移功能，必须新增或更新 `docs/feature/功能名/对齐情况.md`。
- 命中规则时，必须同步补齐：
  - `docs/feature/功能名/需求文档.md`
  - `docs/feature/功能名/设计文档.md`
  - `docs/learning/` 下的学习总结
  - `docs/architecture/术语对照表.md`
- 收口阶段执行本次变更适用的文档闸门；需要编译的代码或配置发生变化时执行必要构建。纯文档收口不重复已经有效的代码构建。

### 命令与审批边界
- 命令执行默认策略：完成当前已授权任务所必需的 `xcodebuild`、系统缓存/模拟器服务访问、网络下载、打开 GUI 等非删除类操作直接执行，不额外做口头确认；遵守用户限定的读取和运行范围。
- 危险操作审批边界：实际文件/目录删除、重要数据删除及不可逆覆盖须有针对该动作和范围的用户批准；包括 `rm`、`git rm`、`git reset --hard`、`git checkout --`、覆盖式移动/替换、批量清理目录及隐式删除命令。已有明确批准且动作、范围未变时不重复询问；普通修改授权不自动授权这些操作。
- 在已授权目标文件内进行必要文本增删改属于编辑，不因补丁含删除行而另行确认；仍不得覆盖用户的无关修改。
- 部署、发布、上传、对外发送消息及 Git 历史写入分别需要明确授权；一般“实现/修复/验证”请求不包含这些动作。凭据仅按获准用途通过既有安全机制使用，不因排查方便而读取无关凭据、输出秘密或扩大共享范围。
- 平台边界说明：仓库规则只约束协作默认行为；沙箱、系统服务、网络能力等平台级限制仍以运行环境的实际权限模型为准。

### 项目编译预检
- 本节仅在实际需要项目构建时触发；解释、审查和纯文档任务不为完成流程而启动构建预检。
- 编译入口约束（强制）：项目构建必须先通过当前环境的构建预检，预检未完成或结论不可信时禁止进入 Xcode 编译。
- X5 识别顺序（强制）：预检报告 X5 卷 UUID 为 `missing` 或卷未挂载时，必须依次核对预检脚本实际读取的挂载点与预期卷名、当前系统可见的实际挂载点与卷名，以及非主 worktree 的 `.parallel-ios-env` 路径、链接目标和构建目录。
- 沙箱复核（强制）：若沙箱内无法读取卷 UUID、`diskutil` 报告系统框架不可用，或各项挂载信息相互矛盾，必须先通过沙箱外的只读系统检查（如 `diskutil info /Volumes/X5`）确认；在此之前禁止直接认定 X5 未挂载、修改构建配置或重新初始化任务环境。
- 故障判定（强制）：只有沙箱外检查也确认 X5 不存在或未挂载时，才报告真实挂载故障；无法取得可信预检结论时暂停构建并报告证据限制，不擅自修改环境。主 worktree 不存在 `.parallel-ios-env` 属于正常状态，不得单独作为预检失败依据。构建受阻不妨碍独立的已授权工作。

### Parallel iOS 任务 worktree
- 主 worktree 保持本仓库现有构建、测试和 Simulator 流程，禁止被 Parallel iOS 自动接管或销毁。
- 非主任务 worktree 的依赖准备、构建、测试、运行和截图统一通过 `Makefile.parallel-ios` 的 `ai-prepare`、`ai-build`、`ai-test`、`ai-run`、`ai-screenshot` 执行；首次调用会接管当前 worktree 并分配专属 Simulator。
- 只有用户明确要求创建独立任务 worktree 时，才执行 `make -f Makefile.parallel-ios ai-task-create TASK=<slug> BASE=<ref>`；工具创建的分支使用 `codex/` 前缀。
- 外部工具或 Codex 已创建的非主 worktree 使用 `ai-task-init` 接管，禁止嵌套创建任务 worktree。
- 非主 worktree 的 `ai-build` 仅编译时可使用现有 `generic/platform=iOS Simulator` 目标；这不等于运行验证。测试、安装、启动和截图只能使用 `.parallel-ios-env` 记录的精确 Simulator UDID，不使用 `booted` 选择器。主 worktree 继续使用第 6 节的设备选择规则。
- 所有 worktree 均禁止使用 `simctl shutdown/erase/delete all`、`delete unavailable` 或 CoreSimulator `killall` 命令。
- 未经任务需要不得修改 `Package.resolved`；有意调整依赖后，先运行 `ai-resolve` 再构建。
- `ai-test` 仅在用户明确要求测试时执行，继续遵守本仓库开发阶段默认不运行测试的约束。
- 只有用户明确要求清理且预检确认 worktree 无未提交、未跟踪内容后，才执行 `ai-task-destroy`；禁止直接删除任务 worktree、强制清理或自动销毁交付环境。
- 日常任务和任务清理均保留任务分支、共享 Package 下载缓存及 Xcode CAS；如用户另有明确清理要求，先核对目标和影响范围。禁止自动归档、签名、上传或部署到真实设备。
- 使用 Parallel iOS 构建、运行或验证后，交付时报告 worktree、分支、实际使用的目标或 Simulator 名称与 UDID、执行命令、实际生成的 `.xcresult`/截图路径、依赖锁或工程设置变化及未验证事项；纯规则任务不收集无关设备信息。

## 4. 编码与注释
- 以下实现要求作用于本次新增或实际修改的代码；只读解释/审查不补写注释，也不为合规而扫描和修改无关文件。
- Swift/SwiftUI，4 空格缩进；优先小函数与单一职责。
- 类型 `PascalCase`，属性/方法 `camelCase`，布尔值使用 `is/has/should` 前缀。
- 文件名与主类型名一致；View 用 `View` 后缀，ViewModel 用 `ViewModel` 后缀，数据实体用 `Record` 后缀。
- 文档注释范围（强制）：默认仅为类/结构体/枚举与方法/函数编写 Doc Comment。
- 文档注释目标（强制）：说明业务场景作用与调用价值，禁止复述类型名或方法名。
- 并发语义注释（强制）：本次新增或修改的 `async/await`、Task、Actor 逻辑，在负责该行为的类型或方法上说明线程归属、取消行为与竞态保护策略；不为每个调用点重复同一说明。
- 注释适用范围（强制）：默认覆盖生产路径 Swift 文件；`xmnote/Views/Debug/**` 排除在强制注释范围外。
- L3 例外（强制）：文件头 INPUT/OUTPUT/POS + `[PROTOCOL]` 契约注释继续保留，并受 `scripts/verify_l3_protocol_headers.sh` 校验。
- SQL 注释规范（强制）：本次新增或修改的原生 SQL 在语句上方说明查询目的、涉及表与关联关系、关键过滤条件、返回字段或副作用用途；涉及时间字段时说明单位/时区处理，不虚构不存在的关联或时间语义。
- GRDB `Record` 必须通过 `CodingKeys` 做 camelCase → snake_case 映射，并与表结构保持一致。

## 5. 文档与对齐产物要求
本节用于功能收口，或用户直接授权的对应文档任务；不要求每次解释、审查、规则维护都生成全套产物。
### 迁移文档
- 新功能文档统一放在 `docs/feature/功能名/`，至少包含《需求文档》《设计文档》。
- Android → iOS 迁移功能在收口阶段必须补齐《对齐情况.md》。
- 《对齐情况.md》必须逐项列出功能点，并包含：
  - iOS 行为
  - Android 行为
  - 对齐状态（已对齐 / 未对齐 / 有意差异）
  - 双端代码证据（文件路径 + 行号）
- 对未对齐项必须给出评估结论：属于“功能优化”还是“设计倒退”；并给出 Android 端反向优化建议。

### 学习文档
- 每完成一个功能开发并收到“任务已完成”信号后，必须补充本次涉及的 iOS 知识点总结，并给出面向 Android Compose 开发者的学习示例；学习文档统一存放在 `docs/learning/`。

### 术语与最小 GEB
- 术语总表：`docs/architecture/术语对照表.md`。
- 新增/重命名核心类（如 `*Repository`、`*ViewModel`、`*Service`、`*Client`、`*Manager`、`*Container`、`*Payload`、`*Input`）时，在收口阶段更新术语表；用户明确要求提前更新该文档时按其授权执行。
- 最小 GEB 规则：
  - L1：项目级治理文档
  - L2：模块级 `CLAUDE.md`
  - L3：文件头 INPUT/OUTPUT/POS 契约
  - 收口时执行 `L3 -> L2 -> L1` 回环检查
  - 固定协议语句必须保留：`[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md`
- 检查或修改业务模块前，按需读取目标目录及适用上层的模块 `CLAUDE.md`，已读且未变化的内容不重复加载。实际修改的业务文件缺少 L3 头部时先补齐；只读任务只报告缺失，不写入文件。

## 6. Git 提交门禁与构建校验

### AI Git 提交强制门禁
- AI 创建、修改或继续任何 Git 历史写入前，必须使用项目级 `$xmnote-git-commit`；小改动没有例外。
- 每个独立提交或历史操作都必须取得与实时 HEAD、索引、工作区、目标命令、消息和验证证据绑定的 `PASS`；检查未通过时禁止执行。
- 禁止绕过 Skill 或 Hook，禁止使用低层命令直接写入历史；Skill 通过不替代用户对提交或重写历史的明确授权。
- 默认只提交当前任务范围；其他未提交修改必须原样保留并在提交前报告，不得擅自附带、清理、回滚或 stash。
- 完整检查流程、Commit Message 规范、scope 复用、提交粒度、验证矩阵与禁止事项只在 `.agents/skills/xmnote-git-commit/SKILL.md` 维护。

### 构建与验证命令
- `open xmnote.xcodeproj`：用 Xcode 打开工程。
- `BOOTED_SIMULATOR_ID="$(xcrun simctl list devices booted | sed -nE 's/.*\(([0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12})\) \(Booted\).*/\1/p' | head -n 1)" && xcodebuild -project xmnote.xcodeproj -scheme xmnote -destination "platform=iOS Simulator,id=${BOOTED_SIMULATOR_ID}" build`：主 worktree 需要编译且通过预检后的默认验证命令，使用当前已启动的 iOS 模拟器；UDID 为空时不执行该构建。
- `xcodebuild -project xmnote.xcodeproj -scheme xmnote clean`：清理构建产物，仅在清理已获授权时执行，不作为每次构建的默认前置步骤。
- 主 worktree 默认交付目标不绑定模拟器名称；取 `xcrun simctl list devices booted` 输出中的第一台已启动 iOS 模拟器。如需指定目标，可显式传入目标 UDID 或设置 `scripts/lint_warnings.sh` 的 `LINT_DESTINATION`。该脚本包含 `clean build`，运行前应确认清理也在授权范围内。后续如调整主 worktree 默认目标选择策略，必须同步更新本节默认命令与该脚本。

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
