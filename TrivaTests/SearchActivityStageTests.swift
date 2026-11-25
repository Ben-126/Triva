//
//  SearchActivityStageTests.swift
//  TrivaTests
//
//  Chantier 2.1 (missions D puis I) : la logique PURE de l'activité en direct, sans ActivityKit : étapes (réflexion,
//  recherche des sources, lecture, rédaction, prête), textes, passage d'une étape à la suivante (jamais en arrière,
//  sauf la réflexion du modèle qui suit la lecture ; étapes finales définitives), question raccourcie, taille sous 4 Ko.
//
//  Mission I : la question n'est plus un attribut FIXE de l'activité mais une partie de son ÉTAT, pour qu'une mise à jour
//  puisse la retirer de l'écran (réglage « Afficher la question » éteint, activité en cours comprise).
//

import Foundation
import Testing
@testable import Triva

@Suite("Activité en direct : étapes")
struct SearchActivityStageTests {
    private func state(_ stage: SearchActivityStage, _ count: Int = 0, question: String? = nil) -> SearchActivityState {
        SearchActivityState(stage: stage, sourceCount: count, question: question)
    }

    // MARK: Textes

    @Test("Les textes de chaque étape")
    func statusTexts() {
        #expect(state(.thinking).statusText == "Réflexion…")
        #expect(state(.searching).statusText == "Recherche des sources…")
        #expect(state(.reading, 3).statusText == "Lecture de 3 sources")
        #expect(state(.reading, 1).statusText == "Lecture d'une source")
        #expect(state(.writing, 3).statusText == "Rédaction…")
        #expect(state(.ready, 3).statusText == "Réponse prête")
        #expect(state(.interrupted).statusText == "Recherche interrompue")
        #expect(state(.failed).statusText == "La recherche n'a pas abouti")
    }

    @Test("Le début d'une activité est la réflexion, sans question")
    func initialState() {
        #expect(SearchActivityState.initial == state(.thinking))
        #expect(SearchActivityState.initial.question == nil)
    }

    @Test("Seules les trois dernières étapes sont terminales")
    func terminalStages() {
        let terminal = [SearchActivityStage.ready, .interrupted, .failed].filter(\.isTerminal)
        let running = [SearchActivityStage.thinking, .searching, .reading, .writing].filter { !$0.isTerminal }
        #expect(terminal.count == 3)
        #expect(running.count == 4)
    }

    @Test("Une activité périmée affiche « interrompue », sauf si elle est déjà finie")
    func staleDisplay() {
        #expect(state(.writing, 3).displayed(isStale: true) == state(.interrupted, 3))
        #expect(state(.thinking).displayed(isStale: true) == state(.interrupted, 0))
        #expect(state(.writing, 3).displayed(isStale: false) == state(.writing, 3))
        #expect(state(.ready, 3).displayed(isStale: true) == state(.ready, 3))
        #expect(state(.failed).displayed(isStale: true) == state(.failed))
    }

    @Test("Périmée, l'activité garde la question (si elle en a une)")
    func staleKeepsTheQuestion() {
        #expect(state(.writing, 3, question: "Q ?").displayed(isStale: true) == state(.interrupted, 3, question: "Q ?"))
        #expect(state(.writing, 3, question: nil).displayed(isStale: true).question == nil)
    }

    // MARK: Passage d'une étape à l'autre

    @Test("Le début d'un échange donne « Réflexion »")
    func started() {
        let next = SearchActivityStage.next(state(.failed, 4), event: .started(question: "q", conversationID: nil))
        #expect(next == .initial)
    }

    @Test("La recherche qui démarre : « Recherche des sources », depuis la réflexion")
    func searchStarts() {
        #expect(SearchActivityStage.next(.initial, event: .searching) == state(.searching))
    }

    @Test("Des sources lues : « Lecture de N sources » avec le bon nombre, depuis la réflexion ou la recherche")
    func sourcesRead() {
        #expect(SearchActivityStage.next(.initial, event: .sources(count: 5)) == state(.reading, 5))
        #expect(SearchActivityStage.next(state(.searching), event: .sources(count: 1)) == state(.reading, 1))
    }

    @Test("Zéro source (ou négatif) : l'étape ne change pas")
    func noSources() {
        #expect(SearchActivityStage.next(state(.searching), event: .sources(count: 0)) == state(.searching))
        #expect(SearchActivityStage.next(.initial, event: .sources(count: -2)) == .initial)
    }

    @Test("Le premier texte de la réponse : « Rédaction », en gardant le nombre de sources")
    func writing() {
        #expect(SearchActivityStage.next(state(.reading, 4), event: .writing) == state(.writing, 4))
        #expect(SearchActivityStage.next(.initial, event: .writing) == state(.writing, 0))
        #expect(SearchActivityStage.next(state(.thinking, 4), event: .writing) == state(.writing, 4))
    }

    @Test("La réflexion du modèle suit la lecture des sources : « Réflexion », le nombre de sources reste")
    func modelReasoning() {
        #expect(SearchActivityStage.next(state(.reading, 4), event: .reasoning) == state(.thinking, 4))
        #expect(SearchActivityStage.next(state(.searching), event: .reasoning) == state(.thinking, 0))
    }

    @Test("La réflexion du modèle, déjà en « Réflexion » : rien ne change")
    func reasoningWhileThinking() {
        #expect(SearchActivityStage.next(.initial, event: .reasoning) == .initial)
        #expect(SearchActivityStage.next(state(.thinking, 4), event: .reasoning) == state(.thinking, 4))
    }

    @Test("Les sources déjà lues ne sont pas relues après la réflexion du modèle")
    func sourcesAfterReasoningIgnored() {
        let thinking = state(.thinking, 4)
        #expect(SearchActivityStage.next(thinking, event: .sources(count: 9)) == thinking)
        #expect(SearchActivityStage.next(thinking, event: .searching) == thinking)
    }

    @Test("Jamais en arrière : sources, recherche ou réflexion reçues pendant la rédaction sont ignorées")
    func neverGoesBack() {
        let writing = state(.writing, 4)
        #expect(SearchActivityStage.next(writing, event: .sources(count: 9)) == writing)
        #expect(SearchActivityStage.next(writing, event: .searching) == writing)
        #expect(SearchActivityStage.next(writing, event: .reasoning) == writing)
        let reading = state(.reading, 4)
        #expect(SearchActivityStage.next(reading, event: .searching) == reading)
        #expect(SearchActivityStage.next(reading, event: .sources(count: 2)) == reading)
    }

    @Test("La question suit l'état à chaque étape")
    func questionTravelsWithTheState() {
        let first = state(.thinking, 0, question: "Capitale de la France ?")
        let searching = SearchActivityStage.next(first, event: .searching)
        let reading = SearchActivityStage.next(searching, event: .sources(count: 3))
        let reasoning = SearchActivityStage.next(reading, event: .reasoning)
        let writing = SearchActivityStage.next(reasoning, event: .writing)
        let ready = SearchActivityStage.next(writing, event: .completed)
        for step in [searching, reading, reasoning, writing, ready] {
            #expect(step.question == "Capitale de la France ?")
        }
        #expect(ready == state(.ready, 3, question: "Capitale de la France ?"))
    }

    @Test("Les fins : prête, interrompue, échouée (le nombre de sources reste)")
    func endings() {
        let writing = state(.writing, 4)
        #expect(SearchActivityStage.next(writing, event: .completed) == state(.ready, 4))
        #expect(SearchActivityStage.next(writing, event: .interrupted) == state(.interrupted, 4))
        #expect(SearchActivityStage.next(writing, event: .failed) == state(.failed, 4))
        #expect(SearchActivityStage.next(.initial, event: .failed) == state(.failed, 0))
    }

    @Test("Une étape finale est définitive, sauf un nouvel échange", arguments: [
        SearchActivityStage.ready, .interrupted, .failed,
    ])
    func terminalIsAbsorbing(stage: SearchActivityStage) {
        let final = state(stage, 2)
        let events: [SearchProgressEvent] = [
            .searching, .sources(count: 7), .reasoning, .writing, .completed, .interrupted, .failed,
        ]
        for event in events {
            #expect(SearchActivityStage.next(final, event: event) == final)
        }
    }

    // MARK: La question

    @Test("Une question courte reste telle quelle, espaces de bord et retours à la ligne ramenés")
    func shortQuestion() {
        #expect(SearchActivityState.oneLineQuestion("  Capitale de la France ?  ") == "Capitale de la France ?")
        #expect(SearchActivityState.oneLineQuestion("Ligne un\nligne deux") == "Ligne un ligne deux")
    }

    @Test("Une question trop longue est coupée à 140 caractères, avec une ellipse")
    func longQuestion() {
        let long = String(repeating: "a", count: 500)
        let question = SearchActivityState.oneLineQuestion(long)
        #expect(question.count == SearchActivityState.maxQuestionLength)
        #expect(question.hasSuffix("…"))
        let exact = String(repeating: "b", count: 140)
        #expect(SearchActivityState.oneLineQuestion(exact) == exact)
    }

    @Test("Montrer ou retirer la question ne change rien d'autre")
    func showingAndRemovingTheQuestion() {
        let plain = state(.reading, 3)
        let withQuestion = plain.showing(question: "Q ?")
        #expect(withQuestion == state(.reading, 3, question: "Q ?"))
        #expect(withQuestion.removingQuestion() == plain)
        #expect(plain.removingQuestion() == plain)
        #expect(withQuestion.showing(question: nil) == plain)
    }

    // MARK: Attributs

    @Test("Un toucher ouvre la conversation, ou rien sans conversation")
    func tapURL() throws {
        let id = try #require(UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF"))
        let url = try #require(SearchActivityAttributes(conversationID: id).tapURL)
        #expect(TrivaURLRoute.parse(url) == .conversation(id))
        #expect(SearchActivityAttributes(conversationID: nil).tapURL == nil)
    }

    @Test("Les attributs ne portent plus aucune question : rien de lisible dans leur JSON")
    func attributesCarryNoQuestion() throws {
        let attributes = SearchActivityAttributes(conversationID: UUID())
        let json = try #require(String(data: JSONEncoder().encode(attributes), encoding: .utf8))
        #expect(!json.contains("question"))
    }

    @Test("Attributs et état, encodés ensemble, tiennent très largement sous les 4 Ko (pire cas : 140 emojis)")
    func encodedSizeUnderFourKilobytes() throws {
        let worst = SearchActivityState.oneLineQuestion(String(repeating: "\u{1F9D1}\u{200D}\u{1F680}", count: 140))
        let attributes = SearchActivityAttributes(conversationID: UUID())
        let attributesData = try JSONEncoder().encode(attributes)
        let stateData = try JSONEncoder().encode(state(.reading, 10_000, question: worst))
        #expect(attributesData.count < 4_096)
        #expect(stateData.count < 4_096)
        #expect(attributesData.count + stateData.count < 4_096)
    }

    @Test("L'état fait l'aller-retour JSON, avec ou sans question")
    func stateRoundTrip() throws {
        for original in [state(.reading, 6), state(.writing, 2, question: "Une question ?")] {
            let decoded = try JSONDecoder().decode(SearchActivityState.self, from: JSONEncoder().encode(original))
            #expect(decoded == original)
        }
    }
}
