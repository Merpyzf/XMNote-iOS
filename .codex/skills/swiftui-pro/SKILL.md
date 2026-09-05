---
name: swiftui-pro
description: Comprehensively reviews SwiftUI code for best practices on modern APIs, maintainability, and performance. Use only for review/audit tasks; for writing or refactoring XMNote SwiftUI code, prefer swiftui-expert-skill.
license: MIT
metadata:
  author: Paul Hudson
  version: "1.0"
---

Review Swift and SwiftUI code for correctness, modern API usage, and adherence to project conventions. This is a review-only skill in XMNote; use `swiftui-expert-skill` for implementation or refactoring tasks. Report only genuine problems - do not nitpick or invent issues.

Follow the current user request and repository `AGENTS.md`. Use `xmnote-design-system` for interface ownership and design decisions, and the maintained `.agents/skills/swiftui-expert-skill` for implementation guidance. Reviewing code does not authorize edits, dependency changes, new tests, or broader modernization.

Select the relevant parts of this review process for the requested scope:

1. Check for deprecated API using `references/api.md`.
1. Check that views, modifiers, and animations have been written optimally using `references/views.md`.
1. Validate that data flow is configured correctly using `references/data.md`.
1. Ensure navigation is updated and performant using `references/navigation.md`.
1. Ensure the code uses designs that are accessible and compliant with Apple’s Human Interface Guidelines using `references/design.md`.
1. Validate accessibility compliance including Dynamic Type, VoiceOver, and Reduce Motion using `references/accessibility.md`.
1. Ensure the code is able to run efficiently using `references/performance.md`.
1. Quick validation of Swift code using `references/swift.md`.
1. Final code hygiene check using `references/hygiene.md`.

For a partial review, load only the relevant reference files. For API choices and deprecation findings, also respect `.agents/skills/swiftui-expert-skill/references/soft-deprecation-scope.md`. Existing portable examples and reference recommendations do not override XMNote components or authorize unrelated cleanup.


## Core Instructions

- Inspect actual target settings when version compatibility affects a finding. XMNote currently uses iOS 26.1 deployment and Swift 5 language mode on its Xcode 26 toolchain baseline; Swift 6.2 toolchain guidance is not permission to switch language mode or SDK.
- For Apple platform facts, first try `apple-doc-mcp`, then Apple official documentation or the relevant local SDK if the MCP is unavailable or insufficient. Name the source and version; keep unsupported conclusions qualified and continue independent review work.
- Prefer existing SwiftUI components where suitable. Judge existing UIKit bridges by their actual purpose and project boundaries; do not infer a user preference to remove UIKit.
- Third-party framework adoption requires explicit authorization. In a review, explain any necessary proposal without installing dependencies or asking for unrelated implementation approval.
- Evaluate file boundaries and organization against project conventions and maintainability; do not demand file splitting or feature reorganization merely to satisfy an upstream preference.
- Run only checks needed and authorized for this review; do not automatically build the App or add/run XCTest or UI Test.


## Output Format

Prioritize actionable findings by user impact, with file and line evidence. For each issue:

1. State the file and relevant line(s).
2. Explain the observed problem, applicable rule, and impact; distinguish confirmed behavior from an unverified risk.
3. Describe the smallest correction. Include a brief before/after snippet only when it makes the correction clearer; a suggested snippet does not authorize applying it.

Skip files with no issues. Do not repeat findings in a second summary unless grouping a large review helps. If there are no actionable findings, say so and state material verification limits.

Illustrative output shape (API claims still require current evidence; these examples are not automatic findings):

### ContentView.swift

**Line 12: Use `foregroundStyle()` instead of `foregroundColor()`.**

```swift
// Before
Text("Hello").foregroundColor(.red)

// After
Text("Hello").foregroundStyle(.red)
```

**Line 24: Icon-only button is bad for VoiceOver - add a text label.**

```swift
// Before
Button(action: addUser) {
    Image(systemName: "plus")
}

// After
Button("Add User", systemImage: "plus", action: addUser)
```

**Line 31: Avoid `Binding(get:set:)` in view body - use `@State` with `onChange()` instead.**

```swift
// Before
TextField("Username", text: Binding(
    get: { model.username },
    set: { model.username = $0; model.save() }
))

// After
TextField("Username", text: $model.username)
    .onChange(of: model.username) {
        model.save()
    }
```

### Summary

1. **Accessibility (high):** The add button on line 24 is invisible to VoiceOver.
2. **Deprecated API (medium):** `foregroundColor()` on line 12 should be `foregroundStyle()`.
3. **Data flow (medium):** The manual binding on line 31 is fragile and harder to maintain.

End of example.


## References

- `references/accessibility.md` - Dynamic Type, VoiceOver, Reduce Motion, and other accessibility requirements.
- `references/api.md` - updating code for modern API, and the deprecated code it replaces.
- `references/design.md` - guidance for building accessible apps that meet Apple’s Human Interface Guidelines.
- `references/hygiene.md` - making code compile cleanly and be maintainable in the long term.
- `references/navigation.md` - navigation using `NavigationStack`/`NavigationSplitView`, plus alerts, confirmation dialogs, and sheets.
- `references/performance.md` - optimizing SwiftUI code for maximum performance.
- `references/data.md` - data flow, shared state, and property wrappers.
- `references/swift.md` - tips on writing modern Swift code, including using Swift Concurrency effectively.
- `references/views.md` - view structure, composition, and animation.
