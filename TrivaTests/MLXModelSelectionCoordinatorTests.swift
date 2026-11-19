//
//  MLXModelSelectionCoordinatorTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 13/09/2026.
//

import Foundation
import Testing
@testable import Triva

/// Ces tests couvrent l'état initial et les transitions atteignables sans modèle d'essai actif. Les chemins
/// de téléchargement, d'essai, d'annulation et de validation (par le pool, avec des doubles) sont dans
/// `MLXModelTrialPoolTests`.
@MainActor
private func makeCoordinatorTestPool() -> MLXProviderPool {
    MLXProviderPool(selection: makePoolSelection(selected: nil))
}

@MainActor
@Suite("MLXModelSelectionCoordinator")
struct MLXModelSelectionCoordinatorTests {
    @Test("État initial : idle, sans modèle sélectionné, première question d'essai")
    func initialState() {
        let coordinator = MLXModelSelectionCoordinator(pool: makeCoordinatorTestPool()) { _ in }

        #expect(coordinator.phase == .idle)
        #expect(coordinator.selectedEntry == nil)
        #expect(coordinator.trialAnswers.isEmpty)
        #expect(coordinator.isGeneratingTrialAnswer == false)
        #expect(coordinator.nextTrialQuestion == MLXModelSelectionCoordinator.trialQuestions[0])
        #expect(coordinator.hasCompletedTrial == false)
    }

    @Test("Il y a exactement 2 questions d'essai")
    func trialQuestionCount() {
        #expect(MLXModelSelectionCoordinator.trialQuestions.count == 2)
    }

    @Test("validateAsDefault() sans sélection ne fait rien : ni callback, ni changement de phase")
    func validateAsDefaultWithoutSelectionIsNoOp() {
        var validatedEntry: MLXModelCatalogEntry?
        let coordinator = MLXModelSelectionCoordinator(pool: makeCoordinatorTestPool()) { entry in
            validatedEntry = entry
        }

        coordinator.validateAsDefault()

        #expect(validatedEntry == nil)
        #expect(coordinator.phase == .idle)
    }

    @Test("cancelDownload() sur un coordinateur neuf reste idempotent")
    func cancelDownloadOnFreshCoordinatorIsIdempotent() {
        let coordinator = MLXModelSelectionCoordinator(pool: makeCoordinatorTestPool()) { _ in }

        coordinator.cancelDownload()

        #expect(coordinator.phase == .idle)
        #expect(coordinator.selectedEntry == nil)
        #expect(coordinator.trialAnswers.isEmpty)
    }

    @Test("chooseAnotherModel() sur un coordinateur neuf reste idempotent")
    func chooseAnotherModelOnFreshCoordinatorIsIdempotent() {
        let coordinator = MLXModelSelectionCoordinator(pool: makeCoordinatorTestPool()) { _ in }

        coordinator.chooseAnotherModel()

        #expect(coordinator.phase == .idle)
        #expect(coordinator.selectedEntry == nil)
        #expect(coordinator.trialAnswers.isEmpty)
        #expect(coordinator.isGeneratingTrialAnswer == false)
    }

    @Test("Phase.failed : isEnvironmentLimitation vaut false par défaut")
    func failedPhaseDefaultsToRealFailure() {
        let realFailure = MLXModelSelectionCoordinator.Phase.failed(description: "boom")
        let environmentLimitation = MLXModelSelectionCoordinator.Phase.failed(
            description: "boom",
            isEnvironmentLimitation: true
        )

        #expect(realFailure != environmentLimitation)
        if case .failed(_, let isEnvironmentLimitation) = realFailure {
            #expect(isEnvironmentLimitation == false)
        } else {
            Issue.record("attendu .failed")
        }
    }

    @Test("Phase.downloading est Equatable sur sa fraction complétée")
    func downloadingPhaseEquality() {
        #expect(
            MLXModelSelectionCoordinator.Phase.downloading(fractionCompleted: 0.5)
                == .downloading(fractionCompleted: 0.5)
        )
        #expect(
            MLXModelSelectionCoordinator.Phase.downloading(fractionCompleted: 0.5)
                != .downloading(fractionCompleted: 0.6)
        )
    }
}
