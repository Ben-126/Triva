//
//  AttachmentKind.swift
//  Triva
//
//  Created by ben podrojsky on 29/09/2026.
//

import Foundation
import UniformTypeIdentifiers

/// Nature d'une pièce jointe ACCEPTÉE. Tout ce qui n'a pas de cas ici est
/// refusé explicitement (`AttachmentExtractionError.unsupportedFileType`),
/// jamais « tenté pour voir ».
///
/// Le DOCX (Word) est lu, depuis la mission W (décision de Ben, 25/11/2026) : la version web d'origine s'appuie sur
/// `officeparser` (npm) ; côté Apple, `NSAttributedString` ne lit le .docx que sur macOS (vérifié dans le SDK iOS 27),
/// donc `DocxTextReader` le lit nativement (ZIP + `XMLParser`, aucune dépendance), identique sur toutes les
/// plateformes. Restent refusés : l'ancien `.doc`, `.docm`, `.dotx`, `.pages`, `.odt`, RTF, HTML, XML, archives.
/// Markdown, CSV et JSON sont acceptés : ce sont du texte, lu par le même chemin que le `.txt`.
nonisolated enum AttachmentKind: String, Sendable, Equatable, CaseIterable {
    case pdf
    /// Document Word `.docx` (mission W) : texte des paragraphes, tableaux et notes, lu par `DocxTextReader`.
    case docx
    case plainText
    case markdown
    case csv
    case json
    /// Image dont le texte est lu EN LOCAL par Vision (chantier 2.2, M6) : capture d'écran, photo de page.
    case image

    /// Formats d'image acceptés : ceux que le système décode et que Vision lit. Liste explicite, pas
    /// `.image` : SVG (du XML), RAW ou ICNS y sont conformes mais ne se lisent pas de la même façon.
    static let imageTypes: [UTType] = [.png, .jpeg, .heic, .heif, .tiff, .gif, .bmp, .webP]

    /// Identifiant système du Markdown. Pas de constante `UTType.markdown`
    /// dans le SDK : on passe par l'identifiant, déclaré par le système
    /// (vérifié sur macOS 27 : `md` et `markdown` y sont rattachés).
    private static let markdownType = UTType("net.daringfireball.markdown")

    /// Identifiant système du .docx (`org.openxmlformats.wordprocessingml.document`), déclaré par macOS et iOS.
    /// L'extension `docx` fait foi aussi si le système ne le déclarait pas (même filet que le Markdown).
    static let docxType: UTType? = SharedFileType.docxContentType

    /// Filet de sécurité si l'identifiant Markdown n'était pas déclaré sur un
    /// OS : l'extension suffit alors à le reconnaître, au lieu de refuser un
    /// fichier texte parfaitement lisible.
    private static let markdownExtensions: Set<String> = ["md", "markdown"]

    /// Résolution par l'extension, via `UTType` plutôt qu'une liste
    /// d'extensions écrite à la main : le système connaît les variantes
    /// (`.text`, `.log`, `.swift`…) et la casse ne compte pas.
    ///
    /// L'ORDRE DES TESTS EST PORTEUR : Markdown, CSV et TSV sont tous
    /// conformes à `public.plain-text` (vérifié sur macOS 27, et dans les
    /// déclarations `MobileCoreTypes` du runtime iOS 27 : mêmes extensions,
    /// mêmes conformances), ils doivent donc être reconnus AVANT le cas
    /// générique. JSON, lui, n'est PAS
    /// conforme à `public.plain-text` (seulement à `public.text`) : sans son
    /// test dédié, il serait refusé. À l'inverse, RTF, HTML et XML ne sont
    /// conformes qu'à `public.text` et restent refusés — leur texte brut est
    /// du balisage, pas du contenu.
    ///
    /// Fichier sans extension : refusé. Le sélecteur de documents conserve
    /// l'extension d'origine, et deviner le type au contenu reviendrait à
    /// traiter comme texte n'importe quel binaire sans extension.
    init?(fileName: String) {
        let fileExtension = (fileName as NSString).pathExtension.lowercased()
        guard !fileExtension.isEmpty, let type = UTType(filenameExtension: fileExtension) else {
            return nil
        }

        if type.conforms(to: .pdf) {
            self = .pdf
        } else if fileExtension == "docx" || Self.docxType == type {
            // Égalité, pas conformité : `.docm` (macros) et `.dotx` (modèle) sont des cousins, pas des .docx.
            self = .docx
        } else if Self.imageTypes.contains(where: { type.conforms(to: $0) }) {
            self = .image
        } else if type.conforms(to: .json) {
            self = .json
        } else if type.conforms(to: .commaSeparatedText) || type.conforms(to: .tabSeparatedText) {
            self = .csv
        } else if Self.markdownExtensions.contains(fileExtension) || Self.markdownType.map(type.conforms(to:)) == true {
            self = .markdown
        } else if type.conforms(to: .plainText) {
            self = .plainText
        } else {
            return nil
        }
    }
}
