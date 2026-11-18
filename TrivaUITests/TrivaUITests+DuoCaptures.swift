//
//  TrivaUITests+DuoCaptures.swift
//  TrivaUITests
//
//  Mission D0 (préparation de la tâche 2.0, iPhone Duo).
//

import XCTest

/// Captures d'écran de tous les écrans principaux sur iPhone Duo, écrites en PNG dans un dossier choisi
/// par l'environnement. Ce ne sont PAS des tests de non-régression : aucune assertion ne bloque, chaque
/// écran manquant est noté dans `journal.txt` et le parcours continue.
///
/// Lancement (jamais sans cette variable, sinon les tests sont ignorés) :
/// `TEST_RUNNER_TRIVA_CAPTURE_DIR=<dossier> TEST_RUNNER_TRIVA_POSE=plie TEST_RUNNER_TRIVA_THEME=clair`
/// (`TRIVA_POSE` et `TRIVA_THEME` ne servent qu'à nommer les fichiers : le pliage se commande dans
/// Device Hub, le thème par `xcrun simctl ui <id> appearance`.)
extension TrivaUITests {
    private var duoCaptureDirectory: URL? {
        ProcessInfo.processInfo.environment["TRIVA_CAPTURE_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    private var duoSuffix: String {
        let environment = ProcessInfo.processInfo.environment
        return "\(environment["TRIVA_POSE"] ?? "plie")_\(environment["TRIVA_THEME"] ?? "clair")"
    }

    /// Une ligne de journal, horodatée.
    private func duoLog(_ text: String) {
        guard let directory = duoCaptureDirectory else { return }
        let stamp = Date.now.formatted(date: .omitted, time: .standard)
        let line = "\(stamp) [\(duoSuffix)] \(text)\n"
        let file = directory.appendingPathComponent("journal.txt")
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: file)
        }
    }

    /// L'écran entier en PNG, nommé `<nom>_<pose>_<thème>.png`.
    private func duoShot(_ name: String) {
        guard let directory = duoCaptureDirectory else { return }
        let png = XCUIScreen.main.screenshot().pngRepresentation
        let file = directory.appendingPathComponent("\(name)_\(duoSuffix).png")
        do {
            try png.write(to: file)
            duoLog("capture \(name)")
        } catch {
            duoLog("ÉCHEC écriture \(name) : \(error.localizedDescription)")
        }
    }

    private func duoPrepare() throws {
        guard duoCaptureDirectory != nil else { throw XCTSkip("TEST_RUNNER_TRIVA_CAPTURE_DIR absent : mission D0 seulement.") }
        continueAfterFailure = true
    }

    /// Tape sur un élément s'il paraît dans les 8 s, sinon l'écrit au journal.
    @discardableResult
    private func duoTap(_ element: XCUIElement, _ label: String) -> Bool {
        guard element.waitForExistence(timeout: 8) else {
            duoLog("ÉCHEC : \(label) introuvable")
            return false
        }
        element.tap()
        return true
    }

    private func duoOpen(_ space: Space, keepingKeyboardState: Bool = false) {
        let tab = tabItem(of: space)
        guard tab.waitForExistence(timeout: 10) else {
            duoLog("ÉCHEC : onglet \(space.rawValue) introuvable")
            return
        }
        if !keepingKeyboardState, app.keyboards.firstMatch.exists { _ = scrollKeyboardAway() }
        tab.tap()
        if !marker(of: space).waitForExistence(timeout: 10) {
            duoLog("constat : marque de \(space.rawValue) absente après ouverture")
        }
    }

    /// Une page de défilement vers le bas, par coordonnées (l'arbre d'une `List` varie).
    private func duoScrollDown() {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        start.press(forDuration: 0.1, thenDragTo: end)
    }

    // MARK: - Parcours

    /// Premier lancement : choix du moteur, étape clé de recherche, Recherche vide, clavier ouvert, paysage.
    @objc func testD0_a_premierLancement_choixMoteur_rechercheVide() throws {
        try duoPrepare()
        launchApp(engine: "none")
        guard element("engine.continue").waitForExistence(timeout: Timeout.launch) else {
            duoLog("ÉCHEC : écran de choix du moteur absent")
            return
        }
        duoShot("choix-moteur_premier-lancement")
        if duoTap(element("engine.card.mlxLocal"), "carte MLX") { duoShot("choix-moteur_mlx-coche") }
        if duoTap(element("engine.card.cloudBYOK"), "carte clé API") { duoShot("choix-moteur_cle-api-coche") }
        duoTap(element("engine.card.appleIntelligence"), "carte Apple Intelligence")
        duoTap(element("engine.continue"), "Continuer")
        if element("onboarding.searchKey.start").waitForExistence(timeout: 15) {
            duoShot("choix-moteur_etape-cle-de-recherche")
            element("onboarding.searchKey.start").tap()
        }
        guard element("search.engineBadge").waitForExistence(timeout: Timeout.launch) else {
            duoLog("ÉCHEC : Recherche absente après le choix du moteur")
            return
        }
        duoShot("recherche-vide")
        if duoTap(element("chat.input"), "barre de saisie") {
            _ = app.keyboards.firstMatch.waitForExistence(timeout: 20)
            duoShot("recherche-vide_clavier")
            app.typeText("brouillon à garder")
            duoShot("recherche-vide_brouillon-saisi")
            // Effacer le brouillon AVANT `dismissKeyboard` : celui-ci tape Entrée et enverrait la question.
            app.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 30))
        }
        dismissKeyboard()
        XCUIDevice.shared.orientation = .landscapeLeft
        _ = element("search.engineBadge").waitForExistence(timeout: 5)
        let landscape = XCUIScreen.main.screenshot().image.size
        duoLog("orientation paysage demandée : capture \(Int(landscape.width))x\(Int(landscape.height)) pt")
        duoShot("recherche-vide_paysage")
        XCUIDevice.shared.orientation = .portrait
    }

    /// Réglages : liste complète, feuille du moteur, feuille des clés API.
    @objc func testD0_b_reglages() throws {
        try duoPrepare()
        launchToSearch()
        duoOpen(.settings)
        duoShot("reglages")
        for page in 2...4 {
            duoScrollDown()
            duoShot("reglages-p\(page)")
        }
        for _ in 0..<4 { app.swipeDown() }
        if duoTap(element("settings.changeEngine"), "Changer de moteur (Réglages)") {
            _ = element("engine.card.mlxLocal").waitForExistence(timeout: 10)
            duoShot("reglages-feuille-moteur")
            // « Annuler » : identifiant `engine.cancel`, sinon le libellé. Sans fermeture, la ligne
            // « Clés API » reste masquée derrière la feuille et le toucher suivant tombe dessus.
            let cancel = element("engine.cancel").exists ? element("engine.cancel") : app.buttons["Annuler"].firstMatch
            if cancel.exists { cancel.tap() }
            if !element("engine.card.mlxLocal").waitForNonExistence(timeout: 10) {
                duoLog("ÉCHEC : la feuille « Changer de moteur » ne se ferme pas")
            }
        }
        if duoTap(element("settings.apiKeys"), "Clés API") {
            _ = element("settings.cloudModel").waitForExistence(timeout: 10)
            duoShot("reglages-cles-api")
            duoScrollDown()
            duoShot("reglages-cles-api-p2")
        }
    }

    /// Réponse (génération en cours, sources), Bibliothèque, Favoris et son détail, brouillon entre onglets.
    @objc func testD0_c_reponse_bibliotheque_favoris() throws {
        try duoPrepare()
        launchToSearch()
        requireChatReady()
        let question = "Cherche le prix d'un billet pour la tour Eiffel"
        let send = sendQuestion(question)
        duoShot("recherche-generation-en-cours")
        waitForAnswerEnd()
        duoShot("recherche-reponse-sources_clavier-ouvert-ou-non")
        _ = scrollKeyboardAway()
        duoShot("recherche-reponse-sources")
        duoScrollDown()
        duoShot("recherche-reponse-sources-p2")
        duoLog("réponse : sources=\(elements("source.link").count) envoi=\(send.label)")

        if duoTap(element("chat.favorite"), "étoile favori") {
            duoShot("recherche-reponse_favori-actif")
        }
        duoOpen(.library)
        duoShot("bibliotheque")
        duoOpen(.favorites)
        duoShot("favoris")
        let row = elements("favorites.row").firstMatch
        if row.waitForExistence(timeout: 8) {
            row.tap()
            _ = element("citation.text").waitForExistence(timeout: 10)
            duoShot("favoris-detail")
            duoScrollDown()
            duoShot("favoris-detail-p2")
            let back = app.navigationBars.buttons["BackButton"].firstMatch
            let toolbarBack = app.buttons.matching(identifier: "BackButton").firstMatch
            if back.exists { back.tap() } else if toolbarBack.exists { toolbarBack.tap() }
        }
    }

    /// Brouillon saisi, puis aller-retour par un autre espace. Pas de `dismissKeyboard()` : il tape Entrée
    /// et ENVOIE le brouillon. On cherche comment un utilisateur ferme le clavier sans envoyer.
    @objc func testD0_e_brouillon_entreOnglets() throws {
        try duoPrepare()
        launchToSearch()
        requireChatReady()
        guard duoTap(element("chat.input"), "barre de saisie") else { return }
        _ = app.keyboards.firstMatch.waitForExistence(timeout: 20)
        app.typeText("brouillon avant changement d'onglet")
        duoShot("brouillon_avant")
        let tab = tabItem(of: .settings)
        duoLog("clavier ouvert : onglet Réglages présent=\(tab.exists) touchable=\(tab.isHittable)")
        if !tab.isHittable {
            element("chat.input").swipeDown()
            duoLog("après balayage vers le bas sur la saisie : clavier=\(app.keyboards.firstMatch.exists)")
        }
        if app.keyboards.firstMatch.exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.15)).tap()
            duoLog("après appui sur l'en-tête : clavier=\(app.keyboards.firstMatch.exists)")
        }
        duoShot("brouillon_clavier-ferme")
        duoOpen(.settings, keepingKeyboardState: true)
        duoShot("brouillon_reglages")
        duoOpen(.search, keepingKeyboardState: true)
        duoShot("brouillon_apres")
        duoLog("brouillon après aller-retour : « \((element("chat.input").value as? String) ?? "?") »")
    }

    /// Découvrir : le fil (ou son état d'erreur).
    @objc func testD0_d_decouvrir() throws {
        try duoPrepare()
        launchToSearch()
        duoOpen(.discover)
        let outcome = firstExisting(
            [element("discover.article"), element("discover.failure"), element("discover.empty")],
            timeout: Timeout.discover
        )
        duoLog("Découvrir : \(outcome?.identifier ?? "aucune issue")")
        duoShot("decouvrir")
        duoScrollDown()
        duoShot("decouvrir-p2")
        duoScrollDown()
        duoShot("decouvrir-p3")
    }
}
