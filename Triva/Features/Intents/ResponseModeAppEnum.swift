//
//  ResponseModeAppEnum.swift
//  Triva
//
//  Chantier 2.1 (mission B) : le mode de réponse vu par Raccourcis et Siri (Rapide, Approfondie, Fiable).
//

import AppIntents
import Foundation

nonisolated enum ResponseModeAppEnum: String, AppEnum {
    case quick
    case deep
    case reliable

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Mode de réponse")
    }

    /// Dictionnaire LITTÉRAL (l'outil de métadonnées d'App Intents refuse tout calcul) : les libellés sont ceux du
    /// sélecteur de l'app (`ResponseMode.title`), un test les compare.
    static var caseDisplayRepresentations: [ResponseModeAppEnum: DisplayRepresentation] {
        [
            .quick: DisplayRepresentation(title: "Rapide"),
            .deep: DisplayRepresentation(title: "Approfondie"),
            .reliable: DisplayRepresentation(title: "Fiable"),
        ]
    }

    init(_ mode: ResponseMode) {
        switch mode {
        case .quick: self = .quick
        case .deep: self = .deep
        case .reliable: self = .reliable
        }
    }

    var mode: ResponseMode {
        switch self {
        case .quick: .quick
        case .deep: .deep
        case .reliable: .reliable
        }
    }
}
