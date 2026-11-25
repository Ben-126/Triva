//
//  AttachmentFileVault.swift
//  Triva
//
//  Chantier 2.2 (M5) : le « coffre » des fichiers joints. Une pièce jointe n'est lue qu'UNE fois (texte extrait,
//  `AttachmentStore` ne garde ni l'URL ni l'accès au fichier). Or deux fonctions ont besoin du fichier après coup :
//  le Coup d'œil (Quick Look) et le dépôt (un fichier reçu par glisser-déposer n'existe que le temps de la
//  fermeture qui le reçoit). Le coffre en garde donc une COPIE temporaire, et la lecture se fait sur cette copie.
//
//  Ce sont des documents de l'utilisateur : rien ne doit traîner. Effacement par pièce jointe retirée, à la
//  nouvelle conversation, à la fermeture de la fenêtre (`deinit` du contrôleur), et purge de tout ce qui reste au
//  lancement de l'app (`purgeAll`).
//

import Foundation

/// Où le coffre a placé un fichier : ce que l'extracteur doit lire, et la copie à conserver (`nil` : aucune copie,
/// le Coup d'œil n'est alors pas proposé).
nonisolated struct AttachmentFilePlacement: Sendable, Equatable {
    let readURL: URL
    let storedURL: URL?
}

nonisolated enum AttachmentFileVaultError: Error, Sendable, Equatable {
    /// Fichier plus gros que `AttachmentFileVault.maxFileByteCount`.
    case tooLarge
    /// Dossier, paquet, fichier illisible ou copie échouée.
    case unreadable
}

/// Coffre d'une conversation : un dossier de session sous `tmp/TrivaAttachments`.
///
/// Structure `Sendable` sans état : le contrôleur de pièces jointes la possède, et ses opérations lourdes (copie
/// d'un PDF) s'exécutent hors du main actor (`@concurrent`).
nonisolated struct AttachmentFileVault: Sendable {
    /// Dossier racine du coffre, dans le dossier temporaire du bac à sable.
    static let folderName = "TrivaAttachments"
    /// Dossier des fichiers reçus par glisser-déposer, pas encore adoptés par une conversation.
    static let depositsFolderName = "_deposits"
    /// Au-delà, aucune copie : 200 Mo, large pour un PDF lu 5 pages à la fois, sans remplir le disque de copies.
    static let maxFileByteCount = 200 * 1024 * 1024

    static var defaultRootDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(folderName, isDirectory: true)
    }

    let rootDirectory: URL
    /// Dossier de cette conversation : `<racine>/<identifiant de session>`.
    let sessionDirectory: URL

    init(rootDirectory: URL = AttachmentFileVault.defaultRootDirectory, sessionID: UUID = UUID()) {
        self.rootDirectory = rootDirectory
        self.sessionDirectory = rootDirectory.appendingPathComponent(sessionID.uuidString, isDirectory: true)
    }

    // MARK: - Placement (hors du main actor)

    /// Place un fichier choisi ou déposé et dit où le lire. Ne lève jamais : sans copie possible, le fichier
    /// d'origine est lu tel quel (sa portée de sécurité est encore valable), sans Coup d'œil.
    /// - Parameter isDeposit : `true` pour un fichier déjà copié dans les dépôts (déplacé, pas recopié).
    /// - Un type que l'extracteur ne lit pas n'est pas copié : il sera refusé avec le message habituel.
    @concurrent
    func place(_ url: URL, isDeposit: Bool) async -> AttachmentFilePlacement {
        guard AttachmentKind(fileName: url.lastPathComponent) != nil else {
            return AttachmentFilePlacement(readURL: url, storedURL: nil)
        }
        do {
            let stored = isDeposit ? try adopt(deposit: url) : try copy(of: url)
            return AttachmentFilePlacement(readURL: stored, storedURL: stored)
        } catch {
            return AttachmentFilePlacement(readURL: url, storedURL: nil)
        }
    }

    // MARK: - Copie

    /// Copie sous `<session>/<identifiant>/<nom d'origine>` : le dossier d'identifiant évite tout conflit de nom
    /// entre deux fichiers, et le nom d'origine (donc l'extension) reste celui que Coup d'œil affiche.
    func copy(of source: URL) throws -> URL {
        let didStartAccessing = source.startAccessingSecurityScopedResource()
        defer { if didStartAccessing { source.stopAccessingSecurityScopedResource() } }

        let size = try Self.fileSize(of: source)
        guard size <= Self.maxFileByteCount else { throw AttachmentFileVaultError.tooLarge }

        let destination = try makeEntryURL(fileName: source.lastPathComponent)
        // Même coordination de lecture que l'extracteur : un document iCloud pas encore téléchargé est
        // matérialisé, un fichier en cours d'écriture par une autre app est attendu.
        var coordinationError: NSError?
        var copyError: (any Error)?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: source, options: [], error: &coordinationError) { readable in
            do {
                try FileManager.default.copyItem(at: readable, to: destination)
            } catch {
                copyError = error
            }
        }
        guard coordinationError == nil, copyError == nil else {
            removeEntry(at: destination)
            throw AttachmentFileVaultError.unreadable
        }
        AttachmentFileProtection.apply(to: destination)
        return destination
    }

    /// Déplace un dépôt (`<racine>/_deposits/<id>/<nom>`) dans la session : même volume, aucune recopie.
    /// Refuse (`unreadable`) toute URL hors de `<racine>/_deposits/` : on déplace le DOSSIER PARENT du dépôt, jamais
    /// celui d'un fichier de l'utilisateur (même garde que `discardDeposit`).
    func adopt(deposit: URL) throws -> URL {
        guard Self.isInsideDeposits(deposit, rootDirectory: rootDirectory) else { throw AttachmentFileVaultError.unreadable }
        let entry = sessionDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
            AttachmentFileProtection.apply(to: sessionDirectory)
            try FileManager.default.moveItem(at: deposit.deletingLastPathComponent(), to: entry)
        } catch {
            throw AttachmentFileVaultError.unreadable
        }
        // Un déplacement garde la classe du dépôt : on la ré-applique au dossier et au fichier adoptés.
        let adopted = entry.appendingPathComponent(deposit.lastPathComponent, isDirectory: false)
        AttachmentFileProtection.apply(to: entry)
        AttachmentFileProtection.apply(to: adopted)
        return adopted
    }

    /// Dossier d'entrée vide `<session>/<id>/` et URL du fichier à y écrire.
    private func makeEntryURL(fileName: String) throws -> URL {
        let entry = sessionDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: entry, withIntermediateDirectories: true)
            AttachmentFileProtection.apply(to: sessionDirectory)
            AttachmentFileProtection.apply(to: entry)
        } catch {
            throw AttachmentFileVaultError.unreadable
        }
        return entry.appendingPathComponent(fileName, isDirectory: false)
    }

    // MARK: - Effacement

    /// Efface une copie (et son dossier d'identifiant). Sans effet sur une URL qui n'est pas dans ce coffre :
    /// jamais un fichier de l'utilisateur.
    func remove(storedURL: URL?) {
        guard let storedURL, isInside(storedURL) else { return }
        removeEntry(at: storedURL)
    }

    /// Efface tout le coffre de cette conversation.
    func removeAll() {
        try? FileManager.default.removeItem(at: sessionDirectory)
    }

    private func removeEntry(at file: URL) {
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    /// Vrai pour un fichier sous le dossier de session (le chemin est comparé normalisé : pas de `..`).
    private func isInside(_ url: URL) -> Bool {
        let prefix = sessionDirectory.standardizedFileURL.path + "/"
        return url.standardizedFileURL.path.hasPrefix(prefix)
    }

    // MARK: - Dépôts (glisser-déposer)

    /// Copie immédiate d'un fichier reçu par glisser-déposer : il n'est garanti que dans la fermeture qui le reçoit
    /// (documentation de `FileRepresentation`). Rangé dans `<racine>/_deposits/<id>/<nom>`, adopté ensuite par la
    /// conversation (`place(_:isDeposit:)`). Appelable depuis n'importe quel contexte.
    static func stageDeposit(
        of received: URL,
        named fileName: String? = nil,
        rootDirectory: URL = AttachmentFileVault.defaultRootDirectory
    ) throws -> URL {
        // Un lien symbolique est suivi jusqu'à sa cible : `copyItem` copierait sinon le LIEN (taille nulle, limite de
        // 200 Mo contournée, lecture ensuite par le lien). Une cible hors du bac à sable fait échouer la copie.
        let source = received.resolvingSymlinksInPath()
        let size = try fileSize(of: source)
        guard size <= maxFileByteCount else { throw AttachmentFileVaultError.tooLarge }
        let (folder, destination) = newDepositLocation(named: fileName ?? received.lastPathComponent, rootDirectory: rootDirectory)
        do {
            try createDepositFolder(folder, rootDirectory: rootDirectory)
            try FileManager.default.copyItem(at: source, to: destination)
            AttachmentFileProtection.apply(to: destination)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw AttachmentFileVaultError.unreadable
        }
        return destination
    }

    /// Dépôt d'octets sans fichier d'origine (image collée, K2) : même dossier, même plafond, même protection que
    /// `stageDeposit(of:)`, pour que le reste du chemin (adoption, lecture, refus) soit identique.
    /// - Parameter maxByteCount: plafond, `maxFileByteCount` (200 Mo) sauf test.
    static func stageDeposit(
        data: Data,
        named fileName: String,
        rootDirectory: URL = AttachmentFileVault.defaultRootDirectory,
        maxByteCount: Int = AttachmentFileVault.maxFileByteCount
    ) throws -> URL {
        guard data.count <= maxByteCount else { throw AttachmentFileVaultError.tooLarge }
        let (folder, destination) = newDepositLocation(named: fileName, rootDirectory: rootDirectory)
        do {
            try createDepositFolder(folder, rootDirectory: rootDirectory)
            try data.write(to: destination, options: .atomic)
            AttachmentFileProtection.apply(to: destination)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw AttachmentFileVaultError.unreadable
        }
        return destination
    }

    /// Renomme un dépôt EN PLACE (même dossier d'identifiant) : une image reçue du système porte souvent un nom
    /// générique, identique d'un collage à l'autre, que le dédoublonnage par nom refuserait.
    /// Sans effet (rend l'URL d'origine) hors du dossier des dépôts ou si le renommage échoue.
    static func renameDeposit(
        _ url: URL,
        to fileName: String,
        rootDirectory: URL = AttachmentFileVault.defaultRootDirectory
    ) -> URL {
        guard isInsideDeposits(url, rootDirectory: rootDirectory) else { return url }
        let destination = url.deletingLastPathComponent().appendingPathComponent(safeName(fileName), isDirectory: false)
        guard destination != url, !FileManager.default.fileExists(atPath: destination.path) else { return url }
        do {
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        } catch {
            return url
        }
    }

    /// `<racine>/_deposits/<id>/` et le fichier à y écrire.
    private static func newDepositLocation(named fileName: String, rootDirectory: URL) -> (folder: URL, file: URL) {
        let folder = rootDirectory
            .appendingPathComponent(depositsFolderName, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return (folder, folder.appendingPathComponent(safeName(fileName), isDirectory: false))
    }

    private static func createDepositFolder(_ folder: URL, rootDirectory: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        AttachmentFileProtection.apply(to: rootDirectory.appendingPathComponent(depositsFolderName, isDirectory: true))
        AttachmentFileProtection.apply(to: folder)
    }

    /// Efface un dépôt jamais adopté (refusé, doublon, excédent). Sans effet hors du dossier des dépôts.
    static func discardDeposit(_ url: URL, rootDirectory: URL = AttachmentFileVault.defaultRootDirectory) {
        guard isInsideDeposits(url, rootDirectory: rootDirectory) else { return }
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    /// Vrai pour un fichier SOUS `<racine>/_deposits/<id>/` (chemin normalisé : pas de `..`). Le dossier des dépôts
    /// lui-même, ou un fichier posé directement dedans, n'en fait pas partie : un dépôt a toujours son dossier `<id>`.
    private static func isInsideDeposits(_ url: URL, rootDirectory: URL) -> Bool {
        let deposits = rootDirectory.appendingPathComponent(depositsFolderName, isDirectory: true).standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(deposits) else { return false }
        return path.dropFirst(deposits.count).contains("/")
    }

    /// Nom de fichier sûr : jamais vide, jamais un chemin.
    private static func safeName(_ name: String) -> String {
        let last = (name as NSString).lastPathComponent
        return last.isEmpty || last == "." || last == ".." ? "Document" : last
    }

    // MARK: - Purge au lancement

    /// Efface TOUT le coffre. À appeler au lancement de l'app, avant que la moindre fenêtre n'existe : aucune
    /// conversation vivante ne peut alors en dépendre. Les copies d'un lancement précédent (arrêt brutal) sont
    /// ainsi supprimées au plus tard au lancement suivant.
    ///
    /// - Returns: `false` si la suppression a été refusée (un dossier absent compte comme réussi) : « Tout effacer »
    ///   ne doit pas annoncer « Tout a été effacé » quand une copie de document est restée sur le disque.
    @discardableResult
    static func purgeAll(rootDirectory: URL = AttachmentFileVault.defaultRootDirectory) -> Bool {
        guard FileManager.default.fileExists(atPath: rootDirectory.path) else { return true }
        do {
            try FileManager.default.removeItem(at: rootDirectory)
            return true
        } catch {
            // Dossier du coffre impossible à retirer mais plus rien dedans : aucune copie de document ne reste.
            let remaining = try? FileManager.default.contentsOfDirectory(atPath: rootDirectory.path)
            return remaining?.isEmpty == true
        }
    }

    // MARK: - Détails

    private static func fileSize(of url: URL) throws -> Int {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey]),
              values.isDirectory != true,
              let size = values.fileSize else {
            throw AttachmentFileVaultError.unreadable
        }
        return size
    }
}
