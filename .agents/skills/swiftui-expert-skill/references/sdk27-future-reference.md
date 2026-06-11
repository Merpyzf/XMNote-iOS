# SDK 27 Future Reference

XMNote's default baseline is Xcode 26 / iOS 26.1. This file is a gated reference for Xcode 27 / SDK 27 work only.

Read this file when:
- The user explicitly asks about Xcode 27, SDK 27, iOS 27, or 2027 OS APIs.
- A SwiftUI build error appears only after an SDK 27 update.
- The task is planning a future migration to Xcode 27.

Do not read or apply this file for ordinary Xcode 26 feature work.

## Source Discipline

The public `superagents-lab/xcode27-skills` repository is a convenience redistribution, not the official Apple documentation endpoint. Before changing production code for an SDK 27 API, verify availability and signatures with Apple official documentation, `apple-doc-mcp` when available, or a local Xcode 27 skill export.

## SwiftUI APIs That Are SDK 27-Only

Do not generate these unconditionally in XMNote's current iOS 26.1 target:

- `reorderable()` and `reorderContainer(...)` for drag-to-reorder outside legacy patterns.
- `swipeActionsContainer()` and `swipeActions(... onPresentationChanged:)` outside `List`.
- `AsyncImage(request:)` and `asyncImageURLSession(_:)`.
- Toolbar overflow and minimization APIs such as `ToolbarOverflowMenu`, `visibilityPriority(_:)`, `.topBarPinnedTrailing`, `toolbarMinimizeBehavior`, `toolbarMinimizationSafeAreaAdjustment`, `contentMarginsRemoved`, and status-bar toolbar placement.
- `alert(_:item:...)` and `confirmationDialog(_:item:...)` item-binding overloads.
- `ReadableDocument`, `WritableDocument`, `DocumentReader`, and `DocumentWriter`.

If the user explicitly requests one of these while the deployment target remains below iOS 27, wrap the usage in an availability gate and provide an iOS 26 fallback.

## SDK 27 Migration Notes

`@State` changes from a property-wrapper implementation detail to macro behavior in SDK 27. If a view fails with initialization or synthesized-property errors after an SDK update, do not fix by blindly reordering stored-property assignments. Re-check the SDK 27 documentation and prefer one of these directions:

- For `@State` initialized in `init`, remove the default declaration value and initialize once in `init`.
- For composed property wrappers on `@State`, refactor the composition instead of preserving colliding backing storage.
- For missing memberwise init synthesis around private `@State`, write the initializer explicitly.

Result-builder changes under SDK 27 can make previously ambiguous `overlay` / `background` expressions fail. Prefer trailing-closure forms when a direct style expression becomes ambiguous.

## Xcode 27 Skill Fit For XMNote

- `swiftui-specialist`: safe to absorb as source-compatible guidance for structure, data flow, environment, localization, ForEach, animation, and scoped soft-deprecation behavior.
- `swiftui-whats-new-27`: future reference only unless the user opts into SDK 27 or an SDK 27 migration.
- `test-modernizer`: useful for normal unit tests migrating from XCTest to Swift Testing; do not apply to XCUI tests or vendor tests.
- `uikit-app-modernization`: useful as an audit guide for `UIScreen.main`, orientation, scene lifecycle, and safe-area assumptions, but adapt the workflow to XMNote tools such as `rg` and `xcodebuild`.
- `c-bounds-safety`: low priority for XMNote unless first-party C code or pointer annotations are introduced.
- `audit-xcode-security-settings`: use for read-only audit/planning unless the user explicitly asks to apply build-setting hardening.
- `device-interaction`: conceptually overlaps with existing iOS simulator/browser workflows; use the available XMNote/Codex tools rather than Xcode 27-only device tools.
