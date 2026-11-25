//
//  AskTrivaIntent.swift
//  Triva
//
//  Chantier 2.1 (mission B) : « Poser une question à Triva » (Siri, Raccourcis). Cherche, lit, rédige SANS fenêtre
//  (une session propre : `HeadlessQuestionSetup`), range la conversation dans l'historique et rend la réponse.
//
//  L'envoi à une IA cloud sans accord est impossible : la politique s'arrête avant de bâtir un lanceur, le lanceur
//  vérifie encore avant d'envoyer, et le fournisseur lui-même refuse sans accord.
//

import AppIntents
import Foundation

/// Message lu ou affiché quand la question ne peut pas aboutir (Siri, Raccourcis).
nonisolated enum AskTrivaError: Error, CustomLocalizedStringResourceConvertible {
    case message(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .message(let text): LocalizedStringResource(stringLiteral: text)
        }
    }
}

struct AskTrivaIntent: LongRunningIntent, CancellableIntent {
    static var title: LocalizedStringResource { "Poser une question à Triva" }
    static var description: IntentDescription {
        IntentDescription("Pose une question à Triva et rend sa réponse, avec ses sources.")
    }

    static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    @Parameter(title: "Question", requestValueDialog: "Quelle est ta question ?")
    var question: String

    @Parameter(title: "Mode de réponse")
    var mode: ResponseModeAppEnum?

    @Dependency var services: TrivaAppServices

    init() {}

    init(question: String, mode: ResponseModeAppEnum? = nil) {
        self.question = question
        self.mode = mode
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<TrivaAnswerEntity> & ProvidesDialog {
        // `progress` n'est lisible que dans `perform()` (la doc d'Apple : « l'utiliser ailleurs plante ») : on le lit
        // ICI, une seule fois, et c'est cet objet que la suite reçoit. Jamais relu dans une fermeture ni plus loin.
        let progress = progress
        let setup = services.prepareHeadlessQuestion(responseMode: mode?.mode)
        guard case .run(let execution) = setup.decision, let runner = setup.runner else {
            throw try await stopBeforeSending(for: setup.decision)
        }
        let outcome = try await runInBackground(runner, execution: execution, progress: progress)
        return try await result(for: outcome)
    }

    // MARK: - Exécution

    /// Marque que le travail a commencé dans `performBackgroundTask` (isolé au main actor : partageable avec la
    /// fermeture, qui s'exécute ailleurs).
    @MainActor
    private final class StartFlag {
        var isSet = false
    }

    /// Temps d'exécution prolongé ; le GPU est demandé seulement pour un modèle local sur iPhone ou iPad. Si le
    /// système refuse de lancer le travail en arrière-plan (GPU non accordé), on continue au premier plan quand il
    /// l'autorise (`HeadlessForegroundFallback`).
    @MainActor
    private func runInBackground(
        _ runner: HeadlessQuestionRunner,
        execution: HeadlessExecution,
        progress: Progress
    ) async throws -> HeadlessQuestionOutcome {
        let options: LongRunningTaskOptions = execution == .backgroundWithGPU ? [.requiresGPU] : []
        let question = question
        let started = StartFlag()
        do {
            return try await performBackgroundTask(options: options) { @Sendable in
                await MainActor.run { started.isSet = true }
                progress.totalUnitCount = HeadlessProgressMeter.totalUnits
                return await runner.run(question: question) { Self.report($0, to: progress) }
            } onCancel: { _ in
                Task { @MainActor in runner.cancel() }
            }
        } catch {
            let wasCancelled = Task.isCancelled || error is CancellationError
            let canContinue = systemContext.currentMode.canContinueInForeground
            guard HeadlessForegroundFallback.shouldContinueInForeground(
                execution: execution, operationStarted: started.isSet,
                wasCancelled: wasCancelled, canContinueInForeground: canContinue
            ) else {
                // Le GPU était demandé et le travail n'a jamais commencé : le système a refusé, on le dit clairement.
                if execution == .backgroundWithGPU, !started.isSet, !wasCancelled {
                    throw AskTrivaError.message(HeadlessForegroundFallback.refusedMessage)
                }
                throw error
            }
            return try await runInForeground(runner, progress: progress)
        }
    }

    /// Triva passe au premier plan (le GPU y est accordé) et pose la question sans `performBackgroundTask`.
    @MainActor
    private func runInForeground(_ runner: HeadlessQuestionRunner, progress: Progress) async throws -> HeadlessQuestionOutcome {
        do {
            try await continueInForeground(
                IntentDialog(LocalizedStringResource(stringLiteral: HeadlessForegroundFallback.dialog)),
                alwaysConfirm: false
            )
        } catch {
            throw AskTrivaError.message(HeadlessForegroundFallback.refusedMessage)
        }
        progress.totalUnitCount = HeadlessProgressMeter.totalUnits
        let question = question
        return await runner.run(question: question) { Self.report($0, to: progress) }
    }

    private static func report(_ update: HeadlessProgressUpdate, to progress: Progress) {
        progress.completedUnitCount = update.completedUnits
        progress.localizedDescription = update.stage.description
    }

    @MainActor
    private func result(
        for outcome: HeadlessQuestionOutcome
    ) async throws -> some IntentResult & ReturnsValue<TrivaAnswerEntity> & ProvidesDialog {
        switch outcome {
        case .answered(let answer):
            return .result(
                value: TrivaAnswerEntity(answer),
                dialog: IntentDialog(LocalizedStringResource(stringLiteral: Self.spokenText(for: answer)))
            )
        case .consentRequired(let providerName):
            // Ne devrait pas arriver (la politique l'a déjà vu) : même réponse que la politique.
            throw try await stopBeforeSending(for: .needsCloudConsent(providerName: providerName))
        case .failed(let message):
            throw AskTrivaError.message(message)
        case .noReliableSources:
            throw AskTrivaError.message(ChatViewModel.noReliableSourcesMessage)
        case .interrupted:
            throw AskTrivaError.message(HeadlessQuestionOutcome.interruptedMessage)
        }
    }

    /// Ce que Siri lit : la réponse, précédée d'un mot si la question a été coupée à 2 000 caractères.
    static func spokenText(for answer: HeadlessAnswer) -> String {
        answer.questionWasTruncated ? "\(HeadlessAnswer.truncationNotice) \(answer.spoken)" : answer.spoken
    }

    // MARK: - Ce qui demande d'ouvrir Triva

    /// L'erreur à lancer quand la question ne part pas. Si le système permet de passer au premier plan, Triva
    /// s'ouvre ; sinon, le message seul.
    @MainActor
    private func stopBeforeSending(for decision: HeadlessDecision) async throws -> any Error {
        switch decision {
        case .run:
            return AskTrivaError.message(HeadlessQuestionOutcome.interruptedMessage)
        case .needsEngineChoice:
            let dialog = HeadlessQuestionPolicy.engineChoiceDialog
            guard systemContext.currentMode.canContinueInForeground else { return AskTrivaError.message(dialog) }
            return needsToContinueInForegroundError(IntentDialog(LocalizedStringResource(stringLiteral: dialog)))
        case .needsAINotice:
            let dialog = HeadlessQuestionPolicy.aiNoticeDialog
            guard systemContext.currentMode.canContinueInForeground else { return AskTrivaError.message(dialog) }
            return needsToContinueInForegroundError(IntentDialog(LocalizedStringResource(stringLiteral: dialog)))
        case .needsCloudConsent(let providerName):
            let dialog = HeadlessQuestionPolicy.consentDialog(providerName: providerName)
            if systemContext.currentMode.canContinueInForeground {
                try await continueInForeground(
                    IntentDialog(LocalizedStringResource(stringLiteral: dialog)),
                    alwaysConfirm: false
                )
                // Triva est au premier plan : la question attend dans la barre de saisie, JAMAIS envoyée.
                SystemRouteDispatcher.shared.submit(.draft(question))
            }
            return AskTrivaError.message(dialog)
        }
    }
}
