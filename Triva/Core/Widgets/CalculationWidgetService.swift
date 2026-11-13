//
//  CalculationWidgetService.swift
//  Triva
//
//  Created by ben podrojsky on 19/09/2026.
//

import Foundation


// MARK: - Formatage

/// Met le résultat en forme pour l'affichage français. Le vrai problème
/// résolu ici est le bruit binaire : `240 * 0.15` vaut `36.000000000000004`
/// en `Double`, et l'afficher décrédibiliserait instantanément le widget.
nonisolated enum CalculationResultFormatter {
    /// Locale FIXE plutôt que `Locale.current` : toute l'interface est en
    /// français (DESIGN.md). Sur un appareil réglé en anglais, `.current`
    /// afficherait « 36.5 » au milieu d'une phrase française, avec un
    /// séparateur décimal différent du reste de l'app.
    static let displayLocale = Locale(identifier: "fr_FR")

    /// 10 décimales maximum : c'est ce seuil, et lui seul, qui fait
    /// disparaître le bruit (`36.000000000000004` arrondi à 10 décimales vaut
    /// exactement 36, et `NumberFormatter` supprime les zéros de fin). Mesuré :
    /// on garde `1/3 -> 0,3333333333` et `123456789012345` intact, là où un
    /// plafond en chiffres SIGNIFICATIFS (essayé à 12) tronquait ce dernier en
    /// `123 456 789 012 000`.
    static let maximumFractionDigits = 10

    /// Au-delà : notation scientifique. 1e15 est juste sous 2^53 ≈ 9,007e15,
    /// limite au-delà de laquelle un `Double` ne représente plus tous les
    /// entiers — afficher 20 chiffres dont les derniers sont faux serait
    /// mentir, et 300 chiffres (`1e300`) serait illisible.
    static let scientificUpperBound = 1e15

    /// En dessous, la notation décimale afficherait « 0 » pour une valeur non
    /// nulle, donc un résultat faux : on bascule aussi.
    static let scientificLowerBound = 1e-10

    /// `nil` si la valeur n'est pas finie. L'évaluateur garantit déjà la
    /// finitude : cette nullité est une ceinture de sécurité pour les
    /// appelants directs (et elle est testée), pas un chemin nominal.
    static func format(_ value: Double, locale: Locale = displayLocale) -> String? {
        guard value.isFinite else { return nil }
        // `-0.0 == 0` est vrai, mais `NumberFormatter` en tire « -0 » :
        // normaliser ici est plus sûr que d'espérer qu'aucun zéro signé ne
        // sorte jamais de l'évaluateur.
        guard value != 0 else { return decimalFormatter(locale: locale).string(from: 0) }

        let magnitude = abs(value)
        let formatter = (magnitude >= scientificUpperBound || magnitude < scientificLowerBound)
            ? scientificFormatter(locale: locale)
            : decimalFormatter(locale: locale)
        return formatter.string(from: NSNumber(value: value))
    }

    /// Un formateur NEUF à chaque appel : `NumberFormatter` est une classe
    /// mutable et non `Sendable`, en partager une instance depuis un contexte
    /// `nonisolated` serait une course de données. Le coût est négligeable
    /// devant l'appel LLM qui précède.
    private static func decimalFormatter(locale: Locale) -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = maximumFractionDigits
        return formatter
    }

    private static func scientificFormatter(locale: Locale) -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .scientific
        formatter.usesSignificantDigits = true
        formatter.maximumSignificantDigits = 10
        // Par défaut `exponentSymbol` vaut « E » ; « e » est la graphie usuelle.
        formatter.exponentSymbol = "e"
        return formatter
    }
}

// MARK: - Donnée du widget

/// Donnée affichable du widget. Équivalent typé du `data: { expression,
/// result }` de la version web d'origine, avec en plus le résultat DÉJÀ
/// formaté : une vue n'a pas à connaître la locale ni le seuil de notation
/// scientifique pour afficher un nombre.
struct CalculationWidgetData: Sendable, Equatable {
    /// Expression telle que le modèle l'a écrite (seulement détourée), PAS sa
    /// forme normalisée : c'est celle-là que l'utilisateur reconnaîtra ; la
    /// normalisation est un détail interne de l'analyse.
    let expression: String
    /// Valeur brute, conservée pour les tests et pour un éventuel « copier le
    /// résultat » sans reparser une chaîne formatée.
    let result: Double
    let formattedResult: String
}

/// Sortie complète du service. Même forme que `WeatherWidgetResult`, pour que
/// l'appelant n'ait qu'un modèle mental pour les deux widgets.
struct CalculationWidgetResult: Sendable, Equatable {
    let data: CalculationWidgetData
    let llmContext: String
}

// MARK: - Service

/// Abstraction exposée à l'appelant : une seule méthode, infaillible en
/// surface. `nil` veut dire « pas de widget », quelle qu'en soit la cause.
nonisolated protocol CalculationWidgetServing: Sendable {
    func computeCalculation(forQuery query: String, chatHistory: [ClassifierChatMessage]) async -> CalculationWidgetResult?
}

/// Port du widget calculatrice de la version web d'origine.
///
/// La version web d'origine extrait l'expression par LLM puis l'évalue avec `mathjs`. Ici
/// l'extraction est identique (prompt texte + parsing JSON tolérant) mais
/// l'évaluation est native : zéro dépendance (règle absolue du projet) et
/// zéro réseau — après l'extraction, ce widget ne sort jamais de l'appareil.
///
/// DIVERGENCE assumée : le prompt décrit la grammaire EXACTE de notre
/// évaluateur au lieu de renvoyer à « la bibliothèque Math JS ». `mathjs`
/// accepte unités, matrices et variables que notre liste blanche refuse ;
/// demander du mathjs générique produirait des expressions valides dans la version web d'origine
/// et systématiquement rejetées ici, donc un widget qui disparaît sans raison
/// visible.
struct CalculationWidgetService: CalculationWidgetServing {
    /// Messages d'historique injectés dans le prompt. Même valeur que
    /// `WeatherWidgetService` : au-delà on dilue l'attention d'un petit modèle
    /// on-device sans mieux désambiguïser (« et fois 3 ? » ne dépend que du
    /// tour précédent).
    static let defaultMaxHistoryMessages = 8

    private let aiProvider: any AIGenerating

    init(aiProvider: any AIGenerating) {
        self.aiProvider = aiProvider
    }

    /// Ne `throw` jamais. Trois portes de sortie, toutes sur `nil` : le modèle
    /// a échoué, il a dit `notPresent`, ou l'expression n'est pas évaluable.
    /// Aucune n'est un incident : un widget est un bonus, jamais un préalable
    /// à la réponse.
    func computeCalculation(
        forQuery query: String,
        chatHistory: [ClassifierChatMessage] = []
    ) async -> CalculationWidgetResult? {
        let prompt = Self.buildExtractionPrompt(query: query, chatHistory: chatHistory)
        guard let rawOutput = try? await aiProvider.generate(prompt: prompt) else { return nil }
        guard let expression = Self.parseExtraction(rawOutput) else { return nil }
        return Self.makeResult(forExpression: expression)
    }

    /// Évalue et met en forme. Séparée de la partie LLM pour être testable
    /// sans provider : c'est ici que se joue le « 15% de 240 -> 36 » du plan.
    ///
    /// Le `try?` assume de perdre le motif d'échec : à ce niveau, division par
    /// zéro, caractère interdit et parenthèse orpheline ont exactement la même
    /// conséquence. Le motif reste accessible en appelant l'évaluateur
    /// directement, ce que font les tests.
    static func makeResult(forExpression expression: String) -> CalculationWidgetResult? {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = try? CalculationExpressionEvaluator.evaluate(trimmed) else { return nil }
        guard let formatted = CalculationResultFormatter.format(value) else { return nil }

        let data = CalculationWidgetData(expression: trimmed, result: value, formattedResult: formatted)
        return CalculationWidgetResult(data: data, llmContext: llmContext(for: data))
    }

    /// Phrase française autoportante : `AIGenerating` n'a qu'un canal texte,
    /// autant donner au modèle une phrase reprenable telle quelle plutôt qu'un
    /// objet à interpréter (la version web d'origine, lui, sérialise du JSON).
    static func llmContext(for data: CalculationWidgetData) -> String {
        "Résultat du calcul « \(data.expression) » : \(data.formattedResult)."
    }

    // MARK: Prompt d'extraction

    static func buildExtractionPrompt(
        query: String,
        chatHistory: [ClassifierChatMessage],
        maxHistoryMessages: Int = defaultMaxHistoryMessages
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
        \(extractionSystemPrompt)

        <conversation_history>
        \(history)
        </conversation_history>

        <user_query>
        \(query)
        </user_query>
        """
    }

    /// La section `<grammar>` n'existe pas dans le prompt de la version web d'origine : elle est la
    /// contrepartie directe du choix d'un évaluateur maison. Chaque règle
    /// correspond à une limite réelle de `CalculationExpressionEvaluator`, et
    /// l'exemple du pourcentage est celui du plan (« 15% de 240 »).
    private static let extractionSystemPrompt: String = """
    <role>
    Tu extrais une expression mathématique. Tu reçois la dernière question de l'utilisateur et l'historique de la conversation.
    Ta tâche est de déterminer si un calcul doit être effectué et, si oui, d'écrire l'expression correspondante.
    </role>

    <grammar>
    - Opérateurs autorisés : + - * / ^ (puissance) et les parenthèses.
    - Racine carrée : sqrt(x), toujours avec des parenthèses.
    - Séparateur décimal : le POINT. N'écris jamais de virgule ni de séparateur de milliers.
    - Pourcentage : le signe % placé après un nombre veut dire « divisé par 100 ». Écris « 15% * 240 » ou « 240 * 15 / 100 » pour « 15% de 240 ». Pour « augmenter 240 de 10% », écris « 240 * 1.1 ».
    - Multiplication toujours explicite : écris « 2 * (3 + 4) », jamais « 2(3 + 4) ».
    - Interdits : variables, unités, symboles monétaires, fonctions autres que sqrt.
    </grammar>

    <instructions>
    - Si la question ne demande aucun calcul, mets notPresent à true.
    - Si tu ne peux pas écrire d'expression respectant la grammaire ci-dessus, mets notPresent à true.
    - Résous les références à l'historique (« et fois 3 ? ») en une expression complète et autonome.
    - N'écris jamais le résultat, seulement l'expression.
    </instructions>

    <output_format>
    Réponds STRICTEMENT au format JSON suivant, sans aucun texte, explication ou phrase de remplissage :
    {
      "expression": chaîne de caractères,
      "notPresent": booléen
    }
    </output_format>
    """

    // MARK: Parsing tolérant de la sortie LLM

    /// Même stratégie que `WeatherWidgetService.parseExtraction` et
    /// `QueryClassifier.parse` — voir cette dernière pour la justification de
    /// fond : aucun des trois moteurs IA de Triva n'expose de sortie
    /// structurée fiable, donc un parsing qui ne `throw` jamais et retombe sur
    /// un repli sûr. Ici le repli sûr est `nil`, donc « pas de widget ».
    /// `notPresent: true` et une sortie illisible renvoient tous deux `nil` :
    /// la distinction n'aurait aucune conséquence observable.
    static func parseExtraction(_ rawOutput: String) -> String? {
        for candidate in jsonCandidates(from: rawOutput) {
            guard let decoded = decodeCandidate(candidate) else { continue }
            if decoded.notPresent == true { return nil }
            let expression = decoded.expression?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !expression.isEmpty { return expression }
            // Décodé mais sans expression exploitable : on tente le candidat
            // suivant, un autre bloc de la réponse peut être complet.
        }
        return nil
    }

    private struct RawExtraction: Decodable {
        let expression: String?
        let notPresent: Bool?
    }

    private static func decodeCandidate(_ candidate: String) -> RawExtraction? {
        guard let data = candidate.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(RawExtraction.self, from: data)
    }

    /// Duplication volontaire et minimale de l'extraction de candidats JSON de
    /// `WeatherWidgetService` : cette logique n'a toujours pas de foyer partagé
    /// et le périmètre de cette mission n'autorise pas à en créer un. Signalé
    /// pour un futur ticket de nettoyage, pas fait ici.
    private static func jsonCandidates(from rawOutput: String) -> [String] {
        var candidates: [String] = []
        for block in fencedBlocks(from: rawOutput) {
            candidates.append(bracesSubstring(from: block) ?? block)
        }
        if let braces = bracesSubstring(from: rawOutput) {
            candidates.append(braces)
        }
        return candidates
    }

    private static func fencedBlocks(from rawOutput: String) -> [String] {
        let components = rawOutput.components(separatedBy: "```")
        guard components.count >= 3 else { return [] }

        var blocks: [String] = []
        var index = 1
        while index < components.count {
            var block = components[index].trimmingCharacters(in: .whitespacesAndNewlines)
            if block.hasPrefix("json") {
                block.removeFirst("json".count)
            }
            blocks.append(block.trimmingCharacters(in: .whitespacesAndNewlines))
            index += 2
        }
        return blocks
    }

    private static func bracesSubstring(from rawOutput: String) -> String? {
        guard
            let firstBrace = rawOutput.firstIndex(of: "{"),
            let lastBrace = rawOutput.lastIndex(of: "}"),
            firstBrace < lastBrace
        else {
            return nil
        }
        return String(rawOutput[firstBrace...lastBrace])
    }
}
