import Foundation
import Testing
@testable import XMNoteWeb

struct DesktopWebAPIManifestTests {
    @Test
    func currentAndroidManifestHasExpectedShape() throws {
        let manifest = try loadManifest()

        #expect(manifest.schemaVersion == 1)
        #expect(manifest.androidBaseline.sourceRevision == "fe5cde3964692ce7c86d0f8a8ce3973a7124dc13")
        #expect(manifest.androidBaseline.installedVersionName == "5.6.0-r8verify")
        #expect(manifest.androidBaseline.installedVersionCode == 185)
        #expect(
            manifest.androidBaseline.installedApkSHA256
                == "6f0e966432cd123a0431f68f112e1d8f9a36832617d9b24febd36f36bf3fd395"
        )
        #expect(
            manifest.androidBaseline.controllerAggregateSHA256
                == "871e4d786f5c1a86031f4cdd6c101bedf39d349b34ec147d2f2d6ea26a2eb993"
        )
        #expect(manifest.androidBaseline.controllerCount == 21)
        #expect(manifest.androidBaseline.endpointCount == 162)
        #expect(manifest.endpoints.count == 162)
        #expect(manifest.crossCuttingIssueCoverage["ANDROID-WEB-088"]?.count == 43)
        #expect(
            Set(manifest.crossCuttingIssueCoverage["ANDROID-WEB-088"] ?? []).count == 43
        )
    }

    @Test
    func endpointIdentitiesAndRoutesAreUnique() throws {
        let endpoints = try loadManifest().endpoints
        let identities = Set(endpoints.map(\.id))
        let routes = Set(endpoints.map { "\($0.method) \($0.path)" })

        #expect(identities.count == endpoints.count)
        #expect(routes.count == endpoints.count)
        #expect(endpoints.allSatisfy { $0.path.hasPrefix("/api/v1/") })
        #expect(endpoints.allSatisfy { (1...5).contains($0.phase) })
    }

    @Test
    func endpointCountsMatchCurrentBaseline() throws {
        let manifest = try loadManifest()
        let methodCounts = Dictionary(grouping: manifest.endpoints, by: \.method).mapValues(\.count)
        let phaseCounts = Dictionary(grouping: manifest.endpoints, by: \.phase).mapValues(\.count)

        #expect(methodCounts == manifest.androidBaseline.methodCounts)
        #expect(methodCounts == ["GET": 73, "POST": 43, "PUT": 34, "DELETE": 12])
        #expect(phaseCounts == [1: 7, 2: 45, 3: 57, 4: 30, 5: 23])
    }

    @Test
    func manifestProgressMatchesAllCompletedImplementationBatches() throws {
        let endpoints = try loadManifest().endpoints
        var completedIDs: Set<String> = [
            "WEB-API-004",
            "WEB-API-005",
            "WEB-API-006",
            "WEB-API-007",
            "WEB-API-008",
            "WEB-API-009",
            "WEB-API-010",
            "WEB-API-011",
            "WEB-API-012",
            "WEB-API-014",
            "WEB-API-015",
            "WEB-API-016",
            "WEB-API-017",
            "WEB-API-018",
            "WEB-API-019",
            "WEB-API-020",
            "WEB-API-021",
            "WEB-API-022",
            "WEB-API-023",
            "WEB-API-024",
            "WEB-API-025",
            "WEB-API-026",
            "WEB-API-027",
            "WEB-API-028",
            "WEB-API-029",
            "WEB-API-030",
            "WEB-API-031",
            "WEB-API-032",
            "WEB-API-033",
            "WEB-API-034",
            "WEB-API-035",
            "WEB-API-036",
            "WEB-API-037",
            "WEB-API-038",
            "WEB-API-039",
            "WEB-API-040",
            "WEB-API-041",
            "WEB-API-042",
            "WEB-API-043",
            "WEB-API-044",
            "WEB-API-045",
            "WEB-API-046",
            "WEB-API-047",
            "WEB-API-048",
            "WEB-API-049",
            "WEB-API-050",
            "WEB-API-051",
            "WEB-API-052",
            "WEB-API-053",
            "WEB-API-054",
            "WEB-API-055",
            "WEB-API-056",
            "WEB-API-057",
            "WEB-API-058",
            "WEB-API-059",
            "WEB-API-060",
            "WEB-API-061",
            "WEB-API-062",
            "WEB-API-063",
            "WEB-API-064",
            "WEB-API-065",
            "WEB-API-066",
            "WEB-API-067",
            "WEB-API-068",
            "WEB-API-069",
            "WEB-API-070",
            "WEB-API-071",
            "WEB-API-072",
            "WEB-API-073",
            "WEB-API-074",
            "WEB-API-075",
            "WEB-API-076",
            "WEB-API-077",
            "WEB-API-078",
            "WEB-API-079",
            "WEB-API-080",
            "WEB-API-081",
            "WEB-API-082",
            "WEB-API-083",
            "WEB-API-084",
            "WEB-API-085",
            "WEB-API-086",
            "WEB-API-087",
            "WEB-API-088",
            "WEB-API-089",
            "WEB-API-090",
            "WEB-API-091",
            "WEB-API-092",
            "WEB-API-093",
            "WEB-API-094",
            "WEB-API-095",
            "WEB-API-096",
            "WEB-API-097",
            "WEB-API-098",
            "WEB-API-099",
            "WEB-API-100",
            "WEB-API-101",
            "WEB-API-102",
            "WEB-API-103",
            "WEB-API-104",
            "WEB-API-105",
            "WEB-API-106",
            "WEB-API-107",
            "WEB-API-108",
            "WEB-API-109",
            "WEB-API-110",
            "WEB-API-111",
            "WEB-API-112",
            "WEB-API-113",
            "WEB-API-114",
            "WEB-API-115",
            "WEB-API-116",
            "WEB-API-117",
            "WEB-API-118",
            "WEB-API-119",
            "WEB-API-120",
            "WEB-API-121",
            "WEB-API-122",
            "WEB-API-123",
            "WEB-API-124",
            "WEB-API-125",
            "WEB-API-126",
            "WEB-API-127",
            "WEB-API-128",
            "WEB-API-129",
            "WEB-API-130",
            "WEB-API-131",
            "WEB-API-132",
            "WEB-API-133",
            "WEB-API-134",
            "WEB-API-135",
            "WEB-API-136",
            "WEB-API-137",
            "WEB-API-138",
            "WEB-API-139",
            "WEB-API-140",
            "WEB-API-141",
            "WEB-API-142",
            "WEB-API-143",
            "WEB-API-144",
            "WEB-API-145",
            "WEB-API-146",
            "WEB-API-147",
            "WEB-API-148",
            "WEB-API-149",
            "WEB-API-150",
            "WEB-API-151",
            "WEB-API-152",
            "WEB-API-153",
            "WEB-API-154",
            "WEB-API-155",
            "WEB-API-156",
            "WEB-API-157",
            "WEB-API-158",
            "WEB-API-159",
            "WEB-API-160"
        ]
        completedIDs.formUnion([
            "WEB-API-001",
            "WEB-API-002",
            "WEB-API-003",
            "WEB-API-013",
            "WEB-API-024",
            "WEB-API-051",
            "WEB-API-052",
            "WEB-API-053",
            "WEB-API-054",
            "WEB-API-063",
            "WEB-API-064",
            "WEB-API-065",
            "WEB-API-066",
            "WEB-API-157",
            "WEB-API-158",
            "WEB-API-159",
            "WEB-API-160"
        ])
        let completed = endpoints.filter { completedIDs.contains($0.id) }
        let pending = endpoints.filter { !completedIDs.contains($0.id) }

        #expect(completed.count == 160)
        #expect(completed.allSatisfy { $0.status.iosDevelopmentCompleted })
        #expect(completed.allSatisfy { $0.status.iosUnitTestCompleted })
        #expect(completed.allSatisfy { $0.status.androidReviewCompleted })
        #expect(Set(pending.map(\.id)) == ["WEB-API-161", "WEB-API-162"])
        #expect(pending.allSatisfy { !$0.status.iosDevelopmentCompleted })
        #expect(pending.allSatisfy { !$0.status.iosUnitTestCompleted })
        #expect(pending.allSatisfy { $0.status.androidReviewCompleted })
        let parityExactIDs: Set<String> = [
            "WEB-API-001",
            "WEB-API-002",
            "WEB-API-003",
            "WEB-API-013",
            "WEB-API-004",
            "WEB-API-005",
            "WEB-API-006",
            "WEB-API-007",
            "WEB-API-008",
            "WEB-API-009",
            "WEB-API-010",
            "WEB-API-011",
            "WEB-API-012",
            "WEB-API-014",
            "WEB-API-015",
            "WEB-API-016",
            "WEB-API-017",
            "WEB-API-018",
            "WEB-API-019",
            "WEB-API-020",
            "WEB-API-021",
            "WEB-API-022",
            "WEB-API-023",
            "WEB-API-024",
            "WEB-API-025",
            "WEB-API-026",
            "WEB-API-027",
            "WEB-API-028",
            "WEB-API-029",
            "WEB-API-030",
            "WEB-API-031",
            "WEB-API-032",
            "WEB-API-033",
            "WEB-API-034",
            "WEB-API-035",
            "WEB-API-036",
            "WEB-API-037",
            "WEB-API-038",
            "WEB-API-039",
            "WEB-API-040",
            "WEB-API-041",
            "WEB-API-042",
            "WEB-API-043",
            "WEB-API-044",
            "WEB-API-045",
            "WEB-API-046",
            "WEB-API-047",
            "WEB-API-048",
            "WEB-API-049",
            "WEB-API-050",
            "WEB-API-051",
            "WEB-API-052",
            "WEB-API-053",
            "WEB-API-054",
            "WEB-API-055",
            "WEB-API-056",
            "WEB-API-057",
            "WEB-API-058",
            "WEB-API-059",
            "WEB-API-060",
            "WEB-API-061",
            "WEB-API-062",
            "WEB-API-063",
            "WEB-API-064",
            "WEB-API-065",
            "WEB-API-066",
            "WEB-API-067",
            "WEB-API-068",
            "WEB-API-069",
            "WEB-API-070",
            "WEB-API-071",
            "WEB-API-072",
            "WEB-API-073",
            "WEB-API-074",
            "WEB-API-075",
            "WEB-API-076",
            "WEB-API-077",
            "WEB-API-078",
            "WEB-API-079",
            "WEB-API-080",
            "WEB-API-081",
            "WEB-API-082",
            "WEB-API-083",
            "WEB-API-084",
            "WEB-API-085",
            "WEB-API-086",
            "WEB-API-087",
            "WEB-API-088",
            "WEB-API-089",
            "WEB-API-090",
            "WEB-API-091",
            "WEB-API-092",
            "WEB-API-093",
            "WEB-API-094",
            "WEB-API-095",
            "WEB-API-096",
            "WEB-API-097",
            "WEB-API-098",
            "WEB-API-099",
            "WEB-API-100",
            "WEB-API-101",
            "WEB-API-102",
            "WEB-API-103",
            "WEB-API-104",
            "WEB-API-105",
            "WEB-API-106",
            "WEB-API-107",
            "WEB-API-108",
            "WEB-API-109",
            "WEB-API-110",
            "WEB-API-111",
            "WEB-API-112",
            "WEB-API-113",
            "WEB-API-114",
            "WEB-API-115",
            "WEB-API-116",
            "WEB-API-117",
            "WEB-API-118",
            "WEB-API-119",
            "WEB-API-120",
            "WEB-API-121",
            "WEB-API-122",
            "WEB-API-123",
            "WEB-API-124",
            "WEB-API-125",
            "WEB-API-126",
            "WEB-API-127",
            "WEB-API-128",
            "WEB-API-129",
            "WEB-API-130",
            "WEB-API-131",
            "WEB-API-132",
            "WEB-API-133",
            "WEB-API-134",
            "WEB-API-135",
            "WEB-API-136",
            "WEB-API-137",
            "WEB-API-138",
            "WEB-API-139",
            "WEB-API-140",
            "WEB-API-141",
            "WEB-API-142",
            "WEB-API-143",
            "WEB-API-144",
            "WEB-API-145",
            "WEB-API-146",
            "WEB-API-147",
            "WEB-API-148",
            "WEB-API-149",
            "WEB-API-150",
            "WEB-API-151",
            "WEB-API-152",
            "WEB-API-153",
            "WEB-API-154",
            "WEB-API-155",
            "WEB-API-156",
            "WEB-API-157",
            "WEB-API-158",
            "WEB-API-159",
            "WEB-API-160"
        ]
        #expect(
            endpoints.allSatisfy {
                $0.status.parity == (parityExactIDs.contains($0.id) ? "exact" : "deferred-p0")
            }
        )
    }

    private func loadManifest() throws -> APIManifest {
        let url = try #require(
            Bundle.module.url(
                forResource: "endpoint-manifest",
                withExtension: "json",
                subdirectory: "Fixtures/APIParity"
            )
        )
        return try JSONDecoder().decode(APIManifest.self, from: Data(contentsOf: url))
    }
}

private struct APIManifest: Decodable {
    let schemaVersion: Int
    let androidBaseline: AndroidBaseline
    let crossCuttingIssueCoverage: [String: [String]]
    let endpoints: [Endpoint]
}

private struct AndroidBaseline: Decodable {
    let sourceRevision: String
    let installedVersionName: String
    let installedVersionCode: Int
    let installedApkSHA256: String
    let controllerAggregateSHA256: String
    let controllerCount: Int
    let endpointCount: Int
    let methodCounts: [String: Int]
}

private struct Endpoint: Decodable {
    let id: String
    let phase: Int
    let method: String
    let path: String
    let status: EndpointStatus
}

private struct EndpointStatus: Decodable {
    let iosDevelopmentCompleted: Bool
    let iosUnitTestCompleted: Bool
    let androidReviewCompleted: Bool
    let parity: String
}
