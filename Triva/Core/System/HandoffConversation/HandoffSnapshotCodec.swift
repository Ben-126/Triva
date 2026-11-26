//
//  HandoffSnapshotCodec.swift
//  Triva
//
//  Chantier 2.3 (mission H2) : le codage versionné de la discussion envoyée par Handoff, et sa lecture.
//
//  À l'ENVOI : plafond de taille (≈ 2 Mo) et de nombre de messages ; une discussion trop lourde perd ses plus anciens
//  échanges, jamais les derniers.
//  À la LECTURE (entrée EXTERNE : un autre appareil, ou quelqu'un qui s'en fait passer pour un) : taille vérifiée avant
//  toute lecture, version, identifiant annoncé, nombres, rôles, doublons, caractères de contrôle, longueurs, et adresses
//  de sources limitées à http et https. Les réponses ne passent PAS par `ExternalQuerySanitizer` (outil de question, coupe
//  à quelques milliers de caractères) : elles ont leurs propres plafonds.
//

import Foundation

nonisolated enum HandoffSnapshotError: Error, Equatable, Sendable {
    case tooLarge
    case malformed
    case unsupportedVersion
    case mismatchedConversation
    case empty
    case tooManyItems
}

nonisolated enum HandoffSnapshotCodec {
    /// Version du codage de la discussion (distincte de la version de l'en-tête de l'activité).
    static let version = 1

    /// Plafond de la discussion codée : 2 Mo.
    static let maxPayloadBytes = 2 * 1024 * 1024
    static let maxMessages = 200
    static let maxSourcesPerMessage = 30
    static let maxMessageCharacters = 60_000
    static let maxTitleCharacters = 200
    static let maxSourceTitleCharacters = 500
    static let maxSourceURLCharacters = 2_048
    static let maxSourceSnippetCharacters = 2_000
    static let maxNoteNumbers = 100

    struct Encoded: Sendable, Equatable {
        let data: Data
        /// Nombre de messages les plus anciens laissés de côté pour tenir dans les plafonds.
        let droppedMessageCount: Int
    }

    private struct Envelope: Codable {
        var v: Int
        var conversation: HandoffConversationSnapshot
    }

    private struct VersionProbe: Decodable {
        var v: Int
    }

    // MARK: Envoi

    /// - Returns: `nil` si même le dernier échange ne tient pas dans `maxBytes` (rien n'est envoyé : le receveur se replie).
    static func encode(_ snapshot: HandoffConversationSnapshot, maxBytes: Int = maxPayloadBytes) -> Encoded? {
        var messages = Array(snapshot.messages.suffix(maxMessages))
        var dropped = snapshot.messages.count - messages.count
        func attempt() -> Data? {
            var candidate = snapshot
            candidate.messages = messages
            return try? encodeUnchecked(candidate)
        }
        while !messages.isEmpty {
            if let data = attempt(), data.count <= maxBytes {
                return Encoded(data: data, droppedMessageCount: dropped)
            }
            // Un échange à la fois : on retire le plus ancien message, puis ce qui reste de son échange (une réponse
            // sans sa question n'a pas de sens). La discussion garde toujours ses derniers messages.
            messages.removeFirst()
            dropped += 1
            while let first = messages.first, first.role != .user, messages.count > 1 {
                messages.removeFirst()
                dropped += 1
            }
        }
        return nil
    }

    /// Codage sans plafond ni normalisation : pour les tests (fabriquer un contenu hostile) et la boucle de `encode`.
    static func encodeUnchecked(_ snapshot: HandoffConversationSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        return try encoder.encode(Envelope(v: version, conversation: snapshot))
    }

    // MARK: Lecture

    /// - Parameter expectedConversationID: l'identifiant annoncé par l'en-tête de l'activité ; `nil` : pas de contrôle.
    static func decode(
        _ data: Data,
        expectedConversationID: UUID?,
        maxBytes: Int = maxPayloadBytes
    ) throws -> HandoffConversationSnapshot {
        guard data.count <= maxBytes else { throw HandoffSnapshotError.tooLarge }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let probe = try? decoder.decode(VersionProbe.self, from: data) else { throw HandoffSnapshotError.malformed }
        guard probe.v == version else { throw HandoffSnapshotError.unsupportedVersion }
        guard let envelope = try? decoder.decode(Envelope.self, from: data) else { throw HandoffSnapshotError.malformed }
        return try validated(envelope.conversation, expectedConversationID: expectedConversationID)
    }

    // MARK: Vérification et normalisation

    private static func validated(
        _ snapshot: HandoffConversationSnapshot,
        expectedConversationID: UUID?
    ) throws -> HandoffConversationSnapshot {
        if let expectedConversationID, snapshot.id != expectedConversationID { throw HandoffSnapshotError.mismatchedConversation }
        guard !snapshot.messages.isEmpty else { throw HandoffSnapshotError.empty }
        guard snapshot.messages.count <= maxMessages,
              snapshot.messages.allSatisfy({ $0.sources.count <= maxSourcesPerMessage }) else {
            throw HandoffSnapshotError.tooManyItems
        }
        guard Set(snapshot.messages.map(\.id)).count == snapshot.messages.count else { throw HandoffSnapshotError.malformed }

        var result = snapshot
        result.title = clean(snapshot.title, limit: maxTitleCharacters)
        let sorted = snapshot.messages.sorted {
            ($0.order, $0.createdAt, $0.id.uuidString) < ($1.order, $1.createdAt, $1.id.uuidString)
        }
        result.messages = sorted.enumerated().map { index, message in
            var cleaned = message
            cleaned.order = index
            cleaned.text = clean(message.text, limit: maxMessageCharacters)
            cleaned.notes.uncitableSourceNumbers = Array(message.notes.uncitableSourceNumbers.filter { $0 > 0 }.prefix(maxNoteNumbers))
            cleaned.sources = message.sources
                .sorted { $0.order < $1.order }
                .enumerated()
                .map { sourceIndex, source in
                    HandoffConversationSnapshot.Source(
                        title: clean(source.title, limit: maxSourceTitleCharacters),
                        url: webURL(source.url),
                        snippet: source.snippet.map { clean($0, limit: maxSourceSnippetCharacters) },
                        order: sourceIndex
                    )
                }
            return cleaned
        }
        return result
    }

    /// Retire les caractères de contrôle (sauf le saut de ligne et la tabulation), unifie les fins de ligne, coupe sans
    /// casser un caractère composé. Les blancs d'un texte de réponse ne sont pas retouchés.
    private static func clean(_ text: String, limit: Int) -> String {
        var scalars = String.UnicodeScalarView()
        var previousWasCarriageReturn = false
        for scalar in text.unicodeScalars {
            defer { previousWasCarriageReturn = (scalar == "\r") }
            switch scalar {
            case "\r": scalars.append("\n")
            case "\n": if !previousWasCarriageReturn { scalars.append("\n") }
            case "\t": scalars.append(scalar)
            default:
                if scalar.properties.generalCategory == .control || scalar.properties.generalCategory == .format && isBidiControl(scalar) { continue }
                scalars.append(scalar)
            }
        }
        let cleaned = String(scalars)
        return cleaned.count > limit ? String(cleaned.prefix(limit)) : cleaned
    }

    /// Les marques de sens d'écriture qui permettent de déguiser un texte (U+202A-202E, U+2066-2069).
    private static func isBidiControl(_ scalar: Unicode.Scalar) -> Bool {
        (0x202A...0x202E).contains(scalar.value) || (0x2066...0x2069).contains(scalar.value)
    }

    /// Une adresse de source n'est gardée que si c'est une adresse web lisible ; sinon elle est VIDÉE (pas retirée : les
    /// numéros `[n]` du texte désignent la source par sa position, le décalage ferait citer la mauvaise).
    private static func webURL(_ raw: String) -> String {
        guard raw.count <= maxSourceURLCharacters,
              raw.unicodeScalars.allSatisfy({ $0.properties.generalCategory != .control }),
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else { return "" }
        return raw
    }
}
