//
//  SharedInbox.swift
//  TrivaShared
//
//  Chantier 2.1 (mission E) : la boîte de partage, dans le dossier de l'App Group :
//  `<groupe>/Library/Application Support/TrivaShared/share-inbox/`. L'extension de partage y ÉCRIT, l'app y LIT puis
//  efface. Une entrée = un manifeste `<id>.json` (écrit EN DERNIER, donc un manifeste lisible annonce un fichier
//  complet) et, pour un fichier, `<id>.payload`. Le nom d'origine du fichier ne figure jamais sur le disque.
//
//  Règles : 8 entrées au plus, gardées 24 h, 400 Mo de fichiers au plus (les plus anciennes partent d'abord) ;
//  PDF 200 Mo, image 50 Mo ; protection de fichiers iOS « jusqu'à la première ouverture » (une lecture en cours
//  survit au verrouillage) ; fichier vérifié sur la COPIE (type par octets d'en-tête, taille exacte) ;
//  entrée illisible, tronquée ou expirée effacée sans plantage. Le contenu d'un fichier n'est jamais chargé en
//  mémoire : une extension en dispose de très peu.
//
//  Compilé dans l'app ET dans l'extension : rien d'ici ne nomme un type de l'app.
//

import Foundation

nonisolated struct SharedInbox: Sendable {
    static let folderName = "share-inbox"
    static let maxEntries = 8
    /// Durée de garde d'une entrée.
    static let maxAge: TimeInterval = 24 * 60 * 60
    /// Un fichier sans manifeste est peut-être en cours d'écriture par l'extension : on lui laisse 10 minutes.
    static let orphanGrace: TimeInterval = 10 * 60
    /// Total des fichiers gardés : 400 Mo, pour ne pas remplir l'appareil de copies que personne n'a reprises.
    static let maxTotalFileByteCount = 400 * 1_024 * 1_024

    private static let manifestExtension = "json"
    private static let payloadExtension = "payload"
    private static let partialExtension = "part"

    /// Pourquoi une écriture est refusée. Motifs fermés, sans nom ni contenu de fichier.
    enum Failure: Error, Equatable, Sendable {
        /// Ni question lisible, ni fichier.
        case emptyContent
        /// Pas un PDF ou une image reconnus, lien, dossier, fichier vide.
        case unsupportedFile
        case tooLarge
        /// Fichier introuvable ou illisible.
        case unreadable
        case writeFailed
    }

    let directory: URL
    /// Horloge injectée (tests d'expiration).
    let now: @Sendable () -> Date

    init(directory: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.now = now
    }

    /// La boîte réelle, ou `nil` quand l'App Group n'est pas disponible (app non signée avec le groupe).
    static func live() -> SharedInbox? {
        AppGroupFileStore.live().map { SharedInbox(directory: $0.directory.appending(path: folderName, directoryHint: .isDirectory)) }
    }

    // MARK: - Écriture (extension de partage)

    /// Ajoute une entrée : une question, un fichier, ou les deux. La source n'est ni déplacée ni modifiée.
    /// - Parameter displayName: nom d'origine du fichier (assaini ici).
    @discardableResult
    func add(text: String?, fileAt source: URL?, displayName: String?) throws -> SharedInboxEntry {
        let cleanText = ExternalQuerySanitizer.sanitize(text)
        guard cleanText != nil || source != nil else { throw Failure.emptyContent }

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw Failure.writeFailed
        }
        let id = UUID()
        let file = try source.map { try copyFile(from: $0, id: id, displayName: displayName) }
        let entry = SharedInboxEntry(version: SharedInboxEntry.currentVersion, id: id, createdAt: now(), text: cleanText, file: file)
        do {
            let manifest = try JSONEncoder().encode(entry)
            try manifest.write(to: manifestURL(id), options: Self.writeOptions)
        } catch {
            removeFiles(of: id)
            throw Failure.writeFailed
        }
        // Ménage après écriture : `validEntries()` ne garde que les 8 plus récentes (celle-ci est la plus récente).
        _ = validEntries()
        return entry
    }

    // MARK: - Lecture (app)

    /// Les entrées valides, la plus récente d'abord. Efface au passage ce qui ne l'est plus : expiré, illisible,
    /// tronqué, fichier remplacé, excédent, orphelin de plus de 10 minutes.
    func validEntries() -> [SharedInboxEntry] {
        validEntries(sweepingOrphans: true)
    }

    /// `sweepingOrphans: false` pendant une écriture : la copie en cours (`.part`) n'a pas encore de manifeste.
    private func validEntries(sweepingOrphans: Bool) -> [SharedInboxEntry] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        var valid: [SharedInboxEntry] = []
        var knownIDs = Set<String>()
        for name in names where (name as NSString).pathExtension == Self.manifestExtension {
            let stem = (name as NSString).deletingPathExtension
            knownIDs.insert(stem)
            if let entry = readValidEntry(named: name, stem: stem) {
                valid.append(entry)
            } else {
                removeFiles(ofStem: stem)
            }
        }
        if sweepingOrphans { removeOrphans(in: names, knownIDs: knownIDs) }
        let sorted = valid.sorted { ($0.createdAt, $0.id.uuidString) > ($1.createdAt, $1.id.uuidString) }
        sorted.dropFirst(Self.maxEntries).forEach(remove)
        return Array(sorted.prefix(Self.maxEntries))
    }

    /// Où lire le fichier d'une entrée.
    func payloadURL(of entry: SharedInboxEntry) -> URL {
        payloadURL(entry.id)
    }

    // MARK: - Effacement

    /// Efface une entrée (manifeste, fichier, copie en cours).
    func remove(_ entry: SharedInboxEntry) {
        removeFiles(of: entry.id)
    }

    /// Vide TOUT le dossier de la boîte : « Tout effacer », même les fichiers en cours d'écriture.
    func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Interne : écriture d'un fichier

    private func copyFile(from source: URL, id: UUID, displayName: String?) throws -> SharedInboxEntry.File {
        let manager = FileManager.default
        guard let attributes = try? manager.attributesOfItem(atPath: source.path), let size = attributes[.size] as? Int else {
            throw Failure.unreadable
        }
        // `attributesOfItem` ne suit pas les liens : un lien symbolique, un dossier ou un paquet ne sont pas des fichiers.
        guard attributes[.type] as? FileAttributeType == .typeRegular, size > 0 else { throw Failure.unsupportedFile }
        // Taille maximale de tous les types : au-delà, on ne copie même pas pour regarder.
        guard size <= SharedFileType.pdf.maxByteCount else { throw Failure.tooLarge }

        let partial = directory.appending(path: "\(id.uuidString).\(Self.partialExtension)", directoryHint: .notDirectory)
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            try manager.copyItem(at: source, to: partial)
        } catch {
            try? manager.removeItem(at: partial)
            throw Failure.writeFailed
        }
        do {
            // On juge la COPIE, pas la source : celle-ci a pu changer entre le contrôle et la copie.
            let verified = try verifiedFile(at: partial, expectedByteCount: nil)
            guard verified.size <= verified.type.maxByteCount else { throw Failure.tooLarge }
            try makeRoom(forFileOfSize: verified.size)
            try Self.protect(partial)
            try manager.moveItem(at: partial, to: payloadURL(id))
            return SharedInboxEntry.File(
                type: verified.type,
                displayName: SharedFileName.sanitized(displayName, type: verified.type),
                byteCount: verified.size
            )
        } catch let failure as Failure {
            try? manager.removeItem(at: partial)
            throw failure
        } catch {
            try? manager.removeItem(at: partial)
            throw Failure.writeFailed
        }
    }

    /// Type et taille d'un fichier régulier déjà dans la boîte. Lève `unsupportedFile` si ce n'est pas un PDF ou une image.
    private func verifiedFile(at url: URL, expectedByteCount: Int?) throws -> (type: SharedFileType, size: Int) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? Int,
              size > 0,
              expectedByteCount.map({ $0 == size }) ?? true,
              let type = SharedFileType.detect(fileAt: url) else {
            throw Failure.unsupportedFile
        }
        return (type, size)
    }

    // MARK: - Interne : lecture et ménage

    private func readValidEntry(named name: String, stem: String) -> SharedInboxEntry? {
        let url = directory.appending(path: name, directoryHint: .notDirectory)
        guard let data = try? Data(contentsOf: url),
              let entry = try? JSONDecoder().decode(SharedInboxEntry.self, from: data),
              entry.version == SharedInboxEntry.currentVersion,
              entry.id.uuidString == stem else {
            return nil
        }
        let age = now().timeIntervalSince(entry.createdAt)
        guard age <= Self.maxAge, age >= -Self.maxAge else { return nil }
        let text = ExternalQuerySanitizer.sanitize(entry.text)
        guard text != nil || entry.file != nil else { return nil }
        if let file = entry.file {
            guard let verified = try? verifiedFile(at: payloadURL(entry.id), expectedByteCount: file.byteCount),
                  verified.type == file.type,
                  verified.size <= verified.type.maxByteCount else {
                return nil
            }
        }
        return SharedInboxEntry(version: entry.version, id: entry.id, createdAt: entry.createdAt, text: text, file: entry.file)
    }

    private func removeOrphans(in names: [String], knownIDs: Set<String>) {
        for name in names where (name as NSString).pathExtension != Self.manifestExtension {
            guard !knownIDs.contains((name as NSString).deletingPathExtension) else { continue }
            let url = directory.appending(path: name, directoryHint: .notDirectory)
            let modified = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
            // Date illisible : on garde (mieux vaut une copie de trop qu'une écriture coupée), le délai ne court pas.
            guard let modified, now().timeIntervalSince(modified) > Self.orphanGrace else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Avant de ranger un fichier de `size` octets : évince les entrées les plus anciennes jusqu'à ce que le total
    /// des fichiers, avec le nouveau, tienne dans 400 Mo.
    private func makeRoom(forFileOfSize size: Int) throws {
        var entries = validEntries(sweepingOrphans: false)
        var total = entries.compactMap(\.file?.byteCount).reduce(0, +)
        while total + size > Self.maxTotalFileByteCount, let oldest = entries.last {
            entries.removeLast()
            total -= oldest.file?.byteCount ?? 0
            remove(oldest)
        }
        // Une entrée sans fichier ne libère rien : si rien d'autre ne peut partir, le fichier entre quand même
        // (il est plafonné à 200 Mo, donc le total reste sous 600 Mo au pire, jusqu'au prochain ménage).
    }

    private func removeFiles(of id: UUID) {
        removeFiles(ofStem: id.uuidString)
    }

    private func removeFiles(ofStem stem: String) {
        for ext in [Self.manifestExtension, Self.payloadExtension, Self.partialExtension] {
            try? FileManager.default.removeItem(at: directory.appending(path: "\(stem).\(ext)", directoryHint: .notDirectory))
        }
    }

    private func manifestURL(_ id: UUID) -> URL {
        directory.appending(path: "\(id.uuidString).\(Self.manifestExtension)", directoryHint: .notDirectory)
    }

    private func payloadURL(_ id: UUID) -> URL {
        directory.appending(path: "\(id.uuidString).\(Self.payloadExtension)", directoryHint: .notDirectory)
    }

    // MARK: - Protection de fichiers

    #if os(iOS)
    private static let writeOptions: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]

    /// `copyItem` n'applique pas les options d'écriture : on pose la protection à la main. « Jusqu'à la première
    /// ouverture » et non « complète » : une lecture déjà commencée survit au verrouillage de l'appareil.
    private static func protect(_ url: URL) throws {
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
    }
    #else
    private static let writeOptions: Data.WritingOptions = [.atomic]
    private static func protect(_ url: URL) throws {}
    #endif
}
