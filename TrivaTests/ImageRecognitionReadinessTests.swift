//
//  ImageRecognitionReadinessTests.swift
//  TrivaTests
//
//  W4-V : la première lecture d'image coûte ~40 s à froid (compilation système du modèle de Vision). La préparation à
//  l'avance est testée ici avec des FAUX (préparateur, registre, conditions de l'appareil) : aucun vrai Vision.
//

import Foundation
import Synchronization
import Testing
@testable import Triva

// MARK: - Faux

/// Préparateur factice : retient l'appel jusqu'à `release()` (ou l'annulation), compte ses appels, note la priorité.
final class GatedPreparer: ImageRecognitionPreparing, @unchecked Sendable {
    private struct Snapshot {
        var callCount = 0
        var cancelledCount = 0
        var priorities: [TaskPriority] = []
        var failure: (any Error)?
    }

    private let state = Mutex(Snapshot())
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init(failure: (any Error)? = nil) {
        (stream, continuation) = AsyncStream<Void>.makeStream()
        state.withLock { $0.failure = failure }
    }

    var callCount: Int { state.withLock { $0.callCount } }
    var cancelledCount: Int { state.withLock { $0.cancelledCount } }
    var priorities: [TaskPriority] { state.withLock { $0.priorities } }

    func setFailure(_ error: (any Error)?) { state.withLock { $0.failure = error } }
    func release() { continuation.yield() }

    func prepareRecognition() async throws {
        let failure = state.withLock { snapshot -> (any Error)? in
            snapshot.callCount += 1
            snapshot.priorities.append(Task.currentPriority)
            return snapshot.failure
        }
        if let failure { throw failure }
        for await _ in stream { break }
        if Task.isCancelled {
            state.withLock { $0.cancelledCount += 1 }
            throw CancellationError()
        }
    }
}

final class MemoryLedger: ImageRecognitionPreparationLedger, @unchecked Sendable {
    private let stored = Mutex<String?>(nil)
    init(preparedKey: String? = nil) { stored.withLock { $0 = preparedKey } }
    var preparedKey: String? { stored.withLock { $0 } }
    func markPrepared(key: String) { stored.withLock { $0 = key } }
}

final class FakeConditions: DeviceConditionsProviding, @unchecked Sendable {
    private struct Values { var lowPower = false; var thermal = ProcessInfo.ThermalState.nominal }
    private let values = Mutex(Values())
    var isLowPowerModeEnabled: Bool { values.withLock { $0.lowPower } }
    var thermalState: ProcessInfo.ThermalState { values.withLock { $0.thermal } }
    func set(lowPower: Bool? = nil, thermal: ProcessInfo.ThermalState? = nil) {
        values.withLock { values in
            if let lowPower { values.lowPower = lowPower }
            if let thermal { values.thermal = thermal }
        }
    }
}

private struct SomeFailure: Error {}

@MainActor
private func waitFor(timeout: Duration = .seconds(10), _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

@MainActor
private func makeReadiness(
    preparer: GatedPreparer = GatedPreparer(),
    ledger: MemoryLedger = MemoryLedger(),
    conditions: FakeConditions = FakeConditions(),
    key: String = "2.0(10)-27A1",
    startDelay: Duration = .zero
) -> ImageRecognitionReadiness {
    ImageRecognitionReadiness(preparer: preparer, ledger: ledger, conditions: conditions, key: key, startDelay: startDelay)
}

// MARK: - Règles pures

@Suite("Préparation de la lecture d'image — règles")
struct ImageRecognitionPreparationRulesTests {
    @Test("Appareil normal : on peut préparer ; économie d'énergie ou chaleur : on remet à plus tard", arguments: [
        (false, ProcessInfo.ThermalState.nominal, ImageRecognitionDeferralReason?.none),
        (true, .nominal, .lowPowerMode),
        (false, .fair, .deviceHot),
        (false, .serious, .deviceHot),
        (false, .critical, .deviceHot),
        (true, .serious, .lowPowerMode),
    ])
    func policy(lowPower: Bool, thermal: ProcessInfo.ThermalState, expected: ImageRecognitionDeferralReason?) {
        #expect(ImageRecognitionPreparationPolicy.deferralReason(isLowPowerModeEnabled: lowPower, thermalState: thermal) == expected)
    }

    @Test("La clé change avec la version, le numéro de build et la version du système")
    func keyChanges() {
        let base = ImageRecognitionPreparationKey.make(appVersion: "2.0", appBuild: "10", systemBuild: "27A1")
        #expect(base == ImageRecognitionPreparationKey.make(appVersion: "2.0", appBuild: "10", systemBuild: "27A1"))
        #expect(base != ImageRecognitionPreparationKey.make(appVersion: "2.1", appBuild: "10", systemBuild: "27A1"))
        #expect(base != ImageRecognitionPreparationKey.make(appVersion: "2.0", appBuild: "11", systemBuild: "27A1"))
        #expect(base != ImageRecognitionPreparationKey.make(appVersion: "2.0", appBuild: "10", systemBuild: "27A2"))
    }

    @Test("Le registre sur UserDefaults se souvient de la clé")
    func userDefaultsLedgerRoundTrip() throws {
        let suite = "ImageRecognitionLedgerTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let ledger = UserDefaultsPreparationLedger(defaults: defaults)
        #expect(ledger.preparedKey == nil)
        ledger.markPrepared(key: "2.0(10)-27A1")
        #expect(ledger.preparedKey == "2.0(10)-27A1")
    }
}

// MARK: - Cycle de vie

@MainActor
@Suite("Préparation de la lecture d'image — cycle de vie")
struct ImageRecognitionReadinessTests {
    @Test("Au lancement : une préparation en priorité moyenne (utility, F3), puis « prête » et clé enregistrée")
    func startsOnceThenReady() async {
        let preparer = GatedPreparer()
        let ledger = MemoryLedger()
        let readiness = makeReadiness(preparer: preparer, ledger: ledger)
        #expect(readiness.state == .idle)

        readiness.startIfNeeded()
        #expect(await waitFor { preparer.callCount == 1 })
        #expect(readiness.state == .preparing)
        #expect(readiness.isPreparing)
        let priority = preparer.priorities[0]
        #expect(priority == .utility, "priorité : \(priority)")

        readiness.startIfNeeded()  // deuxième passage au premier plan pendant la préparation
        preparer.release()
        #expect(await waitFor { readiness.state == .ready })
        #expect(ledger.preparedKey == "2.0(10)-27A1")
        #expect(preparer.callCount == 1)
        #expect(!readiness.isPreparing)
    }

    @Test("Déjà préparée pour cette version : rien à refaire")
    func alreadyPreparedForThisKey() async {
        let preparer = GatedPreparer()
        let readiness = makeReadiness(preparer: preparer, ledger: MemoryLedger(preparedKey: "2.0(10)-27A1"))

        readiness.startIfNeeded()
        #expect(readiness.state == .ready)
        readiness.prepareForUserRequest()
        #expect(readiness.state == .ready)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(preparer.callCount == 0)
    }

    @Test("Nouvelle version de l'app : la préparation est refaite")
    func newVersionPreparesAgain() async {
        let preparer = GatedPreparer()
        let ledger = MemoryLedger(preparedKey: "1.9(9)-27A1")
        let readiness = makeReadiness(preparer: preparer, ledger: ledger)

        readiness.startIfNeeded()
        #expect(await waitFor { preparer.callCount == 1 })
        preparer.release()
        #expect(await waitFor { readiness.state == .ready })
        #expect(ledger.preparedKey == "2.0(10)-27A1")
    }

    @Test("Le délai de lancement : état « programmée », pas encore d'appel")
    func startDelayKeepsLaunchFree() async {
        let preparer = GatedPreparer()
        let readiness = makeReadiness(preparer: preparer, startDelay: .seconds(30))

        readiness.startIfNeeded()
        #expect(readiness.state == .scheduled)
        #expect(!readiness.isPreparing)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(preparer.callCount == 0)
    }

    @Test("Une image arrive pendant le délai : la préparation part tout de suite, en priorité normale")
    func userRequestSkipsDelay() async {
        let preparer = GatedPreparer()
        let readiness = makeReadiness(preparer: preparer, startDelay: .seconds(30))
        readiness.startIfNeeded()

        readiness.prepareForUserRequest()
        #expect(readiness.state == .preparing)
        #expect(await waitFor { preparer.callCount == 1 })
        #expect(preparer.priorities[0].rawValue >= TaskPriority.userInitiated.rawValue)
        preparer.release()
        #expect(await waitFor { readiness.state == .ready })
        #expect(preparer.callCount == 1)
    }

    @Test("Une image arrive pendant la préparation : pas de deuxième préparation")
    func userRequestDuringPreparationDoesNotRestart() async {
        let preparer = GatedPreparer()
        let readiness = makeReadiness(preparer: preparer)
        readiness.startIfNeeded()
        #expect(await waitFor { preparer.callCount == 1 })

        readiness.prepareForUserRequest()
        readiness.prepareForUserRequest()
        #expect(readiness.state == .preparing)
        preparer.release()
        #expect(await waitFor { readiness.state == .ready })
        #expect(preparer.callCount == 1)
    }
}

// MARK: - Conditions de l'appareil

@MainActor
@Suite("Préparation de la lecture d'image — économie d'énergie et chaleur")
struct ImageRecognitionConditionsTests {
    @Test("Économie d'énergie : rien ne démarre, puis la préparation part quand elle est coupée")
    func lowPowerModeDefers() async {
        let preparer = GatedPreparer()
        let conditions = FakeConditions()
        conditions.set(lowPower: true)
        let readiness = makeReadiness(preparer: preparer, conditions: conditions)

        readiness.startIfNeeded()
        #expect(readiness.state == .deferred(.lowPowerMode))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(preparer.callCount == 0)

        conditions.set(lowPower: false)
        readiness.conditionsDidChange()
        #expect(await waitFor { preparer.callCount == 1 })
        #expect(readiness.state == .preparing)
    }

    @Test("Appareil chaud : remis à plus tard, avec la bonne raison")
    func hotDeviceDefers() {
        let conditions = FakeConditions()
        conditions.set(thermal: .serious)
        let readiness = makeReadiness(conditions: conditions)

        readiness.startIfNeeded()
        #expect(readiness.state == .deferred(.deviceHot))
    }

    @Test("Les conditions se dégradent PENDANT la préparation, personne n'attend : elle est annulée")
    func degradedConditionsCancelBackgroundPreparation() async {
        let preparer = GatedPreparer()
        let conditions = FakeConditions()
        let readiness = makeReadiness(preparer: preparer, conditions: conditions)
        readiness.startIfNeeded()
        #expect(await waitFor { preparer.callCount == 1 })

        conditions.set(lowPower: true)
        readiness.conditionsDidChange()

        #expect(readiness.state == .deferred(.lowPowerMode))
        #expect(await waitFor { preparer.cancelledCount == 1 })
        #expect(readiness.state == .deferred(.lowPowerMode), "l'annulation volontaire ne doit pas écraser l'état")
    }

    @Test("Les conditions se dégradent mais l'utilisateur attend une image : la préparation continue")
    func userWaitingKeepsPreparationAlive() async {
        let preparer = GatedPreparer()
        let conditions = FakeConditions()
        let readiness = makeReadiness(preparer: preparer, conditions: conditions)
        readiness.startIfNeeded()
        #expect(await waitFor { preparer.callCount == 1 })
        readiness.prepareForUserRequest()

        conditions.set(thermal: .serious)
        readiness.conditionsDidChange()

        #expect(readiness.state == .preparing)
        preparer.release()
        #expect(await waitFor { readiness.state == .ready })
        #expect(preparer.cancelledCount == 0)
    }

    @Test("Une image attend alors que l'appareil est chaud : l'utilisateur passe avant, la préparation part")
    func userRequestIgnoresConditions() async {
        let preparer = GatedPreparer()
        let conditions = FakeConditions()
        conditions.set(lowPower: true, thermal: .serious)
        let readiness = makeReadiness(preparer: preparer, conditions: conditions)
        readiness.startIfNeeded()
        #expect(readiness.state == .deferred(.lowPowerMode))

        readiness.prepareForUserRequest()

        #expect(readiness.state == .preparing)
        #expect(await waitFor { preparer.callCount == 1 })
        #expect(preparer.priorities[0].rawValue >= TaskPriority.userInitiated.rawValue)
    }

    @Test("L'image est retirée puis l'économie d'énergie s'active : plus personne n'attend, la préparation est annulée")
    func releasedUserRequestLetsConditionsCancel() async {
        let preparer = GatedPreparer()
        let conditions = FakeConditions()
        let readiness = makeReadiness(preparer: preparer, conditions: conditions)
        readiness.prepareForUserRequest()
        #expect(await waitFor { preparer.callCount == 1 })
        conditions.set(lowPower: true)
        readiness.conditionsDidChange()
        #expect(readiness.state == .preparing, "tant qu'une image attend, on continue")

        readiness.userRequestDidEnd()

        #expect(readiness.state == .deferred(.lowPowerMode))
        #expect(await waitFor { preparer.cancelledCount == 1 })
    }

    @Test("Fin d'attente sans rien d'attendu ou sur un appareil calme : la préparation continue")
    func userRequestEndWithoutDegradedConditions() async {
        let preparer = GatedPreparer()
        let readiness = makeReadiness(preparer: preparer)
        readiness.userRequestDidEnd()
        #expect(readiness.state == .idle)
        readiness.prepareForUserRequest()
        #expect(await waitFor { preparer.callCount == 1 })

        readiness.userRequestDidEnd()

        #expect(readiness.state == .preparing)
        preparer.release()
        #expect(await waitFor { readiness.state == .ready })
    }

    @Test("Les conditions changent alors qu'elles étaient déjà bonnes : rien ne bouge")
    func conditionsChangeWithoutEffect() {
        let readiness = makeReadiness()
        readiness.conditionsDidChange()
        #expect(readiness.state == .idle)
    }

    @Test("Les notifications du système (chaleur, économie d'énergie) rappellent l'évaluation")
    func systemNotificationsTriggerReevaluation() async {
        let preparer = GatedPreparer()
        let conditions = FakeConditions()
        conditions.set(lowPower: true)
        let center = NotificationCenter()
        let readiness = makeReadiness(preparer: preparer, conditions: conditions)
        readiness.observeSystemConditions(center: center)
        readiness.startIfNeeded()
        #expect(readiness.state == .deferred(.lowPowerMode))

        conditions.set(lowPower: false)
        center.post(name: .NSProcessInfoPowerStateDidChange, object: nil)

        #expect(await waitFor { preparer.callCount == 1 })
    }
}

// MARK: - Échecs

@MainActor
@Suite("Préparation de la lecture d'image — échecs")
struct ImageRecognitionFailureTests {
    @Test("Échec : pas de clé enregistrée, un nouvel essai au passage suivant, puis on s'arrête")
    func failureRetriesTwiceThenStops() async {
        let preparer = GatedPreparer(failure: SomeFailure())
        let ledger = MemoryLedger()
        let readiness = makeReadiness(preparer: preparer, ledger: ledger)

        readiness.startIfNeeded()
        #expect(await waitFor { readiness.state == .failed })
        #expect(ledger.preparedKey == nil)

        readiness.startIfNeeded()
        #expect(await waitFor { preparer.callCount == 2 })
        #expect(await waitFor { readiness.state == .failed })

        readiness.startIfNeeded()
        readiness.prepareForUserRequest()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(preparer.callCount == 2, "pas de troisième essai pendant ce lancement")
        #expect(readiness.state == .failed)
    }

    @Test("Un essai raté puis réussi : « prête »")
    func failureThenSuccess() async {
        let preparer = GatedPreparer(failure: SomeFailure())
        let readiness = makeReadiness(preparer: preparer)
        readiness.startIfNeeded()
        #expect(await waitFor { readiness.state == .failed })

        preparer.setFailure(nil)
        readiness.startIfNeeded()
        #expect(await waitFor { preparer.callCount == 2 })
        preparer.release()
        #expect(await waitFor { readiness.state == .ready })
    }

    @Test("Annulée par le système (hors conditions) : retour à l'état de départ, rien d'enregistré")
    func systemCancellationLeavesNoMark() async {
        let preparer = GatedPreparer(failure: CancellationError())
        let ledger = MemoryLedger()
        let readiness = makeReadiness(preparer: preparer, ledger: ledger)

        readiness.startIfNeeded()

        #expect(await waitFor { readiness.state == .idle })
        #expect(ledger.preparedKey == nil)
    }
}
