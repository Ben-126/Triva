//
//  ExtractedAttachment.swift
//  Triva
//
//  Created by ben podrojsky on 29/09/2026.
//

import Foundation

/// Un morceau de texte extrait, avec sa page d'origine quand elle existe.
/// Unité de provenance transmise au découpage (`AttachmentChunker`), qui la
/// reporte sur chaque fragment.
nonisolated struct ExtractedTextSection: Sendable, Equatable {
    /// Numéro de page à partir de 1 (convention d'affichage « p. 3 »), `nil`
    /// pour un fichier texte, qui n'a pas de pagination.
    let pageNumber: Int?
    let text: String
}

/// Résultat d'une extraction réussie : jamais vide (au moins une section non
/// blanche, sinon l'extracteur lève une erreur).
nonisolated struct ExtractedAttachment: Sendable, Equatable {
    let fileName: String
    let kind: AttachmentKind
    /// Une section par page non vide pour un PDF, une seule pour un texte.
    let sections: [ExtractedTextSection]
    /// Nombre TOTAL de pages du PDF (pas seulement celles lues) ; `nil` hors PDF.
    let pageCount: Int?
    /// Vrai quand une borne (caractères ou pages) a interrompu la lecture :
    /// seul le DÉBUT du document est disponible. À signaler à l'utilisateur.
    let isTruncated: Bool
    /// PDF dont l'auteur interdit la copie du contenu. Lu malgré tout (voir
    /// `AttachmentTextExtractor.extractPDF`) : c'est un signal exposé pour
    /// que le produit décide, pas une décision prise ici. Toujours `false`
    /// hors PDF.
    let isCopyRestricted: Bool
    /// Encodage détecté pour un fichier texte ; `nil` pour un PDF.
    let textEncoding: AttachmentTextEncoding?

    var characterCount: Int {
        sections.reduce(0) { $0 + $1.text.count }
    }
}
