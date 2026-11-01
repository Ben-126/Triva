//
//  VideoSearchService.swift
//  Triva
//
//  Created by ben podrojsky on 19/09/2026.
//

import Foundation

/// Un résultat de recherche vidéo exploitable par l'UI (1.6 — `VideoResultsView`,
/// hors périmètre de ce fichier).
struct VideoSearchResult: Sendable, Equatable, Identifiable {
    var id: String { sourceURL.absoluteString }

    /// Vignette (`thumbnail` côté SearXNG — PAS `thumbnail_src`, voir
    /// `VideoSearchService.filterAndMap`).
    let thumbnailURL: URL
    /// Page d'origine (ex. `https://youtube.com/watch?v=...`) : c'est CETTE
    /// URL qu'il faut ouvrir dans le navigateur/l'app système pour lire la
    /// vidéo, pas `embedURL`.
    let sourceURL: URL
    let title: String
    /// `iframe_src` de SearXNG, quand l'engine le fournit. Optionnel : voir
    /// DIVERGENCE dans le commentaire de tête de `VideoSearchService`.
    let embedURL: URL?
}

/// Port natif de `src/lib/agents/media/video.ts` (web) : reformule la requête
/// utilisateur en requête de recherche vidéo, cherche sur SearXNG (engine
/// `youtube`), puis filtre/mappe les résultats.
///
/// Écarts volontaires par rapport à la référence web, et pourquoi :
/// 1. **Reformulation + tolérance aux échecs LLM** : identique à
///    `ImageSearchService`, via le même `MediaSearchQueryReformulator`. Voir
///    sa justification là-bas, non répétée ici.
/// 2. **DIVERGENCE ASSUMÉE — `iframe_src` optionnel, pas obligatoire.** La
///    référence web exclut un résultat qui n'a pas `iframe_src`
///    (`result.thumbnail && result.url && result.title && result.iframe_src`).
///    Ici, la mission demande explicitement d'exposer "de quoi ouvrir la
///    vidéo dans le navigateur/lecteur système" — c'est `sourceURL` (la page
///    `url` normale) qui remplit ce rôle, pas `iframe_src` (pensé pour un
///    `<iframe>` embarqué dans une page web, usage que Triva n'a pas
///    aujourd'hui). Exiger `iframe_src` en plus de `url` rejetterait sans
///    raison tout résultat d'une instance SearXNG dont l'engine `youtube` ne
///    remplit pas ce champ (son absence ne rend pas l'URL `sourceURL` moins
///    ouvrable). `embedURL` reste néanmoins porté quand il est présent, pour
///    une éventuelle lecture intégrée future (V2, non câblée ici).
struct VideoSearchService: Sendable {
    private let failoverManager: FailoverManager
    private let aiProvider: any AIGenerating
    private let maxResults: Int
    private let maxHistoryMessages: Int

    /// `maxResults` par défaut à 10, identique à `video.ts` (`.slice(0, 10)`)
    /// et à `ImageSearchService` — même absence de contrainte de contexte-
    /// tokens qui justifierait une valeur différente.
    init(
        failoverManager: FailoverManager,
        aiProvider: any AIGenerating,
        maxResults: Int = 10,
        maxHistoryMessages: Int = 8
    ) {
        self.failoverManager = failoverManager
        self.aiProvider = aiProvider
        self.maxResults = maxResults
        self.maxHistoryMessages = maxHistoryMessages
    }

    /// Ne throw QUE si `failoverManager.search` échoue — même contrat que
    /// `ImageSearchService.search`.
    func search(query: String, chatHistory: [ClassifierChatMessage] = []) async throws -> [VideoSearchResult] {
        let reformulatedQuery = await MediaSearchQueryReformulator.reformulate(
            originalQuery: query,
            chatHistory: chatHistory,
            systemPrompt: Self.reformulationSystemPrompt,
            aiProvider: aiProvider,
            maxHistoryMessages: maxHistoryMessages
        )

        let response = try await failoverManager.search(
            query: reformulatedQuery,
            options: SearXNGSearchOptions(categories: ["videos"], engines: ["youtube"])
        )

        return Self.filterAndMap(response.results, maxResults: maxResults)
    }

    /// Fonction pure et testable séparément du réseau. Port de la boucle
    /// `forEach` de `video.ts`, avec la relaxation de `iframe_src` documentée
    /// en tête de fichier.
    ///
    /// Utilise `result.thumbnail` (pas `result.thumbnailSrc`) : c'est le
    /// champ que `video.ts` lit (`result.thumbnail`), et SearXNG distingue
    /// bien les deux (`thumbnail` = vignette déjà prête à afficher, souvent
    /// une image plus petite ; `thumbnail_src` = une URL alternative propre à
    /// certains engines). Rester fidèle au champ exact évite de récupérer une
    /// vignette absente sur des résultats YouTube où seul `thumbnail` est
    /// rempli.
    static func filterAndMap(_ results: [SearXNGSearchResult], maxResults: Int) -> [VideoSearchResult] {
        let mapped = results.compactMap { result -> VideoSearchResult? in
            let trimmedTitle = result.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard
                !trimmedTitle.isEmpty,
                let thumbnailURL = Self.httpsURL(from: result.thumbnail),
                let sourceURL = Self.httpsURL(from: result.url)
            else { return nil }
            return VideoSearchResult(
                thumbnailURL: thumbnailURL,
                sourceURL: sourceURL,
                title: trimmedTitle,
                embedURL: Self.httpsURL(from: result.iframeSrc)
            )
        }
        return Array(mapped.prefix(max(0, maxResults)))
    }

    private static func httpsURL(from raw: String?) -> URL? {
        guard let raw, let url = URL(string: raw), url.scheme?.lowercased() == "https" else { return nil }
        return url
    }

    /// Port du system prompt de `videoSearchPrompt` (web), même style condensé
    /// que `ImageSearchService.reformulationSystemPrompt`.
    static let reformulationSystemPrompt = """
    Tu reformules la question d'un utilisateur en une courte requête de recherche vidéo, à partir de l'historique de conversation si besoin (ex. "Montre-moi des vidéos" après une question sur la photosynthèse -> "vidéo photosynthèse").
    Réponds UNIQUEMENT avec un objet JSON de la forme {"query": "..."}, sans aucun texte autour.
    """
}
