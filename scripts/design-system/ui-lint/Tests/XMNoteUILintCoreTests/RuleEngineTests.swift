import Testing
@testable import XMNoteUILintCore

struct RuleEngineTests {
    private static let policy = LintPolicy(
        schemaVersion: 3,
        constructionPolicies: ConstructionPolicies(
            rawColor: ConstructionPolicy(
                ruleID: "DS003",
                entryPoints: ["Color(...)", "UIColor(...)"],
                allowedPaths: [
                    "xmnote/Utilities/DesignSystem/SemanticColors.swift",
                    "xmnote/Utilities/DesignSystem/ColorConstruction.swift"
                ]
            ),
            rawTypography: ConstructionPolicy(
                ruleID: "DS001",
                entryPoints: [
                    "Font.system(...)",
                    "UIFont.systemFont(...)",
                    "UIFont.boldSystemFont(...)"
                ],
                allowedPaths: [
                    "xmnote/Utilities/DesignSystem/AppTypography.swift",
                    "xmnote/Utilities/DesignSystem/SharedContentTypography.swift",
                    "xmnote/Utilities/DesignSystem/SemanticTypography.swift",
                    "xmnote/Utilities/DesignSystem/BrandTypography.swift"
                ]
            )
        ),
        symbolPolicies: [],
        dependencyPolicies: [
            DependencyPolicy(
                name: "uiComponentsBoundary",
                ruleID: "DS008",
                pathPrefixes: ["xmnote/UIComponents/"],
                forbiddenExactIdentifiers: ["RepositoryContainer"],
                forbiddenIdentifierSuffixes: ["Repository", "RepositoryProtocol", "ViewModel"]
            )
        ],
        interactionPolicy: InteractionPolicy(
            tapGestureRuleID: "DS009",
            touchTargetRuleID: "DS010",
            touchTargetOwnerPath: "xmnote/Utilities/DesignSystem/InteractionMetrics.swift",
            touchTargetLiteral: 44,
            touchTargetNameFragments: ["touch", "hit", "tap", "button", "control", "action"],
            gestureExceptions: []
        )
    )

    private let engine = RuleEngine(policy: Self.policy)

    @Test func detectsEnforcedRulesWithDeclarationContext() {
        let source = """
        import SwiftUI

        struct ExampleView: View {
            var body: some View {
                VStack(spacing: 12) {
                    Text("Title")
                        .font(.system(size: 17))
                        .padding(.horizontal, 16)
                        .background(Color(red: 1, green: 0, blue: 0))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .alert("Title", isPresented: .constant(false)) {}
            }
        }
        """

        let diagnostics = engine.lint(source: source, path: "xmnote/Views/ExampleView.swift")
        let ruleIDs = Set(diagnostics.map(\.ruleID))

        #expect(ruleIDs.isSuperset(of: ["DS001", "DS002", "DS003", "DS004", "DS006"]))
        #expect(diagnostics.allSatisfy { $0.declaration == "var body" })
    }

    @Test func acceptsTokenBackedVisualValues() {
        let source = """
        import SwiftUI

        struct ExampleView: View {
            var body: some View {
                VStack(spacing: Spacing.base) {
                    Text("Title")
                        .font(AppTypography.body)
                        .padding(.horizontal, Spacing.content)
                        .foregroundStyle(Color.textPrimary)
                        .clipShape(
                            RoundedRectangle(
                                cornerRadius: CornerRadius.card,
                                style: .continuous
                            )
                        )
                }
                .scrollBounceBehavior(.always)
            }
        }
        """

        let diagnostics = engine.lint(source: source, path: "xmnote/Views/ExampleView.swift")
        #expect(diagnostics.filter { $0.ruleID.hasPrefix("DS0") }.isEmpty)
    }

    @Test func detectsDomainFrameworkDependency() {
        let source = """
        import Foundation
        import SwiftUI

        struct DomainValue {}
        """

        let diagnostics = engine.lint(source: source, path: "xmnote/Domain/Models/DomainValue.swift")
        #expect(diagnostics.map(\.ruleID).contains("DS007"))
    }

    @Test func detectsUIComponentsBusinessDependencyIdentifiers() {
        let source = """
        import SwiftUI

        struct ExampleComponent: View {
            let repository: any TagManagementRepositoryProtocol
            let concreteRepository: TagRepository
            let viewModel = ExampleViewModel()
            let container = RepositoryContainer.shared

            var body: some View { EmptyView() }
        }
        """

        let diagnostics = engine.lint(
            source: source,
            path: "xmnote/UIComponents/Foundation/ExampleComponent.swift"
        ).filter { $0.ruleID == "DS008" }

        #expect(diagnostics.count == 4)
        #expect(diagnostics.allSatisfy { $0.reportDisposition == .candidate })
    }

    @Test func dependencyRuleIgnoresCommentsStringsAndUnrelatedNames() {
        let source = """
        import SwiftUI

        // TagManagementRepositoryProtocol is documentation only.
        struct RepositoryBadge: View {
            let copy = "RepositoryContainer"
            var body: some View { Text(copy) }
        }
        """

        let diagnostics = engine.lint(
            source: source,
            path: "xmnote/UIComponents/Foundation/RepositoryBadge.swift"
        )

        #expect(diagnostics.allSatisfy { $0.ruleID != "DS008" })
    }

    @Test func detectsUnregisteredTapGestureAndHonorsExactDeclarationException() {
        let source = """
        import SwiftUI

        struct DenseControl: View {
            var body: some View {
                Color.clear.onTapGesture { }
            }
        }
        """
        let path = "xmnote/UIComponents/Controls/DenseControl.swift"

        let unregistered = engine.lint(source: source, path: path)
        #expect(unregistered.contains { $0.ruleID == "DS009" })

        let registeredPolicy = LintPolicy(
            schemaVersion: Self.policy.schemaVersion,
            constructionPolicies: Self.policy.constructionPolicies,
            symbolPolicies: Self.policy.symbolPolicies,
            dependencyPolicies: Self.policy.dependencyPolicies,
            interactionPolicy: InteractionPolicy(
                tapGestureRuleID: "DS009",
                touchTargetRuleID: "DS010",
                touchTargetOwnerPath: "xmnote/Utilities/DesignSystem/InteractionMetrics.swift",
                touchTargetLiteral: 44,
                touchTargetNameFragments: ["touch", "hit", "tap"],
                gestureExceptions: [
                    GestureException(
                        path: path,
                        declaration: "DenseControl.body",
                        reason: "密集坐标交互",
                        owner: "DenseControl",
                        accessibilityAlternative: "提供可访问性表示",
                        visualFreezeRationale: "不能改变既有网格"
                    )
                ]
            )
        )
        let registered = RuleEngine(policy: registeredPolicy).lint(source: source, path: path)
        #expect(registered.allSatisfy { $0.ruleID != "DS009" })

        let movedSource = source.replacingOccurrences(of: "var body", with: "var content")
        let moved = RuleEngine(policy: registeredPolicy).lint(source: movedSource, path: path)
        #expect(moved.contains { $0.ruleID == "DS009" })
    }

    @Test func detectsSemantic44LiteralWithoutFlaggingVisual44() {
        let source = """
        import SwiftUI

        struct ExampleControl: View {
            private let hitSize: CGFloat = 44
            private let touchHeight = max(44.0, 28)
            private let buttonHeight: CGFloat = 44
            private let controlMinSize: CGFloat = 44
            private let actionSlotWidth: CGFloat = 44
            private var resolvedHitWidth: CGFloat { min(proposedHitWidth, 44) }
            private let proposedHitWidth: CGFloat = 52
            private let compactHitSize: CGFloat = 32
            private let visualHeight: CGFloat = 44
            private let rowHeight: CGFloat = 44
            private let tapWidth = InteractionMetrics.minimumTouchTarget

            var body: some View { EmptyView() }
        }
        """

        let diagnostics = engine.lint(
            source: source,
            path: "xmnote/UIComponents/Controls/ExampleControl.swift"
        ).filter { $0.ruleID == "DS010" }

        #expect(diagnostics.count == 7)
        #expect(diagnostics.contains { $0.message.contains("不得小于 44pt") })
    }

    @Test func detectsDirect44InInteractiveDimensionCallsButAllowsLocalMetrics() {
        let source = """
        import SwiftUI

        struct ExampleControl: View {
            private enum Layout {
                static let visualHeight: CGFloat = 44
            }

            var body: some View {
                VStack {
                    Button("直接尺寸") { }
                        .frame(width: 44, minHeight: 44)
                    Text("视觉尺寸")
                        .frame(height: Layout.visualHeight)
                }
            }

            func install(button: UIButton) {
                button.widthAnchor.constraint(equalToConstant: 44).isActive = true
                button.heightAnchor.constraint(
                    greaterThanOrEqualToConstant: InteractionMetrics.minimumTouchTarget
                ).isActive = true
            }
        }
        """

        let diagnostics = engine.lint(
            source: source,
            path: "xmnote/UIComponents/Controls/ExampleControl.swift"
        ).filter { $0.ruleID == "DS010" }

        #expect(diagnostics.count == 2)
    }

    @Test func permits44LiteralOnlyInsideInteractionMetricsOwner() {
        let source = """
        import SwiftUI

        enum InteractionMetrics {
            static let minimumTouchTarget: CGFloat = 44
        }
        """

        let diagnostics = engine.lint(
            source: source,
            path: "xmnote/Utilities/DesignSystem/InteractionMetrics.swift"
        )
        #expect(diagnostics.allSatisfy { $0.ruleID != "DS010" })
    }

    @Test func permitsColorConstructionInsideDesignSystemOwners() {
        let source = """
        import SwiftUI

        extension Color {
            static let customSemantic = Color(red: 1, green: 0, blue: 0)
        }
        """

        let semanticDiagnostics = engine.lint(
            source: source,
            path: "xmnote/Utilities/DesignSystem/SemanticColors.swift"
        )
        let featureDiagnostics = engine.lint(
            source: source,
            path: "xmnote/Views/ExampleView.swift"
        )
        let similarlyNamedDiagnostics = engine.lint(
            source: source,
            path: "xmnote/Utilities/DesignSystem/SemanticColorsCopy.swift"
        )

        #expect(!semanticDiagnostics.map(\.ruleID).contains("DS003"))
        #expect(featureDiagnostics.map(\.ruleID).contains("DS003"))
        #expect(similarlyNamedDiagnostics.map(\.ruleID).contains("DS003"))
    }

    @Test func enforcesTrailingClosureColorConstructionAgainstExactOwnerPaths() {
        let configuredPolicy = LintPolicy(
            schemaVersion: Self.policy.schemaVersion,
            constructionPolicies: ConstructionPolicies(
                rawColor: ConstructionPolicy(
                    ruleID: "DS003",
                    entryPoints: ["Color(...)", "UIColor(...)"],
                    allowedPaths: [
                        "xmnote/Utilities/DesignSystem/FeatureColorConstruction.swift"
                    ]
                ),
                rawTypography: Self.policy.constructionPolicies.rawTypography
            ),
            symbolPolicies: []
        )
        let configuredEngine = RuleEngine(policy: configuredPolicy)
        let source = """
        import SwiftUI
        import UIKit

        let adaptiveUIColor = UIColor { traits in
            traits.userInterfaceStyle == .dark ? .black : .white
        }
        let adaptiveColor = Color { traits in
            traits.userInterfaceStyle == .dark ? .black : .white
        }
        """

        let ownerDiagnostics = configuredEngine.lint(
            source: source,
            path: "xmnote/Utilities/DesignSystem/FeatureColorConstruction.swift"
        )
        let featureDiagnostics = configuredEngine.lint(
            source: source,
            path: "xmnote/Views/FeatureColorConstruction.swift"
        )
        let similarlyNamedDiagnostics = configuredEngine.lint(
            source: source,
            path: "xmnote/Utilities/DesignSystem/FeatureColorConstructionCopy.swift"
        )

        #expect(ownerDiagnostics.filter { $0.ruleID == "DS003" }.isEmpty)
        #expect(featureDiagnostics.filter { $0.ruleID == "DS003" }.count == 2)
        #expect(similarlyNamedDiagnostics.filter { $0.ruleID == "DS003" }.count == 2)
    }

    @Test func detectsInferredUIKitSystemFontConstruction() {
        let source = """
        import UIKit

        let regular: UIFont = .systemFont(ofSize: 16)
        let bold: UIFont = .boldSystemFont(ofSize: 16)
        """

        let featureDiagnostics = engine.lint(
            source: source,
            path: "xmnote/Views/ExampleView.swift"
        )
        let ownerDiagnostics = engine.lint(
            source: source,
            path: "xmnote/Utilities/DesignSystem/SemanticTypography.swift"
        )

        #expect(featureDiagnostics.filter { $0.ruleID == "DS001" }.count == 2)
        #expect(ownerDiagnostics.filter { $0.ruleID == "DS001" }.isEmpty)
    }

    @Test func distinguishesIconGlyphSizingFromProductionTypography() {
        let source = """
        import SwiftUI

        struct ExampleView: View {
            var body: some View {
                VStack {
                    Image(systemName: "sparkles")
                        .font(.system(size: 17, weight: .semibold))
                    Text("Title")
                        .font(.system(size: 17))
                }
            }
        }
        """

        let diagnostics = engine.lint(source: source, path: "xmnote/Views/ExampleView.swift")
        let typographyDiagnostics = diagnostics.filter { $0.ruleID == "DS001" }

        #expect(typographyDiagnostics.count == 1)
        #expect(typographyDiagnostics.first?.evidence.contains("Text") == true)
    }

    @Test func imageGlyphExemptionRequiresImageAsTheReceiverRoot() {
        let source = """
        import SwiftUI

        struct ExampleView: View {
            var body: some View {
                VStack {
                    Image(systemName: "sparkles")
                        .symbolRenderingMode(.hierarchical)
                        .font(.system(size: 17, weight: .semibold))
                    Text(Image(systemName: "sparkles"))
                        .font(.system(size: 17))
                    VStack { Image(systemName: "sparkles") }
                        .font(.system(size: 17))
                }
            }
        }
        """

        let diagnostics = engine.lint(source: source, path: "xmnote/Views/ExampleView.swift")
        let typographyDiagnostics = diagnostics.filter { $0.ruleID == "DS001" }

        #expect(typographyDiagnostics.count == 2)
        #expect(typographyDiagnostics.allSatisfy { !$0.evidence.hasPrefix("Image(") })
    }

    @Test func enforcesConfiguredMemberSymbolsAgainstExactOwnerPaths() {
        let memberPolicy = SymbolPolicy(
            name: "paletteConstruction",
            ruleID: "DS003",
            symbols: ["Color.xmHex"],
            allowedPaths: ["xmnote/Utilities/DesignSystem/FeaturePalette.swift"],
            replacement: "Color 的语义成员"
        )
        let configuredPolicy = LintPolicy(
            schemaVersion: Self.policy.schemaVersion,
            constructionPolicies: Self.policy.constructionPolicies,
            symbolPolicies: [memberPolicy]
        )
        let configuredEngine = RuleEngine(policy: configuredPolicy)
        let source = """
        import SwiftUI

        let accent = Color.xmHex(0x2ECF77)
        """

        let ownerDiagnostics = configuredEngine.lint(
            source: source,
            path: "xmnote/Utilities/DesignSystem/FeaturePalette.swift"
        )
        let featureDiagnostics = configuredEngine.lint(
            source: source,
            path: "xmnote/Views/FeaturePalette.swift"
        )

        #expect(!ownerDiagnostics.map(\.ruleID).contains("DS003"))
        #expect(featureDiagnostics.filter { $0.ruleID == "DS003" }.count == 1)
        #expect(featureDiagnostics.first?.message.contains("Color 的语义成员") == true)
    }

    @Test func enforcesExplicitlyConfiguredInferredMemberSymbols() {
        let memberPolicy = SymbolPolicy(
            name: "paletteConstruction",
            ruleID: "DS003",
            symbols: ["Color.xmHex"],
            allowedPaths: ["xmnote/Utilities/DesignSystem/FeaturePalette.swift"],
            replacement: "Color 的语义成员",
            matchInferred: true
        )
        let configuredPolicy = LintPolicy(
            schemaVersion: Self.policy.schemaVersion,
            constructionPolicies: Self.policy.constructionPolicies,
            symbolPolicies: [memberPolicy]
        )
        let configuredEngine = RuleEngine(policy: configuredPolicy)
        let source = "let accent: Color = .xmHex(0x2ECF77)"

        let ownerDiagnostics = configuredEngine.lint(
            source: source,
            path: "xmnote/Utilities/DesignSystem/FeaturePalette.swift"
        )
        let featureDiagnostics = configuredEngine.lint(
            source: source,
            path: "xmnote/Views/FeaturePalette.swift"
        )

        #expect(ownerDiagnostics.filter { $0.ruleID == "DS003" }.isEmpty)
        #expect(featureDiagnostics.filter { $0.ruleID == "DS003" }.count == 1)
        #expect(featureDiagnostics.first?.evidence == ".xmHex")
    }

    @Test func enforcesRestrictedSymbolDeclarationsWithoutFlaggingUnrelatedTypes() {
        let colorPolicy = SymbolPolicy(
            name: "retiredColors",
            ruleID: "DS003",
            symbols: [
                "Color.brand",
                "Color.readCalendarSummaryGradientSpec"
            ],
            allowedPaths: [],
            replacement: "当前颜色 owner"
        )
        let spacingPolicy = SymbolPolicy(
            name: "retiredSpacing",
            ruleID: "DS002",
            symbols: ["Spacing.actionReserved"],
            allowedPaths: [],
            replacement: "InteractionMetrics.minimumTouchTarget"
        )
        let configuredPolicy = LintPolicy(
            schemaVersion: Self.policy.schemaVersion,
            constructionPolicies: Self.policy.constructionPolicies,
            symbolPolicies: [colorPolicy, spacingPolicy]
        )
        let configuredEngine = RuleEngine(policy: configuredPolicy)
        let source = """
        import SwiftUI

        extension SwiftUI.Color {
            static let brand = Color.clear
            static func readCalendarSummaryGradientSpec() -> Color { .clear }
        }

        enum Spacing {
            static let actionReserved: CGFloat = 44
        }

        enum Palette {
            case brand
            static let actionReserved: CGFloat = 44
        }

        let unrelated = Palette.brand
        """

        let diagnostics = configuredEngine.lint(
            source: source,
            path: "xmnote/Views/ExampleView.swift"
        )

        #expect(diagnostics.filter { $0.ruleID == "DS003" }.count == 2)
        #expect(diagnostics.filter { $0.ruleID == "DS002" }.count == 1)
        #expect(!diagnostics.map(\.evidence).contains("Palette.brand"))
    }

    @Test func permitsRestrictedSymbolDeclarationOnlyInExactOwnerPath() {
        let memberPolicy = SymbolPolicy(
            name: "paletteConstruction",
            ruleID: "DS003",
            symbols: ["Color.xmHex"],
            allowedPaths: ["xmnote/Utilities/DesignSystem/ColorConstruction.swift"],
            replacement: "Color 的语义成员",
            matchInferred: true
        )
        let configuredPolicy = LintPolicy(
            schemaVersion: Self.policy.schemaVersion,
            constructionPolicies: Self.policy.constructionPolicies,
            symbolPolicies: [memberPolicy]
        )
        let configuredEngine = RuleEngine(policy: configuredPolicy)
        let source = """
        import SwiftUI

        extension Color {
            static func xmHex(_ value: UInt) -> Color { .clear }
        }
        """

        let ownerDiagnostics = configuredEngine.lint(
            source: source,
            path: "xmnote/Utilities/DesignSystem/ColorConstruction.swift"
        )
        let similarlyNamedDiagnostics = configuredEngine.lint(
            source: source,
            path: "xmnote/Utilities/DesignSystem/ColorConstructionCopy.swift"
        )

        #expect(ownerDiagnostics.filter { $0.ruleID == "DS003" }.isEmpty)
        #expect(similarlyNamedDiagnostics.filter { $0.ruleID == "DS003" }.count == 1)
    }

    @Test func enforcesRetiredMemberSymbolsWithoutAllowedOwnerPaths() {
        let retiredPolicy = SymbolPolicy(
            name: "retiredInteractionSpacing",
            ruleID: "DS002",
            symbols: ["Spacing.actionReserved"],
            allowedPaths: [],
            replacement: "InteractionMetrics.minimumTouchTarget 或局部 Metrics/Layout"
        )
        let configuredPolicy = LintPolicy(
            schemaVersion: Self.policy.schemaVersion,
            constructionPolicies: Self.policy.constructionPolicies,
            symbolPolicies: [retiredPolicy]
        )
        let configuredEngine = RuleEngine(policy: configuredPolicy)
        let source = "let reserved = Spacing.actionReserved"

        let featureDiagnostics = configuredEngine.lint(
            source: source,
            path: "xmnote/Views/ExampleView.swift"
        )
        let retiredOwnerDiagnostics = configuredEngine.lint(
            source: source,
            path: "xmnote/Utilities/DesignSystem/Spacing.swift"
        )

        for diagnostics in [featureDiagnostics, retiredOwnerDiagnostics] {
            let retiredDiagnostics = diagnostics.filter { $0.ruleID == "DS002" }
            #expect(retiredDiagnostics.count == 1)
            #expect(retiredDiagnostics.first?.evidence == "Spacing.actionReserved")
            #expect(
                retiredDiagnostics.first?.message.contains(
                    "InteractionMetrics.minimumTouchTarget"
                ) == true
            )
        }
    }

    @Test func retiredMemberSymbolPolicyUsesExactQualifiedMatching() {
        let retiredPolicy = SymbolPolicy(
            name: "retiredInteractionSpacing",
            ruleID: "DS002",
            symbols: ["Spacing.actionReserved"],
            allowedPaths: [],
            replacement: "InteractionMetrics.minimumTouchTarget 或局部 Metrics/Layout"
        )
        let configuredPolicy = LintPolicy(
            schemaVersion: Self.policy.schemaVersion,
            constructionPolicies: Self.policy.constructionPolicies,
            symbolPolicies: [retiredPolicy]
        )
        let configuredEngine = RuleEngine(policy: configuredPolicy)
        let source = """
        let replacement = InteractionMetrics.minimumTouchTarget
        let similarlyNamedOwner = SomeSpacing.actionReserved
        let similarlyNamedMember = Spacing.actionReservedExtra
        let unrelatedInference: OtherSpacing = .actionReserved
        """

        let diagnostics = configuredEngine.lint(
            source: source,
            path: "xmnote/Views/ExampleView.swift"
        )

        #expect(diagnostics.filter { $0.ruleID == "DS002" }.isEmpty)
    }

    @Test func permitsSystemFontConstructionInsideTypographyOwners() {
        let source = """
        import SwiftUI
        import UIKit

        struct AppTypographyProbe: View {
            static let measured = UIFont.systemFont(ofSize: 13)

            var body: some View {
                Text("Probe").font(.system(.footnote, design: .monospaced))
            }
        }
        """

        let ownerDiagnostics = engine.lint(
            source: source,
            path: "xmnote/Utilities/DesignSystem/AppTypography.swift"
        )
        let featureDiagnostics = engine.lint(
            source: source,
            path: "xmnote/Views/ExampleView.swift"
        )
        let similarlyNamedDiagnostics = engine.lint(
            source: source,
            path: "xmnote/Utilities/DesignSystem/AppTypographyCopy.swift"
        )

        #expect(!ownerDiagnostics.map(\.ruleID).contains("DS001"))
        #expect(featureDiagnostics.filter { $0.ruleID == "DS001" }.count == 2)
        #expect(similarlyNamedDiagnostics.filter { $0.ruleID == "DS001" }.count == 2)
    }

    @Test func ignoresIndexMathNestedInsideTokenBackedPadding() {
        let source = """
        import SwiftUI

        struct ExampleView: View {
            let level: Int

            var body: some View {
                Text("Chapter")
                    .padding(
                        .leading,
                        Spacing.contentEdge + CGFloat(max(0, level - 1)) * Layout.chapterIndent
                    )
            }
        }
        """

        let diagnostics = engine.lint(source: source, path: "xmnote/Views/ExampleView.swift")
        #expect(!diagnostics.map(\.ruleID).contains("DS002"))
    }

    @Test func reportRulesDoNotMasqueradeAsEnforcedRules() {
        let source = """
        import SwiftUI

        struct ExampleView: View {
            var body: some View {
                ProgressView()
                    .animation(.smooth(duration: 0.2), value: true)
                    .overlay { Image(systemName: "sparkles") }
            }
        }
        """

        let ruleIDs = Set(engine.lint(source: source, path: "xmnote/Views/ExampleView.swift").map(\.ruleID))
        #expect(ruleIDs.isSuperset(of: ["DSR001", "DSR002", "DSR003"]))
    }

    @Test func groupsSFSymbolInventoryByModuleAndSymbol() {
        let source = """
        import SwiftUI

        struct ExampleView: View {
            var body: some View {
                Label("More", systemImage: "ellipsis")
            }
        }
        """

        let diagnostic = engine.lint(
            source: source,
            path: "xmnote/Views/Book/ExampleView.swift"
        ).first { $0.ruleID == "DSR001" }

        #expect(diagnostic?.reportDisposition == .inventory)
        #expect(diagnostic?.reportGroup == "sf-symbol|Views/Book|ellipsis")
    }

    @Test func classifiesSemanticMotionOwnersNamedPropertiesAndInlineLiterals() {
        let source = """
        import SwiftUI

        enum ExampleMotion {
            static let selection = Animation.snappy(duration: 0.18)
        }

        struct ExampleView: View {
            private var presentationAnimation: Animation {
                .smooth(duration: 0.22)
            }

            var body: some View {
                Text("Title")
                    .animation(.smooth(duration: 0.28), value: true)
            }
        }
        """

        let diagnostics = engine.lint(
            source: source,
            path: "xmnote/Views/ExampleView.swift"
        ).filter { $0.ruleID == "DSR002" }

        #expect(diagnostics.count == 3)
        #expect(diagnostics.first { $0.evidence.contains("0.18") }?.reportDisposition == .inventory)
        #expect(
            diagnostics.first { $0.evidence.contains("0.18") }?.reportGroup
                == "motion|semantic-owner|ExampleMotion"
        )
        #expect(diagnostics.first { $0.evidence.contains("0.22") }?.reportDisposition == .inventory)
        #expect(
            diagnostics.first { $0.evidence.contains("0.22") }?.reportGroup
                == "motion|named-property|presentationAnimation"
        )
        #expect(diagnostics.first { $0.evidence.contains("0.28") }?.reportDisposition == .candidate)
        #expect(
            diagnostics.first { $0.evidence.contains("0.28") }?.reportGroup
                == "motion|inline-literal"
        )
    }

    @Test func recognizesReduceMotionConditionalAsInventory() {
        let source = """
        import SwiftUI

        struct ExampleView: View {
            @Environment(\\.accessibilityReduceMotion) private var reduceMotion

            var body: some View {
                Text("Title")
                    .animation(
                        reduceMotion ? nil : .smooth(duration: 0.22),
                        value: true
                    )
            }
        }
        """

        let diagnostic = engine.lint(
            source: source,
            path: "xmnote/Views/ExampleView.swift"
        ).first { $0.ruleID == "DSR002" }

        #expect(diagnostic?.reportDisposition == .inventory)
        #expect(diagnostic?.reportGroup == "motion|reduce-motion-branch")
    }

    @Test func classifiesProgressFeedbackByStructuralOwner() {
        let source = """
        import SwiftUI

        struct ExampleView: View {
            let value: Double

            var body: some View {
                VStack {
                    ProgressView(value: value, total: 1)
                    Button("Save") { } label: {
                        ProgressView()
                    }
                    processingIndicator
                    ProgressView()
                }
            }

            private var processingIndicator: some View {
                ProgressView()
            }
        }
        """

        let diagnostics = engine.lint(
            source: source,
            path: "xmnote/Views/ExampleView.swift"
        ).filter { $0.ruleID == "DSR003" }

        #expect(diagnostics.count == 4)
        #expect(diagnostics.first { $0.evidence.contains("value:") }?.reportGroup == "progress|determinate")
        #expect(
            diagnostics.first { $0.line == 10 }?.reportGroup
                == "progress|interactive-operation"
        )
        #expect(
            diagnostics.first { $0.declaration == "var processingIndicator" }?.reportGroup
                == "progress|named-owner|processingIndicator"
        )
        #expect(
            diagnostics.first {
                $0.declaration == "var body" && $0.reportDisposition == .candidate
            }?.reportGroup == "progress|unclassified"
        )
    }

    @Test func recognizesDesignSystemLoadingComponentProgressAsInventory() {
        let source = """
        import SwiftUI

        struct LoadingStateView: View {
            var body: some View {
                ProgressView()
            }
        }
        """

        let diagnostic = engine.lint(
            source: source,
            path: "xmnote/UIComponents/Foundation/LoadingStateView.swift"
        ).first { $0.ruleID == "DSR003" }

        #expect(diagnostic?.reportDisposition == .inventory)
        #expect(diagnostic?.reportGroup == "progress|design-system-loading")
    }
}
