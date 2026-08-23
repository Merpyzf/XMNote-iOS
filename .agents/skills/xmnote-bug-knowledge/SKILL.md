---
name: xmnote-bug-knowledge
description: Diagnose and fix evidence-backed XMNote iOS production defects, crashes, regressions, incorrect behavior, races, or performance failures while retrieving and recording reusable local knowledge. Use for a concrete failing behavior with a reproducible path, logs, stack evidence, or an explicit observed-versus-expected result. Do not use for Bug workflow design, pure visual tuning, refactoring, feature work, or generic optimization without defect evidence.
---

# XMNote Bug Knowledge

## Authority and boundaries

- Follow the repository `AGENTS.md` and the nearest module `CLAUDE.md` first.
- Treat Android experience as business-intent evidence, never as an iOS platform fact.
- For Apple API behavior, availability, deprecation, parameters, or platform differences, verify with `apple-doc-mcp` as required by the repository.
- Do not classify a commit as a Bug case merely because its subject starts with `fix`.
- During development, write only to the ignored `artifacts/ai-knowledge/` state. Do not publish repository documentation before the user explicitly says `任务已完成`.

## Before the first production edit

1. Read the applicable repository and module rules.
2. Run:

   ```bash
   python3 scripts/ai-knowledge/kb.py search --query "<现象、触发条件、错误信息>" --paths <相关路径>
   ```

3. Inspect matched cases, patterns, project rules, learning material, and Git history.
4. Establish the minimum fact loop before proposing a systemic change:
   - reproducible path;
   - real owner;
   - real write point;
   - lifecycle or call timing;
   - platform fact source.
5. If the premise becomes doubtful, narrow the problem and rebuild the fact chain before continuing.

The repository Hook may deny the first production write in each relevant feature scope once. Read its hits, then retry the same write unchanged. A new feature scope intentionally triggers a new retrieval.

## During diagnosis and repair

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

1. Publish the closed draft:

   ```bash
   python3 scripts/ai-knowledge/kb.py case publish <DRAFT-ID> --confirm-task-complete
   ```

2. Run `validate`, `audit`, the fixed retrieval evaluation, the independent knowledge-tool tests, and the repository's required documentation/governance gates.
3. Update the closure-stage repository documentation required by `AGENTS.md`.
4. Propose a pattern only when at least two independent formal cases have identical root-cause and repair-strategy fingerprints.
5. Keep the new pattern `candidate`. User approval is required for `active`; `enforced` additionally requires a real mandatory test, static check, build gate, or Git Hook.

Never use a high case score to bypass the repository's abstraction admission rule.
