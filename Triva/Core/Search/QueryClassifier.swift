//
//  QueryClassifier.swift
//  Triva
//
//  Created by ben podrojsky on 14/09/2026.
//

import Foundation

/// Message d'historique propre au `Core` : indépendant de `ChatViewModel.Message`
/// (type UI avec id/isStreaming/sources, hors de propos ici). Ne garde que ce
/// dont la classification a besoin — qui a dit quoi.
nonisolated struct ClassifierChatMessage: Sendable, Equatable {
    enum Role: Sendable, Equatable {
        case user
        case assistant
    }

    let role: Role
    let content: String
}

/// Résultat de la classification : port direct du schéma zod de
/// la version web d'origine — 7 booléens indépendants (une requête peut par
/// exemple demander un widget météo ET être `skipSearch`) plus la
/// reformulation autonome de la requête, utile pour les tours de conversation
/// suivants.
nonisolated struct QueryClassification: Sendable, Equatable {
    let skipSearch: Bool
    let personalSearch: Bool
    let academicSearch: Bool
    let discussionSearch: Bool
    let showWeatherWidget: Bool
    let showStockWidget: Bool
    let showCalculationWidget: Bool
    let standaloneFollowUp: String
}

/// Action unique à laquelle une classification peut mener. Le routage
/// multi-actions réel (par ex. afficher un widget ET quand même lancer une
/// recherche complémentaire) reste le travail des tâches 1.2/1.5 : ceci est
/// seulement la décision "action principale" pure demandée par le plan pour
/// 1.1, isolée pour rester testable sans dépendre du pipeline complet.
nonisolated enum ClassifiedAction: Sendable, Equatable {
    case skip
    case weatherWidget
    case stockWidget
    case calculationWidget
    case personalSearch
    case academicSearch
    case discussionSearch
    case webSearch
}

extension QueryClassification {
    /// Ordre de priorité volontaire : les widgets sont vérifiés en premier
    /// car ils peuvent répondre seuls à la requête et court-circuiter toute
    /// recherche ; `skipSearch` vient juste après pour les cas où aucune
    /// recherche externe n'est nécessaire du tout ; viennent ensuite les
    /// sources de recherche spécialisées explicitement demandées
    /// (personnelle, académique, discussion) ; et la recherche web générale
    /// sert de valeur par défaut quand rien de plus spécifique ne s'applique.
    var primaryAction: ClassifiedAction {
        if showWeatherWidget {
            return .weatherWidget
        } else if showStockWidget {
            return .stockWidget
        } else if showCalculationWidget {
            return .calculationWidget
        } else if skipSearch {
            return .skip
        } else if personalSearch {
            return .personalSearch
        } else if academicSearch {
            return .academicSearch
        } else if discussionSearch {
            return .discussionSearch
        } else {
            return .webSearch
        }
    }
}

/// Deux variantes du prompt système envoyé au LLM, selon la capacité du
/// moteur IA actif. `.full` reprend le prompt détaillé de
/// la version web d'origine — pensé pour un modèle cloud puissant. `.concise` est une version
/// courte et directe, pensée pour un modèle local ultra-léger (MLX 0.5B/1.7B,
/// voir le catalogue de modèles du plan) qui peut se perdre dans un long bloc
/// d'instructions détaillées en langage naturel.
enum ClassifierPromptComplexity: Sendable, Equatable {
    case full
    case concise
}

/// Port natif du classifieur de la version web d'origine : construit un
/// prompt à partir de l'historique de conversation et de la requête, le fait
/// classifier par le provider IA déjà résolu, puis parse la sortie JSON
/// attendue en `QueryClassification`. Contrairement à la version web d'origine (appel
/// LLM avec schéma zod structuré et rôles système/utilisateur séparés),
/// `AIGenerating` ne connaît qu'une seule chaîne `prompt` — tout (consignes +
/// historique + requête) est donc concaténé dans un seul prompt texte, comme
/// pour `SearchOrchestrator.buildPrompt`.
struct QueryClassifier: Sendable {
    private let aiProvider: any AIGenerating
    private let maxHistoryMessages: Int
    private let promptComplexity: ClassifierPromptComplexity

    /// `maxHistoryMessages` par défaut à 8, comme la version web d'origine
    /// (elle ne garde que les 8 derniers messages de l'historique
    /// pour ne pas saturer le contexte du modèle avec une conversation longue).
    /// `promptComplexity` par défaut à `.full` : la checklist du plan (1.1)
    /// demande explicitement de prévoir un prompt adapté à la taille du
    /// modèle actif (Apple Intelligence / MLX ultra-léger / BYOK cloud) — le
    /// choix de LAQUELLE des deux variantes utiliser reste la responsabilité
    /// de l'appelant (il connaît le provider résolu, `QueryClassifier` non) ;
    /// le câblage réel de cette décision selon le provider actif viendra avec
    /// l'intégration dans le pipeline (1.2), pas avant.
    init(aiProvider: any AIGenerating, maxHistoryMessages: Int = 8, promptComplexity: ClassifierPromptComplexity = .full) {
        self.aiProvider = aiProvider
        self.maxHistoryMessages = maxHistoryMessages
        self.promptComplexity = promptComplexity
    }

    func classify(query: String, chatHistory: [ClassifierChatMessage] = []) async throws -> QueryClassification {
        let prompt = Self.buildPrompt(query: query, chatHistory: chatHistory, maxHistoryMessages: maxHistoryMessages, promptComplexity: promptComplexity)
        let rawOutput = try await aiProvider.generate(prompt: prompt)
        return Self.parse(rawOutput, fallbackQuery: query)
    }

    /// Construction du prompt isolée dans une fonction pure et testable
    /// directement (pas `private`), même principe que
    /// `SearchOrchestrator.buildPrompt`. Reste fidèle au format XML-like de
    /// la version web d'origine : historique tronqué aux `maxHistoryMessages` derniers
    /// messages dans `<conversation_history>`, requête dans `<user_query>`.
    static func buildPrompt(query: String, chatHistory: [ClassifierChatMessage], maxHistoryMessages: Int, promptComplexity: ClassifierPromptComplexity = .full) -> String {
        // `suffix(_:)` trappe sur un argument négatif ; aucun site d'appel ne
        // passe aujourd'hui de valeur négative (défaut 8, un seul appelant),
        // mais la fonction est volontairement non-`private` et donc appelable
        // directement — se protéger ici plutôt que faire confiance à l'appelant.
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

        let systemPrompt = promptComplexity == .concise ? Self.classifierSystemPromptConcise : Self.classifierSystemPrompt

        return """
        \(systemPrompt)

        <conversation_history>
        \(history)
        </conversation_history>

        <user_query>
        \(query)
        </user_query>
        """
    }

    /// Parsing volontairement infaillible (jamais de `throw`) : c'est la règle
    /// de repli demandée par le plan pour une sortie LLM ambiguë ou mal
    /// formée. En cas de doute structurel (JSON introuvable/invalide, ou clé
    /// `classification` totalement absente ou de mauvais type), on retombe
    /// sur un objet où tous les booléens sont `false` — donc `primaryAction`
    /// retombera sur `.webSearch`, jamais `.skip` : on ne risque jamais de
    /// sauter la recherche sur une sortie qu'on n'a pas su interpréter.
    /// `fallbackQuery` (la requête originale) sert alors aussi de
    /// `standaloneFollowUp`, faute de mieux.
    ///
    /// Essaie plusieurs candidats JSON dans l'ordre plutôt qu'un seul choix
    /// terminal : si le LLM place plusieurs blocs de code dans sa réponse (ou
    /// si le premier bloc trouvé n'est pas du JSON valide), on ne doit pas
    /// jeter silencieusement une classification valide présente ailleurs.
    static func parse(_ rawOutput: String, fallbackQuery: String) -> QueryClassification {
        let safeFallback = QueryClassification(
            skipSearch: false,
            personalSearch: false,
            academicSearch: false,
            discussionSearch: false,
            showWeatherWidget: false,
            showStockWidget: false,
            showCalculationWidget: false,
            standaloneFollowUp: fallbackQuery
        )

        for candidate in Self.jsonCandidates(from: rawOutput) {
            guard
                let decoded = Self.decodeCandidate(candidate),
                let classification = decoded.classification
            else { continue }

            return QueryClassification(
                skipSearch: classification.skipSearch,
                personalSearch: classification.personalSearch,
                academicSearch: classification.academicSearch,
                discussionSearch: classification.discussionSearch,
                showWeatherWidget: classification.showWeatherWidget,
                showStockWidget: classification.showStockWidget,
                showCalculationWidget: classification.showCalculationWidget,
                standaloneFollowUp: decoded.standaloneFollowUp ?? fallbackQuery
            )
        }

        return safeFallback
    }

    private static func decodeCandidate(_ candidate: String) -> RawClassifierResponse? {
        guard let data = candidate.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(RawClassifierResponse.self, from: data)
    }

    /// Le LLM respecte rarement l'instruction "aucun texte en dehors du
    /// JSON" à la lettre : il ajoute parfois un ou plusieurs blocs de code
    /// markdown, ou des phrases d'accompagnement avant/après le JSON brut.
    /// On construit une liste de candidats à essayer dans l'ordre : le
    /// contenu (réduit aux accolades s'il y en a) de chaque bloc de code
    /// rencontré, puis la sous-chaîne entre la première `{` et la dernière
    /// `}` de la sortie complète en dernier recours. Réduire chaque bloc de
    /// code aux accolades absorbe aussi les variantes de préfixe non gérées
    /// explicitement (```JSON, ```jsonc, ```json5...) : peu importe ce qui
    /// précède la première `{` à l'intérieur du bloc.
    private static func jsonCandidates(from rawOutput: String) -> [String] {
        var candidates: [String] = []
        for fencedBlock in Self.extractFencedBlocks(from: rawOutput) {
            candidates.append(Self.extractBracesSubstring(from: fencedBlock) ?? fencedBlock)
        }
        if let braces = Self.extractBracesSubstring(from: rawOutput) {
            candidates.append(braces)
        }
        return candidates
    }

    /// Renvoie le contenu de CHAQUE bloc ``` ... ``` rencontré, dans l'ordre
    /// d'apparition (les composants d'indices impairs après un split sur
    /// "```" sont alternativement à l'intérieur puis à l'extérieur des
    /// blocs).
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

    private static func extractBracesSubstring(from rawOutput: String) -> String? {
        guard
            let firstBrace = rawOutput.firstIndex(of: "{"),
            let lastBrace = rawOutput.lastIndex(of: "}"),
            firstBrace < lastBrace
        else {
            return nil
        }
        return String(rawOutput[firstBrace...lastBrace])
    }

    /// Miroir `Decodable` du JSON attendu. `init(from:)` écrit à la main
    /// plutôt que synthétisé : `classification` est protégé par `try?` pour
    /// qu'une clé absente ou de type totalement incohérent (ex. une chaîne
    /// au lieu d'un objet) fasse retomber tout le décodage sur `nil` — géré
    /// par `parse` comme repli sûr complet — sans jamais planter.
    private struct RawClassifierResponse: Decodable {
        let classification: RawClassificationFields?
        let standaloneFollowUp: String?

        private enum CodingKeys: String, CodingKey {
            case classification
            case standaloneFollowUp
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.classification = try? container.decodeIfPresent(RawClassificationFields.self, forKey: .classification)
            self.standaloneFollowUp = try? container.decodeIfPresent(String.self, forKey: .standaloneFollowUp)
        }
    }

    /// Distingue volontairement deux cas différents pour chaque champ :
    /// ABSENT (le modèle a juste omis le champ — repli individuel à `false`,
    /// légitime) contre PRÉSENT MAIS DE MAUVAIS TYPE (ex. `"skipSearch":
    /// "oui"` — signal que la sortie n'a pas été comprise du tout). Un champ
    /// absent utilise `decodeIfPresent(...) ?? false` SANS `try?` autour :
    /// `decodeIfPresent` renvoie déjà `nil` sans lever pour une clé absente,
    /// mais lève bien une erreur de type pour une clé présente au mauvais
    /// type — cette erreur remonte alors jusqu'à `RawClassifierResponse`, où
    /// le `try?` sur `classification` tout entier convertit ce cas en `nil`,
    /// donc en repli sûr complet (`parse` ne retourne alors jamais une
    /// classification partiellement décodée où `skipSearch` serait resté
    /// `true` pendant qu'un autre champ, de type invalide, serait retombé
    /// seul à `false`).
    private struct RawClassificationFields: Decodable {
        let skipSearch: Bool
        let personalSearch: Bool
        let academicSearch: Bool
        let discussionSearch: Bool
        let showWeatherWidget: Bool
        let showStockWidget: Bool
        let showCalculationWidget: Bool

        private enum CodingKeys: String, CodingKey {
            case skipSearch
            case personalSearch
            case academicSearch
            case discussionSearch
            case showWeatherWidget
            case showStockWidget
            case showCalculationWidget
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.skipSearch = try container.decodeIfPresent(Bool.self, forKey: .skipSearch) ?? false
            self.personalSearch = try container.decodeIfPresent(Bool.self, forKey: .personalSearch) ?? false
            self.academicSearch = try container.decodeIfPresent(Bool.self, forKey: .academicSearch) ?? false
            self.discussionSearch = try container.decodeIfPresent(Bool.self, forKey: .discussionSearch) ?? false
            self.showWeatherWidget = try container.decodeIfPresent(Bool.self, forKey: .showWeatherWidget) ?? false
            self.showStockWidget = try container.decodeIfPresent(Bool.self, forKey: .showStockWidget) ?? false
            self.showCalculationWidget = try container.decodeIfPresent(Bool.self, forKey: .showCalculationWidget) ?? false
        }
    }

    /// Prompt détaillé, port de la version web d'origine. Écarts de la mission A2 :
    /// `academicSearch` n'est plus déclenché par « des citations » (décision 4
    /// de Ben : « Cite les 27 pays de l'UE » partait sur arXiv, constat Q1),
    /// et `discussionSearch` reçoit la ligne proposée et mesurée par T2
    /// (décision 1 : « Quelles sont les différences entre JavaScript et
    /// TypeScript ? » était classée discussion 3 fois sur 3, donc envoyée sur
    /// Reddit).
    ///
    /// Mission A5 (décision de Ben du 2026-11-11) : `skipSearch` suit la MÊME
    /// liste fermée que le prompt concis (salutation, écriture ou
    /// reformulation, calcul, météo répondue par le widget). Le `skipSearch`
    /// de la version web d'origine (« connaissance générale ») faisait sauter la recherche à
    /// gpt-6-luna pour 6 questions de fait sur 8 (mesure A2, confirmée par
    /// A5 sur les 12 questions de A2 : 6 sur 8 avant, 0 sur 8 après, un seul
    /// essai par question) ; la réponse venait alors de tête, sans source.
    /// Les calculs, la météo et les écritures restent sautés (3 sur 3). Un
    /// écart assumé avec la version web d'origine, qui garde l'ancienne règle.
    private static let classifierSystemPrompt: String = """
    <role>
    Tu es un système d'IA avancé chargé d'analyser la requête de l'utilisateur et l'historique de la conversation pour déterminer la classification la plus appropriée de l'opération de recherche.
    Une historique de conversation détaillée et une requête utilisateur te seront fournies, et tu dois classifier la requête selon les règles et les définitions de labels ci-dessous. Tu dois aussi générer une reformulation autonome et indépendante du contexte de la question de suivi.
    </role>

    <labels>
    1. skipSearch (booléen) : Détermine si la requête peut être répondue sans effectuer de recherche. La liste ci-dessous est FERMÉE.
       - Mets-le à true SEULEMENT dans ces quatre cas : une salutation ; une tâche d'écriture ou de reformulation (poème, e-mail, traduction, résumé de la conversation) ; un calcul ou une conversion ; la météo d'un lieu précis, quand un widget météo la répond entièrement.
       - Mets-le à false pour toute question de fait (chiffre, date, prix, personne, lieu, définition, explication, comparaison), MÊME SI TU CONNAIS LA RÉPONSE : une question de fait déclenche toujours la recherche.
       - Mets-le à false si la requête nécessite une information à jour, des détails spécifiques, ou un contexte non déductible de la conversation.
       - METS TOUJOURS SKIPSEARCH À FALSE SI TU ES INCERTAIN, SI LA REQUÊTE EST AMBIGUË, OU SI TU N'ES PAS SÛR.
    2. personalSearch (booléen) : Détermine si la requête nécessite de chercher dans les documents importés par l'utilisateur.
       - Mets-le à true si la requête référence explicitement ou implique le besoin d'accéder à des documents importés par l'utilisateur, par exemple "Détermine les points clés du document que j'ai importé sur..." ou "Qui est l'auteur ?", "Résume le contenu du document".
       - Mets-le à false si la requête ne référence pas de documents importés ou si l'information peut être obtenue par une recherche web générale.
       - METS TOUJOURS PERSONALSEARCH À FALSE SI TU ES INCERTAIN OU SI LA REQUÊTE EST AMBIGUË. ET METS AUSSI SKIPSEARCH À FALSE DANS CE CAS.
    3. academicSearch (booléen) : Évalue si la requête nécessite de chercher dans des bases académiques ou des articles scientifiques.
       - Mets-le à true seulement si la requête demande explicitement des articles scientifiques, des études ou des publications de recherche, par exemple "Trouve des études récentes sur...", "Que dit la recherche la plus récente sur..." ou "Donne-moi des articles scientifiques sur...".
       - Le verbe "citer" ("Cite les pays de...") demande une liste, pas des sources académiques : mets-le alors à false, comme pour une simple demande d'explication détaillée.
       - Mets-le à false si la requête peut être répondue par une recherche web générale ou ne demande pas spécifiquement de sources académiques.
    4. discussionSearch (booléen) : Évalue si la requête nécessite de chercher dans des forums, des espaces de discussion, ou des plateformes de questions-réponses communautaires.
       - Mets-le à true si la requête cherche des opinions, des expériences personnelles, des conseils communautaires, ou des discussions, par exemple "Que pensent les gens de...", "Y a-t-il des discussions sur...", ou "Quels sont les problèmes courants rencontrés par...".
       - Mets-le à true si l'utilisateur demande des avis ou retours d'utilisateurs sur des produits, services, ou expériences.
       - Mets-le à false si la requête peut être répondue par une recherche web générale ou ne demande pas spécifiquement des plateformes de discussion.
       - Mets-le à false pour une question factuelle, une définition, une explication ou une comparaison technique, par exemple "Quelles sont les différences entre X et Y ?" : ce n'est pas une demande d'avis.
    5. showWeatherWidget (booléen) : Décide si afficher un widget météo répondrait suffisamment à la requête.
       - Mets-le à true si la requête concerne spécifiquement les conditions météo actuelles, des prévisions, ou toute information liée à la météo pour un lieu donné.
       - Mets-le à true pour des requêtes comme "Quel temps fait-il à [Lieu] ?" ou "Va-t-il pleuvoir demain à [Lieu] ?" ou "Montre-moi la météo" (ici, il s'agit de la météo du lieu actuel de l'utilisateur).
       - Si cela répond entièrement à la requête sans recherche supplémentaire, mets aussi skipSearch à true (cas météo de la liste fermée).
    6. showStockWidget (booléen) : Détermine si afficher un widget boursier répondrait suffisamment à la demande.
       - Mets-le à true si la requête concerne spécifiquement le cours actuel d'une action ou des informations boursières pour des entreprises précises. Ne jamais l'utiliser pour une analyse de marché ou des actualités boursières.
       - Mets-le à true pour des requêtes comme "Quel est le cours de l'action [Entreprise] ?" ou "Comment se comporte [Action] aujourd'hui ?" ou "Montre-moi les cours des actions" (ici, il s'agit des actions qui intéressent l'utilisateur).
       - Laisse skipSearch à false : un cours de bourse n'est pas dans la liste fermée de skipSearch.
    7. showCalculationWidget (booléen) : Décide si afficher un widget de calcul répondrait à la requête.
       - Mets-le à true si la requête implique des calculs mathématiques, des conversions, ou toute tâche de calcul.
       - Mets-le à true pour des requêtes comme "Combien font 25% de 80 ?" ou "Convertis 100 USD en EUR" ou "Calcule la racine carrée de 256" ou "Combien font 2 * 3 + 5 ?" ou d'autres expressions mathématiques.
       - Si cela répond entièrement à la requête sans recherche supplémentaire, mets aussi skipSearch à true (cas calcul de la liste fermée).
    </labels>

    <standalone_followup>
    Pour la reformulation autonome, tu dois générer une reformulation autonome et indépendante du contexte de la requête de l'utilisateur.
    Il s'agit de reformuler la requête de l'utilisateur de sorte qu'elle puisse être comprise sans aucun contexte préalable de la conversation.
    Par exemple, si la conversation porte sur les voitures et que l'utilisateur dit "Comment ça marche", la reformulation autonome devrait être "Comment fonctionnent les voitures ?".

    Ne conserve pas d'information excessive ni tout ce qui a été discuté avant, reformule seulement la dernière requête de l'utilisateur de façon autonome.
    La reformulation autonome doit être concise et aller droit au but.
    </standalone_followup>

    <output_format>
    Tu dois répondre STRICTEMENT au format JSON suivant, sans aucun texte, explication ou phrase de remplissage supplémentaire :
    {
      "classification": {
        "skipSearch": booléen,
        "personalSearch": booléen,
        "academicSearch": booléen,
        "discussionSearch": booléen,
        "showWeatherWidget": booléen,
        "showStockWidget": booléen,
        "showCalculationWidget": booléen
      },
      "standaloneFollowUp": chaîne de caractères
    }
    </output_format>
    """

    /// Version courte du prompt système, pour un modèle local ultra-léger :
    /// les règles détaillées et les nombreux exemples du prompt `.full`
    /// (~50 lignes) risquent de diluer l'attention d'un modèle à 0,5-1,7
    /// milliard de paramètres. Ici, une seule ligne d'intention par champ,
    /// directement dans la structure JSON attendue plutôt qu'en labels
    /// séparés — même schéma de sortie, mêmes noms de champs, pour que
    /// `parse` reste identique quelle que soit la variante utilisée.
    ///
    /// Mission A2 (décisions 2 et 4 de Ben). `skipSearch` : la liste FERMÉE
    /// de ce qui se passe de recherche remplace « connaissance générale », qui
    /// faisait répondre de tête « 330 pieds » à la hauteur de la tour Eiffel
    /// (constat Q1) ; les faits passent par la recherche. La liste est celle
    /// de Ben, au mot près : salutation, écriture ou reformulation, calcul. La
    /// météo, retirée par A2, y est REMISE par A5 : Ben a validé la liste avec
    /// « météo répondue par le widget » (sans elle, la recherche web s'ajoutait
    /// au widget et le rédacteur citait à tort l'article Wikipédia de Lyon, éval
    /// A2). `SearchRoute.webUnlessWeatherAnswered` saute alors le web quand le
    /// widget répond. Le prompt `.full` suit la même liste (mission A5).
    /// `academicSearch` : ni « citations » ni « recherches » ne déclenchent
    /// plus la recherche académique. « Cite les 27 pays de l'UE » partait sur
    /// arXiv (constat Q1), « Explique en détail… » sur OpenAlex (éval A2) ;
    /// et « fais des recherches sur X » veut dire « cherche X ».
    private static let classifierSystemPromptConcise: String = """
    Analyse la requête ci-dessous (et l'historique de conversation si utile) et réponds UNIQUEMENT avec ce JSON, sans aucun texte autour :
    {
      "classification": {
        "skipSearch": true SEULEMENT pour une salutation, une écriture ou reformulation (poème, e-mail, traduction, résumé de la conversation), un calcul ou la météo d'un lieu précis (un widget y répond) ; false pour toute question de fait (chiffre, date, prix, personne, lieu, définition, explication), même si tu connais la réponse, et false si incertain,
        "personalSearch": true seulement si la requête parle d'un document importé par l'utilisateur, sinon false,
        "academicSearch": true seulement si la requête demande explicitement des articles scientifiques ou des études (« Cite… » demande une liste : false), sinon false,
        "discussionSearch": true seulement si la requête demande des avis/opinions/discussions communautaires, sinon false,
        "showWeatherWidget": true seulement si la requête porte sur la météo d'un lieu précis, sinon false,
        "showStockWidget": true seulement si la requête porte sur le cours d'une action précise (jamais pour une analyse de marché), sinon false,
        "showCalculationWidget": true seulement si la requête est un calcul ou une conversion, sinon false
      },
      "standaloneFollowUp": "reformulation courte et autonome de la requête, compréhensible sans le reste de la conversation"
    }
    Si tu n'es pas sûr d'un champ, mets-le à false.
    """
}
