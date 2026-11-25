//
//  SearchActivityStageTests.swift
//  TrivaTests
//
//  Chantier 2.1 (mission D) : la logique PURE de l'activité en direct, sans ActivityKit : étapes, textes, passage d'une
//  étape à la suivante (jamais en arrière, étapes finales définitives), question raccourcie, taille sous 4 Ko.
//

import Foundation
import Testing
@testable import Triva

@Suite("Activité en direct : étapes")
struct SearchActivityStageTests {
    private func state(_ stage: SearchActivityStage, _ count: Int = 0) -> SearchActivityState {
        SearchActivityState(stage: stage, sourceCount: count)
    }

    // MARK: Textes

    @Test("Les textes de chaque étape")
    func statusTexts() {
        #expect(state(.searching).statusText == "Recherche…")
        #expect(state(.reading, 3).statusText == "Lecture de 3 sources")
        #expect(state(.reading, 1).statusText == "Lecture d'une source")
        #expect(state(.writing, 3).statusText == "Rédaction…")
        #expect(state(.ready, 3).statusText == "Réponse prête")
        #expect(state(.interrupted).statusText == "Recherche interrompue")
        #expect(state(.failed).statusText == "La recherche n'a pas abouti")
    }

    @Test("Seules les trois dernières étapes sont terminales")
    func terminalStages() {
        let terminal = [SearchActivityStage.ready, .interrupted, .failed].filter(\.isTerminal)
        let running = [SearchActivityStage.searching, .reading, .writing].filter { !$0.isTerminal }
        #expect(terminal.count == 3)
        #expect(running.count == 3)
    }

    @Test("Une activité périmée affiche « interrompue », sauf si elle est déjà finie")
    func staleDisplay() {
        #expect(state(.writing, 3).displayed(isStale: true) == state(.interrupted, 3))
        #expect(state(.searching).displayed(isStale: true) == state(.interrupted, 0))
        #expect(state(.writing, 3).displayed(isStale: false) == state(.writing, 3))
        #expect(state(.ready, 3).displayed(isStale: true) == state(.ready, 3))
        #expect(state(.failed).displayed(isStale: true) == state(.failed))
    }

    // MARK: Passage d'une étape à l'autre

    @Test("Le début d'un échange donne « Recherche »")
    func started() {
        let next = SearchActivityStage.next(state(.failed, 4), event: .started(question: "q", conversationID: nil))
        #expect(next == .initial)
    }

    @Test("Des sources lues : « Lecture de N sources » avec le bon nombre")
    func sourcesRead() {
        #expect(SearchActivityStage.next(.initial, event: .sources(count: 5)) == state(.reading, 5))
        #expect(SearchActivityStage.next(.initial, event: .sources(count: 1)) == state(.reading, 1))
    }

    @Test("Zéro source (ou négatif) : l'étape ne change pas")
    func noSources() {
        #expect(SearchActivityStage.next(.initial, event: .sources(count: 0)) == .initial)
        #expect(SearchActivityStage.next(.initial, event: .sources(count: -2)) == .initial)
    }

    @Test("Le premier texte : « Rédaction », en gardant le nombre de sources")
    func writing() {
        #expect(SearchActivityStage.next(state(.reading, 4), event: .writing) == state(.writing, 4))
        #expect(SearchActivityStage.next(.initial, event: .writing) == state(.writing, 0))
    }

    @Test("Jamais en arrière : sources ou recherche reçues pendant la rédaction sont ignorées")
    func neverGoesBack() {
        let writing = state(.writing, 4)
        #expect(SearchActivityStage.next(writing, event: .sources(count: 9)) == writing)
        #expect(SearchActivityStage.next(writing, event: .searching) == writing)
        let reading = state(.reading, 4)
        #expect(SearchActivityStage.next(reading, event: .searching) == reading)
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
            .searching, .sources(count: 7), .writing, .completed, .interrupted, .failed,
        ]
        for event in events {
            #expect(SearchActivityStage.next(final, event: event) == final)
        }
    }

    // MARK: Attributs

    @Test("Une question courte reste telle quelle, espaces de bord et retours à la ligne ramenés")
    func shortQuestion() {
        #expect(SearchActivityAttributes(question: "  Capitale de la France ?  ", conversationID: nil).question == "Capitale de la France ?")
        #expect(SearchActivityAttributes(question: "Ligne un\nligne deux", conversationID: nil).question == "Ligne un ligne deux")
    }

    @Test("Une question trop longue est coupée à 140 caractères, avec une ellipse")
    func longQuestion() {
        let long = String(repeating: "a", count: 500)
        let question = SearchActivityAttributes(question: long, conversationID: nil).question
        #expect(question.count == SearchActivityAttributes.maxQuestionLength)
        #expect(question.hasSuffix("…"))
        let exact = String(repeating: "b", count: 140)
        #expect(SearchActivityAttributes(question: exact, conversationID: nil).question == exact)
    }

    @Test("Un toucher ouvre la conversation, ou rien sans conversation")
    func tapURL() throws {
        let id = try #require(UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF"))
        let url = try #require(SearchActivityAttributes(question: "q", conversationID: id).tapURL)
        #expect(TrivaURLRoute.parse(url) == .conversation(id))
        #expect(SearchActivityAttributes(question: "q", conversationID: nil).tapURL == nil)
    }

    @Test("Attributs et état, encodés ensemble, tiennent très largement sous les 4 Ko (pire cas : 140 emojis)")
    func encodedSizeUnderFourKilobytes() throws {
        let worst = String(repeating: "\u{1F9D1}\u{200D}\u{1F680}", count: 140)
        let attributes = SearchActivityAttributes(question: worst, conversationID: UUID())
        let attributesData = try JSONEncoder().encode(attributes)
        let stateData = try JSONEncoder().encode(state(.reading, 10_000))
        #expect(attributesData.count < 4_096)
        #expect(stateData.count < 4_096)
        #expect(attributesData.count + stateData.count < 4_096)
    }

    @Test("L'état fait l'aller-retour JSON")
    func stateRoundTrip() throws {
        let original = state(.reading, 6)
        let decoded = try JSONDecoder().decode(SearchActivityState.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
    }
}
