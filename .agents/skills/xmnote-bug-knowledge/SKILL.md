---
name: xmnote-bug-knowledge
description: Diagnose and fix evidence-backed XMNote iOS production defects, crashes, regressions, incorrect behavior, races, or performance failures while retrieving and recording reusable local knowledge. Use for a concrete failing behavior with a reproducible path, logs, stack evidence, or an explicit observed-versus-expected result. Do not use for Bug workflow design, pure visual tuning, refactoring, feature work, or generic optimization without defect evidence.
---

# XMNote Bug Knowledge

## Authority and boundaries

- Follow the user's current request and repository `AGENTS.md`; read the relevant module `CLAUDE.md` for local facts, not as a separate source of permission.
- Treat Android experience as business-intent evidence, never as an iOS platform fact.
- For Apple API behavior, availability, deprecation, parameters, or platform differences, first try `apple-doc-mcp`. If unavailable or insufficient, use Apple official documentation or the relevant local SDK and record the actual source, version, and limitations. If still unverified, pause only the dependent conclusion or edit.
- Do not classify a commit as a Bug case merely because its subject starts with `fix`.
- Explanation and diagnosis do not authorize production repairs, draft lifecycle changes, or publication. Report facts and uncertainty; move into repair only when requested.
- During authorized repair, development-stage knowledge artifacts belong only in ignored `artifacts/ai-knowledge/`. This restriction does not prohibit the production edits needed to fix the Bug. Other documentation follows `AGENTS.md`, including its direct-document-task exception; formal Bug case publication still requires the user explicitly to say `任务已完成`.
- The authoritative knowledge model, lifecycle, commands, and status definitions are `docs/knowledge/bugs/问题库说明.md` and `docs/architecture/AI Bug经验闭环设计.md`; read the relevant sections when operating on that lifecycle.

## Before the first production edit

1. Read the applicable repository and module rules.
2. Run:

   ```bash
   python3 scripts/ai-knowledge/kb.py search --query "<现象、触发条件、错误信息>" --paths <相关路径>
   ```

3. Inspect relevant matched cases, patterns, project rules, learning material, and path-specific Git history. Do not scan unrelated knowledge or history merely to complete categories.
4. Establish the minimum fact loop for root-cause diagnosis and repair; distinguish evidence from hypotheses before proposing a systemic change:
   - reproducible path;
   - real owner;
   - real write point;
   - lifecycle or call timing;
   - platform fact source.
5. If the premise becomes doubtful, narrow the problem and rebuild the fact chain before continuing.

The repository retrieval Hook may deny the first production write in each relevant feature scope once. Confirm that the denial is this known retrieval requirement, read its hits, and satisfy the required retrieval before retrying. Retry the same write unchanged only if its content remains appropriate; otherwise correct the proposed edit first. A new relevant feature scope requires its own retrieval. Do not treat permission denials, other Hook failures, or repeated unexplained failures as a signal to retry blindly or bypass a gate.

## During authorized repair

- Use `draft init` only when the Hook did not create a draft automatically.
- Maintain facts with `draft update <id> --set key=value`. JSON arrays and objects are accepted.
- Record symptom, reproduction, owner paths, write points, lifecycle, platform evidence, root-cause mechanism, trigger boundary, impact/non-impact, repair tradeoffs, and validation evidence.
- A draft is eligible to close only when it has a regression guard or a concrete reason automation is not feasible.
- Prefer a local repair until at least two independent cases prove the same root cause and repair strategy.
- Respect the repository verification boundary: do not add or run App XCTest/UI Test unless the user explicitly requests it. Record the actual compile, manual, fixture, or static verification performed.

Close the local draft after evidence and verification are complete:

```bash
python3 scripts/ai-knowledge/kb.py draft close <DRAFT-ID>
```

## After explicit task completion

Only after the user explicitly says `任务已完成`:

1. Publish the closed draft only when its root cause, applicability boundaries, and actual validation are supported. Do not publish an uncertain case merely to fill the library:

   ```bash
   python3 scripts/ai-knowledge/kb.py case publish <DRAFT-ID> --confirm-task-complete
   ```

2. Run `validate`, `audit`, the fixed retrieval evaluation, the independent knowledge-tool tests, and the repository's required documentation/governance gates.
3. Update the closure-stage repository documentation required by `AGENTS.md`.
4. Propose a pattern only when at least two independent formal cases have identical root-cause and repair-strategy fingerprints, with explicit applicable and non-applicable boundaries.
5. Keep the new pattern `candidate`. User approval is required for `active`; `enforced` additionally requires a real mandatory test, static check, build gate, or Git Hook.

Never use a high case score to bypass the repository's abstraction admission rule.

## Hook trust and trial boundary

- `.codex/hooks.json` provides workflow guardrails, not a security sandbox; project Hooks require user review and trust.
- Keep the approved 30-day trial behavior: a `fix` without a `Knowledge-Case` trailer is a warning. The passage of time alone does not authorize strict blocking; that upgrade requires renewed explicit user approval.
- Pattern activation and Hook enforcement are separate permissions. A successful repair or case publication does not authorize either.
