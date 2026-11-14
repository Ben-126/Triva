//
//  SemanticRelevance.swift
//  Triva
//
//  Created by ben podrojsky on 14/11/2026.
//

import Foundation
import NaturalLanguage

/// Rapprochement de mots par le SENS, isolé derrière un protocole pour que les tests de la règle
/// (`SemanticRelevance`) soient déterministes et que le modèle système ne soit exercé que par
/// quelques tests dédiés.
nonisolated protocol SemanticWordMatching: Sendable {
    /// Parmi `terms`, ceux qui ont dans `words` un mot assez proche par le sens (distance cosinus
    /// inférieure ou égale à `maximumDistance`). Vide si la langue n'a pas de modèle de mots, ou si
    /// un terme n'est pas dans son vocabulaire : jamais d'erreur, le sens ne fait qu'AJOUTER des
    /// correspondances.
    func relatedTerms(_ terms: [String], among words: [String], language: NLLanguage, maximumDistance: Double) async -> Set<String>
}

/// Implémentation réelle : embedding de MOTS Apple (`NLEmbedding.wordEmbedding(for:)`), sur l'appareil,
/// sans réseau ni téléchargement. Acteur : la documentation d'Apple interdit d'utiliser une même
/// instance de `NLEmbedding` depuis plusieurs tâches à la fois (plantage possible), l'acteur sérialise.
/// Les langues sans modèle sont mémorisées pour ne pas retenter un chargement voué à l'échec.
actor SystemSemanticWordMatcher: SemanticWordMatching {
    /// Instance PARTAGÉE de l'app : son cache de modèles survit d'une question à l'autre (une instance par
    /// question rechargeait le modèle à chaque fois). Une seule instance, donc un seul acteur : chaque
    /// `NLEmbedding` n'est jamais touchée par deux tâches à la fois, comme l'exige la documentation d'Apple.
    static let shared = SystemSemanticWordMatcher()

    private var embeddings: [NLLanguage: NLEmbedding] = [:]
    private var languagesWithoutEmbedding: Set<NLLanguage> = []

    func relatedTerms(_ terms: [String], among words: [String], language: NLLanguage, maximumDistance: Double) -> Set<String> {
        guard let embedding = embedding(for: language) else { return [] }
        var related = Set<String>()
        // Un même mot de l'extrait ne valide qu'UN mot de la question (polysémie : « gourmands » ne doit pas
        // répondre à la fois à « gâteau » et à « chocolat »).
        var usedWords = Set<String>()
        for term in terms where embedding.contains(term) {
            let match = words.first { word in
                !usedWords.contains(word) && embedding.contains(word)
                    && embedding.distance(between: term, and: word, distanceType: .cosine) <= maximumDistance
            }
            if let match {
                usedWords.insert(match)
                related.insert(term)
            }
        }
        return related
    }

    /// Le système a-t-il un modèle de mots pour cette langue ? (Absent sur certains simulateurs : le français
    /// n'y est pas, l'anglais oui.) Les tests qui exigent le vrai modèle s'en servent pour se désactiver.
    nonisolated static func hasWordModel(for language: NLLanguage) -> Bool {
        NLEmbedding.wordEmbedding(for: language) != nil
    }

    private func embedding(for language: NLLanguage) -> NLEmbedding? {
        if let cached = embeddings[language] { return cached }
        if languagesWithoutEmbedding.contains(language) { return nil }
        guard let embedding = NLEmbedding.wordEmbedding(for: language) else {
            languagesWithoutEmbedding.insert(language)
            return nil
        }
        embeddings[language] = embedding
        return embedding
    }
}

/// Un résultat (extrait de fichier joint) parle-t-il de la question ? Par les MOTS (`LexicalRelevance`)
/// OU par le SENS (décision de Ben, 2026-11-14, mission C6).
///
/// ## Règle
/// Chaque mot plein de la question compte comme repris si l'extrait le contient (règle lexicale, inchangée)
/// OU contient un mot proche par le sens (voiture / automobile, électrique / batterie). Le résultat est
/// pertinent si `requiredMatches` mots (2, ou tous s'il y en a moins) sont repris, en mêlant les deux sources.
/// Le sens n'ajoute donc jamais qu'un mot repris de plus : il ne remplace pas l'exigence de deux mots.
///
/// ## Au moins UN mot commun (mission C6b, arbitrage provisoire de l'agent principal, à confirmer par Ben)
/// Le sens seul ne suffit jamais : un extrait n'est pertinent que s'il reprend au moins un mot plein de la
/// question par la règle lexicale ; le sens ne complète que les mots suivants (toujours 2 au total). Mesuré :
/// pour « recette gâteau chocolat », un extrait de jardinage (« Taillez les gourmands… ») donnait
/// gâteau~gourmands 0,959 et chocolat~gourmands 0,933, sous le seuil de 1,05 : un hors-sujet comptait comme
/// source fiable (le bug R1-1). Un même mot de l'extrait ne valide d'ailleurs qu'un seul mot de la question.
///
/// ## Pourquoi des mots et pas la similarité de PHRASE (`TextSimilarityScoring`)
/// Mesuré sur macOS 27 (mission C6) : la similarité de phrase française ne sépare pas le sens du hors-sujet
/// (extraits liés : 0,40 à 0,88 ; extraits sans rapport : 0,37 à 0,90, mêmes plages, même avec la question
/// réduite à ses mots pleins ou corrigée par un panel de sujets). En anglais elle sépare mieux (liés 0,23 à
/// 0,57, sans rapport -0,14 à 0,44) mais chevauche encore. C'est la limite déjà documentée dans
/// `NaturalLanguageSimilarityScorer` et `LexicalRelevance`. La distance entre MOTS, elle, sépare : paires liées
/// de 0,87 à 1,20 (voiture / automobile 0,948 ; électrique / batterie 0,941 ; photosynthèse / plantes 0,991),
/// paires sans rapport à partir de 1,31.
///
/// ## Seuil : `maximumWordDistance` = 1,05
/// Ici le dangereux est le FAUX ACCORD (un fichier hors sujet compté comme source désactive le refus du
/// hors-sujet : le bug R1-1) ; le faux rejet est sûr (« Aucune source fiable »). Balayage sur 14 couples
/// question / extraits liés et 84 extraits sans rapport, FR et EN : à 1,05, 19 extraits liés sur 28 passent
/// par le sens seul et seuls des voisins thématiques de la question passent à tort (un extrait de cuisine pour
/// « recette gâteau chocolat », un bail pour « contrat de travail préavis ») ; à 1,10 un extrait sans rapport
/// (mitochondrie pour « photosynthèse ») passe aussi ; à 1,15, 13 faux accords sur 84.
///
/// ## Question à UN seul mot plein : sens désactivé
/// Rien ne corrobore un mot isolé (« photosynthèse » a été rapprochée d'un extrait de cuisine) : la règle
/// reste lexicale.
///
/// ## Langue
/// Détectée sur la question (confiance d'au moins 0,5), sinon sur la question suivie de l'extrait. Pas de modèle
/// de mots pour cette langue, ou langue indétectable : règle lexicale seule (le repli demandé). LIMITE : un
/// extrait écrit dans une autre langue que la question n'est pas aidé par le sens.
///
/// `nonisolated` : logique pure, appelée depuis le pipeline de recherche (`@concurrent`).
nonisolated struct SemanticRelevance: Sendable {
    /// Distance cosinus maximale entre deux mots pour les dire proches par le sens. Voir « Seuil ».
    static let maximumWordDistance = 1.05
    /// Confiance minimale de la détection de langue.
    static let minimumLanguageConfidence = 0.5
    /// Mots distincts d'un extrait examinés au plus (borne le coût sur un gros fragment).
    static let maximumExcerptWords = 300

    private let lexical: LexicalRelevance
    private let matcher: any SemanticWordMatching
    private let query: String

    init(query: String, matcher: any SemanticWordMatching = SystemSemanticWordMatcher.shared) {
        self.query = query
        self.lexical = LexicalRelevance(query: query)
        self.matcher = matcher
    }

    func matches(_ result: SearXNGSearchResult) async -> Bool {
        let matched = lexical.matchedTerms(in: result)
        let required = lexical.requiredMatches
        if matched.count >= required { return true }
        // Aucun mot commun : le sens seul n'a pas le droit de valider (faux accord prouvé, voir « Au moins UN mot »).
        guard !matched.isEmpty else { return false }
        // Un seul mot plein (ou aucun) : rien ne corrobore un rapprochement par le sens.
        guard lexical.terms.count >= 2 else { return false }

        let remaining = lexical.terms.filter { !matched.contains($0) }.compactMap { lexical.surfaceForms[$0] }
        let excerpt = [result.title, result.content ?? ""].joined(separator: " ")
        guard !remaining.isEmpty, let language = Self.language(of: query, excerpt: excerpt) else { return false }

        let related = await matcher.relatedTerms(
            remaining,
            among: Self.excerptWords(excerpt),
            language: language,
            maximumDistance: Self.maximumWordDistance
        )
        return matched.count + related.count >= required
    }

    /// Mots pleins de l'extrait tels qu'écrits (minuscules, accents gardés), sans doublon, 3 lettres au moins.
    static func excerptWords(_ text: String) -> [String] {
        var seen = Set<String>()
        var words: [String] = []
        for word in text.lowercased().components(separatedBy: CharacterSet.letters.inverted) where word.count >= 3 {
            guard let token = LexicalRelevance.tokens(of: word).first, !LexicalRelevance.stopWords.contains(token),
                  seen.insert(word).inserted else { continue }
            words.append(word)
            if words.count >= maximumExcerptWords { break }
        }
        return words
    }

    /// Langue dominante de la question, sinon de la question suivie de l'extrait ; `nil` si incertaine.
    static func language(of query: String, excerpt: String) -> NLLanguage? {
        dominantLanguage(of: query) ?? dominantLanguage(of: query + "\n" + excerpt)
    }

    private static func dominantLanguage(of text: String) -> NLLanguage? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let best = recognizer.languageHypotheses(withMaximum: 1).max(by: { $0.value < $1.value }),
              best.value >= minimumLanguageConfidence else { return nil }
        return best.key
    }
}
