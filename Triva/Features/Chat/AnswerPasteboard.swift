//
//  AnswerPasteboard.swift
//  Triva
//
//  Chantier 2.2 (M4) : écriture d'une réponse dans le presse-papiers, partagée par le bouton « Copier »
//  sous une réponse et l'item de menu Édition > « Copier la réponse » (⇧⌘C). Un seul chemin : le marquage
//  « généré par IA » lisible par une machine (règlement (UE) 2024/1689, art. 50(2)) ne peut pas être oublié.
//

import SwiftUI
#if os(iOS)
import UIKit
import UniformTypeIdentifiers
#else
import AppKit
#endif

enum AnswerPasteboard {
    /// - Parameter text: texte DÉJÀ marqué (`AnswerShareText.text`).
    static func copy(_ text: String) {
        #if os(iOS)
        // Un seul élément à deux représentations : le texte marqué (principal) et la métadonnée
        // « généré par IA » lisible par une machine (AI Act art. 50(2)).
        UIPasteboard.general.setItems([[
            UTType.utf8PlainText.identifier: text,
            AIProvenanceMetadata.pasteboardType: AIProvenanceMetadata.jsonData(),
        ]])
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        NSPasteboard.general.setData(
            AIProvenanceMetadata.jsonData(),
            forType: NSPasteboard.PasteboardType(AIProvenanceMetadata.pasteboardType)
        )
        #endif
    }
}
