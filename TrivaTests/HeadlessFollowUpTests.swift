//
//  HeadlessFollowUpTests.swift
//  TrivaTests
//
//  Chantier 2.1 (mission B2) : dialogue de « Chercher dans l'historique » et repli au premier plan quand l'arrière-plan
//  refuse le GPU. Logique pure.
//

import Testing
import Foundation
@testable import Triva

@Suite("Chercher dans l'historique — dialogue")
struct SearchHistoryDialogTests {
    @Test("Aucun résultat")
    func none() {
        #expect(SearchHistoryDialog.text(count: 0, limit: 20) == "Aucune conversation trouvée.")
    }

    @Test("Un résultat")
    func one() {
        #expect(SearchHistoryDialog.text(count: 1, limit: 20) == "Une conversation trouvée.")
    }

    @Test("Plusieurs résultats")
    func several() {
        #expect(SearchHistoryDialog.text(count: 2, limit: 20) == "2 conversations trouvées.")
        #expect(SearchHistoryDialog.text(count: 19, limit: 20) == "19 conversations trouvées.")
    }

    @Test("Limite atteinte : il peut y en avoir d'autres, le nombre n'est pas annoncé comme un total")
    func limitReached() {
        let text = SearchHistoryDialog.text(count: 20, limit: 20)
        #expect(text == "Voici les 20 conversations les plus récentes qui correspondent.")
    }
}

@Suite("Repli au premier plan (modèle local)")
struct HeadlessForegroundFallbackTests {
    private func decide(
        _ execution: HeadlessExecution = .backgroundWithGPU,
        started: Bool = false,
        cancelled: Bool = false,
        canForeground: Bool = true
    ) -> Bool {
        HeadlessForegroundFallback.shouldContinueInForeground(
            execution: execution, operationStarted: started, wasCancelled: cancelled, canContinueInForeground: canForeground
        )
    }

    @Test("Arrière-plan refusé avant le début du travail, premier plan possible : on continue au premier plan")
    func refusedBeforeStart() {
        #expect(decide())
    }

    @Test("Premier plan impossible : pas de repli")
    func noForegroundAvailable() {
        #expect(!decide(canForeground: false))
    }

    @Test("Le travail a déjà commencé : jamais de seconde question (pas de doublon dans l'historique)")
    func alreadyStarted() {
        #expect(!decide(started: true))
    }

    @Test("Annulation par l'utilisateur ou le système : jamais de repli")
    func cancelled() {
        #expect(!decide(cancelled: true))
    }

    @Test("Exécution standard (Apple Intelligence, cloud, Mac) : pas de GPU demandé, donc pas de repli")
    func standardExecution() {
        #expect(!decide(.standard))
    }

    @Test("Textes du repli")
    func texts() {
        #expect(HeadlessForegroundFallback.dialog == "Triva s'ouvre pour utiliser le modèle de ton appareil.")
        #expect(HeadlessForegroundFallback.refusedMessage == "Le modèle de ton appareil ne peut pas tourner en arrière-plan. Ouvre Triva et réessaie.")
    }
}
