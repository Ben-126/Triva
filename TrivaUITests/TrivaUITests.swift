//
//  TrivaUITests.swift
//  TrivaUITests
//
//  Created by ben podrojsky on 27/08/2026.
//

import XCTest

/// Parcours fonctionnels réels de l'app (mission Q1), joués sur l'iPhone 18 Pro puis l'iPad Pro, en
/// plein écran et en moitié d'écran (`arrangeWindowOnPad`) : vrai moteur Apple Intelligence, vrai
/// réseau, vraie base SwiftData. Rien n'est simulé dans l'app. XCUITest n'existe qu'avec XCTest :
/// c'est la seule exception à Swift Testing dans le projet.
///
/// ## État de départ : arguments de lancement, aucune ligne de test dans l'app
/// Un argument `-clé valeur` passe dans le domaine `NSArgumentDomain` de `UserDefaults`, qui gagne à
/// la lecture sur le domaine persistant : chaque test choisit son moteur et son mode sans que l'app
/// sache qu'elle est testée. PIÈGE : les écritures de l'app vont dans le domaine persistant, et
/// l'argument continue de gagner à la lecture suivante. Un test de persistance ne doit donc JAMAIS
/// épingler la clé qu'il vérifie (voir `test06`), sinon il relirait sa propre valeur de lancement.
///
/// ## Ordre et coût
/// XCTest joue les méthodes par ordre alphabétique, d'où leur numéro. Une réponse réelle prend
/// plusieurs dizaines de secondes : recherche, historique et favoris (parcours 3, 4 et 5) partagent
/// donc une seule question dans `test03`, qui efface sa conversation en partant.
@MainActor
final class TrivaUITests: XCTestCase {

    /// Question de `test03`. Demande explicitement une recherche : le classifieur sur l'appareil saute
    /// parfois la recherche (`skipSearch`) sur une simple question de fait. Vu dans le journal du
    /// simulateur, réponses « 330 pieds » et « Je ne suis pas sûr. », sans source. Courte : le titre
    /// de la Bibliothèque se coupe vers 55 caractères.
    private static let question = "Cherche le prix d'un billet pour la tour Eiffel"
    /// Fragment reconnu dans les libellés : le correcteur du clavier peut retoucher le reste.
    private static let questionFragment = "tour Eiffel"
    /// Question d'une conversation à part (`checkStreamingThenStop`), à la réponse la plus longue
    /// possible. Pas de « Cite » : le classifieur y lit une demande de citations, donc une recherche
    /// académique, hors sujet (constaté, rapport Q1).
    private static let streamingQuestion = "Explique le fonctionnement d'un moteur à réaction, étape par étape"
    private static let streamingFragment = "moteur à"
    /// Instances factices semées dans l'annuaire (`test08b`) : le domaine `.example` est réservé,
    /// aucune requête n'atteint jamais un vrai serveur.
    private static let seededInstances = ["annuaire-un.example", "annuaire-deux.example"]
    /// Seule instance de `test10`. `.invalid` : domaine réservé, jamais résolu (RFC 2606).
    private static let deadInstance = "panne.invalid"

    // MARK: - Mise en place

    var app: XCUIApplication!

    nonisolated override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - 1. Démarrage à froid

    func test01_demarrageAFroid_choixDuMoteur_recherche_bonBadge() throws {
        launchApp(engine: "none")

        checkEngineChoiceScreen()

        step("Apple Intelligence → Recherche, bon badge") {
            element("engine.card.appleIntelligence").tap()
            element("engine.continue").tap()
            // Étape facultative de clé de recherche (mission C2) : aucune saisie n'est exigée,
            // « Commencer » la passe.
            XCTAssertTrue(app.staticTexts["Une clé de recherche ?"].waitForExistence(timeout: Timeout.launch), "Étape de clé de recherche absente.")
            XCTAssertTrue(element("onboarding.searchKey.add").exists, "« Ajouter une clé » absent.")
            capture("01-1b Étape clé de recherche")
            require(element("onboarding.searchKey.start"), "« Commencer » absent de l'étape de clé de recherche.").tap()
            let badge = require(engineBadgeText, "Badge moteur absent après le choix.")
            XCTAssertEqual(badge.label, "Apple Intelligence · Sur l'appareil")
            XCTAssertEqual(element("search.engineCaption").label, "Aucune IA cloud utilisée")
            requireChatReady()
            capture("01-2 Recherche, Apple Intelligence")
        }

        checkOtherEngineBadges()

        step("Le choix survit à un vrai relancement") {
            // Sans l'argument, c'est bien la valeur ENREGISTRÉE qui est relue.
            app.launchArguments.removeAll { $0 == "-\(StoredKey.engine)" || $0 == "none" }
            relaunchApp()
            let badge = require(engineBadgeText, timeout: Timeout.launch, "Le moteur choisi n'a pas été retenu.")
            XCTAssertEqual(badge.label, "Apple Intelligence · Sur l'appareil")
            XCTAssertFalse(element("engine.continue").exists, "L'écran de choix est revenu après relancement.")
        }
    }

    private func checkEngineChoiceScreen() {
        step("Écran de choix du moteur, plein écran") {
            require(element("engine.continue"), timeout: Timeout.launch, "Écran de choix absent au premier lancement.")
            XCTAssertTrue(app.staticTexts["Choisis ton moteur IA"].exists)
            for option in ["appleIntelligence", "mlxLocal", "cloudBYOK"] {
                XCTAssertTrue(element("engine.card.\(option)").exists, "Carte \(option) absente.")
            }
            XCTAssertFalse(element("engine.cancel").exists, "« Annuler » n'a pas de sens au premier lancement.")
            XCTAssertFalse(app.tabBars.buttons[Space.settings.rawValue].exists, "La coquille ne doit pas précéder le choix.")
            capture("01-1 Écran de choix du moteur")
        }
    }

    /// Le badge dit la vérité du moteur actif, et « Annuler » ne change rien.
    private func checkOtherEngineBadges() {
        step("Clé API : le badge ne dit jamais « Sur l'appareil »") {
            switchEngine(to: "cloudBYOK")
            let badge = require(engineBadgeText, "Badge moteur absent.")
            XCTAssertEqual(badge.label, "Clé API personnelle")
            XCTAssertTrue(element("search.engineCaption").label.contains("fournisseur"), "La légende doit parler du fournisseur.")
            XCTAssertTrue(element("search.configureAPIKey").exists, "Sans fournisseur choisi, l'écran doit proposer de configurer une clé.")
            capture("01-3 Recherche, clé API")
        }

        step("Changer de moteur puis Annuler ne change rien") {
            element("search.changeEngine").tap()
            require(element("engine.cancel"), "« Annuler » absent d'un changement de moteur.").tap()
            let badge = require(engineBadgeText, "Retour à la Recherche impossible après Annuler.")
            XCTAssertEqual(badge.label, "Clé API personnelle", "Annuler ne doit pas changer de moteur.")
        }

        step("MLX : bon badge et choix de modèle proposé") {
            switchEngine(to: "mlxLocal")
            let badge = require(engineBadgeText, "Badge moteur absent.")
            XCTAssertEqual(badge.label, "Modèle local (MLX) · Sur l'appareil")
            XCTAssertTrue(element("search.chooseMLXModel").exists, "Sans modèle choisi, l'écran doit proposer d'en choisir un.")
            capture("01-4 Recherche, MLX")
            switchEngine(to: "appleIntelligence")
            XCTAssertEqual(require(engineBadgeText, "Badge moteur absent.").label, "Apple Intelligence · Sur l'appareil")
        }
    }

    private func switchEngine(to option: String) {
        require(element("search.changeEngine"), "« Changer de moteur » absent.").tap()
        require(element("engine.card.\(option)"), "Carte \(option) absente.").tap()
        element("engine.continue").tap()
    }

    // MARK: - 2. Navigation

    func test02_navigation_espacesEtReglages_sansEcranVide() throws {
        launchToSearch()
        XCTAssertFalse(element("engine.continue").exists, "Moteur épinglé : l'écran de choix ne doit pas paraître.")

        for space in [Space.discover, .library, .favorites, .settings, .search] {
            step("Espace \(space.rawValue)") {
                open(space)
                XCTAssertGreaterThan(app.staticTexts.count, 0, "\(space.rawValue) : écran sans aucun texte.")
                capture("02 \(space.rawValue)")
            }
        }

        step("Aller-retour : la Recherche et sa barre de saisie sont intactes") {
            open(.settings)
            open(.search)
            requireChatReady()
        }

        step("Réglages : un écran poussé, puis retour") {
            open(.settings)
            openSettingsRow("settings.searchKeys", title: "Clés de recherche")
            goBack(to: Space.settings.rawValue)
        }

        // En sidebar (iPad, Mac), toutes les piles partagent la colonne de détail : quitter un espace
        // sur un écran poussé a fait planter l'app (bug trouvé par `test10`, voir `TrivaRootView`).
        step("Changer d'espace sur un écran poussé, et y revenir") {
            openSettingsRow("settings.searchKeys", title: "Clés de recherche")
            capture("02 Écran poussé avant de changer d'espace")
            open(.search)
            requireChatReady()
            tapSpace(.settings)
            // Onglets : chaque pile garde son écran. Sidebar : la colonne commune le referme.
            let pushed = app.navigationBars.staticTexts["Clés de recherche"].firstMatch
            XCTAssertNotNil(firstExisting([pushed, marker(of: .settings)], timeout: Timeout.screen), "Réglages : ni l'écran poussé, ni la racine.")
            capture("02 Retour aux Réglages après un écran poussé")
            if pushed.exists {
                goBack(to: Space.settings.rawValue)
            }
        }

        step("Brouillon : toucher le fil ferme le clavier, le texte survit à un aller-retour") {
            open(.search)
            let input = require(element("chat.input"), "Barre de saisie absente.")
            input.tap()
            input.typeText("brouillon")
            capture("02 Brouillon, clavier ouvert")
            // Sur iPhone, Retour enverrait le brouillon et le clavier cache la barre d'onglets : c'est
            // la seule sortie sans envoyer. Le fil vide ne défile pas, d'où le toucher.
            threadPoint.tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: Timeout.screen), "Toucher le fil ne ferme pas le clavier.")
            open(.settings)
            open(.search)
            XCTAssertEqual(element("chat.input").value as? String, "brouillon", "Le brouillon n'a pas survécu à l'aller-retour.")
        }
    }

    // MARK: - 3, 4, 5. Recherche de bout en bout, historique, favoris

    func test03_recherche_historique_favoris() throws {
        launchApp()
        requireChatReady()
        deleteConversationsLeftByAnEarlierRun()
        open(.search)

        step("3. Question envoyée : génération puis sources") {
            askAndCheckAnswer()
        }
        step("4a. La conversation est dans la Bibliothèque et s'y rouvre") {
            openConversationFromLibrary()
        }
        step("4b. Elle y reste après terminate() + launch()") {
            relaunchApp()
            require(element("search.engineBadge"), timeout: Timeout.launch, "Recherche absente au relancement.")
            XCTAssertFalse(element("chat.question").exists, "Le lancement doit ouvrir une conversation vierge.")
            openConversationFromLibrary()
            XCTAssertGreaterThan(elements("source.link").count, 0, "Les sources n'ont pas survécu au relancement.")
            capture("04 Conversation rouverte après relancement")
        }
        step("5. Favori : marquer, retrouver, retirer") {
            checkFavoriteRoundTrip()
        }
        step("3 bis. Stop pendant la recherche : la main revient") {
            checkStopDuringSearch()
        }
        step("3 ter. Le texte arrive par morceaux, Stop en pleine écriture") {
            checkStreamingThenStop()
        }
        step("Ménage : la conversation est supprimée") {
            deleteConversationsLeftByAnEarlierRun()
            open(.search)
            XCTAssertFalse(element("chat.question").waitForExistence(timeout: 2), "Le fil d'une conversation supprimée doit se vider.")
        }
    }

    /// Envoie la question avec le bouton, attend la réponse et ses sources. L'étoile n'existe qu'une
    /// fois la réponse terminée ET enregistrée : c'est le seul signal de fin qui garantit les deux.
    /// Le streaming se vérifie ailleurs (`checkStreamingThenStop`) : cette réponse tient en deux
    /// lignes et s'écrit plus vite qu'une lecture de l'arbre d'accessibilité.
    private func askAndCheckAnswer() {
        let send = sendQuestion(Self.question)
        require(element(labelContaining: Self.questionFragment), "La question n'apparaît pas dans le fil.")
        capture("03-1 Génération en cours")

        waitForAnswerEnd()
        capture("03-2 Réponse terminée")
        scrollKeyboardAway()
        capture("03-2b Réponse lisible, clavier fermé")
        XCTAssertEqual(send.label, "Envoyer", "La fin de réponse doit rendre le bouton d'envoi.")
        XCTAssertFalse(element("chat.error").exists, "Bandeau d'erreur sur une réponse réussie.")

        let sources = elements("source.link")
        XCTAssertGreaterThan(sources.count, 0, "Réponse sans aucune source sur une question factuelle.")
        attachText("Réponse et sources", "Source 1 : \(sources.firstMatch.label)\nRéponse : \(element("citation.text").label)")
    }

    /// Le clavier, resté ouvert depuis l'envoi, cache la moitié de la réponse : on fait défiler le
    /// fil, sans toucher (un toucher pourrait ouvrir un lien de source).
    private func scrollKeyboardAway() {
        threadPoint.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: Timeout.screen), "Défiler dans le fil ne ferme pas le clavier.")
    }

    /// Attend l'étoile ou le bandeau d'erreur, sans pause fixe.
    private func waitForAnswerEnd() {
        guard let end = firstExisting([element("chat.favorite"), element("chat.error")], timeout: Timeout.answer) else {
            return XCTFail("Pas de fin de réponse après \(Int(Timeout.answer)) s.")
        }
        XCTAssertNotEqual(end.identifier, "chat.error", "Erreur à la place de la réponse : \(end.label)")
    }

    private func attachText(_ name: String, _ text: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func libraryRow() -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: "library.row")
            .matching(NSPredicate(format: "label CONTAINS %@", Self.questionFragment))
            .firstMatch
    }

    private func openConversationFromLibrary() {
        open(.library)
        capture("04 Bibliothèque")
        require(libraryRow(), "Conversation absente de la Bibliothèque.").tap()
        require(element("search.engineBadge"), "L'ouverture doit ramener sur la Recherche.")
        require(element(labelContaining: Self.questionFragment), "Question absente de la conversation rouverte.")
        require(element("citation.text"), "Réponse absente de la conversation rouverte.")
    }

    /// Part de la conversation ouverte dans la Recherche.
    private func checkFavoriteRoundTrip() {
        let star = require(element("chat.favorite"), "Étoile absente d'une réponse enregistrée.")
        XCTAssertEqual(star.label, "Ajouter aux favoris")
        star.tap()
        XCTAssertTrue(waitUntil(star, "label == %@", "Retirer des favoris"), "L'étoile n'a pas pris le favori.")
        capture("05-1 Étoile pleine")

        open(.favorites)
        let favorite = elements("favorites.row")
            .matching(NSPredicate(format: "label CONTAINS %@", Self.questionFragment))
            .firstMatch
        require(favorite, "Le favori est absent de l'écran Favoris.")
        capture("05-2 Favoris")
        favorite.tap()
        require(app.navigationBars.staticTexts["Favori"].firstMatch, "Détail du favori absent.")
        require(element("citation.text"), "Réponse absente du détail du favori.")
        capture("05-3 Détail du favori")
        checkLeavingFavoriteDetail(favorite)

        require(element("favorites.detail.remove"), "« Retirer des favoris » absent du détail.").tap()
        require(app.buttons["Retirer"].firstMatch, "Confirmation du retrait absente.").tap()
        require(marker(of: .favorites), "Le retrait doit ramener à la liste.")
        XCTAssertTrue(favorite.waitForNonExistence(timeout: Timeout.screen), "Le favori retiré reste dans la liste.")
        capture("05-4 Favori retiré")

        open(.search)
        XCTAssertTrue(waitUntil(element("chat.favorite"), "label == %@", "Ajouter aux favoris"), "L'étoile doit redevenir vide.")
    }

    /// Quitter le détail d'un favori, pile non vide, par les deux chemins de l'app. En sidebar la vue
    /// repart de sa liste, en onglets elle retrouve son détail : le test accepte les deux, seul le
    /// plantage compte (même bug que dans `test02`).
    private func checkLeavingFavoriteDetail(_ favorite: XCUIElement) {
        let remove = element("favorites.detail.remove")
        func backToDetail() {
            tapSpace(.favorites)
            if !remove.waitForExistence(timeout: 3) {
                require(favorite, "Le favori a disparu après un changement d'espace.").tap()
            }
            require(remove, "Détail du favori absent après un changement d'espace.")
        }
        open(.library)
        backToDetail()
        require(app.buttons["Ouvrir la conversation"].firstMatch, "« Ouvrir la conversation » absent du détail.").tap()
        require(element("search.engineBadge"), "« Ouvrir la conversation » doit ramener sur la Recherche.")
        backToDetail()
    }

    /// Une question de plus dans la conversation ouverte, puis Stop avant le moindre texte : le
    /// bouton redevient « Envoyer », le champ reste utilisable, et un arrêt n'est jamais une erreur.
    private func checkStopDuringSearch() {
        let send = sendQuestion("Quelle est la capitale de la Mongolie ?")
        capture("03-3 Avant Stop, recherche en cours")
        stopGeneration(with: send)
        XCTAssertTrue(element("chat.input").isEnabled, "La barre de saisie doit rester utilisable après Stop.")
        capture("03-4 Après Stop, recherche en cours")
    }

    /// Lit le texte jusqu'à le voir grandir (paliers de 32 caractères,
    /// `MessageBubblePresentation.streamingRevealStep`), puis l'arrête en pleine écriture : le texte
    /// reçu doit rester. Conversation neuve : dans le fil précédent, le modèle a déjà recopié sa
    /// réponse précédente au lieu de répondre (constaté, rapport Q1).
    ///
    /// CONSTAT ET NON ASSERTION : en mode Rapide, la réponse fait 2 à 3 phrases et s'écrit parfois en
    /// moins d'une seconde, soit le temps d'une lecture de l'arbre. Ne rien voir ne prouve donc pas
    /// une panne, et un test rouge une fois sur trois ne dirait rien. Les pièces jointes disent ce
    /// qui a été vu à chaque run.
    private func checkStreamingThenStop() {
        require(element("chat.newConversation"), "« Nouvelle conversation » absent.").tap()
        XCTAssertTrue(element("chat.question").waitForNonExistence(timeout: Timeout.screen), "Le fil ne s'est pas vidé.")
        let answer = element("citation.text")
        let send = sendQuestion(Self.streamingQuestion)

        var lengths: [Int] = []
        let deadline = Date.now.addingTimeInterval(Timeout.answer)
        while Set(lengths).count < 2, send.label == "Arrêter la génération", Date.now < deadline {
            if answer.exists {
                lengths.append(answer.label.count)
            }
        }
        let isStillWriting = send.label == "Arrêter la génération"
        if !isStillWriting, answer.exists {
            lengths.append(answer.label.count)
        }
        attachText(Set(lengths).count > 1 ? "Streaming observé" : "Streaming NON OBSERVÉ", "Longueurs lues : \(lengths)")
        capture("03-5 Pendant ou juste après l'écriture")

        guard isStillWriting else {
            return attachText("Stop en pleine écriture", "Non joué : réponse terminée avant l'appui.")
        }
        stopGeneration(with: send)
        XCTAssertTrue(answer.exists, "Le texte reçu avant Stop doit rester affiché.")
        attachText("Stop en pleine écriture", "Joué. Texte resté à l'écran : \(answer.label.count) caractères.")
        capture("03-6 Après Stop, en pleine écriture")
    }

    private func stopGeneration(with send: XCUIElement) {
        send.tap()
        XCTAssertTrue(waitUntil(send, "label == %@", "Envoyer", timeout: Timeout.stop), "Stop n'a pas rendu la main en \(Timeout.stop) s.")
        XCTAssertFalse(element("chat.error").exists, "Un arrêt volontaire n'est pas une erreur : \(element("chat.error").label)")
    }

    /// Saisit et envoie, puis attend le passage du bouton sur « Arrêter ». Rend le bouton.
    private func sendQuestion(_ text: String) -> XCUIElement {
        let input = require(element("chat.input"), "Barre de saisie absente.")
        input.tap()
        input.typeText(text)
        let send = element("chat.send")
        XCTAssertTrue(waitUntil(send, "enabled == true"), "Bouton d'envoi inactif malgré le texte saisi.")
        send.tap()
        XCTAssertTrue(waitUntil(send, "label == %@", "Arrêter la génération"), "L'envoi n'a pas démarré de génération.")
        return send
    }

    /// Supprime par le balayage toutes les conversations de ce test, y compris celles d'un run
    /// interrompu : la Bibliothèque d'un simulateur ne doit pas se remplir de tests.
    private func deleteConversationsLeftByAnEarlierRun() {
        open(.library)
        let rows = elements("library.row").matching(
            NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@", Self.questionFragment, Self.streamingFragment)
        )
        guard rows.firstMatch.waitForExistence(timeout: 3) else { return }
        var remaining = rows.count
        while remaining > 0 {
            rows.firstMatch.swipeLeft()
            require(app.buttons["Supprimer"].firstMatch, "Balayage : « Supprimer » absent.").tap()
            require(app.buttons["Supprimer"].firstMatch, "Confirmation de suppression absente.").tap()
            remaining -= 1
            let expected = remaining
            let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == %d", expected), object: rows)
            XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: Timeout.screen), .completed, "Suppression sans effet.")
        }
    }

    // MARK: - 6. Mode de réponse

    func test06_modeDeReponse_conserveApresRelancement() throws {
        // Aucune épingle du mode : c'est la valeur enregistrée que ce test met à l'épreuve.
        launchApp(responseMode: nil)
        requireChatReady()
        let selector = element("chat.responseMode")
        let initial = selector.value as? String ?? "Rapide"

        step("Choisir Fiable") { select(mode: "Fiable") }
        step("Conservé après terminate() + launch()") {
            relaunchApp()
            requireChatReady()
            XCTAssertEqual(element("chat.responseMode").value as? String, "Fiable")
            capture("06 Mode conservé")
        }
        step("Retour au mode d'origine") {
            select(mode: initial)
            relaunchApp()
            requireChatReady()
            XCTAssertEqual(element("chat.responseMode").value as? String, initial)
        }
    }

    private func select(mode: String) {
        let selector = require(element("chat.responseMode"), "Sélecteur de mode absent.")
        selector.tap()
        let option = element(labelPrefix: mode, type: .button)
        require(option, "Option \(mode) absente du menu.")
        capture("06 Menu \(mode)")
        option.tap()
        XCTAssertTrue(waitUntil(selector, "value == %@", mode), "Le sélecteur n'affiche pas \(mode).")
    }

    // MARK: - 7. Découvrir

    func test07_decouvrir_contenuOuEtatPropre() throws {
        launchToSearch()
        open(.discover)

        let article = element("discover.article")
        let failure = element("discover.failure")
        let empty = element("discover.empty")
        guard let outcome = firstExisting([article, failure, empty], timeout: Timeout.discover) else {
            capture("07 Découvrir sans issue")
            XCTFail("Découvrir : ni article, ni erreur, ni état vide après \(Int(Timeout.discover)) s.")
            return
        }
        capture("07-1 Découvrir, \(outcome.identifier)")

        if outcome.identifier == "discover.article" {
            checkDiscoverArticles(firstArticle: article)
        } else {
            XCTAssertTrue(app.buttons["Réessayer"].exists || empty.exists, "État d'erreur sans action pour réessayer.")
        }
    }

    /// Sources dont les articles n'offrent pas « Chercher dans Triva » (`FeedSource.allowsAIUse` à
    /// faux dans `DiscoverFeedCatalog`, décision de Ben du 2026-11-11). Le libellé VoiceOver d'un
    /// article porte « titre, source, date » : on écarte ces sources par leur nom entre virgules.
    /// Sans ce tri, test07 échouait dès qu'un article Numerama arrivait en tête (mission V, iPad,
    /// 2026-11-12) alors que l'app faisait exactement ce que Ben a décidé.
    private static let sourcesWithoutAIUse = ["Numerama"]

    private func checkDiscoverArticles(firstArticle: XCUIElement) {
        XCTAssertGreaterThan(elements("discover.chip").count, 1, "Puces de sujets absentes.")
        let article = elements("discover.article").allElementsBoundByIndex.first { candidate in
            !Self.sourcesWithoutAIUse.contains { candidate.label.contains(", \($0), ") }
        } ?? firstArticle
        step("Chercher dans Triva pré-remplit la barre sans envoyer") {
            let title = article.label
            article.press(forDuration: 1.2)
            let search = element(labelPrefix: "Chercher dans Triva")
            require(search, "Menu contextuel : « Chercher dans Triva » absent.")
            capture("07-2 Menu de l'article")
            search.tap()
            require(element("search.engineBadge"), "« Chercher dans Triva » doit ramener sur la Recherche.")
            let input = require(element("chat.input"), "Barre de saisie absente.")
            let draft = input.value as? String ?? ""
            XCTAssertFalse(draft.isEmpty, "Barre de saisie vide après « Chercher dans Triva » (article : \(title)).")
            XCTAssertFalse(element("chat.question").exists, "La question ne doit PAS être envoyée d'office.")
            capture("07-3 Barre pré-remplie")
        }
    }

    // MARK: - 8. Réglages

    func test08a_reglages_chaqueSection() throws {
        launchToSearch()
        open(.settings)
        capture("08-1 Réglages")

        step("Moteur IA : badge et feuille de changement") {
            XCTAssertTrue(element("settings.engineBadge").label.hasPrefix("Apple Intelligence · Sur l'appareil"))
            element("settings.changeEngine").tap()
            require(element("engine.card.mlxLocal"), "Feuille de choix du moteur absente.")
            capture("08-2 Feuille moteur")
            app.navigationBars.buttons["Annuler"].firstMatch.tap()
            require(element("settings.changeEngine"), "Annuler n'a pas refermé la feuille.")
        }
        step("Clé API : Gérer les clés, fournisseur et modèle") {
            element("settings.apiKeys").tap()
            let title = app.navigationBars.staticTexts["Clés API"].firstMatch
            require(title, "Feuille des clés API absente.")
            capture("08-3 Clés API")
            app.navigationBars.firstMatch.swipeDown(velocity: .fast)
            require(element("settings.cloudModel"), "La feuille des clés API ne se referme pas.").tap()
            require(element(labelPrefix: "Fournisseur et modèle"), "Écran fournisseur et modèle absent.")
            capture("08-4 Fournisseur et modèle")
            goBack(to: Space.settings.rawValue)
        }
        step("Clés de recherche : l'écran, sans rien saisir") {
            openSettingsRow("settings.searchKeys", title: "Clés de recherche")
            for source in ["brave", "tavily"] {
                let field = element("searchKeys.field.\(source)")
                scrollTo(field)
                XCTAssertTrue(field.exists, "Champ \(source) absent (ou une clé est déjà enregistrée).")
                XCTAssertFalse(element("searchKeys.save.\(source)").isEnabled, "« Tester et enregistrer » actif sans saisie.")
                XCTAssertTrue(element("searchKeys.link.\(source)").exists, "Lien d'obtention \(source) absent.")
            }
            capture("08-5 Clés de recherche")
            goBack(to: Space.settings.rawValue)
        }
        step("Avancé : page à part, puis instances SearXNG") {
            openSearXNGInstances()
            XCTAssertTrue(element(labelPrefix: "Ajoutées automatiquement").exists || scrollAndFind("Ajoutées automatiquement"), "Section « Ajoutées automatiquement » absente.")
            capture("08-6 Instances SearXNG")
            goBack(to: "Avancé")
            capture("08-6b Avancé")
            goBack(to: Space.settings.rawValue)
        }
        step("Stockage : modèles MLX") {
            openSettingsRow("settings.mlxStorage", title: "Modèles MLX")
            capture("08-7 Modèles MLX")
            goBack(to: Space.settings.rawValue)
        }
    }

    /// Touche une ligne de Réglages et attend le titre de l'écran poussé.
    private func openSettingsRow(_ identifier: String, title: String) {
        let row = element(identifier)
        scrollTo(row)
        row.tap()
        require(app.navigationBars.staticTexts[title].firstMatch, "Écran « \(title) » absent.")
    }

    private func scrollAndFind(_ prefix: String) -> Bool {
        let target = element(labelPrefix: prefix)
        scrollTo(target)
        return target.exists
    }

    /// Réglages > Avancé (page à part, 2026-11-12) > Instances SearXNG.
    private func openSearXNGInstances() {
        openSettingsRow("settings.advanced", title: "Avancé")
        let row = require(element("settings.searxngInstances"), "« Instances SearXNG » absent de la page « Avancé ».")
        row.tap()
        require(app.navigationBars.staticTexts["Instances SearXNG"].firstMatch, "Écran des instances absent.")
    }

    /// Sème deux instances dans l'annuaire et efface les personnalisations éventuelles POUR CE
    /// LANCEMENT : l'écran est ainsi le même quel que soit l'état du simulateur.
    func test08b_instancesAjouteesAutomatiquement_retirer() throws {
        launchToSearch(extraArguments: try instanceArguments(directory: Self.seededInstances))
        open(.settings)
        openSearXNGInstances()

        let rows = elements("searxng.row.automatic")
        let first = app.staticTexts[Self.seededInstances[0]].firstMatch
        let second = app.staticTexts[Self.seededInstances[1]].firstMatch
        scrollTo(first)
        require(first, "Instance semée absente de « Ajoutées automatiquement » (lignes : \(rows.count)).")
        capture("08b-1 Section remplie")

        step("Balayage : Retirer") {
            first.swipeLeft()
            let remove = require(app.buttons["Retirer"].firstMatch, "Balayage : « Retirer » absent.")
            capture("08b-2 Balayage, Retirer visible")
            remove.tap()
            XCTAssertTrue(first.waitForNonExistence(timeout: Timeout.screen), "L'instance retirée reste affichée.")
            XCTAssertFalse(element(labelPrefix: "OK").exists, "Une alerte d'erreur a suivi le retrait.")
            XCTAssertTrue(scrollAndFind("Instances publiques vérifiées"), "Pied de section absent.")
            XCTAssertTrue(element(labelContaining: "1 instance masquée").exists, "Le pied doit dire qu'une instance est masquée.")
            capture("08b-3 Après balayage")
        }
        step("Menu contextuel : Retirer") {
            scrollTo(second)
            second.press(forDuration: 1.2)
            let remove = element(labelPrefix: "Retirer", type: .button)
            require(remove, "Menu contextuel : « Retirer » absent.")
            XCTAssertTrue(element(labelPrefix: "Tester", type: .button).exists, "Menu contextuel : « Tester » absent.")
            capture("08b-4 Menu contextuel")
            remove.tap()
            XCTAssertTrue(second.waitForNonExistence(timeout: Timeout.screen), "L'instance retirée reste affichée.")
            XCTAssertTrue(element(labelContaining: "2 instances masquées").waitForExistence(timeout: Timeout.screen), "Le pied doit compter les deux instances.")
            capture("08b-5 Après menu")
        }
        step("Revenir à la liste par défaut les fait revenir") {
            let reset = element("searxng.reset")
            scrollTo(reset)
            require(reset, "« Revenir à la liste par défaut » absent après un masquage.").tap()
            require(app.buttons["Rétablir la liste"].firstMatch, "Confirmation du rétablissement absente.").tap()
            scrollTo(first)
            require(first, "L'instance masquée n'est pas revenue.")
            capture("08b-6 Liste rétablie")
        }
    }

    /// Arguments qui fixent l'annuaire et les personnalisations POUR CE LANCEMENT. `<hex>` est la
    /// notation plist d'un `Data`, seule forme que le domaine d'arguments accepte pour ces clés.
    /// `nextAttemptAt` lointain : l'entretien de fond ne doit pas remplacer l'annuaire semé.
    private func instanceArguments(directory: [String], added: [String] = [], hidden: [String] = []) throws -> [String] {
        let farFuture = Date().addingTimeInterval(7 * 86_400).timeIntervalSinceReferenceDate
        let snapshot = try JSONSerialization.data(withJSONObject: [
            "instances": directory.map { "https://\($0)" },
            "nextAttemptAt": farFuture,
        ] as [String: Any])
        let overrides = try JSONSerialization.data(withJSONObject: [
            "addedInstances": added.map { "https://\($0)" },
            "hiddenDefaultInstances": hidden.map { "https://\($0)" },
        ])
        return [
            "-\(StoredKey.directorySnapshot)", Self.propertyListData(snapshot),
            "-\(StoredKey.instanceOverrides)", Self.propertyListData(overrides),
        ]
    }

    private static func propertyListData(_ data: Data) -> String {
        "<" + data.map { String(format: "%02x", $0) }.joined() + ">"
    }

    // MARK: - 9. Invitation à ajouter une clé

    /// Le bouton n'existe que si TOUTES les sources de recherche ont échoué sans que l'appareil soit
    /// hors ligne. Impossible à provoquer ici : pas de mode avion en simulateur, réseau partagé avec
    /// le Mac, et aucun code de test autorisé dans l'app. Une question sans résultat n'y suffit pas :
    /// Wikipédia est essayée dans toutes les catégories, et répondre à vide n'est pas un échec
    /// (`WebSearchChain.search`). Le test se déclare donc ignoré et dit pourquoi, au lieu de passer
    /// sans rien avoir vu.
    func test09_invitationCleDeRecherche() throws {
        throw XCTSkip("Échec de toutes les sources non provoquable : ni le bouton « Ajouter une clé de recherche », ni le message hors connexion n'ont pu être vus à l'écran.")
    }

    // MARK: - 10. Chaîne de secours

    /// Aucune instance SearXNG joignable, vrai réseau pour le reste : la question reçoit quand même
    /// une réponse sourcée, sans bandeau d'erreur, grâce aux sources ouvertes de `WebSearchChain`.
    ///
    /// La liste par défaut est LUE À L'ÉCRAN puis masquée par argument : ce fichier ne doit contenir
    /// aucune adresse de la liste locale, qui porte une instance personnelle, et l'argument ne laisse
    /// rien dans le simulateur. Le journal du simulateur (catégorie `WebSearchChain`) montre en plus
    /// l'échec de SearXNG, s'il faut recouper.
    func test10_chaineDeSecours_sansSearXNG_sourcesOuvertes() throws {
        launchToSearch()
        open(.settings)
        openSearXNGInstances()
        let defaults = listedInstanceAddresses()
        XCTAssertFalse(defaults.isEmpty, "Aucune instance lue à l'écran.")
        app.terminate()

        launchToSearch(extraArguments: try instanceArguments(directory: [], added: [Self.deadInstance], hidden: Array(defaults)))
        step("Seule l'instance en panne reste dans la liste") {
            open(.settings)
            openSearXNGInstances()
            XCTAssertEqual(listedInstanceAddresses(), [Self.deadInstance])
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

    /// Adresses de la liste des instances. `Form` ne construit que ce qui est visible : on relit à
    /// chaque écran, en balayage lent pour ne sauter aucune ligne, jusqu'au bouton qui suit la liste.
    private func listedInstanceAddresses() -> Set<String> {
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
