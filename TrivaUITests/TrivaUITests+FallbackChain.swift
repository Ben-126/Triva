//
//  TrivaUITests+FallbackChain.swift
//  TrivaUITests
//
//  Chaîne de secours sans SearXNG (test10) et geste de fermeture du clavier sur un fil qui ne défile
//  pas (test10b). À part pour garder `TrivaUITests.swift` sous 800 lignes.
//

import XCTest

extension TrivaUITests {
    // MARK: - 10. Chaîne de secours

    /// Aucune instance SearXNG joignable, vrai réseau pour le reste : la question reçoit quand même
    /// une réponse sourcée, sans bandeau d'erreur, grâce aux sources ouvertes de `WebSearchChain`.
    ///
    /// La liste embarquée est remplacée par la liste neutre (`neutralDefaults`, `.invalid`) puis
    /// masquée par argument : ce fichier ne doit contenir aucune adresse de la liste locale, qui porte
    /// une instance personnelle, et l'argument ne laisse rien dans le simulateur. Le journal du
    /// simulateur (catégorie `WebSearchChain`) montre en plus l'échec de SearXNG, s'il faut recouper.
    func test10_chaineDeSecours_sansSearXNG_sourcesOuvertes() throws {
        launchToSearch(extraArguments: try instanceArguments(directory: [], added: [Self.deadInstance], hidden: Self.neutralDefaults))
        step("Seule l'instance en panne reste dans la liste") {
            open(.settings)
            openSearXNGInstances()
            let listed = listedInstanceAddresses()
            XCTAssertTrue(listed == [Self.deadInstance], "La liste doit se réduire à l'instance en panne : \(listed.count) instance(s) lue(s).")
            capture("10-1 Liste réduite à l'instance en panne")
        }
        step("La réponse vient des sources ouvertes") {
            open(.search)
            _ = sendQuestion("Cherche la hauteur de la tour Eiffel")
            waitForAnswerEnd()
            scrollKeyboardAway()
            capture("10-2 Réponse sans SearXNG")
            let sources = elements("source.link").allElementsBoundByIndex.map(\.label)
            XCTAssertFalse(sources.isEmpty, "Réponse sans source alors que les sources ouvertes répondent.")
            // Ligne discrète sous les sources : SearXNG n'a rien à y annoncer, tout autre service oui.
            let origin = require(element(labelPrefix: "Résultats\u{00A0}: "), "L'écran ne dit pas d'où viennent les résultats.")
            attachText("Sources reçues sans SearXNG", ([origin.label] + sources).joined(separator: "\n"))
        }
        deleteConversationsLeftByAnEarlierRun()
    }

    /// iPad seulement : force la branche « le fil ne défile pas » de `scrollKeyboardAway`, que
    /// `test10` n'atteint que si la réponse tient dans la zone visible et que le geste n'y ferme rien.
    ///
    /// Constat de la mission E2x2 (iPad Pro 13, fenêtre pleine, réponse d'un mot) : même un fil court
    /// qui ne peut pas défiler ferme le clavier sous le doigt, donc un fil court ne suffit pas à
    /// atteindre la branche. Elle est forcée par le geste : le même glissement, démarré dans la barre
    /// latérale (hors du fil), ne ferme rien et ne déplace pas la question, soit exactement les deux
    /// conditions de la branche. Le test joue d'abord le geste normal et en joint le résultat.
    func test10b_ipad_geste_horsDuFil_clavierFermeParRetour() throws {
        try XCTSkipUnless(isPad, "Branche propre à l'iPad : sur iPhone, un fil qui ne défile pas est un échec.")
        launchApp()
        requireChatReady()
        deleteConversationsLeftByAnEarlierRun()
        open(.search)
        _ = sendQuestion(Self.shortQuestion)
        waitForAnswerEnd()
        capture("10b-1 Fil court, clavier ouvert")
        let normal = scrollKeyboardAway()
        attachText("Geste normal sur un fil court", "Résultat : \(normal)")
        capture("10b-2 Après le geste dans le fil")

        let input = require(element("chat.input"), "Barre de saisie absente.")
        input.tap()
        require(app.keyboards.firstMatch, "Le clavier ne se rouvre pas.")
        let outsideThread = app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.7))
        let forced = scrollKeyboardAway(dragFrom: outsideThread)
        capture("10b-3 Après le geste hors du fil")
        deleteConversationsLeftByAnEarlierRun()
        XCTAssertEqual(forced, .threadFitsClosedByReturn, "Le geste hors du fil doit passer par la branche « fil immobile », clavier fermé par Retour.")
    }

    /// Adresses de la liste des instances. `Form` ne construit que ce qui est visible : on relit à
    /// chaque écran, en balayage lent pour ne sauter aucune ligne, jusqu'au bouton qui suit la liste.
    func listedInstanceAddresses() -> Set<String> {
        let testAll = "Tester toutes les instances"
        let rowButtons = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Tester ' AND label != %@", testAll))
        var addresses = Set<String>()
        for _ in 0..<10 {
            addresses.formUnion(rowButtons.allElementsBoundByIndex.map { String($0.label.dropFirst("Tester ".count)) })
            if app.buttons[testAll].exists, app.buttons[testAll].isHittable {
                break
            }
            app.collectionViews.firstMatch.swipeUp(velocity: .slow)
        }
        return addresses
    }
}
