//
//  TrivaUITests+EngineBadgeLandscape.swift
//  TrivaUITests
//
//  Created by ben podrojsky on 13/11/2026.
//

import XCTest

/// Badge moteur IA réduit à son icône, SEULEMENT sur iPhone en paysage, texte AX3 ou plus et
/// clavier ouvert (mission E2c, décision de Ben) : à ce réglage la barre de saisie débordait
/// d'environ 33 pt et le bouton d'envoi devenait inaccessible. Partout ailleurs le badge garde
/// son texte.
extension TrivaUITests {
    /// Le 1er clavier d'un simulateur fraîchement démarré peut se faire attendre et l'appui se
    /// perdre : on rappuie une fois, comme `sendQuestion`.
    @discardableResult
    private func openKeyboard(on input: XCUIElement) -> XCUIElement {
        input.tap()
        let keyboard = app.keyboards.firstMatch
        if !keyboard.waitForExistence(timeout: Timeout.stop / 3) {
            input.tap()
        }
        return require(keyboard, timeout: Timeout.stop, "Clavier absent.")
    }

    /// AX3 = « accessibility-extra-large ».
    private static let accessibility3 = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"]

    @objc func testE2c_a_portraitNormal_badgeGardeSonTexte() throws {
        launchToSearch()
        requireChatReady()
        XCTAssertTrue(
            waitUntil(engineBadgeText, "label CONTAINS %@", "Apple Intelligence"),
            "Le badge a perdu son texte en portrait, taille normale : \(engineBadgeText.label)"
        )
        openKeyboard(on: element("chat.input"))
        XCTAssertTrue(engineBadgeText.exists, "Le texte du badge a disparu clavier ouvert en portrait.")
        capture("E2c portrait normal, clavier ouvert")
    }

    @objc func testE2c_b_paysageAX3ClavierOuvert_badgeIconeEtEnvoiAccessible() throws {
        #if os(iOS)
        guard !isPad else { throw XCTSkip("iPhone seulement : la règle vise la hauteur compacte.") }
        launchToSearch(extraArguments: Self.accessibility3)
        requireChatReady()
        XCUIDevice.shared.orientation = .landscapeLeft
        let input = require(element("chat.input"), "Barre de saisie absente en paysage.")
        capture("E2c paysage AX3, clavier fermé")
        let keyboard = openKeyboard(on: input)
        input.typeText("a")
        let send = element("chat.send")
        require(send, "Bouton d'envoi absent.")
        capture("E2c paysage AX3, clavier ouvert")
        XCTAssertTrue(send.isHittable, "Envoi non touchable : \(send.frame)")
        XCTAssertLessThanOrEqual(send.frame.maxY, keyboard.frame.minY + 1, "Envoi sous le clavier : \(send.frame) / \(keyboard.frame)")
        XCTAssertTrue(
            waitUntil(element("search.engineBadge"), "label CONTAINS %@", "Apple Intelligence"),
            "Le badge n'a plus de libellé d'accessibilité complet."
        )
        XCTAssertFalse(engineBadgeText.exists, "Le texte du badge est encore affiché (paysage, AX3, clavier ouvert).")
        XCUIDevice.shared.orientation = .portrait
        #else
        throw XCTSkip("iPhone seulement.")
        #endif
    }

    /// Banc de mesure, pas une assertion : rejoue l'envoi qui déclenchait l'avertissement
    /// « glassEffect() tried to update multiple times per frame », à lire dans le journal du simulateur
    /// (`log stream --predicate 'eventMessage CONTAINS "multiple times per frame"'`). Avant le correctif
    /// de `ChatView.send` (`Task.immediate`) : 4 avertissements sur 4 passages ; après : 0 sur 4.
    /// Envoi d'une question clavier ouvert (iPhone, portrait, taille normale) : l'en-tête moteur
    /// change d'état pendant que le clavier se range. Un seul passage : ne joue ni la réponse ni
    /// la Bibliothèque (c'est `test03` qui le fait). L'avertissement SwiftUI « glassEffect() tried
    /// to update multiple times per frame » se lit dans le journal du simulateur, pas ici.
    @objc func testE2c_c_envoiClavierOuvert_enTeteMoteur() throws {
        launchApp()
        requireChatReady()
        // Comme `test03` : un détour par la Bibliothèque, puis retour sur la Recherche.
        open(.library)
        open(.search)
        let input = element("chat.input")
        openKeyboard(on: input)
        input.typeText(Self.marked("Cherche le prix d'un billet pour la tour Eiffel"))
        // Le bouton, pas Retour : seul le toucher sur l'envoi déclenchait l'avertissement.
        let send = element("chat.send")
        XCTAssertTrue(waitUntil(send, "enabled == true"), "Envoi inactif après la saisie.")
        send.tap()
        require(element("chat.question"), timeout: Timeout.screen, "La question n'est pas partie.")
        _ = element("chat.send").waitForExistence(timeout: 10)
        sleep(6)
        capture("E2c envoi clavier ouvert, 6 s après")
        // Ne laisse aucune conversation dans la Bibliothèque du simulateur : 38 lignes « tour Eiffel »
        // s'y étaient accumulées en répétant ce test, et le nettoyage de `test03` n'en venait plus à bout.
        deleteConversationsLeftByAnEarlierRun()
    }
}
