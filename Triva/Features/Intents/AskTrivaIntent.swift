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
        let setup = services.prepareHeadlessQuestion(responseMode: mode?.mode)
        guard case .run(let execution) = setup.decision, let runner = setup.runner else {
            throw try await stopBeforeSending(for: setup.decision)
        }
        let outcome = try await runInBackground(runner, execution: execution)
        return try await result(for: outcome)
    }

    // MARK: - Exécution

    /// Temps d'exécution prolongé ; le GPU est demandé seulement pour un modèle local sur iPhone ou iPad.
    @MainActor
    private func runInBackground(
        _ runner: HeadlessQuestionRunner,
        execution: HeadlessExecution
    ) async throws -> HeadlessQuestionOutcome {
        let options: LongRunningTaskOptions = execution == .backgroundWithGPU ? [.requiresGPU] : []
        let question = question
        let progress = progress
        return try await performBackgroundTask(options: options) { @Sendable in
            progress.totalUnitCount = HeadlessProgressMeter.totalUnits
            return await runner.run(question: question) { update in
                progress.completedUnitCount = update.completedUnits
                progress.localizedDescription = update.stage.description
            }
        } onCancel: { _ in
            Task { @MainActor in runner.cancel() }
        }
    }

    @MainActor
    private func result(
        for outcome: HeadlessQuestionOutcome
    ) async throws -> some IntentResult & ReturnsValue<TrivaAnswerEntity> & ProvidesDialog {
        switch outcome {
        case .answered(let answer):
            return .result(
                value: TrivaAnswerEntity(answer),
                dialog: IntentDialog(LocalizedStringResource(stringLiteral: answer.spoken))
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
