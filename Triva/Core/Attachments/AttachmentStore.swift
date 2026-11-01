//
//  AttachmentStore.swift
//  Triva
//
//  Created by ben podrojsky on 29/09/2026.
//

import Foundation

/// Pièce jointe prête à être interrogée : texte extrait puis découpé.
/// Valeur immuable et `Sendable`, pour pouvoir partir hors du main actor
/// avec le reste du pipeline de recherche.
///
/// Ne conserve que les FRAGMENTS, ni le fichier, ni son URL, ni un signet
/// d'accès (voir `AttachmentStore` pour la raison).
nonisolated struct IndexedAttachment: Sendable, Equatable, Identifiable {
    let id: UUID
    let fileName: String
    let kind: AttachmentKind
    /// Nombre total de pages pour un PDF ; `nil` hors PDF.
    let pageCount: Int?
    /// Caractères extraits (hors recouvrement des fragments) : c'est ce qui
    /// est décompté du budget de la conversation.
    let characterCount: Int
    /// Seul le début du document a été lu (borne atteinte) : à signaler.
    let isTruncated: Bool
    /// Voir `ExtractedAttachment.isCopyRestricted` : signal pour le produit.
    let isCopyRestricted: Bool
    let chunks: [AttachmentChunk]

    init(
        id: UUID = UUID(),
        fileName: String,
        kind: AttachmentKind,
        pageCount: Int?,
        characterCount: Int,
        isTruncated: Bool,
        isCopyRestricted: Bool,
        chunks: [AttachmentChunk]
    ) {
        self.id = id
        self.fileName = fileName
        self.kind = kind
        self.pageCount = pageCount
        self.characterCount = characterCount
        self.isTruncated = isTruncated
        self.isCopyRestricted = isCopyRestricted
        self.chunks = chunks
    }

    init(id: UUID = UUID(), extracted: ExtractedAttachment, chunks: [AttachmentChunk]) {
        self.init(
            id: id,
            fileName: extracted.fileName,
            kind: extracted.kind,
            pageCount: extracted.pageCount,
            characterCount: extracted.characterCount,
            isTruncated: extracted.isTruncated,
            isCopyRestricted: extracted.isCopyRestricted,
            chunks: chunks
        )
    }

    /// Port de `UploadStore.getFileData` (`src/lib/uploads/store.ts`, web) :
    /// les premiers fragments joints par `\n---\n`, pour présenter au modèle
    /// de quoi parle le fichier avant toute recherche. Comme côté web, les
    /// fragments se recouvrent : la fin de l'un réapparaît au début du
    /// suivant.
    func initialContent(maxChunks: Int = 3) -> String {
        chunks.prefix(max(0, maxChunks)).map(\.text).joined(separator: "\n---\n")
    }
}

/// Un fragment retrouvé, avec sa provenance.
nonisolated struct AttachmentSearchMatch: Sendable, Equatable {
    let attachmentID: UUID
    let fileName: String
    let chunkIndex: Int
    let pageRange: ClosedRange<Int>?
    let text: String
    /// Score de CLASSEMENT, à ne lire qu'en ORDRE RELATIF dans un même
    /// résultat : similarité brute pour une requête, somme pondérée par les
    /// rangs pour plusieurs (voir `AttachmentSearchIndex`). Jamais un seuil
    /// de pertinence : deux phrases françaises sans rapport marquent déjà
    /// 0,655 avec le scorer natif, et un extrait français hors sujet passe
    /// devant un extrait anglais pertinent (limite mesurée, documentée dans
    /// `NaturalLanguageSimilarityScorer`).
    let score: Double

    /// Provenance lisible : « rapport.pdf, p. 3 », « rapport.pdf, p. 3–4 »
    /// ou « notes.txt ».
    var provenanceLabel: String {
        guard let pageRange else { return fileName }
        let pages = pageRange.lowerBound == pageRange.upperBound
            ? "\(pageRange.lowerBound)"
            : "\(pageRange.lowerBound)–\(pageRange.upperBound)"
        return "\(fileName), p. \(pages)"
    }
}

/// Refus d'ajout par le store.
nonisolated enum AttachmentStoreError: Error, Sendable, Equatable {
    /// Le budget de caractères de la conversation est entièrement consommé
    /// (ou réservé par des lectures en cours).
    case characterBudgetExhausted

    var userFacingMessage: String {
        switch self {
        case .characterBudgetExhausted:
            return "Tu as atteint la limite de texte joint pour cette conversation. Retire une pièce jointe pour en ajouter une autre."
        }
    }
}

// MARK: - Recherche

/// Recherche dans les fragments — port de `UploadStore.query`
/// (`src/lib/uploads/store.ts`), utilisé par l'action `uploads_search`
/// (`researcher/actions/uploadsSearch.ts`). Instantané immuable et
/// `Sendable` des pièces jointes : le pipeline de recherche le reçoit une
/// fois et l'interroge hors du main actor, sans jamais lire l'état vivant du
/// store pendant que l'utilisateur ajoute ou retire un fichier.
///
/// Le scorer est INJECTÉ (`TextSimilarityScoring`, fondation F1). Il est
/// appelé une fois par requête, sur TOUS les fragments d'un coup : c'est la
/// primitive par lot du protocole, qui n'embarque la requête qu'une fois.
/// `rankedMatches` n'est pas utilisé : la fusion multi-requêtes a besoin du
/// vecteur de scores complet, pas d'un top N déjà tronqué.
///
/// AUCUN SEUIL, pas même zéro : un fragment à 0 reste classable s'il manque
/// de meilleurs candidats. Avec le repli lexical, un extrait anglais
/// pertinent pour une requête française marque souvent 0 faute de mot
/// commun ; le filtrer ferait disparaître exactement ce que la limite de
/// langue du scorer rend déjà difficile à trouver.
nonisolated struct AttachmentSearchIndex: Sendable {
    /// Constante de fusion par rangs réciproques, inchangée du web (`k = 60`,
    /// valeur de référence de Cormack et al., 2009) : elle aplatit l'écart
    /// entre les premiers rangs, pour qu'un fragment bien classé par
    /// plusieurs requêtes l'emporte sur un fragment premier d'une seule.
    static let reciprocalRankConstant = 60.0

    let attachments: [IndexedAttachment]
    private let scorer: any TextSimilarityScoring

    init(attachments: [IndexedAttachment], scorer: any TextSimilarityScoring) {
        self.attachments = attachments
        self.scorer = scorer
    }

    /// Les `limit` meilleurs fragments pour une requête, score = similarité
    /// brute. À score égal, l'ordre des pièces jointes puis des fragments est
    /// conservé (tri stable explicite, `sorted` ne l'étant pas en Swift).
    ///
    /// `@concurrent` : sans lui, `NonisolatedNonsendingByDefault` ferait
    /// tourner la recherche — et le scorer, qui hérite de l'exécuteur de son
    /// appelant — sur le main actor dès qu'un store `@MainActor` l'appelle.
    /// Le repli lexical, notamment, tokenise chaque fragment : du vrai calcul.
    @concurrent
    func search(query: String, limit: Int) async -> [AttachmentSearchMatch] {
        let references = chunkReferences()
        guard limit > 0, !references.isEmpty, !Self.isBlank(query) else { return [] }

        let scores = await scores(of: query, against: references)
        return Self.rankedPositions(of: scores).prefix(limit).map { references[$0].match(score: scores[$0]) }
    }

    /// Plusieurs requêtes fusionnées — l'action web en envoie jusqu'à 3.
    /// Score fusionné = Σ similarité ÷ (rang + 1 + k), rang à partir de 0 :
    /// la formule de `store.ts`.
    ///
    /// BUG DU WEB CORRIGÉ : `store.ts` identifie un fragment par le hachage de
    /// `{ chunk, score }`. Le score faisant partie de la clé, un même fragment
    /// obtient une clé DIFFÉRENTE d'une requête à l'autre (sauf score
    /// identique au bit près) : la fusion n'a en pratique jamais lieu, et le
    /// même fragment peut sortir plusieurs fois. Ici la clé est la position
    /// du fragment, indépendante de la requête.
    ///
    /// Requêtes en double retirées (l'ordre est conservé) : répétée, une
    /// requête pèserait deux fois plus que les autres dans la fusion. Coût :
    /// un passage du scorer par requête distincte, soit un coût linéaire en
    /// nombre de requêtes — à garder en tête sur l'appareil.
    @concurrent
    func search(queries: [String], limit: Int) async -> [AttachmentSearchMatch] {
        let references = chunkReferences()
        let distinctQueries = Self.distinctNonBlank(queries)
        guard limit > 0, !references.isEmpty, !distinctQueries.isEmpty else { return [] }

        var fusedScores = Array(repeating: 0.0, count: references.count)
        for query in distinctQueries {
            let scores = await scores(of: query, against: references)
            for (rank, position) in Self.rankedPositions(of: scores).enumerated() {
                fusedScores[position] += scores[position] / (Double(rank) + 1 + Self.reciprocalRankConstant)
            }
        }

        return Self.rankedPositions(of: fusedScores).prefix(limit).map { references[$0].match(score: fusedScores[$0]) }
    }

    // MARK: Détails

    private func chunkReferences() -> [ChunkReference] {
        attachments.flatMap { attachment in
            attachment.chunks.map { ChunkReference(attachmentID: attachment.id, fileName: attachment.fileName, chunk: $0) }
        }
    }

    /// Un score par fragment, quoi que rende le scorer : lecture indexée avec
    /// repli `0` si le tableau est trop court (contrat violé), et ramené dans
    /// `[0, 1]` — un `NaN` rendrait le tri incohérent, `clampedToUnitRange`
    /// le transforme en `0`. Même garde-fou que `rankedMatches`.
    private func scores(of query: String, against references: [ChunkReference]) async -> [Double] {
        let raw = await scorer.similarities(of: query, against: references.map(\.chunk.text))
        return references.indices.map { position in
            position < raw.count ? TextVectorMath.clampedToUnitRange(raw[position]) : 0
        }
    }

    private static func rankedPositions(of scores: [Double]) -> [Int] {
        scores.indices.sorted { lhs, rhs in
            scores[lhs] == scores[rhs] ? lhs < rhs : scores[lhs] > scores[rhs]
        }
    }

    private static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func distinctNonBlank(_ queries: [String]) -> [String] {
        var seen: Set<String> = []
        return queries.filter { query in
            !isBlank(query) && seen.insert(query).inserted
        }
    }
}

/// Fragment + provenance, aplati sur toutes les pièces jointes.
nonisolated private struct ChunkReference {
    let attachmentID: UUID
    let fileName: String
    let chunk: AttachmentChunk

    func match(score: Double) -> AttachmentSearchMatch {
        AttachmentSearchMatch(
            attachmentID: attachmentID,
            fileName: fileName,
            chunkIndex: chunk.index,
            pageRange: chunk.pageRange,
            text: chunk.text,
            score: score
        )
    }
}

// MARK: - Préparation

/// Point d'injection de la lecture d'un fichier (extraction + découpage),
/// pour tester le store sans disque ni PDF — même principe que
/// `SearXNGSearching` ou `ScrapeServing`.
nonisolated protocol AttachmentPreparing: Sendable {
    /// Lit, extrait et découpe. Lève `AttachmentExtractionError` ou
    /// `CancellationError`. `characterLimit` est déjà borné par l'appelant.
    func prepareAttachment(fileAt url: URL, characterLimit: Int) async throws -> IndexedAttachment
}

/// Implémentation réelle : `AttachmentTextExtractor` puis `AttachmentChunker`.
nonisolated struct AttachmentPreparer: AttachmentPreparing {
    let extractor: AttachmentTextExtractor
    let chunker: AttachmentChunker

    init(extractor: AttachmentTextExtractor = AttachmentTextExtractor(), chunker: AttachmentChunker = AttachmentChunker()) {
        self.extractor = extractor
        self.chunker = chunker
    }

    func prepareAttachment(fileAt url: URL, characterLimit: Int) async throws -> IndexedAttachment {
        try await Self.prepare(fileAt: url, characterLimit: characterLimit, extractor: extractor, chunker: chunker)
    }

    /// Extraction ET découpage dans une même fonction `@concurrent` : le
    /// découpage est synchrone et s'exécuterait sinon là où on l'appelle —
    /// sur le main actor, puisque l'appelant réel est `AttachmentStore`.
    @concurrent
    private static func prepare(
        fileAt url: URL,
        characterLimit: Int,
        extractor: AttachmentTextExtractor,
        chunker: AttachmentChunker
    ) async throws -> IndexedAttachment {
        let extracted = try await extractor.extract(from: url, characterLimit: characterLimit)
        let chunks = chunker.chunks(for: extracted.sections)
        // Inatteignable (une extraction réussie n'est jamais blanche), mais
        // une pièce jointe sans fragment serait invisible à la recherche :
        // mieux vaut le dire que l'afficher comme jointe.
        guard !chunks.isEmpty else { throw AttachmentExtractionError.emptyFile }
        return IndexedAttachment(extracted: extracted, chunks: chunks)
    }
}

// MARK: - Store

/// Pièces jointes de la conversation COURANTE, en mémoire uniquement.
/// `@Observable` et isolé au main actor (isolation par défaut du projet) :
/// c'est un store d'interface, lu par la barre de saisie.
///
/// AUCUNE COPIE PERSISTÉE, choix délibéré :
/// - vie privée : un document joint peut être sensible (bulletin de salaire,
///   dossier médical). Une copie dans le conteneur de l'app survivrait à la
///   conversation, partirait dans les sauvegardes iCloud de l'appareil et
///   exigerait un nettoyage fiable — autant de risques pour aucun bénéfice
///   tant que la conversation seule s'en sert ;
/// - App Store : rien n'est stocké ni transmis par l'app elle-même, ce qui
///   garde le label de confidentialité simple ;
/// - l'accès security-scoped n'est tenu que le temps de la lecture ; aucun
///   signet n'est conservé pour relire le fichier plus tard.
/// Conséquence à connaître : fermer la conversation, ou relancer l'app, fait
/// perdre les pièces jointes. Une conversation rouverte depuis l'historique
/// n'a plus leur contenu. Les conserver (le texte extrait, jamais le
/// fichier) serait un choix produit, pas un correctif.
///
/// BUDGET DE CARACTÈRES PAR CONVERSATION : chaque question ré-embarque TOUT
/// le texte indexé (voir `AttachmentTextExtractor.defaultMaxCharacterCount`
/// pour le coût mesuré). Le budget est donc TOTAL, toutes pièces jointes
/// confondues ; une limite par fichier seule laisserait le nombre de
/// fichiers faire grimper chaque recherche sans borne. Un fichier ajouté quand il reste peu de
/// budget est lu jusqu'à ce reste (et marqué tronqué) ; à budget nul, l'ajout
/// est refusé.
@Observable
final class AttachmentStore {
    /// 185 000 caractères ≈ 75 pages au total (décision de Ben, 2026-10-04 :
    /// 5 pages par fichier, 75 pages en tout, soit 15 fichiers pleins).
    /// Coût extrapolé (voir `AttachmentTextExtractor.defaultMaxCharacterCount`) :
    /// ~9 s par question sur Mac quand le budget est plein, davantage sur iPhone.
    static let defaultTotalCharacterBudget = 185_000

    private(set) var attachments: [IndexedAttachment] = []

    /// Caractères réservés par les lectures EN COURS. Sans réservation, deux
    /// fichiers choisis ensemble verraient chacun tout le budget restant et
    /// le dépasseraient à deux.
    private var reservedCharacterCount = 0

    /// Incrémenté par `removeAll()` : une lecture lancée avant le vidage ne
    /// doit pas réapparaître dans la conversation vidée.
    @ObservationIgnored private var generation = 0

    let totalCharacterBudget: Int
    let maxCharactersPerAttachment: Int
    private let scorer: any TextSimilarityScoring
    private let preparer: any AttachmentPreparing

    init(
        scorer: any TextSimilarityScoring = NaturalLanguageSimilarityScorer(),
        preparer: any AttachmentPreparing = AttachmentPreparer(),
        totalCharacterBudget: Int = AttachmentStore.defaultTotalCharacterBudget,
        maxCharactersPerAttachment: Int = AttachmentTextExtractor.defaultMaxCharacterCount
    ) {
        self.scorer = scorer
        self.preparer = preparer
        self.totalCharacterBudget = max(0, totalCharacterBudget)
        self.maxCharactersPerAttachment = max(1, maxCharactersPerAttachment)
    }

    var indexedCharacterCount: Int {
        attachments.reduce(0) { $0 + $1.characterCount }
    }

    var remainingCharacterBudget: Int {
        max(0, totalCharacterBudget - indexedCharacterCount - reservedCharacterCount)
    }

    /// Instantané à confier au pipeline de recherche (voir `AttachmentSearchIndex`).
    var searchIndex: AttachmentSearchIndex {
        AttachmentSearchIndex(attachments: attachments, scorer: scorer)
    }

    /// Lit le fichier hors du main actor, puis l'ajoute. Lève
    /// `AttachmentStoreError`, `AttachmentExtractionError`, ou
    /// `CancellationError` si la tâche est annulée ou si `removeAll()` a été
    /// appelé pendant la lecture — rien n'est alors ajouté.
    @discardableResult
    func attach(fileAt url: URL) async throws -> IndexedAttachment {
        let characterLimit = min(maxCharactersPerAttachment, remainingCharacterBudget)
        guard characterLimit > 0 else { throw AttachmentStoreError.characterBudgetExhausted }

        let startGeneration = generation
        reservedCharacterCount += characterLimit
        defer { reservedCharacterCount -= characterLimit }

        let attachment = try await preparer.prepareAttachment(fileAt: url, characterLimit: characterLimit)
        guard generation == startGeneration, !Task.isCancelled else { throw CancellationError() }

        attachments.append(attachment)
        return attachment
    }

    func remove(id: UUID) {
        attachments.removeAll { $0.id == id }
    }

    /// Vide la conversation, y compris pour les lectures encore en cours.
    func removeAll() {
        generation += 1
        attachments = []
    }

    /// Raccourcis : la recherche elle-même tourne hors du main actor.
    func search(query: String, limit: Int) async -> [AttachmentSearchMatch] {
        await searchIndex.search(query: query, limit: limit)
    }

    func search(queries: [String], limit: Int) async -> [AttachmentSearchMatch] {
        await searchIndex.search(queries: queries, limit: limit)
    }
}
