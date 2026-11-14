//
//  TrivaUITests+TestData.swift
//  TrivaUITests
//
//  Données créées par les tests : marqueur de run et nettoyage (R4-1). À part pour garder
//  `TrivaUITests.swift` sous 800 lignes.
//

import XCTest

extension TrivaUITests {
    // MARK: - Marqueur de run (R4-1)

    /// Les tests jouent sur la VRAIE base de l'appareil (aucun argument de lancement ne l'isole, et le
    /// périmètre de cette mission exclut l'app) : ils ne doivent donc supprimer ou retrouver QUE ce
    /// qu'ils ont créé. Chaque question de test commence par un marqueur : le préfixe fixe
    /// `markerPrefix` (rare, sans sens, que ne tape aucun humain) puis cinq chiffres tirés une fois par
    /// run. Le titre d'une conversation est coupé à 60 caractères sur une frontière de mot
    /// (`ChatHistoryModels.title`) : le marqueur est donc EN TÊTE, jamais en queue. Les chiffres
    /// échappent au correcteur du clavier.
    ///
    /// - Retrouver ses propres lignes (Bibliothèque, Favoris) : `runMarker` + fragment. Un favori
    ///   resté d'un run interrompu porte un autre `runMarker` et ne gêne plus `checkFavoriteRoundTrip`.
    /// - Nettoyer : toute ligne portant `markerPrefix` (ce run, ou un run interrompu : c'est un test
    ///   qui l'a créée). Une conversation réelle de l'utilisateur ne le porte jamais.
    static let markerPrefix = "ZQX"
    static let runMarker = "\(markerPrefix)\(String(format: "%05d", Int.random(in: 0...99_999)))"

    /// La question de test avec le marqueur du run en tête.
    static func marked(_ question: String) -> String {
        "\(runMarker) : \(question)"
    }

    /// Supprime par le balayage les conversations CRÉÉES PAR LES TESTS (celles qui portent
    /// `markerPrefix`), y compris celles d'un run interrompu : la Bibliothèque d'un simulateur ne doit
    /// pas se remplir de tests. Une conversation réelle de l'utilisateur n'est jamais visée, même
    /// quand elle parle de la tour Eiffel (R4-1).
    ///
    /// La liste est paresseuse : seules les lignes proches de l'écran existent dans l'arbre. On ne
    /// compte donc jamais les lignes. On supprime la première ligne visée, on attend que CETTE ligne
    /// (son libellé complet) ait disparu, et on recommence ; quand plus aucune n'est visible, on fait
    /// défiler jusqu'à la fin de la liste avant de conclure qu'il n'en reste pas.
    func deleteConversationsLeftByAnEarlierRun() {
        deleteConversations(labelContaining: Self.markerPrefix)
    }

    /// Le balayage lui-même, pour tout libellé que le test a lui-même créé.
    func deleteConversations(labelContaining tag: String) {
        open(.library)
        let rows = elements("library.row").matching(NSPredicate(format: "label CONTAINS %@", tag))
        var isFirstLookup = true
        for _ in 0..<Self.maxLeftoverDeletions {
            guard let row = nextLeftoverRow(rows, patience: isFirstLookup ? 3 : 1) else { return }
            isFirstLookup = false
            let sameRow = rows.matching(NSPredicate(format: "label == %@", row.label))
            let before = sameRow.count
            row.swipeLeft()
            require(app.buttons["Supprimer"].firstMatch, "Balayage : « Supprimer » absent.").tap()
            require(app.buttons["Supprimer"].firstMatch, "Confirmation de suppression absente.").tap()
            let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count < %d", before), object: sameRow)
            XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: Timeout.screen), .completed, "Suppression sans effet.")
        }
        XCTFail("Plus de \(Self.maxLeftoverDeletions) conversations de test à supprimer : le nettoyage ne converge pas.")
    }

    /// Garde-fou de `deleteConversationsLeftByAnEarlierRun` : un run interrompu en laisse quelques-unes.
    static let maxLeftoverDeletions = 60

    /// La première ligne de test visible, sinon la première trouvée en faisant défiler la liste jusqu'à
    /// sa fin (la liste ne bouge plus quand la dernière ligne chargée ne change pas).
    func nextLeftoverRow(_ rows: XCUIElementQuery, patience: TimeInterval) -> XCUIElement? {
        if rows.firstMatch.waitForExistence(timeout: patience) { return rows.firstMatch }
        let list = app.collectionViews.firstMatch
        guard list.exists else { return nil }
        var lastLoaded = elements("library.row").allElementsBoundByIndex.last?.label
        for _ in 0..<Self.maxLibraryScrolls {
            list.swipeUp()
            if rows.firstMatch.exists { return rows.firstMatch }
            let nowLoaded = elements("library.row").allElementsBoundByIndex.last?.label
            if nowLoaded == lastLoaded { return nil }
            lastLoaded = nowLoaded
        }
        return nil
    }

    static let maxLibraryScrolls = 30

    // MARK: - Garde-fou du nettoyage (R4-1)

    /// Une conversation qui parle de la tour Eiffel et dont la question contient « seulement par le
    /// mot » (les fragments que l'ancien nettoyage visait) mais SANS le marqueur des tests doit
    /// survivre à `deleteConversationsLeftByAnEarlierRun` : c'est ce qu'est, pour l'app, une vraie
    /// conversation de l'utilisateur. Elle est créée ici, donc supprimée ici (marqueur à part,
    /// `survivorPrefix`, y compris si un run précédent s'est arrêté avant la fin).
    func testR41_nettoyage_neSupprimePasUneConversationDeLUtilisateur() throws {
        launchApp()
        requireChatReady()
        deleteConversations(labelContaining: Self.survivorPrefix)
        open(.search)
        let tag = "\(Self.survivorPrefix)\(String(format: "%05d", Int.random(in: 0...99_999)))"
        _ = sendQuestion("\(tag) : réponds seulement par le mot OK à propos de la tour Eiffel, sans rien chercher.")
        waitForAnswerEnd()

        step("Le nettoyage des tests laisse la conversation") {
            deleteConversationsLeftByAnEarlierRun()
            open(.library)
            let survivor = elements("library.row").matching(NSPredicate(format: "label CONTAINS %@", tag)).firstMatch
            XCTAssertTrue(survivor.waitForExistence(timeout: Timeout.screen), "Le nettoyage a supprimé une conversation qui n'est pas de test.")
        }
        deleteConversations(labelContaining: Self.survivorPrefix)
    }

    /// Marqueur de la conversation du garde-fou : différent de `markerPrefix`, sinon elle serait nettoyée.
    static let survivorPrefix = "ZQW"
}
