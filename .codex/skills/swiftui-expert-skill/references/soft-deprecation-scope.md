# SwiftUI Soft-Deprecation Scope

Use this reference when generating, reviewing, refactoring, or cleaning SwiftUI code that may contain soft-deprecated APIs.

## Meaning

Some SwiftUI APIs are marked deprecated in SDK headers with a placeholder version that may not emit normal warnings. Treat them as APIs to avoid in new code, but do not turn every feature task into a broad migration.

## Scope Rule

Only handle soft-deprecated APIs in the code the current task directly touches.

- New code: do not introduce soft-deprecated APIs.
- Review/modernization task: report soft-deprecated APIs inside the requested review scope.
- Feature/bugfix task: preserve existing soft-deprecated APIs unless changing them is required for the requested behavior.
- Unrelated views in the same file are out of scope unless the user asked for that wider migration.

## Common Examples To Avoid In New Code

- `NavigationView` and `NavigationViewStyle` when `NavigationStack` or `NavigationSplitView` fits.
- `ActionSheet` and `.actionSheet`, use `confirmationDialog`.
- `Alert`-returning `.alert` overloads, use modern `alert` builders where XMNote's `XMSystemAlert` rule does not apply.
- `@Environment(\.presentationMode)`, use `dismiss` or `isPresented`.
- `MagnificationGesture` / `RotationGesture`, use the renamed gestures when available for the target SDK.
- Generic `accessibility(...)` modifiers, use dedicated accessibility modifiers.

## XMNote-Specific Overlay

Repository rules still win. For example, production center alerts use `XMSystemAlert`; do not replace them with SwiftUI `.alert` just because an upstream SwiftUI reference mentions modern alert overloads.

## Review Checklist

- New SwiftUI code avoids known soft-deprecated APIs.
- Existing soft-deprecated APIs are only migrated when in scope.
- The response does not pressure unrelated cleanup.
- Any proposed migration respects XMNote navigation, alert, and component rules.
