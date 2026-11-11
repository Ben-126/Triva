//
//  AppleIntelligenceModelCoordinatorTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 11/11/2026.
//

import Foundation
import Testing
@testable import Triva

/// Faux moteur : texte fixe, ou erreur, en `generate` comme en flux (un yield par morceau).
private final class StubGenerating: AIGenerating, @unchecked Sendable {
    let chunks: [String]
    let error: (any Error)?
    /// Erreur levée APRÈS les morceaux (flux coupé en route), sinon avant tout morceau.
    let failsAfterChunks: Bool
    private(set) var calls = 0

    init(chunks: [String] = [], error: (any Error)? = nil, failsAfterChunks: Bool = false) {
        self.chunks = chunks
        self.error = error
        self.failsAfterChunks = failsAfterChunks
    }

    func generate(prompt: String) async throws -> String {
        calls += 1
        if let error { throw error }
        return chunks.last ?? ""
    }

    func streamGenerate(prompt: String) -> AsyncThrowingStream<String, Error> {
        calls += 1
        let chunks = failsAfterChunks || error == nil ? chunks : []
        let error = error
        return AsyncThrowingStream { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            if let error { continuation.finish(throwing: error) } else { continuation.finish() }
        }
    }
}

private final class FailureLog: @unchecked Sendable {
    var failures: [PrivateCloudFailure] = []
}

private func collect(_ stream: AsyncThrowingStream<String, Error>) async -> (chunks: [String], error: (any Error)?) {
    var chunks: [String] = []
    do {
        for try await chunk in stream { chunks.append(chunk) }
        return (chunks, nil)
    } catch {
        return (chunks, error)
    }
}

@MainActor
@Suite("AppleIntelligenceFallbackProvider")
struct AppleIntelligenceFallbackProviderTests {
    private func provider(primary: StubGenerating, fallback: StubGenerating, log: FailureLog) -> AppleIntelligenceFallbackProvider {
        AppleIntelligenceFallbackProvider(primary: primary, fallback: fallback, onFallback: { log.failures.append($0) })
    }

    @Test("Cloud qui répond : le secours n'est jamais appelé")
    func primarySucceeds() async throws {
        let primary = StubGenerating(chunks: ["cloud"])
        let fallback = StubGenerating(chunks: ["local"])
        let log = FailureLog()
        let text = try await provider(primary: primary, fallback: fallback, log: log).generate(prompt: "q")
        #expect(text == "cloud")
        #expect(fallback.calls == 0 && log.failures.isEmpty)
    }

    @Test("Quota atteint pendant l'envoi : réponse locale, sans erreur, et le coordinateur est prévenu")
    func quotaFallsBackSilently() async throws {
        let primary = StubGenerating(error: PrivateCloudFailure.quotaReached)
        let fallback = StubGenerating(chunks: ["local"])
        let log = FailureLog()
        let text = try await provider(primary: primary, fallback: fallback, log: log).generate(prompt: "q")
        #expect(text == "local")
        #expect(log.failures == [.quotaReached])
    }

    @Test("Erreur qui tient à la demande (garde-fous) ou annulation : pas de repli")
    func requestErrorsAreNotRetried() async {
        for error: any Error in [AppleIntelligenceGenerationError.guardrailViolation, CancellationError()] {
            let fallback = StubGenerating(chunks: ["local"])
            let log = FailureLog()
            await #expect(throws: (any Error).self) {
                _ = try await provider(primary: StubGenerating(error: error), fallback: fallback, log: log).generate(prompt: "q")
            }
            #expect(fallback.calls == 0 && log.failures.isEmpty)
        }
    }

    @Test("Prompt taillé pour le cloud, trop long pour l'appareil : échec générique, jamais « nouvelle conversation »")
    func fullSizePromptAfterQuotaError() async {
        let primary = StubGenerating(error: PrivateCloudFailure.quotaReached)
        let fallback = StubGenerating(error: AppleIntelligenceGenerationError.contextWindowExceeded)
        let log = FailureLog()
        await #expect(throws: AppleIntelligenceError.generationFailed(description: "privateCloud.fallbackContextExceeded")) {
            _ = try await provider(primary: primary, fallback: fallback, log: log).generate(prompt: String(repeating: "x", count: 30_000))
        }
        #expect(log.failures == [.quotaReached])
    }

    @Test("Flux : échec du cloud avant le premier morceau → flux local complet")
    func streamFallsBackBeforeFirstChunk() async {
        let primary = StubGenerating(error: PrivateCloudFailure.networkFailure)
        let fallback = StubGenerating(chunks: ["lo", "local"])
        let log = FailureLog()
        let result = await collect(provider(primary: primary, fallback: fallback, log: log).streamGenerate(prompt: "q"))
        #expect(result.chunks == ["lo", "local"])
        #expect(result.error == nil)
        #expect(log.failures == [.networkFailure])
    }

    @Test("Flux : cloud coupé APRÈS un morceau → échec générique, pas de réponse locale mélangée")
    func streamInterruptedAfterChunk() async {
        let primary = StubGenerating(chunks: ["clo"], error: PrivateCloudFailure.serviceUnavailable, failsAfterChunks: true)
        let fallback = StubGenerating(chunks: ["local"])
        let log = FailureLog()
        let result = await collect(provider(primary: primary, fallback: fallback, log: log).streamGenerate(prompt: "q"))
        #expect(result.chunks == ["clo"])
        #expect(result.error as? AppleIntelligenceError == AppleIntelligenceFallbackProvider.interruptedError)
        #expect(fallback.calls == 0)
        #expect(log.failures == [.serviceUnavailable])
    }

    @Test("Flux : erreur non liée au cloud → telle quelle, sans repli")
    func streamRequestErrorPassesThrough() async {
        let primary = StubGenerating(error: AppleIntelligenceGenerationError.refusal)
        let fallback = StubGenerating(chunks: ["local"])
        let log = FailureLog()
        let result = await collect(provider(primary: primary, fallback: fallback, log: log).streamGenerate(prompt: "q"))
        #expect(result.error as? AppleIntelligenceGenerationError == .refusal)
        #expect(fallback.calls == 0 && log.failures.isEmpty)
    }
}

@MainActor
@Suite("AppleIntelligenceModelCoordinator")
struct AppleIntelligenceModelCoordinatorTests {
    private final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 10_000)
    }

    private static func preferenceStore() -> AppleIntelligenceModelPreference {
        AppleIntelligenceModelPreference(userDefaults: UserDefaults(suiteName: "test.appleModel.\(UUID().uuidString)")!)
    }

    private func makeCoordinator(
        status: PrivateCloudStatus,
        preferenceStore: AppleIntelligenceModelPreference = preferenceStore(),
        clock: Clock = Clock(),
        cloud: StubGenerating = StubGenerating(chunks: ["cloud"])
    ) -> AppleIntelligenceModelCoordinator {
        AppleIntelligenceModelCoordinator(
            probe: FixedPrivateCloudProbe(status: status),
            preferenceStore: preferenceStore,
            now: { clock.now },
            makePrivateCloudProvider: { cloud }
        )
    }

    @Test("Cloud non proposé : provider local rendu tel quel, budget et badge d'avant A4")
    func unavailableKeepsTodaysApp() {
        let coordinator = makeCoordinator(status: .unavailable)
        let local = StubGenerating(chunks: ["local"])
        let provider = coordinator.providerForSending(local: local, isOffline: false)
        #expect(provider as? StubGenerating === local)
        #expect(coordinator.pipelineConfigurationForSending() == .appleIntelligence)
        #expect(!coordinator.isPrivateCloudOffered)
        let badge = AIEngineOption.appleIntelligence.privacyBadge(appleRoute: coordinator.displayedRoute(isOffline: false))
        #expect(badge.text == "Apple Intelligence · Sur l'appareil")
        #expect(badge.caption == "Aucune IA cloud utilisée")
    }

    @Test("Cloud disponible, défaut : cloud avec secours local, budget du cloud, badge cloud")
    func availableUsesPrivateCloud() async throws {
        let coordinator = makeCoordinator(status: .available)
        let local = StubGenerating(chunks: ["local"])
        let provider = coordinator.providerForSending(local: local, isOffline: false)
        #expect(provider is AppleIntelligenceFallbackProvider)
        #expect(try await provider.generate(prompt: "q") == "cloud")
        #expect(coordinator.pipelineConfigurationForSending() == .applePrivateCloud)
        #expect(SearchPipelineConfiguration.applePrivateCloud.promptComplexity == .full)
        #expect(coordinator.displayedRoute(isOffline: false) == .privateCloud)
    }

    @Test("Hors connexion : local et budget de l'appareil, décidés AVANT l'envoi")
    func offlineDecidedBeforeSending() {
        let coordinator = makeCoordinator(status: .available)
        let local = StubGenerating(chunks: ["local"])
        #expect(coordinator.providerForSending(local: local, isOffline: true) as? StubGenerating === local)
        #expect(coordinator.pipelineConfigurationForSending() == .appleIntelligence)
    }

    @Test("Quota déjà atteint : local, budget de l'appareil, mention sous le badge")
    func quotaKnownBeforeSending() {
        let coordinator = makeCoordinator(status: .quotaReached)
        let local = StubGenerating(chunks: ["local"])
        #expect(coordinator.providerForSending(local: local, isOffline: false) as? StubGenerating === local)
        #expect(coordinator.pipelineConfigurationForSending() == .appleIntelligence)
        #expect(coordinator.isPrivateCloudOffered)
        let badge = AIEngineOption.appleIntelligence.privacyBadge(appleRoute: coordinator.displayedRoute(isOffline: false))
        #expect(badge.caption.contains("Limite du cloud privé"))
    }

    @Test("Échec réseau pendant un envoi : réponse locale, puis appareil pendant 5 min ; l'échéance passée, le badge change AVANT tout envoi au cloud")
    func runtimeFailureSuspendsCloud() async throws {
        let clock = Clock()
        let coordinator = makeCoordinator(status: .available, clock: clock, cloud: StubGenerating(error: PrivateCloudFailure.networkFailure))
        let local = StubGenerating(chunks: ["local"])
        let provider = coordinator.providerForSending(local: local, isOffline: false)
        #expect(try await provider.generate(prompt: "q") == "local")
        await waitUntil("le repli est enregistré") { coordinator.suspendedUntil != nil }

        #expect(coordinator.displayedRoute(isOffline: false) == AppleModelRoute(kind: .onDevice, fallback: .privateCloudFailed))
        #expect(coordinator.providerForSending(local: local, isOffline: false) as? StubGenerating === local)
        #expect(coordinator.pipelineConfigurationForSending() == .appleIntelligence)

        // Échéance passée, aucun relevé : le badge dit toujours « appareil », l'envoi aussi.
        clock.now = clock.now.addingTimeInterval(AppleIntelligenceModelRouter.suspensionDuration)
        #expect(coordinator.displayedRoute(isOffline: false).kind == .onDevice)
        #expect(coordinator.providerForSending(local: local, isOffline: false) as? StubGenerating === local)
        // Ce même envoi a levé la mise de côté : le badge passe au cloud, l'envoi SUIVANT aussi.
        #expect(coordinator.displayedRoute(isOffline: false) == .privateCloud)
        #expect(coordinator.providerForSending(local: local, isOffline: false) is AppleIntelligenceFallbackProvider)
    }

    private final class MutableProbe: PrivateCloudAvailabilityProbing, @unchecked Sendable {
        var status: PrivateCloudStatus
        init(_ status: PrivateCloudStatus) { self.status = status }
        func currentStatus() -> PrivateCloudStatus { status }
    }

    private func makeCoordinator(probe: MutableProbe) -> AppleIntelligenceModelCoordinator {
        AppleIntelligenceModelCoordinator(
            probe: probe,
            preferenceStore: Self.preferenceStore(),
            makePrivateCloudProvider: { StubGenerating(chunks: ["cloud"]) }
        )
    }

    @Test("Quota revenu entre l'affichage et l'envoi : CET envoi reste local, le badge passe au cloud pour le suivant")
    func widerStatusNeverAppliesToCurrentSend() {
        let probe = MutableProbe(.quotaReached)
        let coordinator = makeCoordinator(probe: probe)
        #expect(coordinator.displayedRoute(isOffline: false).kind == .onDevice)
        probe.status = .available
        let local = StubGenerating(chunks: ["local"])
        #expect(coordinator.providerForSending(local: local, isOffline: false) as? StubGenerating === local)
        #expect(coordinator.pipelineConfigurationForSending() == .appleIntelligence)
        #expect(coordinator.displayedRoute(isOffline: false) == .privateCloud)
        #expect(coordinator.providerForSending(local: local, isOffline: false) is AppleIntelligenceFallbackProvider)
    }

    @Test("Cloud devenu indisponible entre l'affichage et l'envoi : CET envoi passe déjà sur l'appareil")
    func narrowerStatusAppliesImmediately() {
        let probe = MutableProbe(.available)
        let coordinator = makeCoordinator(probe: probe)
        #expect(coordinator.displayedRoute(isOffline: false) == .privateCloud)
        probe.status = .quotaReached
        let local = StubGenerating(chunks: ["local"])
        #expect(coordinator.providerForSending(local: local, isOffline: false) as? StubGenerating === local)
        #expect(coordinator.pipelineConfigurationForSending() == .appleIntelligence)
        #expect(coordinator.displayedRoute(isOffline: false) == AppleModelRoute(kind: .onDevice, fallback: .quotaReached))
    }

    @Test("Quota atteint pendant un envoi : état « quota » et mention sous le badge")
    func runtimeQuotaUpdatesBadge() {
        let coordinator = makeCoordinator(status: .available)
        coordinator.recordFailure(.quotaReached)
        #expect(coordinator.status == .quotaReached)
        #expect(coordinator.displayedRoute(isOffline: false) == AppleModelRoute(kind: .onDevice, fallback: .quotaReached))
    }

    @Test("Choix « sur l'appareil » : provider local même cloud disponible")
    func userChoosesOnDevice() {
        let coordinator = makeCoordinator(status: .available)
        coordinator.preference = .onDevice
        let local = StubGenerating(chunks: ["local"])
        #expect(coordinator.providerForSending(local: local, isOffline: false) as? StubGenerating === local)
        #expect(coordinator.displayedRoute(isOffline: false) == .onDevice)
    }

    @Test("Réglage persistant : relu par une nouvelle instance, `nil` tant que rien n'est choisi")
    func preferencePersists() {
        let store = Self.preferenceStore()
        let first = makeCoordinator(status: .available, preferenceStore: store)
        #expect(first.preference == nil)
        #expect(first.effectivePreference == .privateCloud)
        first.effectivePreference = .onDevice
        #expect(store.read() == .onDevice)
        #expect(makeCoordinator(status: .available, preferenceStore: store).preference == .onDevice)
    }

    @Test("Valeur illisible dans les préférences : défaut, sans plantage")
    func unreadablePreference() {
        let defaults = UserDefaults(suiteName: "test.appleModel.\(UUID().uuidString)")!
        defaults.set("autreChose", forKey: AppleIntelligenceModelPreference.storageKey)
        #expect(AppleIntelligenceModelPreference(userDefaults: defaults).read() == nil)
    }

    @Test("`shared` sous les tests : cloud jamais proposé")
    func sharedIsFrozenUnderTests() {
        #expect(!AppleIntelligenceModelCoordinator.shared.isPrivateCloudOffered)
    }

    private func waitUntil(_ message: String, _ condition: @MainActor () -> Bool) async {
        for _ in 0..<2_000 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("Timeout en attendant : \(message)")
    }
}

/// `SearchSession` + coordinateur injecté : le provider, le budget et le badge d'un même envoi
/// décrivent le même modèle. La branche « cloud » demande que le modèle LOCAL soit disponible sur
/// la machine (le résolveur le vérifie d'abord) ; sinon elle est sautée en le disant.
@MainActor
@Suite("SearchSession — cloud privé d'Apple")
struct SearchSessionPrivateCloudTests {
    private func makeStores() throws -> TrivaSharedStores {
        let userDefaults = UserDefaults(suiteName: "test.searchSession.pcc.\(UUID().uuidString)")!
        return TrivaSharedStores(
            userDefaults: userDefaults,
            container: try TrivaModelContainer.makeInMemory(),
            isHistoryStorageVolatile: false,
            searchInstances: CustomInstanceStore(defaultInstances: [URL(string: "https://searx.example")!], userDefaults: userDefaults),
            keyStore: MockKeyStore()
        )
    }

    private struct MockKeyStore: APIKeyStoring {
        func apiKey(account: String) throws -> String? { nil }
        func save(apiKey: String, account: String) throws {}
        func deleteAPIKey(account: String) throws {}
    }

    private func coordinator(_ status: PrivateCloudStatus) -> AppleIntelligenceModelCoordinator {
        AppleIntelligenceModelCoordinator(
            probe: FixedPrivateCloudProbe(status: status),
            preferenceStore: AppleIntelligenceModelPreference(userDefaults: UserDefaults(suiteName: "test.appleModel.\(UUID().uuidString)")!),
            makePrivateCloudProvider: { StubGenerating(chunks: ["cloud"]) }
        )
    }

    private var isLocalModelAvailable: Bool { AppleIntelligenceProvider().availabilityError == nil }

    @Test("Cloud non proposé : provider local et budget de l'appareil, comme avant A4")
    func unavailable() async throws {
        guard isLocalModelAvailable else {
            Issue.record("Apple Intelligence indisponible sur cette machine : branche non exercée.", severity: .warning)
            return
        }
        let session = SearchSession(engine: .appleIntelligence, stores: try makeStores(), appleModel: coordinator(.unavailable))
        let provider = try await session.resolveProviderForSending()
        #expect(provider is AppleIntelligenceProvider)
        #expect(session.pipelineConfigurationForSending() == .appleIntelligence)
    }

    @Test("Cloud proposé : cloud avec secours local, budget du cloud, dans le même envoi")
    func available() async throws {
        guard isLocalModelAvailable else {
            Issue.record("Apple Intelligence indisponible sur cette machine : branche non exercée.", severity: .warning)
            return
        }
        let session = SearchSession(engine: .appleIntelligence, stores: try makeStores(), appleModel: coordinator(.available))
        let provider = try await session.resolveProviderForSending()
        #expect(provider is AppleIntelligenceFallbackProvider)
        #expect(session.pipelineConfigurationForSending() == .applePrivateCloud)
        #expect(try await provider.generate(prompt: "q") == "cloud")
    }

    @Test("Moteur cloud BYOK : le coordinateur Apple n'intervient jamais")
    func otherEnginesUntouched() async throws {
        let session = SearchSession(engine: .cloudBYOK, stores: try makeStores(), appleModel: coordinator(.available))
        #expect(session.pipelineConfigurationForSending() == .cloud)
    }
}
