//
//  SearchOrchestrator+Planner.swift
//  Triva
//
//  Created by ben podrojsky on 12/11/2026.
//

import Foundation

/// Décision du planner (itérations 2+ de la boucle de recherche) : quelle
/// action lancer ensuite, avec quelles URLs ou requêtes le cas échéant. Port
/// de la boucle `for` de `researcher/index.ts` (web) — mais là où le TS
/// délègue le choix d'action à un vrai tool-calling LLM (schéma zod +
/// function-calling natif), ici la décision passe par un parsing JSON
/// tolérant, même principe que `QueryClassifier.parse` : aucun des 3
/// providers IA de Triva n'expose de function-calling fiable.
///
/// Plus de champ `reasoning` (bug 8 de la revue) : demandé au modèle mais lu
/// nulle part, il coûtait des tokens de sortie à chaque tour — et, écrit
/// APRÈS l'action dans le JSON, il ne pouvait même pas éclairer la décision.
/// Un modèle qui le renvoie quand même reste accepté (clé ignorée).
///
/// `queries` (1.11) : requêtes de l'action `uploadsSearch` (fichiers joints),
/// 3 au plus retenues par `UploadsSearchResultBuilder.effectiveQueries`.
nonisolated struct PlannerDecision: Sendable, Equatable {
    let actionName: String
    let urls: [String]
    let queries: [String]

    init(actionName: String, urls: [String], queries: [String] = []) {
        self.actionName = actionName
        self.urls = urls
        self.queries = queries
    }
}

/// Planner de la boucle de recherche (itérations 2+) : noms d'actions, prompt du planner et
/// parsing tolérant de sa réponse. Sorti de `SearchOrchestrator.swift` (découpage E1b) : tout y est
/// statique et pur, sans accès aux propriétés de l'orchestrateur.
extension SearchOrchestrator {
    /// Noms d'actions du planner. `uploadsSearch` = `UploadsSearchAction.name`.
    nonisolated static let scrapeActionName = "scrapeURL"
    nonisolated static let uploadsSearchActionName = "uploadsSearch"
    nonisolated static let doneActionName = "done"

    /// Actions proposées à un tour : seulement celles qui ont encore un objet
    /// (une source à scraper, des fichiers joints pas encore consultés), plus
    /// `done`. Sans fichier joint, exactement `["scrapeURL", "done"]`, comme
    /// avant 1.11.
    nonisolated static func plannerActionNames(canScrape: Bool, canSearchUploads: Bool) -> [String] {
        (canScrape ? [scrapeActionName] : []) + (canSearchUploads ? [uploadsSearchActionName] : []) + [doneActionName]
    }

    /// Prompt du planner (itérations 2+) : contrairement au tool-calling
    /// natif de `researcher/index.ts` (web), demande explicitement un JSON
    /// `{ "action": ..., "urls": [...] }`, même approche tolérante que
    /// `QueryClassifier.buildPrompt`. Le marqueur `<planner_context>` (absent
    /// du prompt de classification ET du prompt final) permet de distinguer
    /// sans ambiguïté un prompt de planificateur des deux autres étapes —
    /// utile aux mocks de test comme au débogage.
    ///
    /// Ne liste que les sources AFFICHÉES (bug 8), seules scrapables, chacune
    /// annotée si sa page a déjà été récupérée ou a échoué (bug 11 : sans
    /// cette mémoire, le modèle redemandait les mêmes pages à chaque tour).
    /// Le plafond par tour est interpolé depuis `maxURLsPerIteration` plutôt
    /// qu'écrit en dur (« 1 à 3 ») : un réglage par moteur (bug 6) ne doit
    /// pas laisser le prompt promettre plus que ce que la boucle exécute.
    ///
    /// Chaque action n'est décrite que si elle figure dans
    /// `availableActionNames` (`done` toujours) : `uploadsSearch` (1.11) et
    /// son champ `queries` n'apparaissent qu'avec des fichiers joints pas
    /// encore consultés. Avec `["scrapeURL", "done"]`, le texte est celui
    /// d'avant 1.11.
    nonisolated static func plannerPrompt(
        query: String,
        displayedSources: [SearXNGSearchResult],
        scrapedPages: [ScrapedPage] = [],
        availableActionNames: [String],
        iteration: Int,
        maxIterations: Int,
        maxURLsPerIteration: Int = 3
    ) -> String {
        let succeededByKey = scrapedPages.reduce(into: [String: Bool]()) { status, page in
            let key = urlKey(page.url)
            status[key] = (status[key] ?? false) || page.succeeded
        }
        let sourcesSummary = displayedSources.enumerated()
            .map { index, result in
                let marker: String
                switch succeededByKey[urlKey(result.url)] {
                case true?: marker = " (page déjà récupérée)"
                case false?: marker = " (récupération échouée, ne la redemande pas)"
                case nil: marker = ""
                }
                return "\(index + 1). \(result.title) — \(result.url)\(marker)"
            }
            .joined(separator: "\n")

        let jsonFields = plannerJSONFields(availableActionNames)

        return """
        Tu es un agent de recherche. Itération \(iteration)/\(maxIterations).

        <planner_context>
        Requête de l'utilisateur : \(query)

        Sources affichées à l'utilisateur (les seules que tu peux demander) :
        \(sourcesSummary)

        Actions disponibles : \(availableActionNames.joined(separator: ", "))
        \(plannerActionDescriptions(availableActionNames, maxURLsPerIteration: maxURLsPerIteration))
        </planner_context>

        Réponds STRICTEMENT avec ce JSON, sans aucun texte autour :
        {
          "action": \(actionChoice(availableActionNames)),
          \(jsonFields)
        }
        """
    }

    /// Une ligne par action proposée, `done` toujours en dernier.
    private nonisolated static func plannerActionDescriptions(_ actionNames: [String], maxURLsPerIteration: Int) -> String {
        let scrape = actionNames.contains(scrapeActionName)
            ? ["- \"scrapeURL\" : récupère le contenu complet de sources de la liste ci-dessus dont la page n'a pas encore été récupérée (au plus \(max(1, maxURLsPerIteration)) à la fois), pour approfondir la réponse. Fournis \"urls\" avec leurs URLs exactes."]
            : []
        let uploads = actionNames.contains(uploadsSearchActionName)
            ? ["- \"uploadsSearch\" : cherche dans les fichiers joints par l'utilisateur, sur l'appareil (jamais sur le web), si la question peut porter sur leur contenu. Fournis \"queries\" : 1 à \(UploadsSearchResultBuilder.maxQueries) requêtes courtes."]
            : []
        let done = ["- \"done\" : arrête la recherche, les sources actuelles suffisent pour répondre."]
        return (scrape + uploads + done).joined(separator: "\n")
    }

    /// Champs du JSON attendu, ceux des actions proposées seulement : `urls`
    /// pour `scrapeURL`, `queries` pour `uploadsSearch` — un petit modèle
    /// remplit volontiers un champ qu'on lui montre, même inutile. Sans action
    /// à paramètre (la boucle n'appelle alors jamais le planner), `urls`
    /// reste, comme avant 1.11.
    private nonisolated static func plannerJSONFields(_ actionNames: [String]) -> String {
        let urls = actionNames.contains(scrapeActionName) ? ["\"urls\": [\"url1\", \"url2\"]"] : []
        let queries = actionNames.contains(uploadsSearchActionName) ? ["\"queries\": [\"requête 1\"]"] : []
        let fields = urls + queries
        return fields.isEmpty ? "\"urls\": [\"url1\", \"url2\"]" : fields.joined(separator: ",\n  ")
    }

    /// `"a" ou "b"`, `"a", "b" ou "c"` : la valeur attendue du champ `action`.
    private nonisolated static func actionChoice(_ actionNames: [String]) -> String {
        let quoted = actionNames.map { "\"\($0)\"" }
        guard let last = quoted.last else { return "\"\(doneActionName)\"" }
        let head = quoted.dropLast()
        return head.isEmpty ? last : head.joined(separator: ", ") + " ou " + last
    }

    /// Parsing tolérant, même principe que `QueryClassifier.parse` : jamais
    /// de `throw`, un JSON introuvable/invalide/mal typé retombe sur
    /// `fallbackActionName` ("done" par défaut) — garantit la terminaison de
    /// la boucle planner quelle que soit la sortie du LLM.
    nonisolated static func decideNextAction(rawOutput: String, fallbackActionName: String = "done") -> PlannerDecision {
        let fallback = PlannerDecision(actionName: fallbackActionName, urls: [])

        for candidate in Self.jsonCandidates(from: rawOutput) {
            guard
                let data = candidate.data(using: .utf8),
                let decoded = try? JSONDecoder().decode(RawPlannerResponse.self, from: data),
                let actionName = decoded.action
            else { continue }

            return PlannerDecision(actionName: actionName, urls: decoded.urls ?? [], queries: decoded.queries ?? [])
        }

        return fallback
    }

    /// Extraction de candidats JSON dupliquée depuis `QueryClassifier`
    /// (blocs de code markdown, puis repli sur la sous-chaîne entre la
    /// première `{` et la dernière `}`) plutôt que partagée :
    /// `QueryClassifier.jsonCandidates` est `private`, et ce fichier reste
    /// hors du scope autorisé de modification de `QueryClassifier.swift`
    /// (voir consignes de la tâche 1.2).
    private nonisolated static func jsonCandidates(from rawOutput: String) -> [String] {
        var candidates: [String] = []
        for fencedBlock in Self.extractFencedBlocks(from: rawOutput) {
            candidates.append(Self.extractBracesSubstring(from: fencedBlock) ?? fencedBlock)
        }
        if let braces = Self.extractBracesSubstring(from: rawOutput) {
            candidates.append(braces)
        }
        return candidates
    }

    private nonisolated static func extractFencedBlocks(from rawOutput: String) -> [String] {
        let fenceComponents = rawOutput.components(separatedBy: "```")
        guard fenceComponents.count >= 3 else { return [] }
        var blocks: [String] = []
        var index = 1
        while index < fenceComponents.count {
            var block = fenceComponents[index].trimmingCharacters(in: .whitespacesAndNewlines)
            if block.hasPrefix("json") {
                block.removeFirst("json".count)
            }
            blocks.append(block.trimmingCharacters(in: .whitespacesAndNewlines))
            index += 2
        }
        return blocks
    }

    private nonisolated static func extractBracesSubstring(from rawOutput: String) -> String? {
        guard
            let firstBrace = rawOutput.firstIndex(of: "{"),
            let lastBrace = rawOutput.lastIndex(of: "}"),
            firstBrace < lastBrace
        else { return nil }
        return String(rawOutput[firstBrace...lastBrace])
    }

    /// Sans `reasoning` : clé ignorée si un modèle la renvoie quand même
    /// (`JSONDecoder` tolère les clés inconnues). `queries` : action
    /// `uploadsSearch` (1.11). `nonisolated` : décodé hors du main actor.
    private nonisolated struct RawPlannerResponse: Decodable {
        let action: String?
        let urls: [String]?
        let queries: [String]?
    }
}
