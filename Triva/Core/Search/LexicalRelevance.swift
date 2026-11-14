//
//  LexicalRelevance.swift
//  Triva
//
//  Created by ben podrojsky on 11/11/2026.
//

import Foundation

/// Test LEXICAL de pertinence d'une réponse de recherche (mission A2, décision 6 de Ben) : un
/// résultat parle de la question s'il en reprend les MOTS PLEINS. Sert à `WebSearchChain`, qui
/// acceptait la première réponse NON VIDE, même hors sujet (rapport T1 : « Monty Python » pour une
/// liste chaînée Python, l'aide de Google Maps pour la tour Eiffel), et à son étape SearXNG, qui
/// relance la recherche générale quand des moteurs forcés (académiques, forums) ne rendent rien
/// qui ressemble à la question (décision 5).
///
/// POURQUOI LEXICAL, ET PAS LES SCORES DE SIMILARITÉ : ces scores sont dominés par la LANGUE, pas
/// par le sens (un extrait français hors sujet passe devant un extrait anglais pertinent, et deux
/// phrases françaises sans rapport marquent déjà 0,655) ; un seuil absolu y est donc interdit
/// (limite documentée dans `SourceRanker`, arbitrage réservé à Ben). Retrouver les mots de la
/// question dans le titre, l'extrait ou l'URL ne dépend d'aucun modèle.
///
/// LA RÈGLE, VOLONTAIREMENT PERMISSIVE : un faux rejet coûte plus cher qu'un faux accord. Rejeter à
/// tort la réponse SearXNG fait descendre la chaîne vers une source plus pauvre (Wikipédia, une
/// introduction) voire PAYANTE (recherche du fournisseur cloud). Donc :
/// - un résultat passe s'il reprend `requiredMatches` mots pleins distincts : 2, ou tous s'il y en
///   a moins (« photosynthèse » seul : 1) ;
/// - une réponse passe si UN SEUL de ses résultats passe (`assess`) ;
/// - correspondance par préfixe : le plus court des deux mots, s'il fait au moins 4 lettres, ouvre
///   le plus long (« europe » / « européenne », « list » / « liste », « chaîne » / « chaînée ») ;
///   pluriel en -s/-x retiré des deux côtés ; accents et majuscules ignorés ;
/// - aucune exigence sans mot plein (« Et toi ? » ne laisse rien à chercher) ni sur une réponse
///   dont aucun résultat ne porte d'extrait : la recherche du fournisseur cloud rend des URL nues
///   (`CloudWebSearchProvider`), jugées par un modèle qui a lu la question ; les rejeter ferait
///   payer la recherche pour rien.
///
/// LIMITE ASSUMÉE (à dire honnêtement) : le test RÉDUIT le hors-sujet, il ne le supprime pas.
/// « Liste des sketches des Monty Python » reprend « liste » et « python » : elle passe pour
/// « Comment créer une liste chaînée en Python ? ». Il écarte les réponses qui ne partagent
/// presque rien avec la question, celles qui ont produit les constats T1 et Q1.
///
/// MOTS VIDES : outils grammaticaux du français et de l'anglais, mots interrogatifs, verbes de
/// consigne (« explique », « cite », « donne »…) et verbes génériques (« fonctionne », « créer »,
/// « utiliser »…). Sans eux, « Explique en détail comment fonctionne la photosynthèse » exigerait
/// de retrouver « explique », « détail » ou « fonctionne » dans l'introduction de l'article
/// Photosynthèse, qui n'en dit rien : rejet à tort de la meilleure source. Noms de démarche
/// (« processus », « étape », « méthode », « principe », « manière », « façon ») aussi, depuis la
/// mesure APRÈS de l'éval A2 : « Décrire le processus de la photosynthèse étape par étape »
/// laissait passer « Respiration », « Métabolisme » ou « Sol » sur ces deux mots seuls, sans
/// « photosynthèse », et la réponse Approfondie résumait ces articles hors sujet.
///
/// `nonisolated` : logique pure, appelée depuis la chaîne (`@concurrent`).
nonisolated struct LexicalRelevance: Sendable, Equatable {
    /// Verdict sur une réponse entière (`assess`).
    nonisolated enum Verdict: Sendable, Equatable {
        /// Un résultat reprend assez de mots, ou il n'y a rien à juger (voir la règle).
        case relevant
        /// Des résultats, mais aucun ne reprend assez de mots de la question. `bestMatchCount` :
        /// le plus grand nombre de mots repris par un même résultat, pour garder la réponse la
        /// moins éloignée quand aucune source ne passe.
        case offTopic(bestMatchCount: Int)
        /// Aucun résultat à juger.
        case empty
    }

    /// Mots pleins exigés au plus dans un même résultat. 2 et pas davantage : une question longue
    /// (« Prix d'un billet pour la tour Eiffel en 2026 ») a 5 mots pleins, qu'un extrait de 2 lignes
    /// ne reprend jamais tous ; 1 seul ferait passer « Monty Python » pour toute question sur Python.
    static let requiredMatchCap = 2

    /// Longueur minimale du mot le plus court pour une correspondance par préfixe. En dessous
    /// (« pay », « ue », « ia »), l'égalité seule : un préfixe de 2 ou 3 lettres ouvrirait trop de mots.
    static let minimumPrefixLength = 4

    /// Mots pleins de la question, normalisés, sans doublon, dans l'ordre d'apparition.
    let terms: [String]

    /// Pour chaque mot plein normalisé de `terms`, le mot tel qu'écrit dans la question (minuscules,
    /// accents gardés) : c'est lui, et non la forme normalisée, que connaît un modèle de mots
    /// (`SemanticRelevance`).
    let surfaceForms: [String: String]

    init(query: String) {
        var seen = Set<String>()
        terms = Self.tokens(of: query).filter { !Self.stopWords.contains($0) && seen.insert($0).inserted }
        var surfaces: [String: String] = [:]
        for word in query.components(separatedBy: CharacterSet.alphanumerics.inverted) {
            guard let token = Self.tokens(of: word).first, terms.contains(token), surfaces[token] == nil else { continue }
            surfaces[token] = word.lowercased()
        }
        surfaceForms = surfaces
    }

    /// Mots à retrouver dans UN même résultat.
    var requiredMatches: Int { min(Self.requiredMatchCap, terms.count) }

    /// Nombre de mots de la question repris par ce résultat (titre, extrait, URL).
    func matchCount(in result: SearXNGSearchResult) -> Int {
        matchedTerms(in: result).count
    }

    /// Mots de la question repris par ce résultat (titre, extrait, URL), dans l'ordre de `terms`.
    func matchedTerms(in result: SearXNGSearchResult) -> [String] {
        let words = Self.tokens(of: [result.title, result.content ?? "", result.url].joined(separator: " "))
        let exact = Set(words)
        let long = exact.filter { $0.count >= Self.minimumPrefixLength }
        return terms.filter { term in Self.isMatched(term, exact: exact, long: long) }
    }

    /// Ce résultat parle-t-il de la question ?
    func matches(_ result: SearXNGSearchResult) -> Bool {
        matchCount(in: result) >= requiredMatches
    }

    /// Verdict sur des résultats (une réponse entière, ou ses seuls domaines fiables en mode Fiable).
    func assess(_ results: [SearXNGSearchResult]) -> Verdict {
        guard !results.isEmpty else { return .empty }
        guard !terms.isEmpty, results.contains(where: Self.hasExcerpt) else { return .relevant }
        var best = 0
        for result in results {
            let count = matchCount(in: result)
            if count >= requiredMatches { return .relevant }
            best = max(best, count)
        }
        return .offTopic(bestMatchCount: best)
    }

    // MARK: - Mots

    private static func hasExcerpt(_ result: SearXNGSearchResult) -> Bool {
        !(result.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func isMatched(_ term: String, exact: Set<String>, long: Set<String>) -> Bool {
        if exact.contains(term) { return true }
        if term.count >= minimumPrefixLength, long.contains(where: { $0.hasPrefix(term) }) { return true }
        return long.contains { term.hasPrefix($0) }
    }

    /// Minuscules, sans accents, coupé sur tout ce qui n'est ni lettre ni chiffre (apostrophes
    /// droite et typographique, traits d'union, ponctuation), mots d'une lettre écartés (« l' »,
    /// « d' », « à »), pluriel en -s/-x retiré au-delà de 3 lettres (« tours », « prix » -> « pri »
    /// des deux côtés, donc sans effet sur l'égalité).
    static func tokens(of text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "fr"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }
            .map(singular)
    }

    /// Mots PLEINS de `text`, dans l'ordre, tels qu'écrits (casse et accents gardés) : ce que
    /// `tokens(of:)` garde, moins les mots vides de `stopWords`. Sert à écrire une requête pour un
    /// moteur qui exige TOUS les mots (Wikipédia, mission A5) : « Décrire le processus de la
    /// photosynthèse étape par étape » devient « photosynthèse », qui trouve l'article attendu là
    /// où la phrase entière n'en trouvait aucun. Même liste de mots vides que `assess`, pour que
    /// ce qu'on envoie à la source et ce qu'on attend d'elle restent cohérents. Peut renvoyer un
    /// tableau vide (« Comment faire ça ? ») : l'appelant garde alors la phrase d'origine.
    static func contentWords(of text: String) -> [String] {
        text.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { word in
                guard let token = tokens(of: word).first else { return false }
                return !stopWords.contains(token)
            }
    }

    private static func singular(_ word: String) -> String {
        guard word.count > 3, let last = word.last, last == "s" || last == "x" else { return word }
        return String(word.dropLast())
    }

    /// Mots vides, déjà NORMALISÉS (sans accents, au singulier de `singular`) : comparés aux mots
    /// de la question après `tokens(of:)`. Français et anglais, mêlés : une même liste sert aux deux
    /// langues, et un mot vide d'une langue n'est presque jamais un mot plein de l'autre.
    static let stopWords: Set<String> = Set((frenchStopWords + englishStopWords).map(singular))

    private static let frenchStopWords = """
    le la les un une des du de au aux et ou ni mais donc or car que qu qui quoi dont quand comment pourquoi combien \
    quel quelle quels quelles lequel laquelle lesquels lesquelles est sont suis es sommes etes etre ete etait etaient \
    sera seront serait seraient ai as avons avez ont avoir eu avait avaient aura auront fait faire font fais faut \
    peut peux pouvez pouvons pourrait pourrais veux veut voudrais voulez aimerais sais sait savoir connaitre ce cet \
    cette ces ca cela ceci celle celui ceux celles il ils elle elles on je tu nous vous me te se moi toi lui leur \
    leurs mon ma mes ton ta tes son sa ses notre nos votre vos en dans sur sous avec sans pour par chez vers entre \
    depuis pendant avant apres contre selon comme plus moins tres trop bien aussi encore deja tout tous toute toutes \
    autre autres meme ne pas non oui si cite citer donne donner donnez decris decrire explique expliquer expliquez \
    dis dire montre montrer trouve trouver resume resumer compare comparer definis definir parle parler raconte \
    raconter detail detaille detailler precise preciser chacun chacune chaque quelques plusieurs svp stp merci \
    aujourd hui maintenant actuellement actuel actuelle moment ici voici voila difference fonctionne fonctionner \
    fonctionnement marche marcher sert servir utiliser utilise creer cree obtenir mettre prendre definition \
    signification exemple possible processus etape methode maniere facon principe
    """.split(separator: " ").map(String.init)

    private static let englishStopWords = """
    the an of to in on at by for from with without about into over under and or but not no yes is are was were be \
    been being am do does did done have has had having can could should would will shall may might must what which \
    who whom whose when where why how this that these those there here it its me my mine you your yours we us our \
    they them their he him his she her hers tell explain describe give show find please vs versus between \
    difference compare more most less than as so very also just any some all each every other such only own same \
    then too work make create use using get mean define definition example process step method way principle
    """.split(separator: " ").map(String.init)
}
