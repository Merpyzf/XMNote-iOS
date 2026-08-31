# Repository Guidelines

本文件是本仓库统一协作入口，目标是帮助协作者稳定完成 Android → iOS 重构交付；专项规则按本文明确的 Skill 路由执行。
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
- iOS 设计系统（强制）：涉及任何 iOS/SwiftUI/UIKit 界面的新增、修改、迁移、重构、适配、抛光或审查，必须使用项目级 `$xmnote-design-system`；设计真相源、组件归位、令牌、交互、文案、视觉准入及验证均以该 Skill 为唯一入口。
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
- 页面状态参考入口：涉及页面状态恢复、导航路径恢复、scene 级状态持久化时，优先查阅 `docs/architecture/页面状态基建与开发模式.md`。

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
  - `docs/architecture/术语对照表.md`
- 收口阶段必须执行文档闸门与必要构建校验。

### 命令与审批边界
- 命令执行默认策略（强制）：对 `xcodebuild`、访问系统缓存/模拟器服务、网络下载、打开 GUI 等非删除类命令，默认直接执行，不额外做口头确认。
- 危险操作审批边界（强制）：凡涉及删除或不可逆覆盖的操作，一律先获得用户批准再执行；包括 `rm`、`git rm`、`git reset --hard`、`git checkout --`、覆盖式移动/替换、批量清理目录，以及其他会隐式删除文件的命令。
- 平台边界说明：仓库规则只约束协作默认行为；沙箱、系统服务、网络能力等平台级限制仍以运行环境的实际权限模型为准。

### 项目编译预检
- 编译入口约束（强制）：项目构建必须先通过当前环境的构建预检，预检未完成或结论不可信时禁止进入 Xcode 编译。
- X5 识别顺序（强制）：预检报告 X5 卷 UUID 为 `missing` 或卷未挂载时，必须依次核对预检脚本实际读取的挂载点与预期卷名、当前系统可见的实际挂载点与卷名，以及非主 worktree 的 `.parallel-ios-env` 路径、链接目标和构建目录。
- 沙箱复核（强制）：若沙箱内无法读取卷 UUID、`diskutil` 报告系统框架不可用，或各项挂载信息相互矛盾，必须先通过沙箱外的只读系统检查（如 `diskutil info /Volumes/X5`）确认；在此之前禁止直接认定 X5 未挂载、修改构建配置或重新初始化任务环境。
- 故障判定（强制）：只有沙箱外检查也确认 X5 不存在或未挂载时，才按真实挂载故障停止构建并报告；主 worktree 不存在 `.parallel-ios-env` 属于正常状态，不得单独作为预检失败依据。

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

## 4. 编码与注释
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

### 学习文档
- 每完成一个功能开发并收到“任务已完成”信号后，必须补充本次涉及的 iOS 知识点总结，并给出面向 Android Compose 开发者的学习示例；学习文档统一存放在 `docs/learning/`。

### 术语与最小 GEB
- 术语总表：`docs/architecture/术语对照表.md`。
- 新增/重命名核心类（如 `*Repository`、`*ViewModel`、`*Service`、`*Client`、`*Manager`、`*Container`、`*Payload`、`*Input`）必须更新术语表。
- 最小 GEB 规则：
  - L1：项目级治理文档
  - L2：模块级 `CLAUDE.md`
  - L3：文件头 INPUT/OUTPUT/POS 契约
  - 收口时执行 `L3 -> L2 -> L1` 回环检查
  - 固定协议语句必须保留：`[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md`
- 进入新目录前，优先读取该目录下的 `CLAUDE.md`；若目标业务文件缺少 L3 头部注释，先补齐再继续。

## 6. Git 提交门禁与构建校验

### AI Git 提交强制门禁
- AI 创建、修改或继续任何 Git 历史写入前，必须使用项目级 `$xmnote-git-commit`；小改动没有例外。
- 每个独立提交或历史操作都必须取得与实时 HEAD、索引、工作区、目标命令、消息和验证证据绑定的 `PASS`；检查未通过时禁止执行。
- 禁止绕过 Skill 或 Hook，禁止使用低层命令直接写入历史；Skill 通过不替代用户对提交或重写历史的明确授权。
- 默认只提交当前任务范围；其他未提交修改必须原样保留并在提交前报告，不得擅自附带、清理、回滚或 stash。
- 完整检查流程、Commit Message 规范、scope 复用、提交粒度、验证矩阵与禁止事项只在 `.agents/skills/xmnote-git-commit/SKILL.md` 维护。

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
