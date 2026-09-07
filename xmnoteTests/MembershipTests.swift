import Foundation
import GRDB
import Testing
import XMNoteWeb
@testable import xmnote

#if DEBUG
@MainActor
struct MembershipTests {
    private func sourceURL() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "MembershipTests/\(UUID().uuidString)/transaction.json")
    }

    @Test func purchasePersistsRevocationAndReset() async throws {
        let url = sourceURL()
        let source = SimulatedMembershipSource(fileURL: url)
        let repository = MembershipRepository(source: source)
        await repository.refresh()
        #expect(!(await repository.hasPremiumAccess()))
        await repository.purchase()
        #expect(await repository.hasPremiumAccess())
        let first = await repository.snapshot().entitlement.transactionID
        await repository.purchase()
        #expect(await repository.snapshot().entitlement.transactionID == first)
        let restarted = MembershipRepository(source: SimulatedMembershipSource(fileURL: url))
        await restarted.refresh()
        #expect(await restarted.hasPremiumAccess())
        await restarted.simulate(.revoke)
        await restarted.restore()
        #expect(!(await restarted.hasPremiumAccess()))
        #expect(await restarted.snapshot().entitlement.status == .revoked)
        await restarted.purchase()
        #expect(await restarted.snapshot().entitlement.transactionID != first)
        #expect(await restarted.hasPremiumAccess())
        await restarted.simulate(.reset)
        #expect(await restarted.snapshot().entitlement.status == .notPurchased)
        let resetRestart = MembershipRepository(source: SimulatedMembershipSource(fileURL: url))
        await resetRestart.refresh()
        #expect(!(await resetRestart.hasPremiumAccess()))
    }

    @Test func cancelledFailedAndPendingDoNotGrantAccess() async throws {
        let url = sourceURL()
        let repository = MembershipRepository(source: SimulatedMembershipSource(fileURL: url))
        await repository.refresh()
        await repository.simulate(.nextOutcome(.cancelled))
        await repository.purchase()
        #expect(!(await repository.hasPremiumAccess()))
        await repository.simulate(.nextOutcome(.failure))
        await repository.purchase()
        #expect(!(await repository.hasPremiumAccess()))
        #expect(await repository.snapshot().errorMessage != nil)
        await repository.simulate(.nextOutcome(.pending))
        await repository.purchase()
        #expect(await repository.snapshot().entitlement.hasPendingPurchase)
        #expect(!(await repository.hasPremiumAccess()))
        let restarted = MembershipRepository(source: SimulatedMembershipSource(fileURL: url))
        await restarted.refresh()
        #expect(await restarted.snapshot().entitlement.hasPendingPurchase)
        await restarted.purchase()
        #expect(!(await restarted.hasPremiumAccess()))
        await restarted.simulate(.rejectPending)
        #expect(!(await restarted.snapshot().entitlement.hasPendingPurchase))
        await restarted.simulate(.nextOutcome(.pending))
        await restarted.purchase()
        await restarted.simulate(.approvePending)
        #expect(await restarted.hasPremiumAccess())
    }

    @Test func corruptRecordRequiresExplicitReset() async throws {
        let url = sourceURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("corrupt".utf8).write(to: url)
        let repository = MembershipRepository(source: SimulatedMembershipSource(fileURL: url))
        await repository.refresh()
        #expect(!(await repository.hasPremiumAccess()))
        #expect(!(await repository.snapshot().isLoaded))
        #expect(await repository.snapshot().errorMessage != nil)
        await repository.purchase()
        #expect(!(await repository.hasPremiumAccess()))
        await repository.simulate(.reset)
        #expect(await repository.snapshot().isLoaded)
        await repository.purchase()
        #expect(await repository.hasPremiumAccess())
        #expect(try url.deletingLastPathComponent().resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }

    @Test func corruptRecordDuringRestoreOrRevokeClearsConfirmedAccess() async throws {
        for usesRestore in [true, false] {
            let url = sourceURL()
            let source = SimulatedMembershipSource(fileURL: url)
            _ = try await source.purchase()
            let repository = MembershipRepository(source: source)
            await repository.refresh()
            #expect(await repository.hasPremiumAccess())
            try Data("corrupt".utf8).write(to: url)
            if usesRestore {
                await repository.restore()
            } else {
                await repository.simulate(.revoke)
            }
            #expect(!(await repository.hasPremiumAccess()))
            #expect(!(await repository.snapshot().isLoaded))
            #expect(await repository.snapshot().errorMessage == MembershipError.corruptSimulation.localizedDescription)
        }
    }

    @Test func unavailableSourceNeverGrantsSimulatedPurchase() async throws {
        let simulation = MembershipRepository(source: SimulatedMembershipSource(fileURL: sourceURL()))
        await simulation.refresh()
        await simulation.purchase()
        let production = MembershipRepository(source: UnavailableMembershipSource())
        await production.refresh()
        await production.purchase()
        await production.restore()
        #expect(!(await production.hasPremiumAccess()))
        #expect(await production.product().purchaseAvailable == false)
        #expect(await production.snapshot().errorMessage == MembershipError.unavailable.localizedDescription)
    }

    @Test func refreshingFailureKeepsConfirmedEntitlement() async throws {
        let source = ControlledMembershipSource()
        let repository = MembershipRepository(source: source)
        #expect(!(await repository.hasPremiumAccess()))
        await source.setFailure(true)
        await repository.refresh()
        #expect(!(await repository.snapshot().isLoaded))
        await source.setFailure(false)
        await repository.refresh()
        #expect(await repository.hasPremiumAccess())
        await source.setFailure(true)
        await repository.refresh()
        #expect(await repository.hasPremiumAccess())
        #expect(await repository.snapshot().errorMessage != nil)
    }

    @Test func staleRefreshCannotOverrideReset() async throws {
        let source = ControlledMembershipSource()
        let repository = MembershipRepository(source: source)
        await repository.refresh()
        await source.holdRead()
        let refresh = Task { await repository.refresh() }
        await source.waitForHeldRead()
        await repository.simulate(.reset)
        await source.releaseRead()
        await refresh.value
        #expect(await repository.snapshot().entitlement.status == .notPurchased)
        #expect(!(await repository.hasPremiumAccess()))
    }

    @Test func concurrentPurchasesAreCoalescedAndDuplicateUpdatesAreIdempotent() async throws {
        let source = ControlledMembershipSource(initiallyPremium: false)
        let repository = MembershipRepository(source: source)
        await repository.refresh()
        await source.holdPurchase()
        let purchase = Task { await repository.purchase() }
        await source.waitForHeldPurchase()
        await repository.purchase()
        #expect(await source.purchaseCount == 1)
        await source.releasePurchase()
        await purchase.value
        let first = await repository.snapshot().entitlement.transactionID
        await repository.refresh()
        await repository.refresh()
        #expect(await repository.snapshot().entitlement.transactionID == first)
    }

    @Test func sourceNotificationsRevokeAccessWithoutManualRefresh() async throws {
        let source = SimulatedMembershipSource(fileURL: sourceURL())
        let repository = MembershipRepository(source: source)
        await repository.refresh()
        await repository.purchase()
        #expect(await repository.hasPremiumAccess())
        let states = await repository.states()
        try await source.simulate(.revoke)
        // Repeated notifications/readback must not restore a revoked transaction.
        try await source.simulate(.revoke)
        for await state in states {
            if state.entitlement.status == .revoked {
                #expect(!state.isPremium)
                break
            }
        }
        #expect(!(await repository.hasPremiumAccess()))
    }

    @Test func premiumImportChecksEachBookBeforeItsTransaction() async throws {
        let membership = MembershipRepository(source: SimulatedMembershipSource(fileURL: sourceURL()))
        await membership.refresh()
        await membership.purchase()
        let database = try AppDatabase.empty()
        let repository = NoteImportRepository(databaseManager: DatabaseManager(database: database), requiredMembership: membership)
        var first = NoteImportDraftBook(); first.name = "会员测试一"; first.rawName = first.name
        var second = NoteImportDraftBook(); second.name = "会员测试二"; second.rawName = second.name
        // Separate calls establish the same per-book boundary used by the import loop.
        try await repository.commitImport(books: [.init(draft: first)]) { _, _ in }
        await membership.simulate(.revoke)
        await #expect(throws: MembershipError.self) {
            try await repository.commitImport(books: [.init(draft: second)]) { _, _ in }
        }
        let names = try await database.dbPool.read { db in try BookRecord.fetchAll(db).map(\.name) }
        #expect(names.contains(first.name))
        #expect(!names.contains(second.name))
    }
    @Test func importRechecksAccessInsideTheBookLoop() async throws {
        let gate = SingleBookAccessRepository()
        let database = try AppDatabase.empty()
        let repository = NoteImportRepository(databaseManager: DatabaseManager(database: database), requiredMembership: gate)
        var first = NoteImportDraftBook(); first.name = "批次第一本"; first.rawName = first.name
        var second = NoteImportDraftBook(); second.name = "批次第二本"; second.rawName = second.name
        await #expect(throws: MembershipError.self) {
            try await repository.commitImport(books: [.init(draft: first), .init(draft: second)]) { _, _ in }
        }
        #expect(await gate.checkCount == 2)
        let names = try await database.dbPool.read { db in try BookRecord.fetchAll(db).map(\.name) }
        #expect(names.contains(first.name))
        #expect(!names.contains(second.name))
    }

    @Test func quotaAndDesktopReadTheCurrentEntitlement() async throws {
        let membership = MembershipRepository(source: SimulatedMembershipSource(fileURL: sourceURL()))
        await membership.refresh()
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let quota = NoteImageUploadQuotaRepository(
            configRepository: MembershipS3Config(), appBackendConfigRepository: MembershipBackendConfig(),
            userDefaults: defaults, membership: membership
        )
        let adapter = DesktopWebAPIAdapter(
            repository: DesktopWebSettingsRepository(defaults: defaults),
            nativeActionBridge: DesktopWebNativeActionBridge(), defaults: defaults,
            isPremiumProvider: { await membership.hasPremiumAccess() }
        )
        #expect(await adapter.isDesktopReadOnly())
        let free = await quota.reserveImages(id: "free", owner: .note(bookID: 1, noteID: 0), currentDraftNewImageCount: 0, requestedCount: 3)
        #expect(free.acceptedCount == 2)
        await quota.releaseReservation(id: "free")
        await membership.purchase()
        #expect(!(await adapter.isDesktopReadOnly()))
        let premium = await quota.reserveImages(id: "premium", owner: .note(bookID: 1, noteID: 0), currentDraftNewImageCount: 0, requestedCount: 3)
        #expect(premium.acceptedCount == 3)
        await membership.simulate(.revoke)
        #expect(await adapter.isDesktopReadOnly())
        #expect(!(await adapter.membershipCapability().isPremium))
        let revoked = await quota.reserveImages(id: "after", owner: .note(bookID: 2, noteID: 0), currentDraftNewImageCount: 0, requestedCount: 3)
        #expect(revoked.acceptedCount < 3)
    }

}

private actor ControlledMembershipSource: MembershipSimulationSource {
    var entitlement: MembershipEntitlement
    var failure = false
    var shouldHoldRead = false
    var shouldHoldPurchase = false
    var readContinuation: CheckedContinuation<Void, Never>?
    var purchaseContinuation: CheckedContinuation<Void, Never>?
    var readWaiter: CheckedContinuation<Void, Never>?
    var purchaseWaiter: CheckedContinuation<Void, Never>?
    private(set) var purchaseCount = 0

    init(initiallyPremium: Bool = true) {
        entitlement = initiallyPremium ? .init(status: .lifetime, source: .development, transactionID: "transaction", purchasedAt: Date()) : .init(source: .development)
    }
    func product() async -> MembershipProduct { .init(title: "Test", purchaseAvailable: true, isSimulation: true) }
    func updates() async -> AsyncStream<Void> { AsyncStream { $0.finish() } }
    func currentEntitlement() async throws -> MembershipEntitlement {
        if failure { throw MembershipError.simulatedFailure }
        let captured = entitlement
        if shouldHoldRead {
            shouldHoldRead = false
            await withCheckedContinuation { continuation in
                readContinuation = continuation
                readWaiter?.resume(); readWaiter = nil
            }
        }
        return captured
    }
    func purchase() async throws -> MembershipPurchaseResult {
        purchaseCount += 1
        if shouldHoldPurchase {
            await withCheckedContinuation { continuation in
                purchaseContinuation = continuation
                purchaseWaiter?.resume(); purchaseWaiter = nil
            }
        }
        entitlement = .init(status: .lifetime, source: .development, transactionID: "transaction", purchasedAt: Date())
        return .success(entitlement)
    }
    func restore() async throws -> MembershipEntitlement { entitlement }
    func simulate(_ command: MembershipSimulationCommand) async throws { entitlement = .init(source: .development) }
    func setFailure(_ value: Bool) { failure = value }
    func holdRead() { shouldHoldRead = true }
    func holdPurchase() { shouldHoldPurchase = true }
    func waitForHeldRead() async { if readContinuation == nil { await withCheckedContinuation { readWaiter = $0 } } }
    func waitForHeldPurchase() async { if purchaseContinuation == nil { await withCheckedContinuation { purchaseWaiter = $0 } } }
    func releaseRead() { readContinuation?.resume(); readContinuation = nil }
    func releasePurchase() { purchaseContinuation?.resume(); purchaseContinuation = nil }
}

@MainActor private struct MembershipS3Config: S3ConfigRepositoryProtocol {
    func fetchConfigs() async throws -> [S3Config] { [] }
    func fetchCurrentConfig() async throws -> S3Config? { nil }
    func saveConfig(_ input: S3ConfigFormInput, editingConfig: S3Config?) async throws -> S3Config { throw MembershipError.unavailable }
    func delete(_ config: S3Config) async throws {}
    func select(_ config: S3Config) async throws {}
    func testConnection(_ input: S3ConfigFormInput) async throws {}
}
private actor MembershipBackendConfig: AppBackendConfigRepositoryProtocol {
    func queryValue(key: String) async -> String? { "2" }
}

private actor SingleBookAccessRepository: MembershipRepositoryProtocol {
    private(set) var checkCount = 0
    func snapshot() -> MembershipSnapshot { .init() }
    func states() -> AsyncStream<MembershipSnapshot> { AsyncStream { $0.finish() } }
    func product() -> MembershipProduct { .init(title: "Test", purchaseAvailable: false, isSimulation: false) }
    func refresh() {}
    func purchase() {}
    func restore() {}
    func hasPremiumAccess() -> Bool { checkCount == 0 }
    func requirePremium() throws {
        checkCount += 1
        guard checkCount == 1 else { throw MembershipError.required }
    }
}
#endif
