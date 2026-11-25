//
//  ImageRecognitionPreparationPresentation.swift
//  Triva
//
//  W4-V : le texte de la capsule d'une image jointe pendant la préparation de la lecture (TEXTES À VALIDER PAR BEN).
//

import Foundation

nonisolated enum ImageRecognitionPreparationPresentation {
    /// Ligne courte de la capsule (comme « Début du document seulement »).
    static let summary = "Préparation de la lecture d'image"
    /// Phrase complète pour VoiceOver et l'infobulle Mac : honnête sur la cause, la durée et ce qu'on peut faire.
    static let detail = "Première lecture d'image : Triva prépare la reconnaissance du texte, cela peut prendre un moment. Tu peux continuer à écrire ou annuler."

    /// La note à montrer sur la capsule d'un fichier en cours de lecture : seulement pour une IMAGE, et seulement tant que
    /// la préparation tourne. `nil` sinon (un PDF en file n'a rien à voir avec cette attente).
    static func note(forFileName fileName: String, isPreparing: Bool) -> FileAttachmentTruncationNote? {
        guard isPreparing, AttachmentKind(fileName: fileName) == .image else { return nil }
        return FileAttachmentTruncationNote(summary: summary, detail: detail)
    }
}
