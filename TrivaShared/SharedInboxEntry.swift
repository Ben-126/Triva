//
//  SharedInboxEntry.swift
//  TrivaShared
//
//  Chantier 2.1 (mission E) : une entrée de la boîte de partage, telle qu'écrite dans le manifeste JSON
//  `<id>.json`. Elle décrit ce que l'extension a reçu : une question (texte, titre ou adresse de page) et/ou un fichier.
//  Aucune donnée sensible n'y est nécessaire en plus : le nom du fichier est celui, assaini, que l'utilisateur verra.
//

import Foundation

nonisolated struct SharedInboxEntry: Codable, Sendable, Equatable {
    /// Le fichier joint à l'entrée. Sur le disque il porte le nom `<id>.payload`, jamais son nom d'origine.
    struct File: Codable, Sendable, Equatable {
        let type: SharedFileType
        /// Nom assaini (`SharedFileName`), extension du type réel.
        let displayName: String
        /// Taille exacte : une copie plus courte ou plus longue (écriture interrompue, fichier remplacé) est refusée.
        let byteCount: Int
    }

    /// Les manifestes d'une autre version sont ignorés (et effacés) : une version future ne doit pas être mal lue.
    static let currentVersion = 1

    let version: Int
    let id: UUID
    let createdAt: Date
    /// Question à placer dans la barre de saisie, déjà assainie. `nil` pour un fichier partagé sans question.
    let text: String?
    let file: File?
}
