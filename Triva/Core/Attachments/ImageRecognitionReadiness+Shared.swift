//
//  ImageRecognitionReadiness+Shared.swift
//  Triva
//
//  W4-V : l'instance de l'app (une seule : le cache du système est par programme, pas par fenêtre).
//

import Foundation

extension ImageRecognitionReadiness {
    /// Vision réel, registre dans les préférences. Aucune préparation ne démarre tant que `startIfNeeded()` n'est pas appelé.
    static let shared: ImageRecognitionReadiness = {
        let readiness = ImageRecognitionReadiness(
            preparer: VisionImageTextRecognizer(),
            ledger: UserDefaultsPreparationLedger()
        )
        readiness.observeSystemConditions()
        return readiness
    }()

    /// Instance par défaut des contrôleurs de pièces jointes : `nil` quand l'app sert d'hôte aux tests unitaires (une
    /// vraie préparation y coûterait ~40 s et toucherait les vraies préférences de la machine).
    static var forCurrentProcess: ImageRecognitionReadiness? {
        TrivaTestHost.isHostingUnitTests() ? nil : shared
    }
}
