---
name: ios-airbnb-motion
description: "Use when designing, implementing, or reviewing iOS SwiftUI motion for XMNote using Airbnb-inspired animation philosophy: calm contextual transitions, microinteractions, matched geometry, keyframes, Reduce Motion, Lottie asset boundaries, and motion design critique."
metadata:
  short-description: Apply Airbnb motion philosophy to SwiftUI
---

# iOS Airbnb Motion

Use this skill to make XMNote motion feel calm, contextual, trustworthy, and native to iOS. The goal is not to copy Airbnb's visual surface. The goal is to apply the motion philosophy Airbnb has made public: motion communicates, preserves context, adds a small amount of product personality, and must be maintainable at product scale.

For source notes, decision tables, and deeper review prompts, read `references/airbnb-motion-principles.md`.

## Priority

When guidance conflicts, decide in this order:

1. The user's current request and XMNote `AGENTS.md`
2. Existing XMNote components, design tokens, navigation patterns, and accessibility behavior
3. Apple HIG and official SwiftUI behavior
4. Airbnb motion philosophy from public design and engineering writing
5. Local aesthetic preference

If Apple API availability, semantics, or platform behavior matters, verify against official Apple documentation before recommending implementation details.

## Philosophy First

Before choosing an animation API, name the job the motion is doing:

- Preserve context across screens, cards, sheets, or expanded states.
- Explain a state change so the user understands what changed and why.
- Confirm an operation without making the user wait for decoration.
- Build trust by making objects move consistently with their visual identity.
- Add a small product voice only where the moment can afford it.

Remove or simplify the motion if it does not serve one of those jobs.

## Airbnb-Inspired Motion Principles

- **Conversational motion**: The animation should feel like a short response to the user's action, not a performance.
- **Context preservation**: Keep object identity visible. A list item that becomes a detail view should feel like the same object changing role.
- **Effortless timing**: Motion should finish before the user's next thought. Long spring tails and decorative delays make the UI feel heavy.
- **Dimensional but restrained**: Use scale, shadow, blur, and depth to explain hierarchy. Do not add depth effects merely to look premium.
- **System motion**: Reusable motion semantics beat one-off magic curves. Repeated interactions should share timing and intent.
- **Accessible motion**: Reduce Motion changes the expression, not the state feedback. Replace travel with opacity, shorter changes, or instant hierarchy shifts.

## SwiftUI Decision Path

1. Read the target view and nearby components first. Identify the real object whose state is changing.
2. Prefer SwiftUI-native motion for product structure:
   - `withAnimation` or `.animation(_:value:)` for local state changes.
   - `matchedGeometryEffect` when the same semantic object changes size, position, or container.
   - `transition` for insertion/removal and `contentTransition` for changing values.
   - `PhaseAnimator` or `keyframeAnimator` for multi-stage choreography.
3. Use UIKit custom transitions only when SwiftUI cannot express a navigation-level transition, snapshot choreography, or interactive cancellation correctly.
4. Use Lottie only for brand illustrations, empty states, completion moments, and icon-level animation assets. Do not use Lottie as the default mechanism for core navigation or information-architecture transitions.
5. Respect `@Environment(\.accessibilityReduceMotion)` in every meaningful motion path.

## SwiftUI Defaults

Use explicit values, not ranges, in code. These are starting points:

- Micro feedback: `.snappy(duration: 0.18)` for button press, selection, toggle, and light state confirmation.
- Structure changes: `.smooth(duration: 0.28)` or a low-bounce spring for expand/collapse, filters, and layout shifts.
- Shared-object transitions: `matchedGeometryEffect` with stable IDs and a duration around `0.28-0.36s`.
- Complex choreography: `keyframeAnimator` when position, opacity, scale, shadow, or rotation need different timing.
- Scroll-linked behavior: animate only threshold crossings, never every scroll offset update.
- Reduce Motion: use opacity, crossfade, or immediate state changes with clear feedback.

## Review Checklist

Use this checklist before proposing or approving motion:

- What user action or state change is the motion responding to?
- Which object keeps identity from start to end?
- Does the end frame land exactly, without spring wobble or visible correction?
- Can the animation be interrupted by repeated taps, gestures, navigation, or task cancellation?
- Is it short enough for a high-frequency path?
- Does Reduce Motion preserve the information and feedback?
- Can the timing or transition be reused elsewhere instead of becoming a one-off trick?

## Anti-Patterns

- Adding bounce because the screen feels visually plain.
- Animating unrelated siblings because the animation modifier is too high in the tree.
- Making the user wait for a celebratory animation before continuing.
- Using Lottie for structural navigation that should preserve live SwiftUI object identity.
- Combining blur, scale, shadow, rotation, and delay without a clear hierarchy reason.
- Hiding data latency behind decorative motion instead of providing direct loading, disabled, error, and completion states.

## Working With Other XMNote Skills

- Use `ios-airbnb-motion` for motion intent, rhythm, continuity, and review.
- Use `swiftui-expert-skill` or `swiftui-pro` for SwiftUI API correctness, performance, and accessibility details.
- Use `impeccable-ios-design` for broader visual hierarchy, typography, color, and platform design judgment.
