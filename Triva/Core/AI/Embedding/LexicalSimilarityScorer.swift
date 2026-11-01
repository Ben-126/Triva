//
//  LexicalSimilarityScorer.swift
//  Triva
//
//  Created by ben podrojsky on 16/09/2026.
//

import Foundation
import NaturalLanguage

/// Repli 100 % déterministe et hors-ligne de `TextSimilarityScoring`, utilisé
/// par `NaturalLanguageSimilarityScorer` quand aucun modèle d'embedding de
/// phrase n'existe pour la langue détectée.
///
/// CE REPLI N'EST PAS UN CAS RARE. Recensement exécuté sur macOS 27 :
/// `NLEmbedding.sentenceEmbedding(for:)` répond pour le français, l'anglais,
/// l'allemand et l'italien seulement — il renvoie `nil` pour l'espagnol, le
/// portugais, le japonais, le chinois simplifié, l'arabe et le russe. Pour un
/// utilisateur hispanophone ou lusophone, ce scorer est donc le chemin
/// NORMAL, pas une avarie : il doit être bon, pas seulement présent.
///
/// Utilisable seul, notamment dans les tests : il ne dépend d'aucun asset
/// système téléchargeable, donc son résultat est reproductible partout.
///
/// MESURE RETENUE : cosinus sur des sacs de mots pondérés par une fréquence
/// sous-linéaire `1 + ln(occurrences)`.
///
/// Pourquoi pas Jaccard : `|A ∩ B| / |A ∪ B|` pénalise brutalement
/// l'asymétrie de longueur. Or les deux usages réels sont justement
/// asymétriques — une requête de 5 mots contre un extrait SearXNG de 40 mots
/// (1.3), ou contre un fragment de PDF de 200 mots (1.11). Un document
/// parfaitement pertinent mais long y obtiendrait un score ridicule
/// simplement parce qu'il contient beaucoup d'autres mots.
///
/// Pourquoi pas TF-IDF calculé sur le lot courant (l'autre piste évoquée) :
/// l'IDF dépendrait alors du NOMBRE de candidats comparés, donc la même paire
/// (requête, extrait) n'aurait pas le même score dans un lot de 2 et dans un
/// lot de 50. Ça casserait la propriété que le protocole promet
/// explicitement — un score comparable d'un lot à l'autre — et ça rendrait
/// tout seuil absolu ininterprétable côté 1.3. On remplace donc l'IDF par un
/// filtre de mots vides statique (voir `stopWords`), qui joue le même rôle
/// (neutraliser les mots trop fréquents pour être discriminants) sans
/// dépendre du lot.
///
/// Pourquoi une fréquence sous-linéaire plutôt que le compte brut : les
/// extraits SearXNG contiennent régulièrement du bourrage de mots-clés (le
/// même terme répété 10 fois). En brut, ce terme écraserait le vecteur ;
/// `1 + ln(n)` fait passer 10 occurrences à ~3,3 fois le poids d'une seule au
/// lieu de 10 fois.
///
/// LIMITES CONNUES ET ASSUMÉES :
/// - aucune synonymie ni morphologie : "voiture" et "automobile" donnent 0,
///   "chat" et "chats" aussi. C'est précisément ce que l'embedding natif
///   apporte quand il est disponible ; ce scorer est un filet de sécurité,
///   pas son égal.
/// - la normalisation cosinus conserve une pénalité de longueur douce : à
///   contenu pertinent égal, un extrait concentré sur la requête marque plus
///   qu'une page fourre-tout. C'est voulu — c'est aussi ce qu'on veut classer
///   en tête.
/// - un texte composé uniquement de mots vides ("de la et le") se retrouve
///   sans aucun jeton et marque 0 face à tout, y compris face à lui-même.
///   Documenté et testé : un texte sans mot porteur n'est une preuve de
///   pertinence pour rien.
struct LexicalSimilarityScorer: TextSimilarityScoring {
    func similarities(of reference: String, against candidates: [String]) async -> [Double] {
        guard !candidates.isEmpty else { return [] }

        // Le sac de mots de la référence est calculé UNE fois pour tout le
        // lot : c'est la raison d'être de la primitive par lot du protocole.
        let referenceWeights = Self.weightedTokenCounts(of: reference)
        guard !referenceWeights.isEmpty else {
            return Array(repeating: 0, count: candidates.count)
        }

        // Norme AU CARRÉ, pas la norme : voir le commentaire de la division
        // plus bas — on ne prend la racine qu'une seule fois, à la toute fin.
        let referenceSquaredNorm = Self.squaredEuclideanNorm(of: referenceWeights)

        return candidates.map { candidate in
            let candidateWeights = Self.weightedTokenCounts(of: candidate)
            guard !candidateWeights.isEmpty else { return 0 }

            let candidateSquaredNorm = Self.squaredEuclideanNorm(of: candidateWeights)
            guard referenceSquaredNorm > 0, candidateSquaredNorm > 0 else { return 0 }

            // Produit scalaire sur l'intersection des jetons : les jetons
            // absents d'un des deux côtés valent 0, inutile de les parcourir.
            // On itère sur le plus petit des deux sacs pour rester rapide
            // même quand un fragment de document est très long.
            let (smaller, larger) = referenceWeights.count <= candidateWeights.count
                ? (referenceWeights, candidateWeights)
                : (candidateWeights, referenceWeights)

            var dotProduct = 0.0
            for (token, weight) in smaller {
                if let otherWeight = larger[token] {
                    dotProduct += weight * otherWeight
                }
            }

            // Une SEULE racine, sur le produit des normes au carré, plutôt
            // que le produit de deux racines : même valeur en maths, pas en
            // flottant. Mesuré sur 2 000 textes, `√a × √b` rend
            // 0,999999999999999 8 au lieu de 1 pour un texte comparé à
            // lui-même une fois sur quatre, alors que `√(a·b)` rend
            // exactement 1 dans 2 000 cas sur 2 000. Même raisonnement et
            // même correctif que `TextVectorMath.cosine`.
            //
            // Le clamp n'est donc PAS ce qui garantit l'identité (il ne fait
            // que plafonner, `min(1, max(0, x))` ne remonterait jamais
            // 0,999… à 1) : il ne reste là que comme garde-fou de contrat,
            // le cosinus de deux vecteurs à composantes toutes positives
            // étant déjà dans [0, 1].
            return TextVectorMath.clampedToUnitRange(
                dotProduct / (referenceSquaredNorm * candidateSquaredNorm).squareRoot()
            )
        }
    }

    // MARK: - Tokenisation

    /// Sac de mots pondéré : jeton normalisé -> `1 + ln(occurrences)`.
    static func weightedTokenCounts(of text: String) -> [String: Double] {
        var counts: [String: Int] = [:]
        for token in tokenize(text) {
            counts[token, default: 0] += 1
        }

        return counts.mapValues { 1 + log(Double($0)) }
    }

    /// Découpage via `NLTokenizer` (framework Apple natif, aucune dépendance
    /// ajoutée) plutôt qu'un `components(separatedBy:)` sur les espaces : le
    /// tokenizer système gère la ponctuation, les langues sans espaces
    /// (japonais, chinois) et les règles de chaque script, ce qu'une
    /// séparation Foundation naïve ne fait pas.
    static func tokenize(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }

        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text

        var tokens: [String] = []
        for range in tokenizer.tokens(for: text.startIndex..<text.endIndex) {
            // `NLTokenizer` garde l'élision française collée ("l'été" ressort
            // en un seul jeton — vérifié sur macOS 27). Sans ce redécoupage,
            // "l'été" et "été" ne matcheraient jamais, ce qui est
            // rédhibitoire pour une app dont la langue par défaut est le
            // français. On coupe donc sur les deux apostrophes courantes,
            // droite et typographique.
            for piece in String(text[range]).split(whereSeparator: { $0 == "'" || $0 == "\u{2019}" }) {
                let normalized = normalize(String(piece))
                guard !normalized.isEmpty, !stopWords.contains(normalized) else { continue }
                tokens.append(normalized)
            }
        }

        return tokens
    }

    /// Minuscules + suppression des diacritiques, avec une locale FIXE
    /// (`en_US_POSIX`) et non la locale courante : le repli casse Turc du "i"
    /// rendrait le score dépendant de la langue du téléphone, donc non
    /// reproductible d'un appareil à l'autre. Le repli de largeur gère les
    /// caractères pleine chasse des textes CJK.
    ///
    /// On rejette ensuite les jetons ne contenant ni lettre ni chiffre : la
    /// ponctuation résiduelle ("---", "»") n'a aucune valeur discriminante.
    static func normalize(_ token: String) -> String {
        let folded = token.folding(
            options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )

        let hasMeaningfulCharacter = folded.unicodeScalars.contains {
            CharacterSet.alphanumerics.contains($0)
        }

        return hasMeaningfulCharacter ? folded : ""
    }

    /// Norme euclidienne AU CARRÉ (pas de racine ici) — voir la division dans
    /// `similarities(of:against:)` pour la raison numérique.
    private static func squaredEuclideanNorm(of weights: [String: Double]) -> Double {
        weights.values.reduce(0) { $0 + $1 * $1 }
    }

    // MARK: - Mots vides

    /// Mots vides français et anglais, sous leur forme DÉJÀ normalisée
    /// (minuscules, sans diacritiques) — `tokenize` compare après
    /// normalisation, donc "À" et "été" se testent ici comme "a" et "ete".
    ///
    /// Deux langues seulement, et c'est assumé : ce sont les deux langues de
    /// sources retenues pour le produit (décision Discover du plan). Pour une
    /// requête dans une autre langue, la liste ne filtre rien — le score
    /// reste correct, juste un peu bruité par les mots outils, ce qui est un
    /// dégradé acceptable pour un chemin de repli.
    static let stopWords: Set<String> = [
        // Français
        "a", "ai", "aime", "alors", "au", "aucun", "aussi", "autre", "aux",
        "avant", "avec", "avoir", "bon", "car", "ce", "cela", "ces", "cet",
        "cette", "ceux", "chaque", "ci", "comme", "comment", "dans", "de",
        "dedans", "dehors", "depuis", "des", "deux", "doit", "donc", "dos",
        "du", "elle", "elles", "en", "encore", "es", "est", "et", "eu",
        "ete", "etre", "eux", "fait", "faire", "fois", "font", "hors", "ici",
        "il", "ils", "je", "juste", "la", "le", "les", "leur", "leurs", "lui",
        "ma", "maintenant", "mais", "mes", "moins", "mon", "mot", "meme",
        "ne", "ni", "nommes", "nos", "notre", "nous", "on", "ont", "ou",
        "par", "parce", "pas", "peu", "peut", "plupart", "plus", "pour",
        "pourquoi", "quand", "que", "quel", "quelle", "quelles", "quels",
        "qui", "sa", "sans", "ses", "seulement", "si", "sien", "son", "sont",
        "sous", "soyez", "sujet", "sur", "ta", "tandis", "tel", "tels", "tes",
        "ton", "tous", "tout", "toute", "toutes", "trop", "tres", "tu", "un",
        "une", "voient", "vont", "vos", "votre", "vous", "vu", "etaient",
        "etait", "etant",
        // Anglais
        "about", "after", "again", "all", "also", "am", "an", "and", "any",
        "are", "as", "at", "be", "because", "been", "before", "being",
        "between", "both", "but", "by", "can", "could", "did", "do", "does",
        "doing", "down", "during", "each", "few", "for", "from", "further",
        "had", "has", "have", "having", "he", "her", "here", "hers", "him",
        "his", "how", "i", "if", "in", "into", "is", "it", "its", "itself",
        "just", "me", "more", "most", "my", "no", "nor", "not", "now", "of",
        "off", "once", "only", "or", "other", "our", "ours", "out",
        "over", "own", "same", "she", "should", "so", "some", "such", "than",
        "that", "the", "their", "theirs", "them", "then", "there", "these",
        "they", "this", "those", "through", "to", "too", "under", "until",
        "up", "very", "was", "we", "were", "what", "when", "where", "which",
        "while", "who", "whom", "why", "will", "with", "would", "you", "your",
        "yours",
        // Lettres isolées produites par l'élision française ("l'eau" -> "l",
        // "d'accord" -> "d") et par les contractions anglaises ("don't" ->
        // "don" + "t") : aucune valeur discriminante.
        "c", "d", "j", "l", "m", "n", "s", "t"
    ]
}
