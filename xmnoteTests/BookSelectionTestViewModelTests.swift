#if DEBUG
import Testing
@testable import xmnote

@MainActor
struct BookSelectionTestViewModelTests {
    @Test
    func registryContainsTwentyUniqueAndroidScenarios() {
        let scenarios = BookSelectionTestViewModel.scenarios

        #expect(scenarios.count == 20)
        #expect(Set(scenarios.map(\.id)).count == 20)
    }

    @Test
    func scenarioConfigurationsStayRunnableForEachGroup() {
        let sampleLocalBook = BookPickerBook(id: 1, title: "三体", author: "刘慈欣")

        for scenario in BookSelectionTestViewModel.scenarios {
            let configuration = scenario.configurationSpec.makeConfiguration(sampleLocalBooks: [sampleLocalBook])

            #expect(!scenario.title.isEmpty)
            #expect(!scenario.androidEntry.isEmpty)
            #expect(!scenario.capabilityTags.isEmpty)
            #expect(!scenario.configurationSpec.implementationDescription.isEmpty)

            switch scenario.group {
            case .localSingleWithCreation:
                #expect(configuration.scope == .local)
                #expect(configuration.selectionMode == .single)
                #expect(configuration.allowsCreationFlow)
            case .localSingle:
                #expect(configuration.scope == .local)
                #expect(configuration.selectionMode == .single)
                #expect(!configuration.allowsCreationFlow)
            case .localMultipleFilter:
                #expect(configuration.scope == .local)
                #expect(configuration.selectionMode == .multiple)
                #expect(configuration.multipleConfirmationPolicy == .allowsEmptyResult)
            case .mixedDirectSelection:
                #expect(configuration.scope == .both)
                #expect(configuration.onlineSelectionPolicy == .returnRemoteSelection)
            case .onlineDirectSelection:
                #expect(configuration.scope == .online)
                #expect(configuration.onlineSelectionPolicy == .returnRemoteSelection)
            }
        }
    }

    @Test
    func importScenarioUsesFirstLocalBookAsPreselectionWhenAvailable() throws {
        let scenario = try #require(BookSelectionTestViewModel.scenarios.first { $0.id == "import-book-map" })
        let sampleLocalBook = BookPickerBook(id: 7, title: "活着", author: "余华")

        let configuration = scenario.configurationSpec.makeConfiguration(sampleLocalBooks: [sampleLocalBook])

        #expect(configuration.preselectedBooks == [sampleLocalBook])
    }
}
#endif
