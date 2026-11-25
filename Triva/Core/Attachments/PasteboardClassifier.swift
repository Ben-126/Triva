//
//  PasteboardClassifier.swift
//  Triva
//
//  K2 : que faire d'un Cmd+V ou d'un « Coller ». Logique pure (aucun accès au presse-papiers) : la lecture réelle
//  (`NSPasteboard`, `UIPasteboard`, `NSItemProvider`) remplit un `PasteboardSnapshot`, ce classement décide.
//

import Foundation
import UniformTypeIdentifiers

/// Ce que porte un presse-papiers, réduit à ce qui décide du collage.
nonisolated struct PasteboardSnapshot: Sendable, Equatable {
    /// Adresses de FICHIERS (copie dans le Finder ou l'app Fichiers) ; une adresse web n'en fait pas partie.
    var fileURLs: [URL] = []
    /// Un fichier est présent mais son adresse n'est pas encore lue (iOS : on interroge les fournisseurs d'éléments
    /// sans les charger).
    var hasFileItem = false
    /// Une image (capture d'écran, « Copier l'image »…) dans un format que Triva sait lire.
    var hasImage = false
    /// Le texte brut, s'il y en a un.
    var text: String?
    /// Un fichier que Triva ne lit pas (ancien .doc, archive…), sans adresse de fichier : présent seul, il doit recevoir
    /// un refus clair plutôt que « presse-papiers vide » (mission W).
    var hasUnsupportedFileItem = false
}

nonisolated enum PasteboardDecision: Sendable, Equatable {
    /// Joindre les fichiers.
    case files
    /// Joindre l'image.
    case image
    /// Collage de texte NORMAL : Triva ne s'en mêle pas.
    case text
    /// Seulement un fichier que Triva ne lit pas : refus expliqué (« Triva ne lit pas ce type de fichier. »).
    case unsupportedFile
    case nothing
}

nonisolated enum PasteboardClassifier {
    /// Règle : le TEXTE gagne (un presse-papiers texte colle toujours du texte), sauf quand il porte un fichier.
    /// - Le Finder dépose avec le fichier son NOM en texte et son icône en image : le fichier l'emporte sur les deux.
    /// - Une image gagne sur du texte seulement quand ce texte n'est que son ADRESSE web (« Copier l'image » de
    ///   Safari). Une cellule de tableur (texte + image du rendu) ou une phrase restent du texte.
    static func decision(for snapshot: PasteboardSnapshot) -> PasteboardDecision {
        if !snapshot.fileURLs.isEmpty || snapshot.hasFileItem { return .files }
        let text = snapshot.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if snapshot.hasImage, text.isEmpty || isSingleWebAddress(text) { return .image }
        if !text.isEmpty { return .text }
        return snapshot.hasUnsupportedFileItem ? .unsupportedFile : .nothing
    }

    /// Nature d'un élément du presse-papiers d'après les types qu'il propose (les types, jamais son contenu).
    enum ProviderKind: Sendable, Equatable {
        /// Un fichier que Triva lit ou dont l'adresse suffira à le classer : adresse de fichier, PDF, .docx.
        case file
        /// Des octets qui ne sont ni du texte, ni une adresse, ni une image, ni une liste de propriétés : un fichier
        /// d'un autre genre (ancien .doc, archive, .pages…).
        case unsupportedFile
        case other
    }

    static func kind(ofTypeIdentifiers identifiers: [String]) -> ProviderKind {
        let types = identifiers.compactMap { UTType($0) }
        if types.contains(where: { $0.conforms(to: .fileURL) || $0.conforms(to: .pdf) || $0 == AttachmentKind.docxType }) { return .file }
        let isForeign = types.contains { type in
            type.conforms(to: .data) && !type.conforms(to: .text) && !type.conforms(to: .url)
                && !type.conforms(to: .image) && !type.conforms(to: .propertyList)
        }
        return isForeign ? .unsupportedFile : .other
    }

    /// Une seule adresse http(s), sans espace ni saut de ligne.
    private static func isSingleWebAddress(_ text: String) -> Bool {
        guard !text.contains(where: \.isWhitespace),
              let url = URL(string: text),
              let scheme = url.scheme?.lowercased() else { return false }
        return (scheme == "http" || scheme == "https") && url.host?.isEmpty == false
    }
}
