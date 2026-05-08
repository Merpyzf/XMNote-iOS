# Airbnb Motion Principles for SwiftUI

This reference turns public Airbnb motion/design writing into practical SwiftUI guidance for XMNote. It separates public source claims from SwiftUI implementation inferences.

## Source Grounding

- Airbnb DLS frames its design language around `Unified`, `Universal`, `Iconic`, and `Conversational`. The motion takeaway is that animation is part of communication, not decoration. Sources: [Building a Visual Language](https://medium.com/airbnb-design/building-a-visual-language-behind-the-scenes-of-our-airbnb-design-system-224748775e4e), [Airbnb Design Principles](https://principles.design/examples/airbnb-design-principles)
- Airbnb engineering describes motion as a scalable product system: transitions preserve user context, small animation moments add delight, and the implementation must be repeatable across teams. Source: [Motion Engineering at Scale](https://medium.com/airbnb-engineering/motion-engineering-at-scale-5ffabfc878)
- Airbnb's Host Passport iOS case study shows that believable motion comes from coordinated property timing: position, scale, rotation, shadow, content, and depth can each need their own curve and keyframes. Source: [Bringing the Host Passport to life on iOS](https://medium.com/airbnb-engineering/animations-bringing-the-host-passport-to-life-on-ios-72856aea68a7)
- Lottie reduces design-to-engineering loss for complex After Effects assets, especially brand illustration and icon animation. In SwiftUI product screens, it should complement native transitions rather than replace them. Sources: [Introducing Lottie](https://www.engineering.fyi/article/introducing-lottie), [Lottie iOS](https://airbnb.io/projects/lottie-ios/)
- Apple fluid interface guidance reinforces the same constraints: direct manipulation, low latency, momentum continuity, interruption, and accessibility. Sources: [Designing Fluid Interfaces](https://developer.apple.com/videos/play/wwdc2018/803), [Explore SwiftUI animation](https://developer.apple.com/videos/play/wwdc2023/10156/), [Wind your way through advanced animations in SwiftUI](https://developer.apple.com/videos/play/wwdc2023/10157/), [Animate with springs](https://developer.apple.com/videos/play/wwdc2023/10158/)

## Design Philosophy

### Conversational Motion

Airbnb's DLS principle `Conversational` implies animation should behave like product language. A good animation answers the user's action: "selected", "saved", "expanded", "moved here", "this is now primary". It should be brief, legible, and tonally consistent.

SwiftUI implication: do not start with `.spring`. Start with the sentence the motion is saying. Then choose the smallest animation that says it.

### Context Preservation

Airbnb motion repeatedly focuses on keeping the user oriented between features and screens. The user should be able to track the same object through a role change: card to detail, compact row to expanded panel, search field to search surface, sheet source to sheet content.

SwiftUI implication: prefer stable model IDs and `matchedGeometryEffect` for shared objects. Avoid replacing a live object with an unrelated fade if the user needs spatial continuity.

### Effortless Timing

Airbnb's polished feel depends on timing discipline. The motion often feels soft because it is short, well synchronized, and lands cleanly, not because every interaction is slow or bouncy.

SwiftUI implication: pick one explicit duration for the interaction. Tune spring bounce downward for productivity flows. Check the final 10 percent of the animation; lingering tails often feel like lag.

### Dimensional But Restrained

Depth effects help explain hierarchy when a card lifts, folds, flips, or recedes. They become noise when every transition gets blur, shadow, scale, and rotation.

SwiftUI implication: use depth properties only when the visual layer relationship changes. For ordinary state changes, opacity, offset, or content transition is usually enough.

### Design-System Motion

Airbnb's engineering writing treats motion as a system problem. A one-off transition can be impressive; a reusable motion language keeps a product coherent.

SwiftUI implication: when the same motion appears in multiple places, extract a named animation, transition, or view modifier with semantic intent. Prefer names like `selectionFeedback`, `cardExpansion`, or `panelReveal` over raw curve names.

## SwiftUI Landing Table

| UI moment | Motion philosophy | SwiftUI tools | Cautions |
| --- | --- | --- | --- |
| Button, chip, row selection | Short acknowledgement | `snappy` animation around `0.16-0.20s`, scale or foreground change | No delayed feedback. Do not animate large parent layout. |
| List item to detail | Preserve object identity | `matchedGeometryEffect`, stable `id`, local namespace | Source and destination must represent the same semantic object. |
| Card expand/collapse | Object changes role | `matchedGeometryEffect`, `smooth` animation around `0.26-0.34s`, asymmetric content transitions | Avoid pushing unrelated siblings with broad root animations. |
| Search field to search surface | Continue the input object | matched geometry for field/background, staged opacity for suggestions | Keep keyboard/focus behavior primary; motion must not delay typing. |
| Sheet or panel reveal | Explain layer hierarchy | `.move(edge:)`, opacity, material transition, low-bounce spring | Sheet motion should match system expectations where possible. |
| Numeric/text value change | Clarify changed value | `contentTransition(.numericText())`, opacity or blur transition | Do not animate every timer or scroll-driven tick unless meaningful. |
| Loading to content | Maintain trust | delayed loading gate, fade/scale content entrance | Do not hide slow data behind decorative loops. |
| Completion or empty state | Add light personality | Lottie or small keyframed symbol motion | Must not block next action; offer static fallback. |
| Complex hero/card choreography | Coordinate multiple tracks | `keyframeAnimator`, `PhaseAnimator`, custom transition | Split timing per property; test interruption and Reduce Motion. |

## Timing Guidance

These are defaults for product work, not laws:

- Press/selection feedback: `0.12-0.20s`
- Toggle or small state transition: `0.16-0.24s`
- Expand/collapse or filter panel: `0.24-0.34s`
- Shared-object navigation: `0.28-0.40s`
- Brand illustration or completion animation: `0.50-1.20s`, only when non-blocking

Choose explicit values in implementation. Do not literally paste duration ranges into Swift code.

## Reduce Motion Strategy

Reduced motion should preserve information, not remove feedback.

- Replace travel with opacity or immediate state change.
- Keep small feedback such as color, checkmark, text, or haptic-compatible state confirmation.
- Avoid large scale changes, parallax, 3D rotation, and long scroll-linked movement.
- Keep loading, error, disabled, and completion states visible even when animation is removed.

## Review Prompts

Use these prompts when reviewing an XMNote interaction:

- What would be confusing if this animation were removed?
- Is the motion explaining object identity, hierarchy, or result?
- Is a real object moving, or is the UI merely adding ornamental activity?
- Does this motion fit the frequency of the path?
- Could the user tap again halfway through without visual breakage?
- Does the implementation scope animation tightly enough to avoid sibling movement?
- Should this become a reusable motion semantic in XMNote?

## Public Claims vs SwiftUI Inference

Use careful wording:

- It is fair to say Airbnb publicly emphasizes conversational design, context-preserving motion, scalable motion systems, Lottie for high-fidelity assets, and precise iOS choreography.
- It is an implementation inference to map those ideas to SwiftUI tools such as `matchedGeometryEffect`, `keyframeAnimator`, `PhaseAnimator`, and `contentTransition`.
- Do not claim Airbnb uses a specific SwiftUI API unless a source states it. Many Airbnb iOS motion posts predate modern SwiftUI APIs and discuss UIKit-era infrastructure.
