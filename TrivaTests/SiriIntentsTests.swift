//
//  SiriIntentsTests.swift
//  TrivaTests
//
//  Chantier 2.1 (mission B) : les actions Raccourcis et Siri qui ne demandent pas de pipeline : mode de réponse,
//  recherche dans l'historique, réponse rendue, raccourcis proposés. Le registre de dépendances du système ne se
//  contrôle pas depuis un test : on vise les fonctions statiques.
//

import AppIntents
import Foundation
import Testing
@testable import Triva

@MainActor
@Suite("Siri et Raccourcis : actions")
struct SiriIntentsTests {
    private func makeStore() throws -> ChatHistoryStore {
        ChatHistoryStore(container: try TrivaModelContainer.makeInMemory(), locale: Locale(identifier: "fr_FR"))
    }

    private func defaults() throws -> UserDefaults {
        try #require(TestDefaults.suite(named: "test.siriIntents.\(UUID().uuidString)"))
    }

    // MARK: - Mode de réponse

    @Test("Mode de réponse : les trois cas se traduisent dans les deux sens, avec les libellés du sélecteur")
    func responseModeEnum() {
        for mode in ResponseMode.allCases {
            let value = ResponseModeAppEnum(mode)
            #expect(value.mode == mode)
            #expect(value.rawValue == mode.rawValue)
        }
        #expect(ResponseModeAppEnum.allCases.count == ResponseMode.allCases.count)
        #expect(ResponseModeAppEnum.caseDisplayRepresentations.count == 3)
        for mode in ResponseMode.allCases {
            let shown = ResponseModeAppEnum.caseDisplayRepresentations[ResponseModeAppEnum(mode)]
            #expect(shown.map { String(localized: $0.title) } == mode.title)
        }
    }

    @Test("Choisir le mode : écrit dans le store, et dit « Mode de réponse : Fiable. »")
    func setMode() throws {
        let store = ResponseModeSettingsStore(userDefaults: try defaults())
        #expect(store.selectedMode == .quick)

        let dialog = SetResponseModeIntent.apply(.reliable, to: store)

        #expect(store.selectedMode == .reliable)
        #expect(dialog == "Mode de réponse : Fiable.")
        #expect(SetResponseModeIntent.dialog(for: .quick) == "Mode de réponse : Rapide.")
        #expect(SetResponseModeIntent.dialog(for: .deep) == "Mode de réponse : Approfondie.")
    }

    @Test("Le mode écrit est relu par l'envoi suivant (mêmes réglages)")
    func modeIsReadBySend() throws {
        let userDefaults = try defaults()
        _ = SetResponseModeIntent.apply(.deep, to: ResponseModeSettingsStore(userDefaults: userDefaults))
        #expect(ChatViewModel.persistedResponseMode(in: userDefaults) == .deep)
    }

    @Test("L'intent et l'écran partagent UNE instance du store du mode")
    func sharedStoreIsUnique() {
        #expect(SetResponseModeIntent.targetStore === ResponseModeSettingsStore.shared)
        #expect(ResponseModeSettingsStore.shared === ResponseModeSettingsStore.shared)
    }

    // MARK: - Chercher dans l'historique

    @Test("Chercher dans l'historique : titre et date, 20 au plus, les plus récentes d'abord")
    func searchHistoryLimit() throws {
        let store = try makeStore()
        for day in 1...25 {
            _ = try store.createConversation(title: "Voyage \(day)", now: Date(timeIntervalSince1970: TimeInterval(day) * 86_400))
        }
        _ = try store.createConversation(title: "Cuisine", now: Date(timeIntervalSince1970: 30 * 86_400))

        let found = try SearchHistoryIntent.search("voyage", in: store)

        #expect(found.count == 20)
        #expect(found.first?.title == "Voyage 25")
        #expect(found.allSatisfy { $0.title.hasPrefix("Voyage") })
    }

    @Test("Recherche vide ou blanche : rien")
    func searchHistoryEmpty() throws {
        let store = try makeStore()
        _ = try store.createConversation(title: "Voyage", now: .now)
        #expect(try SearchHistoryIntent.search("   ", in: store).isEmpty)
    }

    // MARK: - Réponse rendue

    @Test("L'entité réponse reprend la question, le texte et les sources")
    func answerEntity() {
        let answer = HeadlessAnswer(
            question: "Capitale ?",
            text: "Paris.",
            spoken: "Paris. La réponse complète est dans Triva.",
            sourceTitles: ["Titre A"],
            sourceLinks: [URL(string: "https://a.example")!],
            conversationID: nil
        )
        let entity = TrivaAnswerEntity(answer)
        #expect(entity.question == "Capitale ?")
        #expect(entity.text == "Paris.")
        #expect(entity.sourceTitles == ["Titre A"])
        #expect(entity.sourceLinks == [URL(string: "https://a.example")!])
        #expect(TrivaAnswerEntity().text.isEmpty)
    }

    // MARK: - Raccourcis proposés

    @Test("Quatre raccourcis proposés (poser une question, nouvelle recherche, historique, conversation), sous la limite de 10 d'Apple")
    func shortcuts() {
        let shortcuts = TrivaShortcuts.appShortcuts
        #expect(shortcuts.count == 4)
    }

    @Test("Textes de la spec : titres des intents")
    func titles() {
        #expect(String(localized: AskTrivaIntent.title) == "Poser une question à Triva")
        #expect(String(localized: SearchHistoryIntent.title) == "Chercher dans l'historique")
        #expect(String(localized: SetResponseModeIntent.title) == "Choisir le mode de réponse")
    }

    @Test("Les intents s'exécutent dans l'app (cible .main) et ont leurs modes")
    func executionTargets() {
        #expect(AskTrivaIntent.allowedExecutionTargets == .main)
        #expect(SearchHistoryIntent.allowedExecutionTargets == .main)
        #expect(SetResponseModeIntent.allowedExecutionTargets == .main)
    }
}

/// Les conformances doivent être visibles hors du main actor, où le système les cherche (même contrôle que la
/// mission A). Suite NON isolée.
@Suite("Siri et Raccourcis : conformances hors du main actor")
struct SiriIntentConformanceOffMainActorTests {
    @Test("Les intents et entités sont reconnus depuis une tâche détachée")
    func conformancesVisibleOffMain() async {
        let result = await Task.detached {
            let intents: [Any.Type] = [AskTrivaIntent.self, SearchHistoryIntent.self, SetResponseModeIntent.self]
            let entities: [Any.Type] = [TrivaAnswerEntity.self]
            let enums: [Any.Type] = [ResponseModeAppEnum.self]
            let longRunning: [Any.Type] = [AskTrivaIntent.self]
            return (
                intents.allSatisfy { $0 is any AppIntent.Type },
                entities.allSatisfy { $0 is any AppEntity.Type },
                enums.allSatisfy { $0 is any AppEnum.Type },
                longRunning.allSatisfy { $0 is any LongRunningIntent.Type },
                longRunning.allSatisfy { $0 is any CancellableIntent.Type }
            )
        }.value
        #expect(result.0)
        #expect(result.1)
        #expect(result.2)
        #expect(result.3)
        #expect(result.4)
    }
}
