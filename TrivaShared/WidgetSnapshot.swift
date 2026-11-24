//
//  WidgetSnapshot.swift
//  TrivaShared
//
//  Chantier 2.1 (mission C) : l'instantané que l'app écrit pour le widget, `widget-snapshot.json` dans l'App Group.
//  La dernière conversation SEULEMENT (identifiant, titre court, date) : jamais le texte d'une réponse, jamais
//  plusieurs conversations.
//
//  Règle de Ben (2026-11-24) : tant que le réglage « Dernière question dans le widget » est éteint (défaut), AUCUN
//  fichier n'existe, donc aucune question n'est écrite dans l'App Group. Le widget lit ce fichier et rien d'autre.
//

import Foundation

nonisolated struct WidgetSnapshot: Codable, Equatable, Sendable {
    static let currentVersion = 1
    /// Longueur maximale du titre affiché, « … » compris.
    static let maxTitleLength = 80
    static let fileName = "widget-snapshot.json"
    /// Texte quand une conversation n'a pas de titre exploitable.
    static let untitledFallback = "Conversation sans titre"

    struct Conversation: Codable, Equatable, Sendable {
        let id: UUID
        let title: String
        let updatedAt: Date
    }

    let version: Int
    /// La dernière conversation, ou `nil` quand l'historique est vide.
    let conversation: Conversation?

    /// Aucune conversation : le réglage est allumé mais l'historique est vide.
    static let empty = WidgetSnapshot(version: currentVersion, conversation: nil)

    init(version: Int, conversation: Conversation?) {
        self.version = version
        self.conversation = conversation
    }

    /// Titre nettoyé (`displayTitle`) ; date arrondie à la seconde, précision du fichier JSON : sans cet arrondi,
    /// un instantané relu ne serait jamais égal à celui qu'on vient de calculer et on réécrirait pour rien.
    init(conversationID: UUID, title: String, updatedAt: Date) {
        let wholeSeconds = Date(timeIntervalSince1970: updatedAt.timeIntervalSince1970.rounded(.down))
        self.init(
            version: Self.currentVersion,
            conversation: Conversation(id: conversationID, title: Self.displayTitle(title), updatedAt: wholeSeconds)
        )
    }

    /// Titre prêt à afficher : espaces et retours à la ligne ramenés à un seul espace, bords retirés, coupé à
    /// `maxTitleLength` caractères (« … » compris, jamais au milieu d'un caractère), repli si vide.
    static func displayTitle(_ raw: String) -> String {
        let collapsed = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty else { return untitledFallback }
        guard collapsed.count > maxTitleLength else { return collapsed }
        let head = collapsed.prefix(maxTitleLength - 1)
        let trimmed = head.last?.isWhitespace == true ? head.dropLast() : head
        return String(trimmed) + "…"
    }
}

/// Lecture et écriture de l'instantané dans l'App Group.
nonisolated struct WidgetSnapshotStore: Sendable {
    let files: AppGroupFileStore

    var exists: Bool { files.exists(WidgetSnapshot.fileName) }

    /// L'instantané courant, ou `nil` : fichier absent, version inconnue (laissée en place), illisible ou corrompu
    /// (supprimé, pour que le widget ne bute pas dessus à chaque fois). Jamais de plantage.
    func load() -> WidgetSnapshot? {
        let data: Data
        do {
            guard let found = try files.read(WidgetSnapshot.fileName) else { return nil }
            data = found
        } catch {
            return nil
        }
        let decoder = Self.makeDecoder()
        guard let probe = try? decoder.decode(VersionProbe.self, from: data) else {
            removeCorruptFile()
            return nil
        }
        guard probe.version == WidgetSnapshot.currentVersion else { return nil }
        guard let snapshot = try? decoder.decode(WidgetSnapshot.self, from: data) else {
            removeCorruptFile()
            return nil
        }
        return snapshot
    }

    func save(_ snapshot: WidgetSnapshot) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try files.write(try encoder.encode(snapshot), to: WidgetSnapshot.fileName)
    }

    func delete() throws {
        try files.remove(WidgetSnapshot.fileName)
    }

    private struct VersionProbe: Decodable { let version: Int }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Nettoyage au mieux : un fichier qu'on ne peut pas supprimer sera simplement ignoré à la lecture suivante.
    private func removeCorruptFile() {
        try? files.remove(WidgetSnapshot.fileName)
    }
}
