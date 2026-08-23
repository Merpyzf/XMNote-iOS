# AI Bug 经验闭环：Android 到 iOS 工程治理总结

## 1. 核心迁移认识

Android 与 iOS 都可以用 Markdown 案例和本地索引复用 Bug 经验，但平台工程流程不同：iOS 仓库在用户确认完成前冻结正式文档，并要求 Apple API 结论回到当前代码、最小实验或官方文档。因此不能机械复制 Android 的“修复后立即生成案例”。

最终采用两段提交语义：

- 开发期：`artifacts/ai-knowledge/drafts/`，允许反复补证据，不污染 Git。
- 收口期：用户明确完成后发布 `docs/knowledge/bugs/cases/`。

## 2. Android 与 iOS 心智映射

| 目标 | Android 工程经验 | iOS 适配 | 原则 |
| --- | --- | --- | --- |
| 权威知识 | Markdown Front Matter | Markdown/JSON Front Matter | SQLite 都只是索引 |
| 开发期记录 | 可直接形成案例 | 先写 artifacts 草稿 | 遵守文档冻结 |
| 平台事实 | Compose/Android 行为 | 当前 SwiftUI/UIKit 代码、实验、Apple 文档 | 业务意图不等于平台事实 |
| 工程 gate | Gradle verification 可参与 | 不加 Xcode Build Phase | 普通 App 构建不依赖知识库 |
| 会话状态 | 仓库 artifacts | 每个 worktree 独立 artifacts | Parallel iOS 不串状态 |
| 模式晋升 | 案例聚类 | 两个独立案例 + 双指纹 + 用户批准 | 不凭评分越过抽象准入 |

## 3. 为什么必须记录 owner 和写入点

“阅读页回弹异常”表面 owner 是 ScrollView，实际 owner 是 `MainTabView` 根级搜索 modifier；“时间线查看崩溃”表面入口是时间线，实际 owner 是分页状态与页级异步生命周期。

这说明 Bug 卡如果只记录“改了哪个文件”，AI 下次仍会从受害页面开始试错。案例必须把：

- 受害者；
- 真实 owner；
- 写入点；
- 写入发生的生命周期；

明确分开。

## 4. 先命中、再加权

Android 原排序可能让 `enforced` 模式即使没有文本或路径匹配，也凭固定类型分进入 Top N。iOS 版先计算关键词、全文、元数据或路径命中；基础分为零就淘汰，之后才增加类型和状态权重。

伪代码：

```python
matched, base_score = real_match(record, query, paths)
if not matched:
    continue
score = base_score + kind_bonus(record.kind) + status_bonus(record.status)
```

这相当于 Compose 列表先按业务条件过滤，再对候选项排序，不能让“置顶权重”制造不存在的候选。

## 5. 脏工作树基线

AI 经常进入已有用户改动的工作树。仅保存文件名不够：同一个脏文件可能在任务中继续变化。iOS 版保存任务开始时的文件哈希：

```text
任务归因变化 = 当前 changed file hash != baseline hash
```

原本已脏且内容未变的文件不属于本任务；同一文件后来继续修改，则只把新变化视为当前任务范围。

## 6. Hook 不是安全沙箱

Codex Hook 适合做一次性检索提醒和 Stop 事实检查，但它依赖用户信任，也可能被配置错误。设计上应：

- 本地、无网络、最小写入范围；
- 首次拒绝后原样重试放行；
- `stop_hook_active` 防无限续跑；
- 提供 Git/Hook 关闭方式；
- 不把 Hook 描述成完整安全边界。

## 7. 面向 Compose 开发者的使用示例

收到“日历左右翻月偶发失效”的任务时：

```bash
python3 scripts/ai-knowledge/kb.py search \
  --query "日历 左右翻月 失效 DragGesture" \
  --paths xmnote/Views/Reading/ReadCalendar/ReadCalendarContentView.swift
```

检索会命中 `IOS-BUG-20260301-001`。但不能直接套用“删 DragGesture”：仍要在当前实现中确认分页 gesture owner、写入点和 selection 生命周期。案例帮助提出高质量假设，不替代复现。

开发期维护草稿：

```bash
python3 scripts/ai-knowledge/kb.py draft update DRAFT-20260823-001 \
  --set 'owner_paths=["xmnote/Views/Reading/ReadCalendar/ReadCalendarContentView.swift"]' \
  --set 'lifecycle="分页滚动结束前 selection 被重复写回"'
```

## 8. 评测解读

8 个种子各提供两条同义改写和一条边界负例。边界负例的含义是“对应错误案例不应被召回”，不是要求仓库完全没有任何相关规则或学习资料。

当前结果 Recall@5 100%、MRR 0.9688。高分只说明种子可被当前改写召回，不能证明对未来所有问题的语义泛化；后续先扩充真实查询，再决定是否需要 Embedding。

## 9. 最终结论

Bug 经验闭环的价值不在案例数量，而在事实密度和触发时机：修复前检索、修复中保持 owner/生命周期证据、收口后才固化、多个独立案例后才抽象。这样 AI 的“记忆”才不会变成新的先验偏见。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
