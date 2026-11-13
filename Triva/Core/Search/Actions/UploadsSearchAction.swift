//
//  UploadsSearchAction.swift
//  Triva
//
//  Created by ben podrojsky on 30/09/2026.
//

import Foundation

/// Port de la recherche dans les fichiers joints de la version web d'origine :
/// recherche dans les fichiers joints à la conversation, entièrement sur
/// l'appareil — aucun upload, aucun serveur, les fragments viennent de
/// `AttachmentStore` (1.11a).
///
/// PIÈCES JOINTES CAPTURÉES À LA CONSTRUCTION (voie « a ») : la signature
/// commune `SearchAction.execute(query:urls:failoverManager:scrapeService:)`
/// ne transporte aucune pièce jointe, et faire évoluer le protocole
/// toucherait toutes les actions existantes. L'action reçoit donc un
/// INSTANTANÉ `AttachmentSearchIndex` (immuable, `Sendable`), directement ou
/// via `init(attachmentStore:)` qui le lit une fois. Conséquence voulue : un
/// fichier ajouté ou retiré PENDANT une recherche n'en change pas le
/// résultat — c'est le contrat posé par `AttachmentStore.searchIndex`. Il
/// faut donc construire l'action au moment de lancer la recherche, pas la
/// garder d'une question à l'autre.
///
/// SORTIE : `.searchResults`, UN résultat par pièce jointe — exactement la
/// forme de la version web d'origine, qui renvoie `type: 'search_results'` après avoir fusionné
/// les fragments d'un même fichier (clé `metadata.url`). Les fichiers joints
/// deviennent ainsi des sources citables `[n]` comme une page web, sans
/// nouveau cas dans `SearchActionOutput`. Détails de construction (budget,
/// déduplication, URL synthétique) : voir `UploadsSearchResultBuilder`.
///
/// Isolation : volontairement identique à `WebSearchAction` (aucune
/// annotation, donc main actor par défaut), pour que la conformance au
/// protocole soit la même que celle des actions sœurs. Le travail lourd — le
/// scorer, appelé sur tous les fragments — tourne déjà hors du main actor :
/// `AttachmentSearchIndex.search(queries:limit:)` est `@concurrent`. Il ne
/// reste ici qu'une mise en forme bornée (≤ 10 fragments).
struct UploadsSearchAction: SearchAction {
    let name = "uploadsSearch"
    let descriptionForPlanner = "Recherche dans les fichiers joints par l'utilisateur : à utiliser dès que la question porte sur le contenu de ses documents. Ne cherche jamais sur le web."

    private let searchIndex: AttachmentSearchIndex
    private let maxFragments: Int
    private let maxTotalCharacters: Int

    /// `maxFragments` à 10 : le `topK` de la version web d'origine (`uploadStore.query(queries, 10)`).
    /// `maxTotalCharacters` à 6000 : voir
    /// `UploadsSearchResultBuilder.defaultMaxTotalCharacters`. Valeurs
    /// négatives ramenées à 0 (l'action rend alors toujours un résultat vide).
    init(
        searchIndex: AttachmentSearchIndex,
        maxFragments: Int = UploadsSearchResultBuilder.defaultMaxFragments,
        maxTotalCharacters: Int = UploadsSearchResultBuilder.defaultMaxTotalCharacters
    ) {
        self.searchIndex = searchIndex
        self.maxFragments = max(0, maxFragments)
        self.maxTotalCharacters = max(0, maxTotalCharacters)
    }

    /// Lit `attachmentStore.searchIndex` UNE fois, ici : voir la note
    /// « instantané » en tête de type.
    init(
        attachmentStore: AttachmentStore,
        maxFragments: Int = UploadsSearchResultBuilder.defaultMaxFragments,
        maxTotalCharacters: Int = UploadsSearchResultBuilder.defaultMaxTotalCharacters
    ) {
        self.init(
            searchIndex: attachmentStore.searchIndex,
            maxFragments: maxFragments,
            maxTotalCharacters: maxTotalCharacters
        )
    }

    /// `urls`, `failoverManager` et `scrapeService` sont ignorés : cette
    /// action ne sort jamais sur le réseau (même consigne que la version web d'origine : « Never
    /// use this tool to search the web »). Le protocole ne transporte qu'UNE
    /// requête ; les requêtes multiples passent par `search(queries:)`.
    func execute(
        query: String,
        urls: [String],
        failoverManager: FailoverManager,
        scrapeService: any ScrapeServing
    ) async throws -> SearchActionOutput {
        .searchResults(try await search(queries: [query]))
    }

    /// Jusqu'à 3 requêtes, comme la version web d'origine (`input.queries.slice(0, 3)`), fusion
    /// par rangs réciproques déléguée à l'index. Aucune pièce jointe, aucune
    /// requête exploitable ou budget nul : tableau vide, JAMAIS une erreur —
    /// une conversation sans fichier joint n'est pas un échec de recherche.
    /// Seule l'annulation de la tâche est propagée (`CancellationError`), pour
    /// ne pas construire un contexte que personne n'attend plus.
    func search(queries: [String]) async throws -> [SearXNGSearchResult] {
        let effectiveQueries = UploadsSearchResultBuilder.effectiveQueries(queries)
        guard
            !effectiveQueries.isEmpty,
            !searchIndex.attachments.isEmpty,
            maxFragments > 0,
            maxTotalCharacters > 0
        else { return [] }

        let matches = await searchIndex.search(queries: effectiveQueries, limit: maxFragments)
        try Task.checkCancellation()

        return UploadsSearchResultBuilder.makeResults(
            from: matches,
            maxFragments: maxFragments,
            maxTotalCharacters: maxTotalCharacters
        )
    }
}

/// Logique pure de l'action, séparée pour être testée sans index ni scorer :
/// requêtes -> fragments dédoublonnés -> regroupement par fichier -> budget
/// de caractères -> `SearXNGSearchResult`. `nonisolated` : données et calcul
/// déterministes, aucune raison d'être rattaché au main actor.
nonisolated enum UploadsSearchResultBuilder {
    /// Plafond de la version web d'origine (`'Can be a maximum of 3 queries'`). Au-delà, chaque
    /// requête coûte un passage complet du scorer sur TOUS les fragments —
    /// le coût dominant sur l'appareil (voir `AttachmentSearchIndex`).
    static let maxQueries = 3

    /// `topK` de la version web d'origine.
    static let defaultMaxFragments = 10

    /// Budget TOTAL des fragments injectés, toutes pièces jointes confondues.
    /// C'est la SEULE protection anti-débordement sur ce chemin :
    /// `SearchOrchestrator.buildPrompt` interpole `content` sans le tronquer.
    /// 6000 caractères (~1500 tokens, proxy caractères/4) plutôt que les
    /// 8000 du contenu scrapé : les deux blocs peuvent coexister dans un même
    /// prompt, et Apple Intelligence plafonne autour de 4k tokens au total —
    /// 10 fragments de 800 caractères (la version web d'origine) n'y tiendraient pas avec le
    /// reste. Réglable par l'appelant sans changer de code.
    static let defaultMaxTotalCharacters = 6000

    /// Schéma de l'URL synthétique d'une pièce jointe (voir `sourceURL(for:)`).
    static let attachmentURLScheme = "triva-attachment"

    /// Même séparateur que la version web d'origine (`existingResult.content += '\n\n' + ...`).
    static let fragmentSeparator = "\n\n"

    // MARK: Requêtes

    /// Requêtes nettoyées, blanches retirées, doublons retirés (ordre
    /// conservé), puis plafonnées à `maxQueries`.
    ///
    /// ÉCART ASSUMÉ avec la version web d'origine, qui tronque à 3 AVANT tout dédoublonnage :
    /// ici on dédoublonne d'abord, pour qu'une requête répétée ou blanche ne
    /// prenne pas la place d'une vraie troisième requête. Le dédoublonnage se
    /// fait après nettoyage des blancs de bord : « impôts » et « impôts  »
    /// sont la même requête, alors que l'index, lui, ne les distinguerait que
    /// par des octets.
    static func effectiveQueries(_ queries: [String]) -> [String] {
        var seen: Set<String> = []
        let distinct = queries
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        return Array(distinct.prefix(maxQueries))
    }

    // MARK: URL synthétique

    /// `triva-attachment:<UUID>` — unique par pièce jointe, et SANS `//`.
    ///
    /// PIÈGE ÉVITÉ : la version web d'origine utilise `file_id://<id>`. En Swift, une URL de
    /// forme `schéma://<uuid>` fait de l'UUID un HÔTE (`URL.host` non vide),
    /// et `SourcesListView` construit alors un `Link` tapable vers une
    /// adresse que rien ne sait ouvrir. La forme opaque sans autorité donne
    /// `host == nil` : la source s'affiche en texte simple. Unicité requise
    /// par `SearchOrchestrator.accumulate`, qui dédoublonne les sources par
    /// URL ; `SourceRanker.normalizedURLKey` retombe sur la chaîne brute en
    /// minuscules faute d'hôte, donc deux pièces jointes ne fusionnent pas.
    static func sourceURL(for attachmentID: UUID) -> String {
        "\(attachmentURLScheme):\(attachmentID.uuidString)"
    }

    /// Réciproque de `sourceURL(for:)`, pour l'interface : reconnaître une
    /// source issue d'un fichier joint (icône, pas de lien). `nil` pour toute
    /// autre URL, y compris une URL web ordinaire.
    static func attachmentID(fromSourceURL url: String) -> UUID? {
        let prefix = attachmentURLScheme + ":"
        guard url.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(url.dropFirst(prefix.count)))
    }

    // MARK: Construction des résultats

    /// Pipeline complet, pur et déterministe :
    /// 1. au plus `maxFragments` fragments, dans l'ordre de classement reçu ;
    /// 2. déduplication (voir `deduplicated`) ;
    /// 3. regroupement par pièce jointe — port de la fusion par
    ///    `metadata.url` de la version web d'origine : fichiers ordonnés par leur MEILLEUR
    ///    fragment (ça compte : les fichiers joints ouvrent les sources de
    ///    `SearchOrchestrator`, leur rang devient leur numéro de citation
    ///    `[n]`), fragments d'un fichier dans l'ordre de classement, comme
    ///    le `+=` de la version web d'origine ;
    /// 4. budget réparti équitablement entre fichiers (`fairShares`), chaque
    ///    contenu tronqué à SA part. La troncature mange donc la fin d'un
    ///    contenu, c'est-à-dire ses fragments les MOINS pertinents.
    ///
    /// Garantie : la somme des `content.count` ne dépasse jamais
    /// `maxTotalCharacters` (séparateurs et repères de page compris).
    ///
    /// LIMITE ASSUMÉE : deux fragments consécutifs d'un même document se
    /// recouvrent (jusqu'à `AttachmentChunker.defaultOverlapCharacters`), et
    /// ce recouvrement reste en double s'ils sont retenus tous les deux.
    /// Le retirer demanderait de deviner la frontière exacte après le
    /// nettoyage des blancs fait par le découpeur — fragile, pour un gain de
    /// quelques dizaines de caractères.
    static func makeResults(
        from matches: [AttachmentSearchMatch],
        maxFragments: Int = defaultMaxFragments,
        maxTotalCharacters: Int = defaultMaxTotalCharacters
    ) -> [SearXNGSearchResult] {
        guard maxFragments > 0, maxTotalCharacters > 0 else { return [] }

        let groups = groupedByAttachment(deduplicated(Array(matches.prefix(maxFragments))))
        let fullContents = groups.map { group in
            group.fragments.map(formattedFragment).joined(separator: fragmentSeparator)
        }
        let shares = fairShares(of: fullContents.map(\.count), budget: maxTotalCharacters)

        return groups.indices.compactMap { position in
            let bounded = String(fullContents[position].prefix(shares[position]))
            let content = trimmingTrailingWhitespace(bounded)
            guard !content.isEmpty else { return nil }
            return makeResult(for: groups[position], content: content)
        }
    }

    /// Retire un fragment déjà vu, par POSITION (même pièce jointe, même
    /// index de fragment) ou par TEXTE identique : le même document joint
    /// deux fois produit deux pièces jointes distinctes aux fragments
    /// identiques, qui gaspilleraient le budget en disant deux fois la même
    /// chose. Le premier — donc le mieux classé — est conservé.
    static func deduplicated(_ matches: [AttachmentSearchMatch]) -> [AttachmentSearchMatch] {
        var seenPositions: Set<FragmentPosition> = []
        var seenTexts: Set<String> = []
        return matches.filter { match in
            let position = FragmentPosition(attachmentID: match.attachmentID, chunkIndex: match.chunkIndex)
            let text = match.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !seenPositions.contains(position), !seenTexts.contains(text) else { return false }
            seenPositions.insert(position)
            seenTexts.insert(text)
            return true
        }
    }

    /// Fragments regroupés par pièce jointe, dans l'ordre de première
    /// apparition (donc par meilleur rang), ordre interne conservé.
    static func groupedByAttachment(_ matches: [AttachmentSearchMatch]) -> [AttachmentFragmentGroup] {
        var groups: [AttachmentFragmentGroup] = []
        var positionByID: [UUID: Int] = [:]
        for match in matches {
            if let position = positionByID[match.attachmentID] {
                groups[position] = groups[position].appending(match)
            } else {
                positionByID[match.attachmentID] = groups.count
                groups.append(AttachmentFragmentGroup(attachmentID: match.attachmentID, fileName: match.fileName, fragments: [match]))
            }
        }
        return groups
    }

    /// Partage max-min équitable d'un budget entre contenus de longueurs
    /// données : chacun reçoit au plus sa longueur, et ce qu'un contenu court
    /// n'utilise pas revient aux autres.
    ///
    /// Même principe que le budget des pages scrapées
    /// (`PromptTemplates.numberedContext`, ex-`SearchOrchestrator.formatScrapedPages`) :
    /// part égale, jamais « premier arrivé, premier servi » qui laisserait le
    /// premier fichier manger tout le budget. Avec une amélioration : là-bas,
    /// une page courte laisse sa part inutilisée perdue ; ici, elle est
    /// redistribuée. Algorithme : on sert les plus courts d'abord, chacun
    /// recevant au plus `reste ÷ nombre restant`.
    ///
    /// Garanties : `Σ parts ≤ budget`, `part ≤ longueur`, et si
    /// `budget ≥ nombre de contenus non vides`, chacun reçoit au moins 1.
    static func fairShares(of lengths: [Int], budget: Int) -> [Int] {
        var shares = Array(repeating: 0, count: lengths.count)
        guard budget > 0, !lengths.isEmpty else { return shares }

        let shortestFirst = lengths.indices.sorted { lhs, rhs in
            lengths[lhs] == lengths[rhs] ? lhs < rhs : lengths[lhs] < lengths[rhs]
        }
        var remaining = budget
        for (served, position) in shortestFirst.enumerated() {
            let fairPart = remaining / (lengths.count - served)
            let share = min(max(0, lengths[position]), fairPart)
            shares[position] = share
            remaining -= share
        }
        return shares
    }

    /// Texte d'un fragment, précédé de sa page pour un PDF (« (p. 3) »,
    /// « (p. 3–4) ») : le modèle peut alors situer ce qu'il cite, et la
    /// réponse renvoyer à une page précise. Rien hors PDF (`pageRange == nil`).
    ///
    /// PARENTHÈSES ET NON CROCHETS, exprès : les citations de la réponse
    /// sont des `[n]` (`PromptTemplates`, `CitationParser`). Un « [3] » de
    /// page dans le contexte inviterait un petit modèle sur l'appareil à
    /// recopier `[3]`, que `CitationParser` lirait comme la source n° 3.
    static func formattedFragment(_ match: AttachmentSearchMatch) -> String {
        let text = match.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pageRange = match.pageRange else { return text }
        let pages = pageRange.lowerBound == pageRange.upperBound
            ? "\(pageRange.lowerBound)"
            : "\(pageRange.lowerBound)–\(pageRange.upperBound)"
        return "(p. \(pages)) \(text)"
    }

    // MARK: Détails

    /// Titre = nom du fichier seul : c'est ce que l'utilisateur reconnaît
    /// dans la liste des sources ; les pages sont déjà dans le contenu.
    private static func makeResult(for group: AttachmentFragmentGroup, content: String) -> SearXNGSearchResult {
        SearXNGSearchResult(
            title: group.fileName,
            url: sourceURL(for: group.attachmentID),
            content: content,
            imgSrc: nil,
            thumbnailSrc: nil,
            thumbnail: nil,
            author: nil,
            iframeSrc: nil
        )
    }

    /// Une coupe peut tomber juste après un séparateur : on ne laisse pas de
    /// blancs pendants en fin de contenu (ça ne fait que raccourcir, donc le
    /// budget reste respecté).
    private static func trimmingTrailingWhitespace(_ text: String) -> String {
        var trimmed = Substring(text)
        while let last = trimmed.last, last.isWhitespace {
            trimmed.removeLast()
        }
        return String(trimmed)
    }
}

/// Fragments retenus d'une même pièce jointe, dans l'ordre de classement.
nonisolated struct AttachmentFragmentGroup: Sendable, Equatable {
    let attachmentID: UUID
    let fileName: String
    let fragments: [AttachmentSearchMatch]

    /// Copie enrichie plutôt que mutation en place (règle d'immuabilité).
    func appending(_ match: AttachmentSearchMatch) -> AttachmentFragmentGroup {
        AttachmentFragmentGroup(attachmentID: attachmentID, fileName: fileName, fragments: fragments + [match])
    }
}

/// Clé de position d'un fragment, indépendante de son score (voir le bug de la
/// version web d'origine corrigé dans `AttachmentSearchIndex.search(queries:limit:)`).
nonisolated private struct FragmentPosition: Hashable {
    let attachmentID: UUID
    let chunkIndex: Int
}
