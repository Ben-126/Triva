//
//  TrivaUITests+Support.swift
//  TrivaUITests
//
//  Created by ben podrojsky on 05/11/2026.
//

#if canImport(UIKit)
import UIKit
#endif
import XCTest

/// Outils communs des parcours de `TrivaUITests` : lancement, requêtes, attentes, navigation.
/// À part pour que le fichier des parcours se lise comme la liste de ce qui est vérifié.
extension TrivaUITests {
    // MARK: - Constantes

    /// Délais d'ATTENTE MAXIMALE, jamais des pauses : `waitForExistence` rend la main dès que
    /// l'élément paraît. Ils couvrent un simulateur chargé, pas une lenteur normale.
    enum Timeout {
        static let screen: TimeInterval = 20
        static let launch: TimeInterval = 60
        /// Réseau réel plus génération sur l'appareil : classification, recherche, lecture des
        /// pages, puis rédaction. Mesuré en dizaines de secondes, large pour un Mac occupé.
        static let answer: TimeInterval = 420
        /// Bouton Stop : une génération arrêtée doit rendre la main vite, c'est tout l'enjeu.
        static let stop: TimeInterval = 30
        /// Découvrir interroge tous ses sujets sur des instances publiques parfois lentes.
        static let discover: TimeInterval = 150
    }

    /// Clés `UserDefaults` de l'app, recopiées parce qu'elles y sont privées.
    enum StoredKey {
        static let engine = "ai.engine.selectedOption"
        static let responseMode = "chat.responseMode.selected"
        static let instanceOverrides = "searxng.instanceOverrides"
        static let directorySnapshot = "searxng.directorySnapshot.v1"
    }

    /// Les cinq espaces, avec le titre que montrent la barre d'onglets et la sidebar.
    enum Space: String, CaseIterable {
        case search = "Recherche"
        case discover = "Découvrir"
        case library = "Bibliothèque"
        case favorites = "Favoris"
        case settings = "Réglages"

        /// Identifiant d'accessibilité de l'onglet (`TrivaRootView.tabs`) : les libellés disparaissent
        /// sur iPhone Duo plié, l'identifiant reste.
        var tabIdentifier: String {
            switch self {
            case .search: "tab.search"
            case .discover: "tab.discover"
            case .library: "tab.library"
            case .favorites: "tab.favorites"
            case .settings: "tab.settings"
            }
        }
    }

    /// `engine` : valeur de lancement du moteur. `nil` : aucune épingle, le moteur enregistré vaut.
    /// « none » n'est aucun cas de `AIEngineOption`, le store lit donc « pas de moteur choisi » : le
    /// premier lancement se rejoue sans dépendre de ce que le simulateur a déjà en mémoire.
    /// `responseMode` : même logique, `nil` pour vérifier le mode réellement enregistré.
    func launchApp(
        engine: String? = "appleIntelligence",
        responseMode: String? = "quick",
        extraArguments: [String] = []
    ) {
        #if os(iOS)
        // Portrait imposé : `TrivaUITestsLaunchTests` (une passe par configuration d'interface)
        // laisse le simulateur en paysage, et les parcours suivants héritaient de cette
        // orientation sans l'avoir choisie (constaté sur iPhone 18 Pro, mission C1).
        XCUIDevice.shared.orientation = .portrait
        #endif
        let application = XCUIApplication()
        var arguments = ["-AppleLanguages", "(fr)", "-AppleLocale", "fr_FR"]
        if let engine {
            arguments += ["-\(StoredKey.engine)", engine]
        }
        if let responseMode {
            arguments += ["-\(StoredKey.responseMode)", responseMode]
        }
        application.launchArguments = arguments + extraArguments
        application.launch()
        app = application
        // Sur un échec, l'arbre d'accessibilité complet : sans lui, relire un échec XCUITest revient
        // à deviner ce que la requête n'a pas trouvé. `.deleteOnSuccess` : rien à relire sinon.
        addTeardownBlock { @MainActor in
            let attachment = XCTAttachment(string: application.debugDescription)
            attachment.name = "Arbre d'accessibilité à la fin du test"
            attachment.lifetime = .deleteOnSuccess
            XCTContext.runActivity(named: "Arbre d'accessibilité") { $0.add(attachment) }
        }
        // L'instance personnelle de Ben peut déclencher l'alerte « réseau local » à la 1re requête.
        addUIInterruptionMonitor(withDescription: "Alerte système") { alert in
            for title in ["Autoriser", "Allow", "OK"] where alert.buttons[title].exists {
                alert.buttons[title].tap()
                return true
            }
            return false
        }
        XCTAssertTrue(application.wait(for: .runningForeground, timeout: Timeout.launch), "L'app n'est pas passée au premier plan.")
        arrangeWindowOnPad()
    }

    func launchToSearch(extraArguments: [String] = []) {
        launchApp(extraArguments: extraArguments)
        require(element("search.engineBadge"), timeout: Timeout.launch, "Recherche absente au lancement.")
    }

    /// Fermeture puis relancement réels du processus : c'est ce qui met la persistance à l'épreuve.
    func relaunchApp() {
        app.terminate()
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: Timeout.launch), "L'app n'a pas redémarré.")
    }

    /// iPad : la taille de la fenêtre survit aux lancements. Chaque lancement la fixe donc par la vraie
    /// commande système (appui long sur les trois points, menu « Déplacer et redimensionner »), pour
    /// ne rien hériter du run précédent. « Gauche », la moitié d'écran d'un Split View, se demande par
    /// `TEST_RUNNER_TRIVA_WINDOW=Gauche`, que xcodebuild passe au test sans son préfixe.
    /// En plein écran, les trois points n'existent pas : seule la poignée permet d'en sortir.
    func arrangeWindowOnPad() {
        guard isPad else { return }
        let option = ProcessInfo.processInfo.environment["TRIVA_WINDOW"] ?? "Remplir"
        // Déjà plein écran et « Remplir » demandé : rien à faire, et surtout aucune requête sur
        // SpringBoard. Son arbre est énorme, et chercher des commandes qui n'existent pas en plein
        // écran a coûté 922 s de « Collecting debug information » (iPad Pro 13, mission V).
        if option == "Remplir", appFillsScreen { return }
        let springBoard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let anyElement = springBoard.descendants(matching: .any)
        let controls = anyElement.matching(identifier: "window-controls:com.benpodrojsky.Triva").firstMatch
        if !controls.waitForExistence(timeout: 3) {
            guard option != "Remplir" else { return }
            let corner = anyElement.matching(identifier: "resize-grabber").firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            corner.press(forDuration: 0.5, thenDragTo: corner.withOffset(CGVector(dx: -300, dy: -300)))
        }
        require(controls, "Commandes de fenêtre absentes.").press(forDuration: 1.2)
        require(springBoard.buttons[option].firstMatch, "Menu de fenêtre : « \(option) » absent.").tap()
    }

    /// La fenêtre de l'app couvre l'écran (orientation indifférente : on compare les côtés triés).
    var appFillsScreen: Bool {
        #if os(iOS)
        let window = app.windows.firstMatch.frame
        let screen = UIScreen.main.bounds
        let (windowShort, windowLong) = (min(window.width, window.height), max(window.width, window.height))
        let (screenShort, screenLong) = (min(screen.width, screen.height), max(screen.width, screen.height))
        return abs(windowShort - screenShort) < 1 && abs(windowLong - screenLong) < 1
        #else
        true
        #endif
    }

    // MARK: - Éléments

    func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    func elements(_ identifier: String) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: identifier)
    }

    /// Premier élément dont le libellé commence par `prefix`. Les options de menu et les lignes de
    /// `Form` portent souvent un libellé composé (« Fiable, Se limite aux… »).
    func element(labelPrefix prefix: String, type: XCUIElement.ElementType = .any) -> XCUIElement {
        app.descendants(matching: type).matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    func element(labelContaining text: String, type: XCUIElement.ElementType = .any) -> XCUIElement {
        app.descendants(matching: type).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    @discardableResult
    func require(
        _ element: XCUIElement,
        timeout: TimeInterval = Timeout.screen,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), message, file: file, line: line)
        return element
    }

    /// Attend qu'un élément déjà présent remplisse un prédicat (« label == … ») : un libellé qui
    /// change n'est pas une apparition, `waitForExistence` n'y verrait rien.
    func waitUntil(_ element: XCUIElement, _ format: String, _ arguments: CVarArg..., timeout: TimeInterval = Timeout.screen) -> Bool {
        let predicate = NSPredicate(format: format, argumentArray: arguments)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Le premier présent parmi plusieurs issues possibles. Chaque tour attend sur le premier
    /// candidat : aucune pause fixe, et un coup d'œil aux autres au moins chaque seconde.
    func firstExisting(_ candidates: [XCUIElement], timeout: TimeInterval) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let found = candidates.first(where: \.exists) {
                return found
            }
            _ = candidates[0].waitForExistence(timeout: 1)
        } while Date() < deadline
        return candidates.first(where: \.exists)
    }

    /// Le texte du badge moteur. Un `Label` expose DEUX éléments sous le même identifiant, l'icône
    /// (« Lock ») et le texte : `firstMatch` seul rend l'un ou l'autre selon le moment.
    var engineBadgeText: XCUIElement {
        app.staticTexts.matching(identifier: "search.engineBadge").firstMatch
    }

    /// Fait défiler le formulaire jusqu'à l'élément : `Form` ne construit que ce qui est visible.
    func scrollTo(_ element: XCUIElement) {
        var swipes = 0
        while !(element.exists && element.isHittable), swipes < 8 {
            app.collectionViews.firstMatch.swipeUp()
            swipes += 1
        }
    }

    func capture(_ name: String) {
        // L'écran entier : sur iPad en fenêtre, `app.screenshot()` découpe la mauvaise zone.
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func step(_ name: String, _ body: () -> Void) {
        XCTContext.runActivity(named: name) { _ in
            MainActor.assumeIsolated { body() }
        }
    }

    // MARK: - Navigation

    var isPad: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad
        #else
        false
        #endif
    }

    /// Ouvre un espace et attend sa marque. Barre d'onglets si elle existe (iPhone, fenêtre iPad
    /// étroite), sinon sidebar : c'est la largeur de la fenêtre qui décide, pas l'appareil.
    func open(_ space: Space, file: StaticString = #filePath, line: UInt = #line) {
        tapSpace(space, file: file, line: line)
        XCTAssertTrue(marker(of: space).waitForExistence(timeout: Timeout.screen), "L'écran \(space.rawValue) ne s'est pas affiché.", file: file, line: line)
    }

    /// Le geste seul : un espace peut se rouvrir sur un écran poussé, sans la marque de `open`.
    func tapSpace(_ space: Space, file: StaticString = #filePath, line: UInt = #line) {
        let tab = tabItem(of: space)
        if isPad, !tab.exists {
            openFromSidebar(space, file: file, line: line)
        } else {
            XCTAssertTrue(tab.waitForExistence(timeout: Timeout.screen), "Onglet \(space.rawValue) introuvable.", file: file, line: line)
            dismissKeyboard()
            tab.tap()
        }
    }

    /// L'onglet d'un espace, par identifiant puis par titre : sur iPhone Duo plié la barre d'onglets
    /// passe sur le côté sans libellé (HIG « Designing for iPhone Duo », contrôles verticaux), et
    /// la recherche par titre ne trouve plus rien.
    func tabItem(of space: Space) -> XCUIElement {
        // Hors « BackButton » : sur un écran poussé, le retour porte le titre de l'écran précédent
        // (« Réglages », « Favoris »), et serait pris pour l'onglet.
        app.buttons.matching(NSPredicate(
            format: "identifier != 'BackButton' AND (identifier == %@ OR label == %@)", space.tabIdentifier, space.rawValue
        )).firstMatch
    }

    /// Si le `NavigationSplitView` a masqué sa sidebar, on la révèle comme le ferait l'utilisateur.
    func openFromSidebar(_ space: Space, file: StaticString, line: UInt) {
        let item = app.collectionViews.cells.containing(.staticText, identifier: space.rawValue).firstMatch
        if !(item.exists && item.isHittable) {
            let toggle = app.buttons["ToggleSidebar"]
            if toggle.waitForExistence(timeout: 3) {
                toggle.tap()
            }
        }
        XCTAssertTrue(item.waitForExistence(timeout: Timeout.screen), "Sidebar : \(space.rawValue) introuvable.", file: file, line: line)
        item.tap()
    }

    /// Élément propre à l'écran : la Recherche a son badge, les autres leur titre de navigation.
    func marker(of space: Space) -> XCUIElement {
        switch space {
        case .search:
            element("search.engineBadge")
        case .discover, .library, .favorites, .settings:
            app.navigationBars.staticTexts[space.rawValue].firstMatch
        }
    }

    /// Le retour de la pile de navigation, par son identifiant système : son libellé varie, et sur
    /// iPad le premier bouton des barres de navigation est celui de la sidebar.
    func goBack(to title: String) {
        // iPhone Duo plié : les contrôles de navigation passent sur le côté, le retour n'est plus
        // DANS la barre de navigation mais dans la barre d'outils (constaté dans l'arbre, mission E1dH).
        let inBar = app.navigationBars.buttons["BackButton"].firstMatch
        let back = inBar.exists ? inBar : app.buttons.matching(identifier: "BackButton").firstMatch
        require(back, "Bouton de retour absent.").tap()
        require(app.navigationBars.staticTexts[title].firstMatch, "Le retour n'a pas ramené sur \(title).")
    }

    /// Un point du fil, clavier ouvert ou non. Par coordonnées : `app.scrollViews.firstMatch` vise la
    /// barre de suggestions du clavier quand il est ouvert, et son balayage SAISIT une suggestion.
    var threadPoint: XCUICoordinate {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.33))
    }

    /// Retour du clavier. Le champ étant vide, `send()` ne fait rien et le champ perd le focus :
    /// c'est le geste d'un utilisateur qui veut voir la barre d'onglets, cachée derrière le clavier.
    func dismissKeyboard() {
        if app.keyboards.firstMatch.exists {
            app.typeText("\n")
        }
    }

    /// Recherche prête à recevoir une question. Si Apple Intelligence n'est pas disponible, l'écran
    /// remplace le chat par une explication : on échoue avec ce message plutôt qu'au bout du délai.
    func requireChatReady(file: StaticString = #filePath, line: UInt = #line) {
        let input = element("chat.input")
        let setup = element("search.setupRequirement")
        guard let found = firstExisting([input, setup], timeout: Timeout.screen) else {
            XCTFail("Ni barre de saisie ni explication après \(Timeout.screen) s.", file: file, line: line)
            return
        }
        XCTAssertEqual(found.identifier, "chat.input", "Moteur pas prêt : \(setup.exists ? setup.label : "")", file: file, line: line)
    }
}
