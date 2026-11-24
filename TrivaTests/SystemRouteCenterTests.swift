//
//  SystemRouteCenterTests.swift
//  TrivaTests
//
//  Chantier 2.1 (mission A) : une route est consommée UNE fois ; sur Mac elle passe par le lanceur de fenêtres ;
//  elle n'envoie JAMAIS une question.
//

import Foundation
import Testing
@testable import Triva

@MainActor
@Suite("Routeur système")
struct SystemRouteCenterTests {
    // MARK: iPhone et iPad : file vidée par la fenêtre active

    @Test("Une route déposée n'est rendue qu'UNE fois : un seul consommateur")
    func routeIsConsumedOnce() {
        let center = SystemRouteCenter(windowLauncher: nil)
        center.submit(.newQuestion(.keyboard))

        #expect(center.drain() == [.newQuestion(.keyboard)])
        #expect(center.drain().isEmpty)
    }

    @Test("Chaque dépôt fait avancer la révision (déclencheur des onChange), la lecture jamais")
    func revisionAdvancesOnSubmitOnly() {
        let center = SystemRouteCenter(windowLauncher: nil)
        #expect(center.revision == 0)
        center.submit(.newQuestion(.keyboard))
        center.submit(.conversation(UUID()))
        #expect(center.revision == 2)
        _ = center.drain()
        #expect(center.revision == 2)
    }

    @Test("Les routes restent dans l'ordre, et la file est bornée : les plus anciennes sont oubliées")
    func queueIsOrderedAndBounded() {
        let center = SystemRouteCenter(windowLauncher: nil)
        let ids = (0..<(SystemRouteCenter.maxPending + 4)).map { _ in UUID() }
        for id in ids { center.submit(.conversation(id)) }

        #expect(center.drain() == ids.suffix(SystemRouteCenter.maxPending).map { .conversation($0) })
    }

    @Test("Un brouillon est assaini à l'entrée ; vide ou illisible, il est jeté")
    func draftIsSanitized() {
        let center = SystemRouteCenter(windowLauncher: nil)
        center.submit(.draft("  Bonjour\u{202E}\u{200B} le monde\t! \n"))
        center.submit(.draft("   \n\t "))
        center.submit(.draft("\u{200B}\u{202E}"))

        #expect(center.drain() == [.draft("Bonjour le monde !")])
    }

    // MARK: Mac : délégation au lanceur de fenêtres

    @Test("Mac, nouvelle question : le lanceur ouvre une recherche neuve, la file reste vide")
    func macNewQuestionGoesToLauncher() {
        let launcher = ExternalSearchLauncher()
        let center = SystemRouteCenter(windowLauncher: launcher)

        center.submit(.newQuestion(.keyboard))

        let targets = launcher.drain()
        #expect(targets.count == 1)
        if case .newSearch = targets.first {} else { Issue.record("Une recherche neuve était attendue : \(targets)") }
        #expect(center.drain().isEmpty)
    }

    @Test("Mac, conversation : le lanceur ouvre ou ramène cette conversation")
    func macConversationGoesToLauncher() {
        let launcher = ExternalSearchLauncher()
        let center = SystemRouteCenter(windowLauncher: launcher)
        let id = UUID()

        center.submit(.conversation(id))

        #expect(launcher.drain() == [.conversation(id)])
        #expect(center.drain().isEmpty)
    }

    @Test("Mac, brouillon : déposé comme BROUILLON (origine .draft), donc jamais envoyé par la fenêtre")
    func macDraftIsNeverSent() throws {
        let launcher = ExternalSearchLauncher()
        let center = SystemRouteCenter(windowLauncher: launcher)

        center.submit(.draft("Une question privée"))

        guard case .newSearch(let id) = launcher.drain().first else {
            Issue.record("Une recherche neuve était attendue")
            return
        }
        let query = try #require(launcher.inbox.takeQuery(for: id))
        #expect(query.text == "Une question privée")
        #expect(query.origin == .draft)
        #expect(center.drain().isEmpty)
    }

    @Test("Mac, brouillon vide ou illisible : aucune fenêtre ne s'ouvre")
    func macEmptyDraftOpensNothing() {
        let launcher = ExternalSearchLauncher()
        let center = SystemRouteCenter(windowLauncher: launcher)

        center.submit(.draft(" \u{200B} "))

        #expect(launcher.drain().isEmpty)
        #expect(launcher.revision == 0)
    }

    // MARK: URL

    @Test("open(url:) : une URL valide devient une route, une URL piégée ne fait rien")
    func openURL() throws {
        let center = SystemRouteCenter(windowLauncher: nil)
        let id = UUID()

        #expect(center.open(url: try #require(URL(string: "triva://conversation/\(id.uuidString)"))))
        #expect(!center.open(url: try #require(URL(string: "triva://new?q=envoie"))))
        #expect(!center.open(url: try #require(URL(string: "https://example.com"))))

        #expect(center.drain() == [.conversation(id)])
    }
}
