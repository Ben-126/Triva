//
//  ImageSearchService.swift
//  Triva
//
//  Created by ben podrojsky on 19/09/2026.
//

import Foundation

/// Un résultat de recherche d'images exploitable par l'UI (1.6 — `ImageResultsView`,
/// hors périmètre de ce fichier). Ne garde QUE les champs déjà validés comme
/// exploitables par `ImageSearchService.filterAndMap` : `imageURL` et
/// `sourceURL` sont garanties `https`, `title` garanti non vide — l'UI n'a
/// donc jamais besoin de re-vérifier ce que ce type contient.
struct ImageSearchResult: Sendable, Equatable, Identifiable {
    var id: String { imageURL.absoluteString }

    /// URL de l'image elle-même (`img_src` côté SearXNG) — ce que l'UI affiche.
    let imageURL: URL
    /// Page d'origine (`url` côté SearXNG) — ouverte si l'utilisateur tape sur l'image.
    let sourceURL: URL
    let title: String
}

/// Port natif de `src/lib/agents/media/image.ts` (web) : reformule la requête
/// utilisateur en requête de recherche d'images via un appel LLM, cherche sur
/// SearXNG (catégorie `images`), puis filtre/mappe les résultats.
///
/// Écarts volontaires par rapport à la référence web, et pourquoi :
/// 1. **Reformulation par prompt texte + parsing tolérant**, pas
///    `generateObject` (schéma zod + function-calling). Aucun des 3 moteurs
///    IA de Triva n'expose de function-calling fiable (voir `QueryClassifier`,
///    `SearchOrchestrator.decideNextAction`) : même principe ici, via
///    `MediaSearchQueryReformulator` (partagé avec `VideoSearchService`, les
///    deux n'ayant besoin que d'un unique champ `query`).
/// 2. **Ne throw JAMAIS sur un échec de reformulation.** Le web ne gère pas
///    explicitement ce cas (une erreur `generateObject` remonterait telle
///    quelle) ; ici, un LLM qui échoue à reformuler correctement la requête
///    ne doit pas priver l'utilisateur d'une recherche d'images tout court —
///    repli sur la requête originale, documenté dans
///    `MediaSearchQueryReformulator.reformulate`.
/// 3. **Filtre `https` strict, absent du web.** `SearXNGSearchResult` est un
///    type partagé avec le reste de l'app (voir `SearXNGModels.swift`) : rien
///    ne garantit qu'une instance publique mal configurée ne renvoie pas un
///    `img_src` en `http://` (contenu mixte bloqué par `AsyncImage` sur
///    App Transport Security) ou une URL vide/malformée. Le web laisse passer
///    ces cas (le navigateur affiche juste une image cassée) ; ici on les
///    exclut à la source pour ne jamais présenter de vignette qui ne
///    chargera jamais.
struct ImageSearchService: Sendable {
    private let failoverManager: FailoverManager
    private let aiProvider: any AIGenerating
    private let maxResults: Int
    private let maxHistoryMessages: Int

    /// `maxResults` par défaut à 10 : reprend exactement `.slice(0, 10)` de
    /// `image.ts` — aucune raison de diverger, une grille d'images n'a pas la
    /// contrainte de contexte-tokens qui a motivé les autres bornes du projet
    /// (`SearchOrchestrator.maxScrapedContextCharacters`).
    /// `maxHistoryMessages` par défaut à 8, cohérent avec `QueryClassifier`.
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

    /// Ne throw QUE si `failoverManager.search` échoue (toutes les instances
    /// SearXNG indisponibles, ou aucune instance configurée) — l'appelant
    /// (futur `SearchOrchestrator` ou UI) doit pouvoir distinguer "aucune
    /// image trouvée" (tableau vide, cas normal) de "la recherche n'a pas pu
    /// être exécutée du tout" (throw), exactement comme `FailoverManager`
    /// distingue déjà les deux pour la recherche texte.
    func search(query: String, chatHistory: [ClassifierChatMessage] = []) async throws -> [ImageSearchResult] {
        let reformulatedQuery = await MediaSearchQueryReformulator.reformulate(
            originalQuery: query,
            chatHistory: chatHistory,
            systemPrompt: Self.reformulationSystemPrompt,
            aiProvider: aiProvider,
            maxHistoryMessages: maxHistoryMessages
        )

        let response = try await failoverManager.search(
            query: reformulatedQuery,
            options: SearXNGSearchOptions(categories: ["images"], engines: ["bing images", "google images"])
        )

        return Self.filterAndMap(response.results, maxResults: maxResults)
    }

    /// Fonction pure et testable séparément du réseau : c'est elle qui porte
    /// la logique de `image.ts` (`forEach` + `push` conditionnel +
    /// `.slice(0, 10)`), traduite en `compactMap` + `prefix`.
    static func filterAndMap(_ results: [SearXNGSearchResult], maxResults: Int) -> [ImageSearchResult] {
        let mapped = results.compactMap { result -> ImageSearchResult? in
            let trimmedTitle = result.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard
                !trimmedTitle.isEmpty,
                let imageURL = Self.httpsURL(from: result.imgSrc),
                let sourceURL = Self.httpsURL(from: result.url)
            else { return nil }
            return ImageSearchResult(imageURL: imageURL, sourceURL: sourceURL, title: trimmedTitle)
        }
        return Array(mapped.prefix(max(0, maxResults)))
    }

    /// `URL(string:)` accepte des chaînes qui ne sont pas des URLs
    /// exploitables comme image (chemin relatif, `javascript:`...) — on exige
    /// en plus un schéma `https` exact, voir la justification de tête de
    /// fichier.
    private static func httpsURL(from raw: String?) -> URL? {
        guard let raw, let url = URL(string: raw), url.scheme?.lowercased() == "https" else { return nil }
        return url
    }

    /// Port du system prompt de `imageSearchPrompt` (web) — condensé, cette
    /// instruction unique n'a pas besoin de la distinction `.full`/`.concise`
    /// des prompts de classification/rédaction : c'est déjà la version la
    /// plus courte possible d'une consigne à un seul champ de sortie.
    static let reformulationSystemPrompt = """
    Tu reformules la question d'un utilisateur en une courte requête de recherche d'images, à partir de l'historique de conversation si besoin (ex. "Montre-moi des photos" après une question sur le Japon -> "photos Japon").
    Réponds UNIQUEMENT avec un objet JSON de la forme {"query": "..."}, sans aucun texte autour.
    """
}

/// Reformulation de requête média, factorisée entre `ImageSearchService` et
/// `VideoSearchService` : les deux ont EXACTEMENT le même besoin (un appel
/// LLM qui renvoie `{"query": "..."}`, historique inclus), seul le prompt
/// système diffère. Dupliquer cette logique aurait fait diverger le
/// comportement de repli au premier correctif appliqué à un seul des deux
/// fichiers.
///
/// `nonisolated` explicite : sous `-default-isolation=MainActor`, un type non
/// annoté hérite du main actor, ce qui interdirait son usage depuis un
/// contexte `nonisolated async` — `ImageSearchService`/`VideoSearchService`
/// sont des `struct Sendable` ordinaires, pas des types isolés.
nonisolated enum MediaSearchQueryReformulator {
    /// Ne throw JAMAIS : un échec de l'appel LLM (provider indisponible,
    /// clé BYOK invalide...) OU une sortie qui ne contient pas de JSON
    /// exploitable retombent tous les deux sur `originalQuery`, jamais sur
    /// une chaîne vide qui ferait échouer la recherche SearXNG en aval pour
    /// une raison qui n'a rien à voir avec elle.
    static func reformulate(
        originalQuery: String,
        chatHistory: [ClassifierChatMessage],
        systemPrompt: String,
        aiProvider: any AIGenerating,
        maxHistoryMessages: Int
    ) async -> String {
        let prompt = Self.buildPrompt(
            originalQuery: originalQuery,
            chatHistory: chatHistory,
            systemPrompt: systemPrompt,
            maxHistoryMessages: maxHistoryMessages
        )

        guard let rawOutput = try? await aiProvider.generate(prompt: prompt) else {
            return originalQuery
        }

        guard
            let parsedQuery = Self.parseQuery(rawOutput)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !parsedQuery.isEmpty
        else {
            return originalQuery
        }
        return parsedQuery
    }

    static func buildPrompt(
        originalQuery: String,
        chatHistory: [ClassifierChatMessage],
        systemPrompt: String,
        maxHistoryMessages: Int
    ) -> String {
        let history = chatHistory.suffix(max(0, maxHistoryMessages))
            .map { message in
                switch message.role {
                case .user: return "User: \(message.content)"
                case .assistant: return "AI: \(message.content)"
                }
            }
            .joined(separator: "\n")

        return """
        \(systemPrompt)

        <conversation>
        \(history)
        </conversation>
        <follow_up>
        \(originalQuery)
        </follow_up>
        """
    }

    /// Parsing tolérant simplifié de `QueryClassifier.parse` : le schéma
    /// attendu n'a ici qu'un seul champ `query`, ce qui rend inutile la
    /// distinction fenced-blocks/braces-substring complète — extraire la
    /// première sous-chaîne entre `{` et `}` couvre déjà les deux cas
    /// (bloc de code markdown inclus, puisque les accolades y sont aussi).
    static func parseQuery(_ rawOutput: String) -> String? {
        guard
            let openBrace = rawOutput.firstIndex(of: "{"),
            let closeBrace = rawOutput.lastIndex(of: "}"),
            openBrace < closeBrace
        else { return nil }

        let jsonSubstring = String(rawOutput[openBrace...closeBrace])
        guard let data = jsonSubstring.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(RawMediaQuery.self, from: data).query
    }

    private struct RawMediaQuery: Decodable {
        let query: String
    }
}
