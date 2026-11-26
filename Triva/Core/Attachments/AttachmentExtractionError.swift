//
//  AttachmentExtractionError.swift
//  Triva
//
//  Created by ben podrojsky on 29/09/2026.
//

import Foundation

/// Échec de lecture d'une pièce jointe. Motifs FERMÉS, sans texte libre :
/// aucun cas ne transporte de contenu issu du fichier, donc rien de ce que
/// contient un document ne peut ressortir tel quel dans un message d'erreur
/// affiché (même principe que `SearchWidgetFailure`).
///
/// Le seul libre-texte, `fileExtension`, vient du NOM choisi par
/// l'utilisateur, pas du contenu ; il sert au diagnostic et aux tests, et
/// n'est volontairement pas repris dans `userFacingMessage`.
nonisolated enum AttachmentExtractionError: Error, Sendable, Equatable {
    /// Type hors liste (`AttachmentKind`) : DOCX, image, HTML, archive…
    case unsupportedFileType(fileExtension: String)
    /// Fichier introuvable, illisible, accès refusé par le bac à sable, ou
    /// coordination de fichier en échec (voir `extract(from:characterLimit:)`).
    case fileUnreadable
    /// Fichier texte au-delà de `maxTextFileByteCount`.
    case fileTooLarge(byteCount: Int, maximumByteCount: Int)
    /// Zéro octet, ou uniquement des blancs une fois décodé.
    case emptyFile
    /// Fichier « texte » qui contient en réalité du binaire (image renommée
    /// en `.txt`, par exemple).
    case binaryContent
    /// Aucun décodage n'a abouti. En pratique inatteignable sans marque
    /// d'ordre des octets (le repli Latin-1 accepte toute suite d'octets),
    /// mais une marque UTF-8/UTF-16/UTF-32 suivie d'octets invalides y mène.
    case undecodableText
    /// `PDFKit` refuse le document : fichier corrompu, tronqué, ou pas un PDF.
    case invalidPDF
    /// PDF chiffré avec mot de passe d'ouverture.
    case passwordProtectedPDF
    /// PDF dont l'auteur interdit la copie du texte ET son extraction pour l'accessibilité
    /// (`allowsCopying == false` et `allowsContentAccessibility == false`) : jamais lu, avec
    /// aucun moteur (décision de Ben, 2026-11-17 ; CPI L331-5 — À FAIRE VALIDER PAR UN JURISTE).
    case copyProtectedPDF
    /// PDF lisible mais sans couche texte : document scanné, ou pages
    /// composées uniquement d'images.
    case noExtractableText(pageCount: Int)
    /// Octets qui ne sont pas une image lisible (fichier tronqué, renommé…).
    case invalidImage
    /// Image au-delà de `maxImageByteCount`.
    case imageTooLarge(byteCount: Int, maximumByteCount: Int)
    /// Image dont les dimensions dépassent `maxImagePixelCount` : quelques Mo de PNG ou de GIF peuvent se
    /// décoder en plusieurs Go de pixels (bombe de décompression), que Vision ne doit jamais recevoir.
    case imageDimensionsTooLarge
    /// Image lue, mais aucun texte reconnu (photo de paysage, image vide).
    case noTextInImage
    /// Faux .docx ou .docx abîmé : pas une archive ZIP, tronquée, XML invalide, sans corps, déclaration de type de
    /// document (entités), entrée plus longue que annoncée, nom d'entrée piégé ou en double.
    case invalidDocx
    /// Document Word protégé par un mot de passe (conteneur OLE2 chiffré) OU ancien format `.doc` : même en-tête
    /// binaire, donc un seul message qui couvre les deux cas.
    case protectedOrLegacyWord
    /// Taille décompressée, nombre d'entrées ou durée de lecture au-delà des plafonds (bombe de décompression).
    case docxTooLarge
    /// Document Word lisible, sans aucun texte (pages d'images seulement).
    case noTextInDocument

    /// Message court en français, tutoiement, sans jargon, prêt pour l'UI.
    /// Aucune interpolation de donnée issue du fichier (seule la limite de
    /// taille, une constante de l'app, est affichée).
    var userFacingMessage: String {
        switch self {
        case .unsupportedFileType:
            // Un seul message pour tous les chemins (sélecteur, dépôt, collage, partage) : celui du dépôt.
            return DropRefusal.unsupportedTypeMessage
        case .fileUnreadable:
            return "Impossible d'ouvrir ce fichier. Vérifie qu'il est disponible sur l'appareil, puis réessaie."
        case let .fileTooLarge(_, maximumByteCount):
            let megabytes = max(1, maximumByteCount / (1_024 * 1_024))
            return "Ce fichier est trop volumineux : \(megabytes) Mo maximum pour un fichier texte."
        case .emptyFile:
            return "Ce fichier est vide."
        case .binaryContent:
            return "Ce fichier ne contient pas de texte lisible."
        case .undecodableText:
            return "Impossible de décoder le texte de ce fichier."
        case .invalidPDF:
            return "Ce PDF est illisible ou endommagé."
        case .passwordProtectedPDF:
            return "Ce PDF est protégé par un mot de passe. Retire la protection, puis joins-le à nouveau."
        case .copyProtectedPDF:
            // Validé par Ben le 2026-11-18 (texte légal)
            return PDFCopyPolicy.refusalMessage
        case .noExtractableText:
            return "Ce PDF ne contient aucun texte sélectionnable. C'est sans doute un document scanné."
        case .invalidImage:
            return "Cette image est illisible ou endommagée."
        case let .imageTooLarge(_, maximumByteCount):
            let megabytes = max(1, maximumByteCount / (1_024 * 1_024))
            return "Cette image est trop volumineuse : \(megabytes) Mo maximum."
        case .imageDimensionsTooLarge:
            // À valider par Ben.
            return "Cette image est trop grande (en pixels). Réduis-la, puis joins-la à nouveau."
        case .noTextInImage:
            return "Triva ne trouve aucun texte dans cette image."
        // Textes de la mission W : à valider par Ben.
        case .invalidDocx:
            return "Ce document Word est illisible ou endommagé."
        case .protectedOrLegacyWord:
            return "Ce document Word est protégé par un mot de passe ou dans un ancien format. Retire la protection ou enregistre-le au format .docx, puis joins-le à nouveau."
        case .docxTooLarge:
            return "Ce document Word est trop volumineux ou trop complexe pour être lu."
        case .noTextInDocument:
            return "Ce document Word ne contient aucun texte."
        }
    }
}

/// Politique des PDF à copie interdite (décision FINALE de Ben, 2026-11-17 ; CPI L331-5 et
/// L335-3-1 — À FAIRE VALIDER PAR UN JURISTE). `PDFDocument.allowsContentAccessibility`
/// (PDFKit, PDFDocument.h : « Extract content, but only for the purpose of accessibility ») :
/// un PDF qui interdit la copie n'est lu que s'il autorise cette extraction.
nonisolated enum PDFCopyPolicy {
    /// Vrai si le texte du PDF peut être extrait.
    static func allowsReading(allowsCopying: Bool, allowsContentAccessibility: Bool) -> Bool {
        allowsCopying || allowsContentAccessibility
    }

    /// Validé par Ben le 2026-11-18 (texte légal)
    static let refusalMessage = "Ce PDF interdit la copie de son texte : Triva ne peut pas le lire."
}
