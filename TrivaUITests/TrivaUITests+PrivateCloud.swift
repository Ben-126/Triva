//
//  TrivaUITests+PrivateCloud.swift
//  TrivaUITests
//
//  Created by ben podrojsky on 11/11/2026.
//

import XCTest

/// Cloud privé d'Apple (mission A4) : le choix et toute mention du cloud n'apparaissent QUE si le
/// cloud est proposé. Sans l'entitlement d'Apple, il ne l'est jamais : l'argument de lancement
/// `-debug.simulatePrivateCloud YES` (build de débogage seulement) le simule, avec un « cloud »
/// qui échoue à chaque envoi et ne construit jamais le vrai modèle.
extension TrivaUITests {
    private static let simulatePrivateCloud = ["-debug.simulatePrivateCloud", "YES"]

    @objc func testA4_cloudPrive_choixEtBadgeSeulementSiPropose() throws {
        step("Cloud proposé : badge « Apple · Cloud privé », choix dans les Réglages") {
            launchToSearch(extraArguments: Self.simulatePrivateCloud)
            XCTAssertTrue(
                waitUntil(engineBadgeText, "label == %@", "Apple · Cloud privé"),
                "Badge inattendu avec le cloud proposé : \(engineBadgeText.label)"
            )
            XCTAssertFalse(element(labelContaining: "Aucune IA cloud").exists, "« Aucune IA cloud » alors que le cloud répondrait.")
            capture("A4-1 Recherche, cloud privé proposé")
            open(.settings)
            require(element("settings.appleModelPicker"), "Choix cloud privé / appareil absent des Réglages.")
            capture("A4-2 Réglages, cloud privé proposé")
        }
        step("Cloud non proposé : l'app d'avant A4, sans aucune mention du cloud") {
            app.terminate()
            launchToSearch()
            XCTAssertTrue(
                waitUntil(engineBadgeText, "label == %@", "Apple Intelligence · Sur l'appareil"),
                "Badge inattendu sans cloud : \(engineBadgeText.label)"
            )
            XCTAssertEqual(element("search.engineCaption").label, "Aucune IA cloud utilisée")
            open(.settings)
            require(element("settings.engineBadge"), "Badge absent des Réglages.")
            XCTAssertFalse(element("settings.appleModelPicker").exists, "Le choix du cloud ne doit pas apparaître sans cloud proposé.")
            XCTAssertFalse(element(labelContaining: "Cloud privé").exists, "Mention du cloud privé alors qu'il n'est pas proposé.")
            capture("A4-3 Réglages, cloud non proposé")
        }
    }
}
