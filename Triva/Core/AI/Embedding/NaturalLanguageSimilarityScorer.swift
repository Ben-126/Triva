//
//  NaturalLanguageSimilarityScorer.swift
//  Triva
//
//  Created by ben podrojsky on 16/09/2026.
//

import Foundation
import NaturalLanguage

/// Accès aux vecteurs de phrase du système, isolé derrière un protocole pour
/// UNE raison précise : sur toute machine de développement, le français et
/// l'anglais répondent (vérifié sur macOS 27), donc le chemin de repli du
/// scorer — son comportement le plus important — ne s'exécuterait jamais en
/// test et partirait non testé. Ce point d'injection permet de simuler
/// l'absence de modèle de façon déterministe.
///
/// Méthodes `async` alors que l'API Apple est synchrone : l'implémentation
/// réelle est un acteur (elle garde des modèles en cache), et c'est lui qui
/// impose la suspension, pas l'API sous-jacente.
nonisolated protocol SentenceVectorProviding: Sendable {
    /// `false` quand aucun modèle de phrase n'existe pour cette langue —
    /// `NLEmbedding.sentenceEmbedding(for:)` renvoie `nil` pour la majorité
    /// des langues. Recensé sur macOS 27 : répondent le français, l'anglais,
    /// l'allemand et l'italien ; renvoient `nil` l'espagnol, le portugais, le
    /// japonais, le chinois simplifié, l'arabe et le russe.
    func supportsSentenceEmbedding(for language: NLLanguage) async -> Bool

    /// Vecteur dense du texte dans l'espace de `language`, ou `nil` si le
    /// texte n'est pas embeddable (vérifié : une chaîne vide renvoie `nil`).
    func vector(for text: String, language: NLLanguage) async -> [Double]?
}

/// Implémentation réelle : acteur, parce que `NLEmbedding` est une classe
/// non-`Sendable` et que son chargement coûte cher. Le cache évite de
/// recharger un modèle à chaque lot, et l'isolation d'acteur protège ce cache
/// sans verrou manuel (même choix que `FailoverManager`).
///
/// On mémorise aussi les langues SANS modèle : sans ça, chaque recherche en
/// espagnol retenterait un chargement voué à échouer.
actor SystemSentenceVectorProvider: SentenceVectorProviding {
    private var loadedEmbeddings: [NLLanguage: NLEmbedding] = [:]
    private var languagesWithoutEmbedding: Set<NLLanguage> = []

    func supportsSentenceEmbedding(for language: NLLanguage) -> Bool {
        embedding(for: language) != nil
    }

    func vector(for text: String, language: NLLanguage) -> [Double]? {
        embedding(for: language)?.vector(for: text)
    }

    private func embedding(for language: NLLanguage) -> NLEmbedding? {
        if let cached = loadedEmbeddings[language] {
            return cached
        }
        if languagesWithoutEmbedding.contains(language) {
            return nil
        }

        guard let embedding = NLEmbedding.sentenceEmbedding(for: language) else {
            languagesWithoutEmbedding.insert(language)
            return nil
        }

        loadedEmbeddings[language] = embedding
        return embedding
    }
}

/// Implémentation native de `TextSimilarityScoring` : embedding de phrase
/// Apple (`NLEmbedding`) + cosinus, avec repli lexical documenté.
///
/// POURQUOI `NLEmbedding` ET PAS `NLContextualEmbedding` : le second est plus
/// moderne mais ses modèles sont téléchargés par-dessus le réseau
/// (`requestEmbeddingAssets`, `load(...)` échoue tant que l'asset est absent).
/// Faire dépendre le classement des sources d'un téléchargement contredirait
/// la règle "aucun appel réseau pour calculer une similarité", et le premier
/// usage de l'app se ferait sans scoring. L'en-tête d'Apple pointe d'ailleurs
/// lui-même vers `NLEmbedding` pour les tâches de similarité sémantique.
/// `NLEmbedding.sentenceEmbedding(for:)` est, lui, servi par le système sans
/// téléchargement — il renvoie simplement `nil` quand la langue n'est pas
/// couverte.
///
/// UNE SEULE LANGUE PAR LOT, et c'est structurel : les espaces vectoriels
/// n'ont pas la même dimension d'une langue à l'autre (vérifié sur macOS 27 :
/// 512 en anglais, 640 en français), donc un vecteur anglais et un vecteur
/// français ne sont pas comparables du tout — aucune passerelle n'existe
/// entre les deux modèles. On détecte donc UNE langue pour tout le lot et on
/// y embarque aussi les textes rédigés dans une autre langue.
///
/// LIMITE MESURÉE, IMPORTANTE POUR 1.3 — à lire avant de se fier à ces
/// scores sur un lot multilingue. Requête française « comment fonctionne la
/// photosynthèse », modèle français, quatre extraits :
///   FR pertinent 0,904 > FR hors-sujet 0,881 > EN hors-sujet 0,857 >
///   EN pertinent 0,842.
/// Autrement dit le classement est dominé par la LANGUE du texte, pas par son
/// sens : un extrait français hors-sujet passe devant un extrait anglais
/// pertinent. C'est le comportement attendu d'un modèle monolingue à qui l'on
/// soumet une langue qu'il n'a pas apprise — le texte étranger tombe dans une
/// région quelconque de l'espace, ni proche ni lointaine pour de bonnes
/// raisons.
///
/// On garde malgré tout ce fonctionnement, faute de mieux au niveau de cette
/// fondation : la seule alternative disponible est le repli lexical, et il
/// est ENCORE moins bon dans ce cas précis (il n'a aucun vocabulaire commun
/// entre deux langues, donc il marque souvent 0 sur l'extrait anglais
/// pertinent). Les sources FR+EN mélangées étant le cas courant de Triva
/// (décision Discover du plan), c'est un arbitrage que le propriétaire de 1.3
/// doit connaître : dans sa formule `similarity * 0,7 + positionScore * 0,3`,
/// la part `similarity` est peu fiable dès que le lot mélange les langues.
///
/// AUTRE PROPRIÉTÉ MESURÉE, tout aussi utile à 1.3 : les scores vivent dans
/// une bande haute et étroite. Deux phrases françaises sans aucun rapport
/// (« le chat dort sur le canapé » / « la mitochondrie produit de l'ATP »)
/// marquent déjà 0,655, et sur un de nos cas de test l'extrait pertinent
/// (0,8094) et le hors-sujet (0,8085) étaient quasiment à égalité. Ces scores
/// sont donc exploitables comme un ORDRE RELATIF à l'intérieur d'un même lot,
/// jamais comme un seuil absolu de pertinence : un test du genre
/// `score > 0,8` ne voudrait rien dire.
///
/// REPLI, deux niveaux volontairement distincts :
/// - panne systémique (langue indétectable, pas de modèle pour cette langue,
///   référence non embeddable) -> TOUT le lot repasse par `fallback`. Mélanger
///   deux échelles de score dans un même tableau serait pire que tout : 1.3
///   trie ces scores entre eux, un candidat calculé sur une autre échelle
///   remonterait ou tomberait arbitrairement.
/// - candidat isolé non embeddable -> `0` pour ce candidat seulement. Un texte
///   qu'aucun modèle ne sait représenter n'est pas une preuve de pertinence,
///   et le reste du tableau garde une échelle cohérente.
struct NaturalLanguageSimilarityScorer: TextSimilarityScoring {
    private let vectorProvider: any SentenceVectorProviding
    private let fallback: any TextSimilarityScoring
    private let maxCharactersPerText: Int
    private let minimumLanguageConfidence: Double
    private let maxCandidatesSampledForLanguageDetection: Int

    /// - Parameters:
    ///   - maxCharactersPerText: 1 000 caractères. Mesuré sur macOS 27 :
    ///     embedder un texte de 5 120 caractères coûte 218,7 ms contre 42,9 ms
    ///     pour ses 1 000 premiers, alors que le score final ne bouge
    ///     quasiment pas (0,8524 contre 0,8599 sur le même couple). Cinq fois
    ///     plus rapide pour une différence négligeable — ce qui compte pour
    ///     1.11, qui compare une requête à des dizaines de fragments. Ce n'est
    ///     pas une limite de l'API : l'en-tête `NLEmbedding.h` n'en documente
    ///     aucune (la propriété `maximumSequenceLength` appartient bien à
    ///     `NLContextualEmbedding`, pas à `NLEmbedding` — vérifié dans le SDK
    ///     iPhoneOS 27.0).
    ///   - minimumLanguageConfidence: en dessous, on préfère le repli lexical,
    ///     qui est agnostique à la langue, plutôt qu'un modèle choisi au
    ///     hasard. Le seuil de 0,5 sépare nettement les deux régimes, mesuré
    ///     sur macOS 27 : une vraie requête en langue naturelle est reconnue
    ///     très haut (« comment fonctionne la photosynthèse » -> fr à 0,999,
    ///     « how does photosynthesis work » -> en à 0,972), alors qu'une
    ///     requête d'un ou deux mots ne l'est pas du tout (« python » -> en à
    ///     0,422, « ok » -> polonais à 0,291). Ce sont exactement les cas où
    ///     embarquer le texte dans un modèle tiré au sort n'aurait aucun sens,
    ///     et où le repli lexical — qui, lui, matche "python" avec "python" —
    ///     fait mieux.
    ///   - maxCandidatesSampledForLanguageDetection: la détection tourne sur
    ///     la référence PLUS un échantillon de candidats, parce qu'une requête
    ///     seule est souvent trop courte pour décider alors que les extraits
    ///     donnent beaucoup de matière. Mesuré sur macOS 27 avec la requête
    ///     ambiguë « python » : seule, elle est classée « en » à 0,422 (sous
    ///     le seuil, donc repli) ; accompagnée d'un seul extrait français,
    ///     elle passe à « fr » à 0,9998 — et la valeur ne bouge plus jusqu'à
    ///     20 candidats. La borne à 8 ne sert donc PAS à améliorer la
    ///     détection, qui est déjà stable bien avant : elle plafonne le coût
    ///     de concaténation et de traitement pour un lot de 1.11 qui peut
    ///     compter des dizaines de fragments.
    init(
        vectorProvider: any SentenceVectorProviding = SystemSentenceVectorProvider(),
        fallback: any TextSimilarityScoring = LexicalSimilarityScorer(),
        maxCharactersPerText: Int = 1_000,
        minimumLanguageConfidence: Double = 0.5,
        maxCandidatesSampledForLanguageDetection: Int = 8
    ) {
        self.vectorProvider = vectorProvider
        self.fallback = fallback
        self.maxCharactersPerText = maxCharactersPerText
        self.minimumLanguageConfidence = minimumLanguageConfidence
        self.maxCandidatesSampledForLanguageDetection = maxCandidatesSampledForLanguageDetection
    }

    func similarities(of reference: String, against candidates: [String]) async -> [Double] {
        guard !candidates.isEmpty else { return [] }

        let trimmedReference = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        // Sans référence, il n'y a rien à quoi comparer : `0` partout, et on
        // évite au passage un repli lexical qui rendrait lui aussi `0`.
        guard !trimmedReference.isEmpty else {
            return Array(repeating: 0, count: candidates.count)
        }

        guard let language = detectLanguage(reference: trimmedReference, candidates: candidates),
              await vectorProvider.supportsSentenceEmbedding(for: language) else {
            return await fallback.similarities(of: reference, against: candidates)
        }

        let truncatedReference = Self.truncated(trimmedReference, to: maxCharactersPerText)
        guard let referenceVector = await vectorProvider.vector(for: truncatedReference, language: language) else {
            return await fallback.similarities(of: reference, against: candidates)
        }

        var scores: [Double] = []
        scores.reserveCapacity(candidates.count)

        for candidate in candidates {
            let trimmedCandidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedCandidate.isEmpty else {
                scores.append(0)
                continue
            }

            let truncatedCandidate = Self.truncated(trimmedCandidate, to: maxCharactersPerText)
            guard let candidateVector = await vectorProvider.vector(for: truncatedCandidate, language: language),
                  let cosine = TextVectorMath.cosine(referenceVector, candidateVector) else {
                scores.append(0)
                continue
            }

            scores.append(TextVectorMath.clampedToUnitRange(cosine))
        }

        return scores
    }

    // MARK: - Détection de langue

    /// Langue dominante du lot, ou `nil` si la détection n'est pas assez sûre.
    /// `NLLanguageRecognizer` est une classe non-`Sendable` : elle est créée,
    /// utilisée et abandonnée dans cette fonction SYNCHRONE, sans le moindre
    /// point de suspension entre-temps — elle ne traverse donc jamais de
    /// frontière d'isolation.
    private func detectLanguage(reference: String, candidates: [String]) -> NLLanguage? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(languageDetectionSample(reference: reference, candidates: candidates))

        let hypotheses = recognizer.languageHypotheses(withMaximum: 1)
        guard let best = hypotheses.max(by: { $0.value < $1.value }),
              best.value >= minimumLanguageConfidence else {
            return nil
        }

        return best.key
    }

    private func languageDetectionSample(reference: String, candidates: [String]) -> String {
        let sampledCandidates = candidates
            .prefix(maxCandidatesSampledForLanguageDetection)
            .map { Self.truncated($0, to: maxCharactersPerText) }

        return ([reference] + sampledCandidates).joined(separator: "\n")
    }

    // MARK: - Troncature

    /// Coupe au dernier blanc avant la limite plutôt qu'en plein milieu d'un
    /// mot : un mot tronqué ("TypeScr") est un mot que le modèle ne connaît
    /// pas, donc du bruit ajouté juste avant la fin du texte.
    static func truncated(_ text: String, to maxCharacters: Int) -> String {
        guard maxCharacters > 0 else { return "" }

        guard text.count > maxCharacters else { return text }

        let head = text.prefix(maxCharacters)
        guard let lastBreak = head.lastIndex(where: { $0.isWhitespace }) else {
            return String(head)
        }

        return String(head[head.startIndex..<lastBreak])
    }
}
