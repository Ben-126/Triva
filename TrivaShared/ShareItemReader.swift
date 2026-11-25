//
//  ShareItemReader.swift
//  TrivaShared
//
//  Chantier 2.1 (mission E) : ce que l'extension de partage comprend de ce qu'on lui envoie : un PDF, une image, une
//  page web (titre et adresse, via le prétraitement Safari `ShareSafariPreprocessor.js`) ou du texte.
//  Placé dans `TrivaShared` pour être TESTÉ avec de vrais `NSItemProvider` (l'extension elle-même ne l'est pas).
//
//  Mémoire : une extension de partage en dispose de très peu. Un fichier n'est JAMAIS chargé en mémoire : le système
//  l'écrit dans un fichier temporaire, supprimé au retour de la fermeture (doc `loadFileRepresentation`), et on le
//  copie (clone APFS, sans lecture) dans le dossier de travail de l'extension.
//

import Foundation
import UniformTypeIdentifiers

/// Un fichier partagé, copié dans le dossier de travail de l'extension (à effacer avec `ShareItemReader.clearStaging`).
nonisolated struct StagedShareFile: Sendable, Equatable {
    let url: URL
    /// Nom assaini, extension du type réel.
    let displayName: String
    let type: SharedFileType
    let byteCount: Int
}

nonisolated enum ShareContent: Sendable, Equatable {
    case text(String)
    /// Page web : son titre (s'il y en a un de lisible) et son adresse http(s).
    case page(title: String?, url: URL)
    case file(StagedShareFile)

    /// La question proposée dans la feuille, que l'utilisateur peut changer. Texte tel quel ; page : son TITRE, sinon
    /// l'adresse (même règle que Découvrir : une adresse brute envoyée à SearXNG ne trouve que la page elle-même) ;
    /// fichier : aucune.
    var suggestedQuestion: String? {
        switch self {
        case .text(let text): ExternalQuerySanitizer.sanitize(text)
        case .page(let title, let url): ExternalQuerySanitizer.sanitize(title) ?? url.absoluteString
        case .file: nil
        }
    }
}

/// Pourquoi un partage est refusé. Motifs fermés : aucun ne recopie le nom ou le contenu du fichier.
nonisolated enum ShareReadError: Error, Equatable, Sendable {
    /// Rien que Triva sache lire (« Triva n'a pas pu lire ce contenu. »).
    case nothingReadable
    /// Un fichier, mais pas un PDF ni une image reconnus (« Triva ne lit pas ce type de fichier. »).
    case unsupportedFile
    case tooLarge
}

nonisolated enum ShareItemReader {
    /// On ne regarde que les premières pièces jointes d'un partage.
    private static let maxProviders = 8

    private static let imageTypes: [UTType] = [.png, .jpeg, .heic, .heif, .tiff, .gif, .bmp, .webP]

    /// Lit le contenu partagé. Un fichier est copié sous `stagingDirectory/<id>/` ; en cas de refus, rien n'y reste.
    @MainActor
    static func read(_ items: [NSExtensionItem], stagingDirectory: URL) async throws -> ShareContent {
        let providers = Array(items.flatMap { $0.attachments ?? [] }.prefix(maxProviders))
        if let provider = providers.first(where: { fileTypeIdentifier(of: $0) != nil }), let identifier = fileTypeIdentifier(of: provider) {
            return .file(try await stageFile(from: provider, typeIdentifier: identifier, stagingDirectory: stagingDirectory))
        }
        if let page = await readPage(providers) {
            // Une app qui partage un texte ET une adresse : sans titre de page, le texte vaut mieux que l'adresse brute.
            if case .page(nil, _) = page, let text = await readText(providers) { return .text(text) }
            return page
        }
        if let text = await readText(providers) { return .text(text) }
        throw providers.contains(where: looksLikeAForeignFile) ? ShareReadError.unsupportedFile : ShareReadError.nothingReadable
    }

    /// Efface le dossier de travail de l'extension (fin du partage, annulation, erreur).
    static func clearStaging(at directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Efface les dossiers de travail LAISSÉS par un partage précédent (feuille balayée, extension tuée par le
    /// système) : un PDF de 200 Mo ne doit pas rester dans le dossier temporaire de l'extension, hors de portée de
    /// « Tout effacer ». Un dossier plus récent que `olderThan` est gardé : une autre feuille peut être en cours.
    static func purgeStaleStaging(
        in root: URL,
        olderThan age: TimeInterval = 5 * 60,
        now: Date = Date()
    ) {
        let manager = FileManager.default
        let names = (try? manager.contentsOfDirectory(atPath: root.path)) ?? []
        for name in names {
            let folder = root.appending(path: name, directoryHint: .isDirectory)
            let modified = (try? manager.attributesOfItem(atPath: folder.path)[.modificationDate]) as? Date
            // Date illisible : on efface (ce n'est pas un dossier que nous avons écrit).
            guard modified.map({ now.timeIntervalSince($0) > age }) ?? true else { continue }
            try? manager.removeItem(at: folder)
        }
    }

    // MARK: - Fichier

    /// L'identifiant de type sous lequel demander le fichier : PDF d'abord, puis un format d'image précis, puis « image ».
    private static func fileTypeIdentifier(of provider: NSItemProvider) -> String? {
        let types = provider.registeredTypeIdentifiers.compactMap { identifier in UTType(identifier).map { (identifier, $0) } }
        if let pdf = types.first(where: { $0.1.conforms(to: .pdf) }) { return pdf.0 }
        if let image = types.first(where: { entry in imageTypes.contains { entry.1.conforms(to: $0) } }) { return image.0 }
        return types.first(where: { $0.1 == .image })?.0
    }

    /// Un fichier d'un autre genre (Word, archive…) : à refuser clairement plutôt que de dire « illisible ».
    private static func looksLikeAForeignFile(_ provider: NSItemProvider) -> Bool {
        provider.registeredTypeIdentifiers.contains { identifier in
            guard let type = UTType(identifier) else { return false }
            return type.conforms(to: .data) && !type.conforms(to: .text) && !type.conforms(to: .url) && !type.conforms(to: .propertyList)
        }
    }

    @MainActor
    private static func stageFile(from provider: NSItemProvider, typeIdentifier: String, stagingDirectory: URL) async throws -> StagedShareFile {
        let suggestedName = provider.suggestedName
        return try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, error in
                // La copie doit se faire ICI : le fichier temporaire est supprimé quand cette fermeture rend la main.
                continuation.resume(with: Result {
                    guard let url, error == nil else { throw ShareReadError.nothingReadable }
                    return try copy(received: url, suggestedName: suggestedName, into: stagingDirectory)
                })
            }
        }
    }

    private static func copy(received: URL, suggestedName: String?, into stagingDirectory: URL) throws -> StagedShareFile {
        let manager = FileManager.default
        guard let attributes = try? manager.attributesOfItem(atPath: received.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? Int, size > 0 else {
            throw ShareReadError.unsupportedFile
        }
        guard size <= SharedFileType.pdf.maxByteCount else { throw ShareReadError.tooLarge }

        let folder = stagingDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let copied = folder.appending(path: "fichier", directoryHint: .notDirectory)
        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            try manager.copyItem(at: received, to: copied)
        } catch {
            try? manager.removeItem(at: folder)
            throw ShareReadError.nothingReadable
        }
        // On juge la COPIE : type par octets d'en-tête (jamais par le nom), taille réelle.
        guard let type = SharedFileType.detect(fileAt: copied) else {
            try? manager.removeItem(at: folder)
            throw ShareReadError.unsupportedFile
        }
        guard size <= type.maxByteCount else {
            try? manager.removeItem(at: folder)
            throw ShareReadError.tooLarge
        }
        // Le fichier temporaire du système garde le nom d'origine ; le nom proposé par l'app source (souvent sans
        // extension, parfois un libellé générique comme « Document PDF ») ne sert qu'à défaut.
        let rawName = received.lastPathComponent.isEmpty ? suggestedName : received.lastPathComponent
        let displayName = SharedFileName.sanitized(rawName, type: type)
        let named = folder.appending(path: displayName, directoryHint: .notDirectory)
        do {
            try manager.moveItem(at: copied, to: named)
        } catch {
            try? manager.removeItem(at: folder)
            throw ShareReadError.nothingReadable
        }
        return StagedShareFile(url: named, displayName: displayName, type: type, byteCount: size)
    }

    // MARK: - Page web

    @MainActor
    private static func readPage(_ providers: [NSItemProvider]) async -> ShareContent? {
        var title: String?
        var scriptURL: URL?
        var providedURL: URL?
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.propertyList.identifier),
               let results = await preprocessingResults(of: provider) {
                title = title ?? (results["title"] as? String)
                scriptURL = scriptURL ?? webURL(from: results["url"] as? String)
            }
            if providedURL == nil, provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                providedURL = await loadURL(from: provider)
            }
        }
        guard let url = providedURL ?? scriptURL else { return nil }
        return .page(title: ExternalQuerySanitizer.sanitize(title), url: url)
    }

    /// Le résultat du script de prétraitement Safari : un petit plist (titre, adresse). Safari le fournit sous forme
    /// d'objet (`loadItem`, déprécié mais seul chemin qui rend un dictionnaire ; un avertissement de compilation, rien
    /// de plus) ; à défaut, on décode les octets du plist (quelques centaines d'octets, plafonnés à 64 Ko).
    @MainActor
    private static func preprocessingResults(of provider: NSItemProvider) async -> [String: Any]? {
        let identifier = UTType.propertyList.identifier
        if let item = try? await provider.loadItem(forTypeIdentifier: identifier) as? NSDictionary,
           let results = item[NSExtensionJavaScriptPreprocessingResultsKey] as? [String: Any] {
            return results
        }
        let data: Data? = await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: identifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
        guard let data, data.count <= 64 * 1_024,
              let root = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return nil
        }
        return root[NSExtensionJavaScriptPreprocessingResultsKey] as? [String: Any]
    }

    @MainActor
    private static func loadURL(from provider: NSItemProvider) async -> URL? {
        let loaded: NSURL? = await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: NSURL.self) { object, _ in
                continuation.resume(returning: object as? NSURL)
            }
        }
        return webURL(from: loaded?.absoluteString)
    }

    /// Une page web : `http` ou `https` seulement. `javascript:`, `file:`, `mailto:`, `data:`… ne sont jamais lus.
    private static func webURL(from text: String?) -> URL? {
        guard let text, let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host?.isEmpty == false else {
            return nil
        }
        return url
    }

    // MARK: - Texte

    @MainActor
    private static func readText(_ providers: [NSItemProvider]) async -> String? {
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            // Une adresse est traitée comme une page (ou refusée), jamais comme du texte libre.
            guard !provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) else { continue }
            if let text = await loadString(from: provider), ExternalQuerySanitizer.sanitize(text) != nil { return text }
        }
        return nil
    }

    @MainActor
    private static func loadString(from provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                continuation.resume(returning: (object as? NSString).map { $0 as String })
            }
        }
    }
}
