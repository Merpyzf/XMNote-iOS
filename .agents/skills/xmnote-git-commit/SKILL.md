---
name: xmnote-git-commit
description: XMNote 项目级 Git 提交强制门禁。凡准备、创建、修改或继续任何 Git 历史写入，包括 commit、amend、reword、merge、revert、cherry-pick、rebase、冲突后的 continue 和 fast-forward，都必须使用本 Skill；根据实时 diff 检查提交边界、历史 scope、验证证据和提交信息，并生成一次性 PASS 凭据。只读的 status、diff、log、show 不单独触发，除非正在规划提交。
---

# XMNote Git Commit

本 Skill 是 XMNote 的 Git 提交工作流与 Commit Message 唯一规范源。它只约束 AI，不改变开发者手工 Git 流程，也不替代用户对提交或重写历史的明确授权。

## 不可绕过的入口

- 每次独立的 Git 历史写入前都重新执行本 Skill；小改动没有例外。
- 没有与实时状态绑定的 `PASS` 凭据时，不执行任何写历史命令。
- Skill 检查通过不等于用户授权。用户没有明确要求提交、合并、回退、拣选或重写历史时，只对该历史操作输出建议，不生成执行凭据或写入历史；继续完成独立且已授权的开发工作。说明或审查本 Skill 不自动触发提交流程。
- 永久禁止 AI 使用 `--no-verify`、禁用 `core.hooksPath`、`commit-tree`、`update-ref`、直接编辑引用、`git stash` 或其他低层方式绕过门禁；组合式 `git pull` 必须拆成可审计的获取与 merge。
- 不 stash、不清理、不回滚、不覆盖、不附带提交工作区中的其他修改；默认只暂存当前任务范围，并报告其余修改。
- `.codex/hooks.json` 中的门禁是工作流护栏，不是安全沙箱；即使 Hook 未加载，也必须遵守本 Skill。

## 每次提交的标准流程

### 1. 检查授权和实时事实

确认会话中是否已经授权当前历史写入；动作和范围未变时不重复询问。实际准备执行时运行：

```bash
python3 .agents/skills/xmnote-git-commit/scripts/commit_gate.py inspect
git diff -- <当前任务路径>
git diff --cached
```

读取完整工作区路径与状态、全部暂存 diff、当前任务的未暂存 diff、结构化 `blockers` / `warnings`、相关路径历史 scope，以及目标命令实际会写入的完整内容。当前任务中拟提交的未跟踪文件需要检查；无关修改通常只核对路径和状态，不逐一读取无关文件、凭据、会话记录或缓存。发现疑似秘密时不要在输出中展示内容。门禁自身的状态摘要和快照绑定仍照常执行，不缩小其校验范围。Commit Message 只能基于实际 diff，不得只根据对话、任务标题或最初需求推断。

### 2. 划定提交边界

将修改明确分为：

- 当前任务且属于同一业务意图的修改；
- 与当前任务无关、必须原样保留的修改；
- 临时文件、生成文件、个人配置或调试残留；
- 同一文件中无法安全拆分的混合修改。

一个提交只包含一个可独立理解、验证和回滚的逻辑变更。多个独立变更拆成多个候选，每个候选分别暂存、检查、取得凭据和提交。若同一文件混有无法安全拆分的其他修改，输出 `FAIL`，不得扩大范围。

未解决冲突、冲突标记、私钥、签名凭据、`.DS_Store`、日志、临时文件、DerivedData、`xcuserdata`、构建产物和门禁凭据属于硬阻断，不能用人工说明覆盖。疑似密钥、调试输出、TODO/FIXME、大于 1 MiB 的文件和受控生成物属于待确认风险；必须逐条复核 `inspect` 生成的 finding ID，并在 `review.risk_acceptances` 中写明理由。

复核不等于每项都询问用户：能用当前授权和事实判断的 warning 由执行者记录理由；只有缺失信息会实质改变提交范围或风险、或需要超出授权时才询问。硬阻断仍不能通过风险接受绕过。

### 3. 从完整历史选择 scope

提交主题格式为：

```text
type(功能模块): 动作 + 结果
```

允许的 `type` 仅为 `feat`、`fix`、`refactor`、`chore`、`docs`、`test`、`build`、`ci`、`revert`。

scope 表达稳定业务域，不表达文件名、实现技术或一次性动作。必须先从完整历史主题中检索语义接近的 scope：

```bash
git log --all --pretty=format:'%H%x09%s'
```

- 有语义等价名称时，完全复用历史中文写法，不创造近义词。
- 同一功能的代码、文档、术语和收口提交默认复用同一 scope。
- 只有相关路径历史与全仓历史中都不存在等价名称时才新增 scope；记录检索词、相邻候选以及逐项不适用理由。
- 新 scope 会按 Unicode、大小写、单复数、空格和分隔符归一化；与历史名称等价时必须复用，高相似候选未逐项排除时不得新增。
- 新 scope 应简洁、稳定、面向业务；`基础设施`、`工程`、`工程配置`、`规范` 只在确属跨域或仓库治理且没有更具体历史 scope 时使用。

### 4. 根据实际 diff 编写消息

- 主题使用中文，描述真实动作和结果，禁止 `提交本地全部改动`、`更新代码`、`修复问题` 等无信息标题。
- 多文件变更，或涉及配置、脚本、Skill、Hook、依赖、工程文件时，正文必填并包含 `变更点`、`影响范围`、`验证命令与结果`。
- 证据化缺陷已发布正式案例时，在正文末尾添加 `Knowledge-Case: IOS-BUG-YYYYMMDD-NNN`；试运行期缺少 trailer 可告警，但错误的案例或格式必须失败。
- `revert` 优先使用 `--no-commit` 落到工作区，再按普通提交检查和生成消息。
- 不合规的 cherry-pick 消息使用 `--no-commit`，再按普通提交检查。
- rebase 必须审计完整 replay 范围；未修改的历史消息可以保留，reword 必须逐条检查。发生冲突后，continue 前重新检查。

### 5. 执行验证矩阵

以下是 Git 历史写入的基础门禁，不是所有开发任务的默认流程。用户明确授权历史写入后，可执行这些检查，无须另等“任务已完成”；这不授权提前补写整套收口文档。所有提交至少执行并通过：

```bash
git diff --cached --check
python3 scripts/design-system/ds.py lint --staged
```

文档治理校验（术语表、L3 协议头、架构文档同步、Bug 知识库校验）不作为每次提交的强制前置条件，也不由 `prepare` 自动执行。是否运行这些检查遵循用户明确要求与仓库收口阶段规则；不能仅因用户要求提交就触发文档收口。此调整不删除校验工具，也不免除收口阶段的文档要求。

按变更类型追加证据：

- 生产 Swift、Xcode 工程配置或依赖配置：先通过仓库构建预检；主 worktree 使用当前已启动 Simulator 的 `xcodebuild`，非主 worktree 使用 `Makefile.parallel-ios ai-build`，并提供成功证据。非主 worktree 纯编译可用通用模拟器目标，运行类验证仍绑定任务 UDID。
- UI：执行 `$xmnote-design-system` 要求的相关上下文与静态检查；实际修改机器策略或工具逻辑时追加对应测试或 audit，不因只编辑 Skill 措辞就运行全量设计系统测试。
- Skill：对每个修改过的 Skill 运行 `quick_validate.py` 并核对引用，包括 `.agents`、`.codex` 和 `.claude` 中的入口；纯说明修改不自动触发工具实现测试。
- 脚本或 Hook：实际修改工具逻辑时运行对应工具测试；Hook 配置完成 JSON 解析；门禁逻辑修改运行临时仓库测试。
- App 单元测试和 UI Test 仍只在用户明确要求时运行；未运行时在验证摘要中写明仓库边界，不能伪装成已验证。

任何必需检查失败、验证不足、暂存内容变化、消息与 diff 不匹配或边界不清时输出 `FAIL`。

在当前任务授权内修正可解决的问题并重验受影响项；需要修改被冻结或无关文档时，报告阻塞并暂停该历史写入，继续其他独立工作。不降低门禁、不伪造通过结果，也不把提交失败当作停止整个任务的指令。

## 生成一次性 PASS 凭据

先在已忽略的 `artifacts/git-commit-gate/review.json` 记录决策：

```json
{
  "version": 2,
  "operation": "commit",
  "summary": "基于实际暂存 diff 的一句话说明",
  "included_paths": ["实际暂存路径"],
  "modules": ["主要模块"],
  "boundary_confirmed": true,
  "mixed_files": [],
  "scope": {
    "value": "历史 scope 或新 scope",
    "source": "historical",
    "search_terms": ["检索词"],
    "candidates": []
  },
  "validation": [
    {"command": "实际执行命令", "status": "passed", "result": "简短结果"},
    {"command": "未运行项", "status": "not_run", "reason": "明确原因"}
  ],
  "risk_acceptances": [
    {"id": "inspect 输出的精确 finding ID", "reason": "接受该风险的具体依据"}
  ],
  "message": "完整 Commit Message"
}
```

没有待确认风险时，`risk_acceptances` 必须是空数组；有风险时必须与实时 warning ID 完全一致，遗漏、伪造、重复或过期 ID 都会失败。`source` 为 `new` 时，`candidates` 至少记录相邻历史 scope 及不适用理由，并提供 `new_reason`。使用将要原样执行的精确命令准备凭据：

```bash
python3 .agents/skills/xmnote-git-commit/scripts/commit_gate.py prepare \
  --review artifacts/git-commit-gate/review.json \
  --command 'git commit -F artifacts/git-commit-gate/message.txt'
```

保留现有消息的 merge、cherry-pick 或 rebase 还必须声明 `message_mode: "preserve"`、`history_audit_confirmed: true` 和按执行顺序排列的 `replay_commits`。门禁会独立展开并绑定真实 replay 范围：fast-forward merge 只允许 `--ff-only`；合并提交先用 `--no-ff --no-commit`，再走普通 commit；revert 先用 `--no-commit`；不合规的 cherry-pick 同样先落到工作区。冲突后的 continue 会重新绑定当前 HEAD、索引、工作区和 replay 状态，无法确认完整范围时直接 `FAIL`。

`prepare` 会重新核对实时状态，并生成：

- `artifacts/git-commit-gate/attestation.json`
- `artifacts/git-commit-gate/message.txt`

`prepare` 会以参数数组重新执行全部基础验证命令，不接受仅在 review 中宣称“已通过”的结果；专项验证证据仍需先实际运行并记录。普通提交与 amend 必须通过 `-F artifacts/git-commit-gate/message.txt` 使用门禁生成的消息。

凭据绑定 worktree、HEAD、分支、索引 tree、暂存文件、工作区快照、操作类型、目标、精确命令、消息摘要、验证证据、风险 findings 与接受理由。v1 review/凭据已过期，必须重新执行 `inspect/prepare`；旧文件保留供审计，不自动删除。任一绑定内容改变即失效；一次成功的历史写入后凭据被消费；命令失败且历史未改变时可原样重试。

## 提交前用户可见输出

执行历史写入前必须输出简洁摘要：

```text
PASS
- 准备提交：<实际内容>
- 主要文件/模块：<范围>
- 验证：<已通过；未运行项与原因>
- 已说明风险：<无，或逐项 finding ID>
- 保留的其他修改：<无，或路径与原因>
- scope 依据：<复用的历史提交，或新建理由>
- Commit Message：<完整主题；正文可压缩展示>
```

失败时输出：

```text
FAIL
- 阻断原因：<具体事实>
- 需要处理：<下一步>
```

用户已明确授权时，输出 `PASS` 后执行与凭据完全一致的命令；否则停在建议阶段。执行后检查状态，确认只写入预期内容；若还有后续提交，从第 1 步重新开始。
