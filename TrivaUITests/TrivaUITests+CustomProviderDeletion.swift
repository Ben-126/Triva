//
//  TrivaUITests+CustomProviderDeletion.swift
//  TrivaUITests
//
//  Mission E2x1 : retirer un fournisseur IA « Personnalisé » de la liste des clés API.
//

import XCTest

/// Ajoute un fournisseur « Personnalisé » par l'interface, puis le retire par le geste de la
/// plateforme (clic droit sur Mac, glisser sur iPhone et iPad) en passant par la confirmation.
/// Le test retire lui-même son fournisseur ; au début, il retire aussi les « ZZ Test E2x1 »
/// qu'un essai interrompu aurait laissés dans les clés API de l'app testée.
extension TrivaUITests {
    private static let customProviderName = "ZZ Test E2x1"

    @objc func testE2x1_fournisseurPersonnalise_ajouterPuisSupprimer() throws {
        launchToSearch()
        open(.settings)
        let apiKeys = element("settings.apiKeys")
        scrollTo(apiKeys)
        apiKeys.tap()
        require(app.navigationBars.staticTexts["Clés API"].firstMatch, "Feuille des clés API absente.")

        step("Retirer les restes d'un essai interrompu") {
            for _ in 0..<5 where customRows.count > 0 {
                let before = customRows.count
                requestDeletion(of: customRows.firstMatch)
                confirmButton.tap()
                XCTAssertTrue(waitUntilCount(below: before), "Reste impossible à retirer.")
            }
        }

        step("Ajouter le fournisseur personnalisé") {
            let add = element("apiKeys.addCustomProvider")
            scrollTo(add)
            add.tap()
            let name = require(app.textFields["Nom (ex. Mon LLM)"], "Champ « Nom » absent.")
            name.tap()
            name.typeText(Self.customProviderName)
            let url = app.textFields["URL de base (ex. https://api.exemple.com/v1)"]
            url.tap()
            url.typeText("https://llm.example.com/v1")
            let model = app.textFields["Nom du modèle"]
            model.tap()
            model.typeText("mon-modele")
            app.buttons["Ajouter"].firstMatch.tap()
            require(customRows.firstMatch, "Le fournisseur ajouté n'apparaît pas dans la liste.")
            capture("E2x1-1 Fournisseur ajouté")
        }

        step("Le retirer : geste de la plateforme, puis confirmation") {
            requestDeletion(of: customRows.firstMatch)
            require(element(labelContaining: "Supprimer \(Self.customProviderName)"), "Titre de confirmation absent.")
            XCTAssertTrue(element(labelContaining: "sa clé API seront effacés").exists, "Message de confirmation absent.")
            capture("E2x1-2 Confirmation")
            cancelConfirmation()
            XCTAssertEqual(customRows.count, 1, "« Annuler » ne doit rien supprimer.")

            requestDeletion(of: customRows.firstMatch)
            require(element(labelContaining: "Supprimer \(Self.customProviderName)"), "Confirmation absente (2e essai).")
            confirmButton.tap()
            XCTAssertTrue(waitUntilCount(below: 1), "Le fournisseur reste dans la liste après confirmation.")
            capture("E2x1-3 Fournisseur retiré")
        }
    }

    /// Les lignes « Personnalisé » de ce test. Le libellé est porté par un texte enfant, pas par
    /// le bouton de la ligne.
    private var customRows: XCUIElementQuery {
        app.buttons.matching(identifier: "apiKeys.customRow")
            .containing(NSPredicate(format: "label == %@", Self.customProviderName))
    }

    /// Le bouton rouge de la confirmation.
    private var confirmButton: XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@", "Supprimer")).firstMatch
    }

    /// « Annuler » quand le système l'affiche ; sur iPhone la confirmation, présentée depuis une
    /// feuille, est une bulle sans bouton d'annulation : on la ferme en touchant à côté.
    private func cancelConfirmation() {
        let cancel = app.buttons["Annuler"].firstMatch
        if cancel.waitForExistence(timeout: 2) {
            cancel.tap()
            return
        }
        let outside = require(element("PopoverDismissRegion"), "Ni « Annuler » ni zone de fermeture de la bulle.")
        outside.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.05)).tap()
    }

    private func waitUntilCount(below count: Int, timeout: TimeInterval = Timeout.screen) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while customRows.count >= count, Date() < deadline {
            _ = app.wait(for: .runningForeground, timeout: 0.3)
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        return customRows.count < count
    }

    private func requestDeletion(of row: XCUIElement) {
        #if os(macOS)
        row.rightClick()
        require(app.menuItems["Supprimer"], "« Supprimer » absent du menu contextuel.").click()
        #else
        row.swipeLeft()
        require(app.buttons["Supprimer"].firstMatch, "Action « Supprimer » absente après le glissement.").tap()
        #endif
    }
}
