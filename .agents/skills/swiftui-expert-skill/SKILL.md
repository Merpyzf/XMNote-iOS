---
name: swiftui-expert-skill
description: Write, review, or improve SwiftUI code for XMNote using Xcode 26/iOS 26 as the default baseline, with modern state management, view composition, performance, localization, soft-deprecation scope, macOS-specific APIs, iOS 26+ Liquid Glass, and explicitly gated SDK 27 future references. Use when building new SwiftUI features, refactoring existing views, reviewing code quality, or adopting modern SwiftUI patterns.
---

# SwiftUI Expert Skill

## Overview
Use this skill to build, review, or improve SwiftUI features with correct state management, optimal view composition, and iOS 26+ Liquid Glass styling. Prioritize native APIs, Apple design guidance, and performance-conscious patterns. This skill focuses on facts and best practices without enforcing specific architectural patterns.

XMNote currently targets Xcode 26 / iOS 26.1. Treat Xcode 27 guidance as either source-compatible SwiftUI practice or a future SDK reference; do not generate SDK 27-only APIs unless the user explicitly asks for Xcode 27 / SDK 27 work or an SDK 27 migration error.

## Workflow Decision Tree

### 1) Review existing SwiftUI code
- **First, consult `references/latest-apis.md`** to ensure only current, non-deprecated APIs are used
- Check property wrapper usage against the selection guide (see `references/state-management.md`)
- Verify view composition follows extraction rules (see `references/view-structure.md`)
- Check performance patterns are applied (see `references/performance-patterns.md`)
- Verify list patterns use stable identity (see `references/list-patterns.md`)
- Check custom environment/focused values for invalidation hazards (see `references/environment-patterns.md`)
- Check user-facing strings, formatting, and RTL layout (see `references/localization-patterns.md`)
- Apply soft-deprecation guidance only to code in the current task scope (see `references/soft-deprecation-scope.md`)
- Check animation patterns for correctness (see `references/animation-basics.md`, `references/animation-transitions.md`)
- Review accessibility: proper grouping, traits, Dynamic Type support (see `references/accessibility-patterns.md`)
- For macOS targets: verify correct use of macOS-specific APIs and patterns (see `references/macos-scenes.md`, `references/macos-window-styling.md`, `references/macos-views.md`)
- Inspect Liquid Glass usage for correctness and consistency (see `references/liquid-glass.md`)
- Validate iOS 26+ availability handling with sensible fallbacks
- When SDK 27 APIs, compiler errors, or availability questions appear, consult `references/sdk27-future-reference.md` before recommending code

### 2) Improve existing SwiftUI code
- **First, consult `references/latest-apis.md`** to replace any deprecated APIs with their modern equivalents
- Audit state management for correct wrapper selection (see `references/state-management.md`)
- Extract complex views into separate subviews (see `references/view-structure.md`)
- Refactor hot paths to minimize redundant state updates (see `references/performance-patterns.md`)
- Ensure ForEach uses stable identity (see `references/list-patterns.md`)
- Keep soft-deprecated API cleanup limited to the code the user asked to touch (see `references/soft-deprecation-scope.md`)
- Preserve localization context when changing text or formatting (see `references/localization-patterns.md`)
- Improve animation patterns (use value parameter, proper transitions, see `references/animation-basics.md`, `references/animation-transitions.md`)
- Improve accessibility: use `Button` over tap gestures, add `@ScaledMetric` for Dynamic Type (see `references/accessibility-patterns.md`)
- For macOS targets: adopt macOS-specific APIs (MenuBarExtra, Settings, Table, Commands, etc.) where appropriate (see `references/macos-scenes.md`, `references/macos-window-styling.md`, `references/macos-views.md`)
- Suggest image downsampling when `UIImage(data:)` is used (as optional optimization, see `references/image-optimization.md`)
- Adopt Liquid Glass only when explicitly requested by the user
- Do not migrate to SDK 27-only APIs unless the user explicitly requests SDK 27 work

### 3) Implement new SwiftUI feature
- **First, consult `references/latest-apis.md`** to use only current, non-deprecated APIs for the target deployment version
- Design data flow first: identify owned vs injected state (see `references/state-management.md`)
- Structure views for optimal diffing (extract subviews early, see `references/view-structure.md`)
- Keep business logic in services and models for testability (see `references/layout-best-practices.md`)
- Keep custom environment values stable and avoid closure-valued keys (see `references/environment-patterns.md`)
- Type reusable user-facing strings as localized resources where appropriate (see `references/localization-patterns.md`)
- Use correct animation patterns (implicit vs explicit, transitions, see `references/animation-basics.md`, `references/animation-transitions.md`, `references/animation-advanced.md`)
- Use `Button` for tappable elements, add accessibility grouping and labels (see `references/accessibility-patterns.md`)
- For macOS targets: use macOS-specific scenes (see `references/macos-scenes.md`), window styling (see `references/macos-window-styling.md`), and views like HSplitView, Table (see `references/macos-views.md`)
- Apply glass effects after layout/appearance modifiers (see `references/liquid-glass.md`)
- Gate iOS 26+ features with `#available` and provide fallbacks
- Prefer Xcode 26/iOS 26 APIs by default; read `references/sdk27-future-reference.md` only for explicit SDK 27 tasks

## Core Guidelines

### Source and Availability Discipline
- Current default: Xcode 26.2, Swift 6.2.x, iOS 26.1 deployment.
- Xcode 27 skills are guidance inputs, not an instruction to install or generate SDK 27 APIs by default.
- If Apple API behavior, availability, deprecation, or platform semantics matters, verify with `apple-doc-mcp` when available, Apple official documentation, or a local Xcode 27 export before changing code.
- Do not copy upstream skill text verbatim into product answers; use these references as concise local decision guides.

### State Management
- `@State` must be `private`; use for internal view state
- `@Binding` only when a child needs to **modify** parent state
- `@StateObject` when view **creates** the object; `@ObservedObject` when **injected**
- iOS 17+: Use `@State` with `@Observable` classes; use `@Bindable` for injected observables needing bindings
- Use `let` for read-only values; `var` + `.onChange()` for reactive reads
- Never pass values into `@State` or `@StateObject` — they only accept initial values
- Nested `ObservableObject` doesn't propagate changes — pass nested objects directly; `@Observable` handles nesting fine

### View Composition
- Extract complex views into separate subviews for better readability and performance
- Prefer modifiers over conditional views for state changes (maintains view identity)
- Keep view `body` simple and pure (no side effects or complex logic)
- Use `@ViewBuilder` functions only for small, simple sections
- Prefer `@ViewBuilder let content: Content` over closure-based content properties
- Keep business logic in services and models; views should orchestrate UI flow
- Action handlers should reference methods, not contain inline logic
- Views should work in any context (don't assume screen size or presentation style)

### Performance
- Pass only needed values to views (avoid large "config" or "context" objects)
- Eliminate unnecessary dependencies to reduce update fan-out
- Consider per-item `@Observable` state objects in lists to narrow update/dependency scope
- Consider whether frequently-changing values belong in the environment; prefer more local state when it reduces unnecessary view updates
- Check for value changes before assigning state in hot paths
- Avoid redundant state updates in `onReceive`, `onChange`, scroll handlers
- Minimize work in frequently executed code paths
- Use `LazyVStack`/`LazyHStack` for large lists
- Use stable identity for `ForEach` (never `.indices` for dynamic content)
- Ensure constant number of views per `ForEach` element
- Avoid inline filtering in `ForEach` (prefilter and cache)
- Avoid `AnyView` in list rows
- Consider POD views for fast diffing (or wrap expensive views in POD parents)
- Suggest image downsampling when `UIImage(data:)` is encountered (as optional optimization)
- Avoid layout thrash (deep hierarchies, excessive `GeometryReader`)
- Gate frequent geometry updates by thresholds
- Use `Self._logChanges()` or `Self._printChanges()` to debug unexpected view updates
- `Shape.path()`, `visualEffect`, `Layout`, and `onGeometryChange` closures may run off the main thread — capture values instead of accessing `@MainActor` state

### Animations
- Use `.animation(_:value:)` with value parameter (deprecated version without value is too broad)
- Use `withAnimation` for event-driven animations (button taps, gestures)
- Prefer transforms (`offset`, `scale`, `rotation`) over layout changes (`frame`) for performance
- Transitions require animations outside the conditional structure
- Custom `Animatable` implementations must have explicit `animatableData` (or use `@Animatable` macro on iOS 26+)
- iOS 26+: Use `@Animatable` macro to auto-synthesize `animatableData`; use `@AnimatableIgnored` to exclude properties
- Use `.phaseAnimator` for multi-step sequences (iOS 17+)
- Use `.keyframeAnimator` for precise timing control (iOS 17+)
- Animation completion handlers need `.transaction(value:)` for reexecution
- Implicit animations override explicit animations (later in view tree wins)

### Accessibility
- Prefer `Button` over `onTapGesture` for tappable elements (free VoiceOver support)
- Use `@ScaledMetric` for custom numeric values that should scale with Dynamic Type
- Group related elements with `accessibilityElement(children: .combine)` for joined labels
- Provide `accessibilityLabel` when default labels are unclear or missing
- Use `accessibilityRepresentation` for custom controls that should behave like native ones

### Liquid Glass (iOS 26+)
**Only adopt when explicitly requested by the user.**
- Use native `glassEffect`, `GlassEffectContainer`, and glass button styles
- Wrap multiple glass elements in `GlassEffectContainer`
- Apply `.glassEffect()` after layout and visual modifiers
- Use `.interactive()` only for tappable/focusable elements
- Use `glassEffectID` with `@Namespace` for morphing transitions

## Quick Reference

### Property Wrapper Selection
| Wrapper | Use When |
|---------|----------|
| `@State` | Internal view state (must be `private`) |
| `@Binding` | Child modifies parent's state |
| `@StateObject` | View owns an `ObservableObject` |
| `@ObservedObject` | View receives an `ObservableObject` |
| `@Bindable` | iOS 17+: Injected `@Observable` needing bindings |
| `let` | Read-only value from parent |
| `var` | Read-only value watched via `.onChange()` |

### Liquid Glass Patterns
```swift
// Basic glass effect with fallback
if #available(iOS 26, *) {
    content
        .padding()
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16))
} else {
    content
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
}

// Grouped glass elements
GlassEffectContainer(spacing: 24) {
    HStack(spacing: 24) {
        GlassButton1()
        GlassButton2()
    }
}

// Glass buttons
Button("Confirm") { }
    .buttonStyle(.glassProminent)
```

## Review Checklist

### Latest APIs (see `references/latest-apis.md`)
- [ ] No deprecated modifiers used (check against the quick lookup table)
- [ ] API choices match the project's minimum deployment target
- [ ] SDK 27-only APIs are absent unless the task explicitly targets SDK 27

### State Management
- [ ] `@State` properties are `private`
- [ ] `@Binding` only where child modifies parent state
- [ ] `@StateObject` for owned, `@ObservedObject` for injected
- [ ] iOS 17+: `@State` with `@Observable`, `@Bindable` for injected
- [ ] Passed values NOT declared as `@State` or `@StateObject`
- [ ] Nested `ObservableObject` avoided (or passed directly to child views)

### Sheets & Navigation (see `references/sheet-navigation-patterns.md`)
- [ ] Using `.sheet(item:)` for model-based sheets
- [ ] Sheets own their actions and dismiss internally

### ScrollView (see `references/scroll-patterns.md`)
- [ ] Using `ScrollViewReader` with stable IDs for programmatic scrolling

### View Structure (see `references/view-structure.md`)
- [ ] Using modifiers instead of conditionals for state changes
- [ ] Complex views extracted to separate subviews
- [ ] Container views use `@ViewBuilder let content: Content`
- [ ] `.compositingGroup()` before `.clipShape()` on layered views

### Performance (see `references/performance-patterns.md`)
- [ ] View `body` kept simple and pure (no side effects)
- [ ] Passing only needed values (not large config objects)
- [ ] Eliminating unnecessary dependencies
- [ ] Consider making @Observable dependencies as granular as needed (for example, per-item data for list rows) when it helps performance
- [ ] State updates check for value changes before assigning
- [ ] Hot paths minimize state updates
- [ ] No object creation in `body`
- [ ] Heavy computation moved out of `body`
- [ ] Sendable closures capture values instead of accessing @MainActor state

### Environment & Localization (see `references/environment-patterns.md`, `references/localization-patterns.md`)
- [ ] Custom environment/focused values do not store closures
- [ ] Frequently-changing values are not pushed through broad environment scopes
- [ ] User-facing strings preserve localization context
- [ ] Formatting uses locale-aware format styles where practical
- [ ] Layout uses leading/trailing instead of left/right for localized UI

### List Patterns (see `references/list-patterns.md`)
- [ ] ForEach uses stable identity (not `.indices`)
- [ ] Constant number of views per ForEach element
- [ ] No inline filtering in ForEach
- [ ] No `AnyView` in list rows

### Soft Deprecation (see `references/soft-deprecation-scope.md`)
- [ ] New code does not introduce soft-deprecated SwiftUI APIs
- [ ] Existing soft-deprecated APIs are only discussed or migrated inside the current task scope
- [ ] Unrelated views/files are not scanned or pressured into opportunistic cleanup

### Layout (see `references/layout-best-practices.md`)
- [ ] Avoiding layout thrash (deep hierarchies, excessive GeometryReader)
- [ ] Gating frequent geometry updates by thresholds
- [ ] Business logic kept in services and models (not in views)
- [ ] Action handlers reference methods (not inline logic)
- [ ] Using relative layout (not hard-coded constants)
- [ ] Views work in any context (context-agnostic)

### Animations (see `references/animation-basics.md`, `references/animation-transitions.md`, `references/animation-advanced.md`)
- [ ] Using `.animation(_:value:)` with value parameter
- [ ] Using `withAnimation` for event-driven animations
- [ ] Transitions paired with animations outside conditional structure
- [ ] Custom `Animatable` has explicit `animatableData` (or `@Animatable` macro on iOS 26+)
- [ ] Preferring transforms over layout changes for animation performance
- [ ] Phase animations for multi-step sequences (iOS 17+)
- [ ] Keyframe animations for precise timing (iOS 17+)
- [ ] Completion handlers use `.transaction(value:)` for reexecution

### Accessibility (see `references/accessibility-patterns.md`)
- [ ] `Button` used instead of `onTapGesture` for tappable elements
- [ ] `@ScaledMetric` used for custom values that should scale with Dynamic Type
- [ ] Related elements grouped with `accessibilityElement(children:)`
- [ ] Custom controls use `accessibilityRepresentation` when appropriate

### macOS APIs (see `references/macos-scenes.md`, `references/macos-window-styling.md`, `references/macos-views.md`)
- [ ] Using `Settings` scene for preferences (not a custom window)
- [ ] Using `MenuBarExtra` for menu bar items (not AppKit `NSStatusItem`)
- [ ] Using `Commands` / `CommandGroup` / `CommandMenu` for menu bar menus
- [ ] `Table` adapts for compact size classes on iOS (first column shows combined info)
- [ ] Window sizing configured with `defaultSize`, `windowResizability`, and `frame(minWidth:minHeight:)`
- [ ] macOS-only code wrapped in `#if os(macOS)` conditionals
- [ ] Using `NSViewRepresentable` with proper `makeNSView`/`updateNSView` lifecycle
- [ ] Using `NavigationSplitView` (not `HSplitView`) for sidebar-based navigation
- [ ] `HSplitView`/`VSplitView` reserved for IDE-style equal peer panes

### Liquid Glass (iOS 26+)
- [ ] `#available(iOS 26, *)` with fallback for Liquid Glass
- [ ] Multiple glass views wrapped in `GlassEffectContainer`
- [ ] `.glassEffect()` applied after layout/appearance modifiers
- [ ] `.interactive()` only on user-interactable elements
- [ ] Shapes and tints consistent across related elements

## References
- `references/latest-apis.md` - **Required reading for all workflows.** Version-segmented guide of deprecated-to-modern API transitions (iOS 15+ through iOS 26+)
- `references/state-management.md` - Property wrappers and data flow
- `references/view-structure.md` - View composition, extraction, and container patterns
- `references/performance-patterns.md` - Performance optimization techniques and anti-patterns
- `references/list-patterns.md` - ForEach identity, stability, Table (iOS 16+), and list best practices
- `references/environment-patterns.md` - Custom environment/focused values, invalidation hazards, and scope control
- `references/localization-patterns.md` - Localized strings, format styles, interpolation, casing, and RTL layout
- `references/soft-deprecation-scope.md` - How to handle SwiftUI soft-deprecated APIs without unrelated churn
- `references/sdk27-future-reference.md` - SDK 27/Xcode 27 SwiftUI APIs and migration notes; explicit opt-in only
- `references/layout-best-practices.md` - Layout patterns, context-agnostic views, and testability
- `references/accessibility-patterns.md` - Accessibility traits, grouping, Dynamic Type, and VoiceOver
- `references/animation-basics.md` - Core animation concepts, implicit/explicit animations, timing, performance
- `references/animation-transitions.md` - Transitions, custom transitions, Animatable protocol
- `references/animation-advanced.md` - Transactions, phase/keyframe animations (iOS 17+), completion handlers (iOS 17+), `@Animatable` macro (iOS 26+)
- `references/sheet-navigation-patterns.md` - Sheet presentation, NavigationSplitView, Inspector, and navigation patterns
- `references/scroll-patterns.md` - ScrollView patterns and programmatic scrolling
- `references/image-optimization.md` - AsyncImage, image downsampling, and optimization
- `references/liquid-glass.md` - iOS 26+ Liquid Glass API
- `references/macos-scenes.md` - macOS scene types: Settings, MenuBarExtra, WindowGroup, Window, UtilityWindow, DocumentGroup
- `references/macos-window-styling.md` - macOS window configuration: toolbar styles, sizing, positioning, NavigationSplitView, Inspector, Commands
- `references/macos-views.md` - macOS views and components: HSplitView, VSplitView, Table, PasteButton, file dialogs, drag & drop, AppKit interop

## Philosophy

This skill focuses on **facts and best practices**, not architectural opinions:
- We don't enforce specific architectures (e.g., MVVM, VIPER)
- We do encourage separating business logic for testability
- We optimize for performance and maintainability
- We follow Apple's Human Interface Guidelines and API design patterns
