//
//  ImageRecognitionReadiness.swift
//  Triva
//
//  W4-V : conduit la préparation de la lecture d'image (voir `ImageRecognitionPreparation.swift`) et dit à l'interface
//  quand une image attend après elle. Une lecture réelle lancée PENDANT la préparation partage son coût (mesuré : les deux
//  finissent ensemble) : aucune jointure à coder, seulement un message honnête.
//

import Foundation
import Observation

@MainActor
@Observable
final class ImageRecognitionReadiness {
    enum State: Equatable, Sendable {
        /// Rien de lancé.
        case idle
        /// Programmée après un délai (le lancement n'attend pas).
        case scheduled
        /// La reconnaissance de préparation tourne.
        case preparing
        /// Préparée pour cette version (registre) ou à l'instant.
        case ready
        /// Remise à plus tard : économie d'énergie ou appareil chaud.
        case deferred(ImageRecognitionDeferralReason)
        /// Deux échecs : on arrête pour ce lancement.
        case failed
    }

    /// Échecs tolérés par lancement de l'app : au-delà, on ne réessaie plus (la lecture d'image reste possible).
    static let maxFailuresPerLaunch = 2

    private(set) var state: State = .idle
    var isPreparing: Bool { state == .preparing }

    @ObservationIgnored private let preparer: any ImageRecognitionPreparing
    @ObservationIgnored private let ledger: any ImageRecognitionPreparationLedger
    @ObservationIgnored private let conditions: any DeviceConditionsProviding
    @ObservationIgnored private let key: String
    @ObservationIgnored private let startDelay: Duration
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var failureCount = 0
    /// Une image attend la préparation : plus question de l'interrompre pour la chaleur ou l'économie d'énergie.
    @ObservationIgnored private var userIsWaiting = false
    @ObservationIgnored private var observations: [Task<Void, Never>] = []

    init(
        preparer: any ImageRecognitionPreparing,
        ledger: any ImageRecognitionPreparationLedger,
        conditions: any DeviceConditionsProviding = SystemDeviceConditions(),
        key: String = ImageRecognitionPreparationKey.current(),
        startDelay: Duration = .seconds(10)
    ) {
        self.preparer = preparer
        self.ledger = ledger
        self.conditions = conditions
        self.key = key
        self.startDelay = startDelay
    }

    deinit {
        task?.cancel()
        observations.forEach { $0.cancel() }
    }

    // MARK: Points d'entrée

    /// Au lancement et à chaque retour au premier plan : prépare en fond si ce n'est pas déjà fait pour cette version,
    /// sans ralentir le lancement (délai de 10 s, priorité moyenne `.utility`) et seulement si l'appareil est calme.
    /// Priorité moyenne depuis F3 (26/11) : mesurée à ~45 s sur un Mac chargé, contre ~237 s en `.background` (W4-V).
    func startIfNeeded() {
        switch state {
        case .preparing, .scheduled, .ready: return
        case .idle, .deferred, .failed: break
        }
        if markReadyIfAlreadyPrepared() { return }
        guard failureCount < Self.maxFailuresPerLaunch else { return }
        if let reason = deferralReason() {
            state = .deferred(reason)
            return
        }
        launch(delay: startDelay, priority: .utility)
    }

    /// Une image vient d'être jointe : l'utilisateur passe avant tout (délai, économie d'énergie, chaleur ignorés),
    /// et l'interface peut dire que la lecture attend une préparation.
    func prepareForUserRequest() {
        if markReadyIfAlreadyPrepared() { return }
        switch state {
        case .preparing:
            userIsWaiting = true
            return
        case .ready:
            return
        case .idle, .scheduled, .deferred, .failed:
            break
        }
        guard failureCount < Self.maxFailuresPerLaunch else { return }
        userIsWaiting = true
        launch(delay: .zero, priority: .userInitiated)
    }

    /// Plus aucune image n'attend (retirée, conversation vidée, lecture terminée) : la préparation redevient un travail de
    /// fond, soumis de nouveau à l'économie d'énergie et à la chaleur.
    func userRequestDidEnd() {
        guard userIsWaiting else { return }
        userIsWaiting = false
        conditionsDidChange()
    }

    /// Économie d'énergie ou chaleur ont changé (notification du système, voir `observeSystemConditions`).
    func conditionsDidChange() {
        let reason = deferralReason()
        switch state {
        case .preparing, .scheduled:
            guard !userIsWaiting, let reason else { return }
            cancelTask()
            state = .deferred(reason)
        case .deferred:
            if let reason {
                state = .deferred(reason)
            } else {
                startIfNeeded()
            }
        case .idle, .ready, .failed:
            break
        }
    }

    /// Branche les notifications du système sur `conditionsDidChange()`.
    func observeSystemConditions(center: NotificationCenter = .default) {
        guard observations.isEmpty else { return }
        let names: [Notification.Name] = [ProcessInfo.thermalStateDidChangeNotification, .NSProcessInfoPowerStateDidChange]
        // La séquence est créée ICI, avant la tâche : une notification postée tout de suite après l'appel n'est pas perdue.
        observations = names.map { name in
            let notifications = center.notifications(named: name).map { _ in () }
            return Task { [weak self] in
                for await _ in notifications {
                    self?.conditionsDidChange()
                }
            }
        }
    }

    // MARK: Interne

    private func markReadyIfAlreadyPrepared() -> Bool {
        guard ledger.preparedKey == key else { return false }
        state = .ready
        return true
    }

    private func deferralReason() -> ImageRecognitionDeferralReason? {
        ImageRecognitionPreparationPolicy.deferralReason(
            isLowPowerModeEnabled: conditions.isLowPowerModeEnabled,
            thermalState: conditions.thermalState
        )
    }

    private func cancelTask() {
        task?.cancel()
        task = nil
        generation += 1
    }

    private func launch(delay: Duration, priority: TaskPriority) {
        cancelTask()
        let current = generation
        state = delay > .zero ? .scheduled : .preparing
        task = Task(priority: priority) { [weak self, preparer] in
            if delay > .zero {
                do { try await Task.sleep(for: delay) } catch { return }
                guard self?.beginAfterDelay(generation: current) == true else { return }
            }
            do {
                try await preparer.prepareRecognition()
                self?.finish(generation: current, outcome: .prepared)
            } catch is CancellationError {
                self?.finish(generation: current, outcome: .cancelled)
            } catch {
                self?.finish(generation: current, outcome: .failed)
            }
        }
    }

    /// Fin du délai : les conditions ont pu changer entre-temps.
    private func beginAfterDelay(generation current: Int) -> Bool {
        guard current == generation else { return false }
        if !userIsWaiting, let reason = deferralReason() {
            task = nil
            state = .deferred(reason)
            return false
        }
        state = .preparing
        return true
    }

    private enum Outcome { case prepared, cancelled, failed }

    private func finish(generation current: Int, outcome: Outcome) {
        // Une annulation volontaire a déjà changé de génération et d'état : sa fin ne compte plus.
        guard current == generation else { return }
        task = nil
        userIsWaiting = false
        switch outcome {
        case .prepared:
            ledger.markPrepared(key: key)
            state = .ready
        case .cancelled:
            state = .idle
        case .failed:
            failureCount += 1
            state = .failed
        }
    }
}
