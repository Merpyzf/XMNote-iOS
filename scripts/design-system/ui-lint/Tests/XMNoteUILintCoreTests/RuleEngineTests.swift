import Testing
@testable import XMNoteUILintCore

struct RuleEngineTests {
    private let engine = RuleEngine()

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

        #expect(!semanticDiagnostics.map(\.ruleID).contains("DS003"))
        #expect(featureDiagnostics.map(\.ruleID).contains("DS003"))
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

        #expect(!ownerDiagnostics.map(\.ruleID).contains("DS001"))
        #expect(featureDiagnostics.filter { $0.ruleID == "DS001" }.count == 2)
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
}
