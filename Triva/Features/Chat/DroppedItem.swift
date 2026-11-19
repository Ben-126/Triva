//
//  DroppedItem.swift
//  Triva
//
//  Chantier 2.2 (M5) : ce que la fenêtre de recherche reçoit quand on y glisse quelque chose (Finder, Fichiers,
//  Safari, Notes…). Un seul `Transferable`, représentations ORDONNÉES : fichiers d'abord, puis texte, puis adresse
//  web. Le classement des fichiers se fait par l'extension réelle (`AttachmentKind`, voir `receiveFile`).
//

import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// Pourquoi un élément déposé est refusé. Messages FERMÉS : aucun ne recopie le nom ou le contenu du fichier.
nonisolated enum DropRefusal: Sendable, Equatable {
    case unsupportedType
    case tooLarge
    case unreadable

    /// Message unique de refus d'un type (fermé : ne recopie jamais le nom ni le contenu du fichier).
    static let unsupportedTypeMessage = "Triva ne lit pas ce type de fichier."

    var message: String {
        switch self {
        case .unsupportedType: Self.unsupportedTypeMessage
        case .tooLarge: "Ce fichier est trop volumineux pour être joint."
        case .unreadable: "Impossible de lire ce fichier."
        }
    }
}

/// Élément reçu. Un fichier est déjà COPIÉ dans les dépôts du coffre (le fichier reçu n'existe que dans la
/// fermeture d'import) : `url` est donc valable après le dépôt.
nonisolated enum DroppedItem: Sendable, Equatable, Transferable {
    /// Fichier lisible comme pièce jointe (PDF, texte, Markdown, CSV, JSON).
    case attachment(URL)
    /// Image : son texte est lu en local (Vision, M6) à la jointure. Copiée dans les dépôts comme un fichier.
    case image(URL)
    /// Texte glissé depuis une page ou une note : va dans le brouillon.
    case text(String)
    /// Adresse web : va dans le brouillon, jamais lue toute seule.
    case webURL(URL)
    case refused(DropRefusal)

    static var transferRepresentation: some TransferRepresentation {
        // 1. Une URL d'abord : un fichier glissé depuis le Finder ou Fichiers arrive comme `file://` avec son VRAI nom
        //    (les représentations « fichier » ci-dessous donnent un nom temporaire) ; un lien web arrive en `http(s)`.
        ProxyRepresentation(importing: { (url: URL) in DroppedItem.fromURL(url) })
        // 2. Fichiers sans adresse (pièce jointe d'un mail, promesse de fichier). PAS de `.plainText` : il
        //    s'appliquerait aussi à du texte glissé depuis une page, qui doit aller dans le brouillon.
        FileRepresentation(importedContentType: .pdf) { DroppedItem.receive($0) }
        FileRepresentation(importedContentType: markdownType) { DroppedItem.receive($0) }
        FileRepresentation(importedContentType: .commaSeparatedText) { DroppedItem.receive($0) }
        FileRepresentation(importedContentType: .json) { DroppedItem.receive($0) }
        FileRepresentation(importedContentType: .image) { DroppedItem.receive($0) }
        // 3. Texte en mémoire.
        DataRepresentation(importedContentType: .utf8PlainText) { data in
            DroppedItem.text(String(decoding: data, as: UTF8.self))
        }
    }

    /// `net.daringfireball.markdown`, repli sur le texte brut si le système ne le déclare pas.
    private static var markdownType: UTType {
        UTType("net.daringfireball.markdown") ?? .plainText
    }

    // MARK: - Réception (pur, testable)

    /// Fichier reçu sans adresse : copié tout de suite (il n'existe que pendant la fermeture d'import).
    static func receive(_ received: ReceivedTransferredFile, depositRoot: URL = AttachmentFileVault.defaultRootDirectory) -> DroppedItem {
        receiveFile(at: received.file, depositRoot: depositRoot)
    }

    /// Adresse reçue : un fichier local est classé et copié, une page web va dans le brouillon, le reste est refusé
    /// (`mailto:`, `javascript:`…).
    static func fromURL(_ url: URL, depositRoot: URL = AttachmentFileVault.defaultRootDirectory) -> DroppedItem {
        if url.isFileURL { return receiveFile(at: url, depositRoot: depositRoot) }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return .refused(.unsupportedType)
        }
        return .webURL(url)
    }

    /// Classe par l'extension réelle (comme l'extracteur, `AttachmentKind`), jamais par un nom d'affichage, puis copie
    /// dans les dépôts. La portée de sécurité d'un fichier venu d'une autre app n'est ouverte que le temps de la copie.
    static func receiveFile(at url: URL, depositRoot: URL = AttachmentFileVault.defaultRootDirectory) -> DroppedItem {
        // Une image n'est retenue que dans un format que Vision lit (`AttachmentKind.imageTypes`) : un SVG ou un RAW
        // sont refusés ici, sans être copiés.
        guard let kind = AttachmentKind(fileName: url.lastPathComponent) else {
            return .refused(.unsupportedType)
        }
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer { if didStartAccessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let staged = try AttachmentFileVault.stageDeposit(of: url, rootDirectory: depositRoot)
            return kind == .image ? .image(staged) : .attachment(staged)
        } catch AttachmentFileVaultError.tooLarge {
            return .refused(.tooLarge)
        } catch {
            return .refused(.unreadable)
        }
    }
}

/// Ce que la fenêtre fait d'un dépôt : calculé sans interface, testé.
nonisolated struct DropPlan: Sendable, Equatable {
    /// Fichiers à joindre (copies dans les dépôts).
    private(set) var attachmentURLs: [URL] = []
    /// Images (copies dans les dépôts) : jointes comme les fichiers, leur texte est lu en local à la lecture.
    private(set) var imageURLs: [URL] = []
    /// Texte à ajouter au brouillon, déjà assaini, dans l'ordre du dépôt.
    private(set) var draftTexts: [String] = []
    private(set) var refusals: [DropRefusal] = []

    init(items: [DroppedItem]) {
        for item in items {
            switch item {
            case .attachment(let url): attachmentURLs.append(url)
            case .image(let url): imageURLs.append(url)
            case .text(let text): add(text: text)
            case .webURL(let url): add(text: url.absoluteString)
            case .refused(let refusal): refusals.append(refusal)
            }
        }
    }

    private mutating func add(text: String) {
        if let clean = ExternalQuerySanitizer.sanitize(text) {
            draftTexts.append(clean)
        } else {
            refusals.append(.unsupportedType)
        }
    }

    /// Tout ce qui est joint à la conversation, fichiers d'abord puis images.
    var attachableURLs: [URL] { attachmentURLs + imageURLs }

    var isEmpty: Bool { attachmentURLs.isEmpty && imageURLs.isEmpty && draftTexts.isEmpty && refusals.isEmpty }

    /// Un seul message, le premier refus (les autres sont du même ordre) : rien n'est abandonné en silence.
    var refusalMessage: String? { refusals.first?.message }

    /// Ajoute le texte déposé au brouillon : à la suite, séparé par une espace, jamais collé au mot précédent.
    static func appending(_ texts: [String], to draft: String) -> String {
        texts.reduce(draft) { current, text in
            guard !current.isEmpty else { return text }
            return current.last?.isWhitespace == true ? current + text : current + " " + text
        }
    }
}

