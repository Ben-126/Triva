//
//  FileAttachmentRules.swift
//  Triva
//
//  Découpé de FileAttachmentPicker.swift (K2, 25/11/2026) : déplacement pur, sans changement de code.
//

import Foundation
import UniformTypeIdentifiers


/// Résultat de `FileAttachmentRules.plan` : ce qui sera lu, et ce qui ne le
/// sera pas, nommé pour être affiché (rien n'est abandonné en silence).
nonisolated struct FileAttachmentSelectionPlan: Sendable, Equatable {
    let accepted: [URL]
    let duplicateFileNames: [String]
    let overflowFileNames: [String]
}

// MARK: - Règles (logique pure, testable)

/// Ce que le sélecteur de pièces jointes (tâche 1.11) accepte, et combien.
/// `nonisolated` : règles déterministes, sans état (comme `SuggestionsPresentation`).
nonisolated enum FileAttachmentRules {
    /// 15 pièces jointes au plus par conversation, jointes et en lecture
    /// confondues : 15 × 5 pages = le budget total de 75 pages décidé par Ben
    /// (2026-10-04). La limite de CONTENU reste le budget de 185 000 caractères
    /// du store, PARTAGÉ entre les fichiers ; celle-ci évite qu'un « Tout
    /// sélectionner » sur 200 fichiers lance 200 lectures (`.fileImporter` ne
    /// sait pas borner une sélection), et garde la rangée lisible d'un coup
    /// d'œil sur iPhone. Valeur de produit : à ajuster ici seulement.
    static let maxAttachmentCount = 15

    /// Types proposés par `.fileImporter`, DÉRIVÉS de `AttachmentKind` : le
    /// `switch` exhaustif de `contentTypes(for:)` ne compile plus si
    /// l'extracteur apprend un format que le sélecteur ne propose pas.
    static let allowedContentTypes: [UTType] = {
        var seenIdentifiers: Set<String> = []
        return AttachmentKind.allCases
            .flatMap(FileAttachmentRules.contentTypes(for:))
            .filter { seenIdentifiers.insert($0.identifier).inserted }
    }()

    /// Reflet de `AttachmentKind.init?(fileName:)`, qui fait foi :
    /// - JAMAIS `.text` : HTML, RTF et XML y sont conformes, et l'extracteur
    ///   les refuse (leur texte brut est du balisage) ;
    /// - `.json` à part : il n'est PAS conforme à `.plainText` ;
    /// - Markdown, CSV et TSV, conformes à `.plainText`, listés quand même ;
    ///   Markdown aussi par extension, même filet que l'extracteur si
    ///   l'identifiant système n'est pas déclaré.
    static func contentTypes(for kind: AttachmentKind) -> [UTType] {
        switch kind {
        case .pdf: return [.pdf]
        // Seul le type exact du .docx : `.docm` et `.dotx` ne sont pas lus.
        case .docx: return [AttachmentKind.docxType].compactMap { $0 }
        case .plainText: return [.plainText]
        case .markdown:
            return [UTType("net.daringfireball.markdown"), UTType(filenameExtension: "md"), UTType(filenameExtension: "markdown")].compactMap { $0 }
        case .csv: return [.commaSeparatedText, .tabSeparatedText]
        case .json: return [.json]
        case .image: return AttachmentKind.imageTypes
        }
    }

    /// Conformance à l'un des types autorisés, comme le teste le sélecteur.
    static func accepts(_ contentType: UTType) -> Bool {
        allowedContentTypes.contains { contentType.conforms(to: $0) }
    }

    /// Répartit une sélection, dans son ordre, entre fichiers à lire, doublons
    /// et excédent (au-delà de `availableSlots`). Doublon : même nom, casse
    /// ignorée, qu'un fichier joint, en lecture ou plus haut dans la sélection.
    /// Le store ne dédoublonne pas : joint deux fois, un document consommerait
    /// deux fois le budget et sortirait deux fois en source `[n]`. Le nom est
    /// le seul repère (le store ne garde pas l'URL) ; limite assumée : deux
    /// fichiers distincts de même nom ne peuvent être joints ensemble.
    static func plan(for urls: [URL], existingFileNames: [String], availableSlots: Int) -> FileAttachmentSelectionPlan {
        var seenKeys = Set(existingFileNames.map(duplicateKey(for:)))
        var accepted: [URL] = []
        var duplicates: [String] = []
        var overflow: [String] = []
        for url in urls {
            let fileName = url.lastPathComponent
            if !seenKeys.insert(duplicateKey(for: fileName)).inserted {
                duplicates.append(fileName)
            } else if accepted.count < max(0, availableSlots) {
                accepted.append(url)
            } else {
                overflow.append(fileName)
            }
        }
        return FileAttachmentSelectionPlan(accepted: accepted, duplicateFileNames: duplicates, overflowFileNames: overflow)
    }

    /// Casse ignorée, comme APFS par défaut. `String` compare déjà à
    /// équivalence canonique près (« é » composé ou décomposé), `Set` aussi.
    private static func duplicateKey(for fileName: String) -> String {
        fileName.lowercased()
    }
}
