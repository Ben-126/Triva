//
//  SuggestionsService.swift
//  Triva
//
//  Created by ben podrojsky on 19/09/2026.
//

import Foundation

/// Port natif de `src/lib/agents/suggestions/index.ts` et
/// `src/lib/prompts/suggestions.ts` (web) : demande au LLM 3 à 5 questions de
/// suivi pertinentes à partir de l'historique de conversation, une fois une
/// réponse produite. Réutilise `ClassifierChatMessage` (défini dans
/// `QueryClassifier.swift`) pour l'historique plutôt que d'inventer un
/// nouveau type — l'historique de suggestions n'a besoin de rien de plus que
/// "qui a dit quoi", exactement comme la classification.
///
/// Différence majeure avec la référence web : `generateObject` (web) appelle
/// le LLM avec un schéma zod structuré (`{ suggestions: string[] }`) que le
/// SDK garantit respecté. `AIGenerating` ne connaît qu'une seule chaîne
/// `prompt` en sortie libre — aucun des 3 moteurs IA de Triva n'expose de
/// sortie structurée fiable (voir `QueryClassifier` et
/// `SearchOrchestrator.decideNextAction`, même contrainte). Le parsing est
/// donc TOLÉRANT et ne throw JAMAIS : un modèle 0.6B on-device renvoie
/// souvent une liste à puces en texte brut au lieu du JSON demandé, et
/// `generateSuggestions` doit dans tous les cas retomber sur une liste vide
/// plutôt que de propager une erreur jusqu'à l'UI — l'UI n'affiche alors
/// simplement pas la section suggestions, ce qui est un repli acceptable
/// pour une fonctionnalité secondaire.
struct SuggestionsService: Sendable {
    private let aiProvider: any AIGenerating
    private let maxHistoryMessages: Int
    private let maxSuggestionCount: Int
    private let maxSuggestionLength: Int

    /// `maxHistoryMessages` par défaut à 8, même valeur et même raison que
    /// `QueryClassifier` : ne pas saturer le contexte d'un petit modèle avec
    /// une conversation longue, et rester cohérent avec le reste du
    /// pipeline. `maxSuggestionCount` par défaut à 5 : le plan (1.7) demande
    /// "3 à 5 questions" — 5 est la borne haute, `sanitize` ne complète
    /// jamais artificiellement en dessous de 3, une liste plus courte (ou
    /// vide) reste un résultat valide plutôt qu'un échec.
    /// `maxSuggestionLength` par défaut à 160 caractères : assez pour une
    /// question complète et naturelle en français, assez court pour tenir
    /// dans une puce/chip d'UI sur une seule ligne sans troncature visuelle
    /// — une "suggestion" plus longue que ça est le signe que le parsing a
    /// capturé un paragraphe entier plutôt qu'une vraie question isolée
    /// (sortie absurde ou mal structurée), donc on l'exclut plutôt que de
    /// l'afficher telle quelle.
    init(
        aiProvider: any AIGenerating,
        maxHistoryMessages: Int = 8,
        maxSuggestionCount: Int = 5,
        maxSuggestionLength: Int = 160
    ) {
        self.aiProvider = aiProvider
        self.maxHistoryMessages = maxHistoryMessages
        self.maxSuggestionCount = maxSuggestionCount
        self.maxSuggestionLength = maxSuggestionLength
    }

    /// Ne throw jamais : toute erreur du provider (réseau, quota, moteur
    /// indisponible...) retombe sur une liste vide, jamais propagée. C'est
    /// une fonctionnalité d'agrément affichée après coup — son échec ne doit
    /// jamais faire échouer ou perturber la conversation principale.
    func generateSuggestions(chatHistory: [ClassifierChatMessage]) async -> [String] {
        let prompt = Self.buildPrompt(chatHistory: chatHistory, maxHistoryMessages: maxHistoryMessages)
        do {
            let rawOutput = try await aiProvider.generate(prompt: prompt)
            return Self.parse(rawOutput, maxCount: maxSuggestionCount, maxLength: maxSuggestionLength)
        } catch {
            return []
        }
    }

    /// Construction du prompt isolée dans une fonction pure et testable
    /// directement, même principe que `QueryClassifier.buildPrompt` et
    /// `SearchOrchestrator.buildPrompt`. Prompt volontairement court (une
    /// dizaine de lignes) : contrairement au classifieur, les suggestions
    /// tournent systématiquement après une réponse déjà produite, donc sur
    /// n'importe quel moteur actif — y compris un modèle MLX 0.6B, le plus
    /// petit du catalogue. Un prompt long dilue l'attention de ces modèles
    /// (même constat documenté dans `QueryClassifier` pour sa variante
    /// `.concise`), donc ici il n'existe qu'une seule variante, déjà
    /// minimale.
    static func buildPrompt(chatHistory: [ClassifierChatMessage], maxHistoryMessages: Int) -> String {
        // `suffix(_:)` trappe sur un argument négatif ; se protéger ici
        // plutôt que faire confiance à l'appelant, même remarque que
        // `QueryClassifier.buildPrompt`.
        let history = chatHistory.suffix(max(0, maxHistoryMessages))
            .map { message in
                switch message.role {
                case .user:
                    return "User: \(message.content)"
                case .assistant:
                    return "AI: \(message.content)"
                }
            }
            .joined(separator: "\n")

        return """
        \(Self.systemPrompt)

        <conversation_history>
        \(history)
        </conversation_history>
        """
    }

    /// Parsing tolérant, jamais de `throw` — même philosophie que
    /// `QueryClassifier.parse`. Essaie d'abord une sortie structurée (JSON,
    /// éventuellement enveloppé dans un bloc markdown ou un objet
    /// `{"suggestions": [...]}`), et ne retombe sur un découpage ligne par
    /// ligne (listes à puces ou numérotées en texte brut) que si aucune
    /// structure JSON exploitable n'a été trouvée : un petit modèle ignore
    /// souvent la consigne de format et répond avec une liste en langage
    /// naturel. Le résultat brut de l'une ou l'autre voie passe ensuite
    /// systématiquement par `sanitize`, qui applique le nettoyage et les
    /// bornes quelle que soit la source.
    static func parse(_ rawOutput: String, maxCount: Int = 5, maxLength: Int = 160) -> [String] {
        let raw = Self.parseStructuredJSON(rawOutput) ?? Self.parsePlainTextList(rawOutput)
        return Self.sanitize(raw, maxCount: maxCount, maxLength: maxLength)
    }

    /// Nettoyage centralisé, appliqué une seule fois en sortie de `parse`
    /// quelle que soit la forme d'entrée détectée (JSON ou texte brut) :
    /// retire les puces/numéros résiduels qu'un modèle glisse parfois même
    /// à l'intérieur d'un tableau JSON (ex. `"1. Quelle..."` comme élément
    /// de tableau), retire les guillemets englobants, déduplique de façon
    /// insensible à la casse (un modèle reformule souvent une même question
    /// deux fois avec une ponctuation différente), exclut les suggestions
    /// vides ou trop longues, puis borne le nombre total. `Set` préserve
    /// l'ordre d'apparition de `raw` en ne servant qu'à détecter les
    /// doublons — l'ordre du modèle (généralement de la plus pertinente à la
    /// moins pertinente) est donc conservé dans le résultat.
    static func sanitize(_ raw: [String], maxCount: Int = 5, maxLength: Int = 160) -> [String] {
        var seenLowercased: Set<String> = []
        var result: [String] = []

        for candidate in raw {
            guard result.count < maxCount else { break }

            var cleaned = Self.strippingLeadingMarker(candidate.trimmingCharacters(in: .whitespacesAndNewlines))
            cleaned = Self.strippingWrappingQuotes(cleaned)
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !cleaned.isEmpty, cleaned.count <= maxLength else { continue }

            let key = cleaned.lowercased()
            guard !seenLowercased.contains(key) else { continue }

            seenLowercased.insert(key)
            result.append(cleaned)
        }

        return result
    }

    // MARK: - Parsing structuré (JSON)

    /// Tente un décodage JSON dans l'ordre : chaque bloc de code markdown
    /// rencontré (dans l'ordre d'apparition), puis la sortie complète en
    /// dernier recours — même stratégie de candidats que
    /// `QueryClassifier.jsonCandidates`, pour la même raison : un LLM
    /// respecte rarement à la lettre "aucun texte en dehors du JSON".
    private static func parseStructuredJSON(_ rawOutput: String) -> [String]? {
        for block in Self.extractFencedBlocks(from: rawOutput) {
            if let suggestions = Self.structuredSuggestions(in: block) {
                return suggestions
            }
        }
        return Self.structuredSuggestions(in: rawOutput)
    }

    /// Essaie d'abord un tableau JSON brut (`["...", "..."]`), la forme la
    /// plus simple à produire pour un petit modèle, puis un objet enveloppe
    /// `{"suggestions": ["...", "..."]}` (la forme du schéma zod de la
    /// référence web). L'extraction par sous-chaîne entre premier/dernier
    /// crochet fonctionne aussi quand le tableau est lui-même imbriqué dans
    /// un objet (`{"suggestions": [...]}` contient bien un `[` et un `]`) :
    /// c'est volontaire, ça absorbe la forme "objet" sans code dédié tant
    /// que le contenu du tableau décode proprement en `[String]`. L'objet
    /// n'est essayé qu'en repli, pour le cas où le tableau contiendrait par
    /// exemple des nombres ou objets imbriqués plutôt que des chaînes.
    private static func structuredSuggestions(in text: String) -> [String]? {
        if
            let arrayCandidate = Self.extractBracketsSubstring(from: text),
            let data = arrayCandidate.data(using: .utf8),
            let decoded = try? JSONDecoder().decode([String].self, from: data)
        {
            return decoded
        }

        if
            let objectCandidate = Self.extractBracesSubstring(from: text),
            let data = objectCandidate.data(using: .utf8),
            let decoded = try? JSONDecoder().decode(RawSuggestionsResponse.self, from: data),
            let suggestions = decoded.suggestions
        {
            return suggestions
        }

        return nil
    }

    /// Miroir `Decodable` de l'enveloppe `{"suggestions": [...]}`. Un champ
    /// absent ou de mauvais type fait échouer tout le décodage (pas de
    /// `try?` interne comme dans `QueryClassifier.RawClassifierResponse`) :
    /// contrairement à la classification, il n'y a ici aucun champ
    /// individuel à sauver — soit le tableau de suggestions est exploitable
    /// dans son ensemble, soit on passe au candidat suivant.
    private struct RawSuggestionsResponse: Decodable {
        let suggestions: [String]?
    }

    /// Même découpage que `QueryClassifier.extractFencedBlocks` : renvoie le
    /// contenu de chaque bloc ``` ... ``` rencontré, dans l'ordre
    /// d'apparition, débarrassé d'un éventuel préfixe `json`. Dupliqué
    /// plutôt que partagé car `QueryClassifier` le garde `private` — pas de
    /// bonne raison d'introduire un couplage entre les deux types pour dix
    /// lignes de découpage de texte.
    private static func extractFencedBlocks(from rawOutput: String) -> [String] {
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

    private static func extractBracketsSubstring(from text: String) -> String? {
        guard
            let firstBracket = text.firstIndex(of: "["),
            let lastBracket = text.lastIndex(of: "]"),
            firstBracket < lastBracket
        else {
            return nil
        }
        return String(text[firstBracket...lastBracket])
    }

    private static func extractBracesSubstring(from text: String) -> String? {
        guard
            let firstBrace = text.firstIndex(of: "{"),
            let lastBrace = text.lastIndex(of: "}"),
            firstBrace < lastBrace
        else {
            return nil
        }
        return String(text[firstBrace...lastBrace])
    }

    // MARK: - Parsing texte brut (listes à puces / numérotées)

    /// Repli quand aucune structure JSON n'a été trouvée : chaque ligne non
    /// vide devient un candidat, après retrait d'une éventuelle puce ou d'un
    /// numéro en tête. Un modèle qui ignore complètement la consigne de
    /// format répond typiquement ainsi ("- Question un\n- Question deux" ou
    /// "1. Question un\n2. Question deux"). Une sortie absurde (prose sans
    /// puces ni numéros) traverse aussi ce chemin : chaque ligne devient un
    /// candidat brut, et c'est `sanitize` (borne de longueur) qui filtrera
    /// ensuite ce qui ressemble à un paragraphe plutôt qu'à une question.
    private static func parsePlainTextList(_ rawOutput: String) -> [String] {
        rawOutput
            .components(separatedBy: .newlines)
            .compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return trimmed.isEmpty ? nil : trimmed
            }
    }

    /// Retire une puce (`-`, `*`, `•`, `–`) ou un numéro (`1.`, `2)`, `12.`)
    /// en tête de ligne, s'il y en a un. Appelée à la fois par le
    /// découpage en texte brut et par `sanitize` (un élément de tableau JSON
    /// peut lui aussi contenir un numéro résiduel, ex. `"1. Quelle est..."`,
    /// un petit modèle mélange parfois les deux formats).
    private static func strippingLeadingMarker(_ line: String) -> String {
        let bulletCharacters: Set<Character> = ["-", "*", "•", "–"]
        if let first = line.first, bulletCharacters.contains(first) {
            return String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
        }

        var digitsEndIndex = line.startIndex
        while digitsEndIndex < line.endIndex, line[digitsEndIndex].isNumber {
            digitsEndIndex = line.index(after: digitsEndIndex)
        }
        guard
            digitsEndIndex > line.startIndex,
            digitsEndIndex < line.endIndex,
            line[digitsEndIndex] == "." || line[digitsEndIndex] == ")"
        else {
            return line
        }

        let afterMarker = line.index(after: digitsEndIndex)
        return String(line[afterMarker...]).trimmingCharacters(in: .whitespaces)
    }

    /// Retire une paire de guillemets (droits, simples, ou chevrons
    /// français) qui englobe tout le texte — un modèle qui produit un
    /// tableau JSON "à la main" en texte brut cite parfois chaque élément.
    /// Ne touche qu'à une paire englobant réellement toute la chaîne, jamais
    /// à des guillemets internes (ex. une vraie citation dans la question).
    private static func strippingWrappingQuotes(_ text: String) -> String {
        let quotePairs: [(Character, Character)] = [("\"", "\""), ("'", "'"), ("«", "»")]
        guard text.count >= 2, let first = text.first, let last = text.last else { return text }

        for (open, close) in quotePairs where first == open && last == close {
            return String(text.dropFirst().dropLast())
        }
        return text
    }

    /// Prompt système unique et volontairement court (voir doc de
    /// `buildPrompt`). Demande la forme "objet enveloppe" plutôt que
    /// "tableau nu" pour rester au plus près du schéma zod
    /// `{ suggestions: string[] }` de la référence web
    /// (`src/lib/prompts/suggestions.ts`) — mais `parse` accepte de toute
    /// façon les deux formes, ainsi que le texte brut, donc un modèle qui
    /// dévie de la consigne n'entraîne jamais un résultat vide par excès de
    /// rigueur du parsing.
    private static let systemPrompt: String = """
    Propose entre 3 et 5 questions de suivi courtes et pertinentes que l'utilisateur pourrait poser après la conversation ci-dessous.
    Réponds STRICTEMENT avec ce format JSON, sans aucun texte, explication ou phrase autour :
    {"suggestions": ["première question", "deuxième question", "..."]}
    Les questions doivent être courtes, concrètes, et formulées du point de vue de l'utilisateur.
    """
}
