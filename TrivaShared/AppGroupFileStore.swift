//
//  AppGroupFileStore.swift
//  TrivaShared
//
//  Chantier 2.1 (mission C) : lecture et écriture de petits fichiers dans le dossier partagé de l'App Group,
//  `<groupe>/Library/Application Support/TrivaShared/`. C'est le SEUL canal de données entre l'app et ses
//  extensions : pas de `UserDefaults(suiteName:)` (sur Mac, un groupe hors préfixe d'équipe peut déclencher une
//  invite d'accès), pas de base de données partagée (SwiftData reste dans le conteneur de l'app).
//
//  Compilé dans l'app ET dans les extensions : rien d'ici ne doit nommer un type de l'app.
//  Écriture atomique (le widget ne lit jamais un fichier à moitié écrit) ; sur iPhone et iPad, protection
//  « jusqu'à la première ouverture » pour que le widget de l'écran verrouillé puisse lire après un déverrouillage.
//

import Foundation

nonisolated struct AppGroupFileStore: Sendable {
    enum StoreError: Error, Equatable, CustomStringConvertible {
        /// Le chemin relatif sort du dossier ou n'est pas une suite de noms simples.
        case invalidPath
        case writeFailed(String)
        case readFailed(String)
        case removeFailed(String)

        var description: String {
            switch self {
            case .invalidPath: "chemin refusé"
            case .writeFailed(let reason): "écriture impossible (\(reason))"
            case .readFailed(let reason): "lecture impossible (\(reason))"
            case .removeFailed(let reason): "suppression impossible (\(reason))"
            }
        }
    }

    /// Nom du dossier de Triva dans `Library/Application Support/` du conteneur de l'App Group.
    static let folderName = "TrivaShared"

    let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    /// Le dossier partagé réel, ou `nil` quand l'App Group n'est pas disponible (app non signée avec le groupe).
    static func live() -> AppGroupFileStore? {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroup.identifier) else {
            return nil
        }
        let directory = container
            .appending(path: "Library", directoryHint: .isDirectory)
            .appending(path: "Application Support", directoryHint: .isDirectory)
            .appending(path: folderName, directoryHint: .isDirectory)
        return AppGroupFileStore(directory: directory)
    }

    // MARK: Opérations

    /// Écrit (ou remplace) le fichier, en créant les dossiers intermédiaires.
    func write(_ data: Data, to path: String) throws {
        let target = try url(for: path)
        do {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target, options: Self.writeOptions)
        } catch {
            throw StoreError.writeFailed(error.localizedDescription)
        }
    }

    /// Le contenu du fichier, ou `nil` s'il n'existe pas. Lève si le fichier existe mais ne se lit pas.
    func read(_ path: String) throws -> Data? {
        let target = try url(for: path)
        guard FileManager.default.fileExists(atPath: target.path) else { return nil }
        do {
            return try Data(contentsOf: target)
        } catch {
            throw StoreError.readFailed(error.localizedDescription)
        }
    }

    /// Supprime le fichier ; sans effet s'il n'existe pas.
    func remove(_ path: String) throws {
        let target = try url(for: path)
        guard FileManager.default.fileExists(atPath: target.path) else { return }
        do {
            try FileManager.default.removeItem(at: target)
        } catch {
            throw StoreError.removeFailed(error.localizedDescription)
        }
    }

    /// `false` aussi pour un chemin refusé.
    func exists(_ path: String) -> Bool {
        guard let target = try? url(for: path) else { return false }
        return FileManager.default.fileExists(atPath: target.path)
    }

    // MARK: Interne

    #if os(iOS)
    private static let writeOptions: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
    #else
    private static let writeOptions: Data.WritingOptions = [.atomic]
    #endif

    /// Chemin relatif fait de noms simples séparés par `/` : ni vide, ni `.` ni `..`, ni blanc, ni `\` ou NUL.
    private func url(for path: String) throws -> URL {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        let isSafe = !components.isEmpty && components.allSatisfy { component in
            !component.isEmpty
                && component != "." && component != ".."
                && !component.allSatisfy(\.isWhitespace)
                && !component.contains(where: { $0 == "\\" || $0 == "\0" })
        }
        guard isSafe else { throw StoreError.invalidPath }
        return components.reduce(directory) { $0.appending(path: String($1), directoryHint: .inferFromPath) }
    }
}
