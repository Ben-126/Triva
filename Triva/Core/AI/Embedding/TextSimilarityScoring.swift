//
//  TextSimilarityScoring.swift
//  Triva
//
//  Created by ben podrojsky on 16/09/2026.
//

import Foundation

/// Socle de similarité sémantique (fondation F1), remplaçant natif de
/// `computeSimilarity(queryEmbedding, chunkEmbedding)` du web
/// (`src/lib/utils/computeSimilarity.ts`), utilisé là-bas par
/// `baseSearch.ts` (scoring des sources, futur 1.3) et `uploadsSearch.ts`
/// (recherche dans les fichiers joints, futur 1.11).
///
/// DIVERGENCE STRUCTURELLE assumée vis-à-vis du web : côté Vane, un modèle
/// d'embedding distant (`BaseEmbedding.embedText`) transforme le texte en
/// vecteur, puis le cosinus est calculé à part. Triva n'a pas de backend et
/// ne doit jamais payer un appel réseau pour mesurer une similarité (voir
/// CLAUDE.md) : on expose donc directement le SCORE, pas le vecteur. Ça
/// laisse les implémentations libres de leur représentation interne —
/// vecteur `NaturalLanguage` pour `NaturalLanguageSimilarityScorer`, sacs de
/// mots pondérés pour `LexicalSimilarityScorer` — et ça évite d'imposer une
/// dimension commune à des espaces qui n'en partagent aucune (vérifié :
/// l'embedding de phrase Apple fait 512 dimensions en anglais et 640 en
/// français, deux vecteurs non comparables).
///
/// `nonisolated` + `Sendable` : le calcul est lourd en CPU et sera appelé
/// depuis le pipeline de recherche hors du main actor (même modèle que
/// `SearXNGSearching`, voir `SearXNGClient.swift`).
nonisolated protocol TextSimilarityScoring: Sendable {
    /// PRIMITIVE du protocole, volontairement par lot plutôt que par paire :
    /// c'est le vrai usage (1.3 compare une requête à ~10-20 résultats, 1.11
    /// à des dizaines de fragments de document). Une API purement pairwise
    /// forcerait à recalculer l'embedding de la référence à chaque candidat —
    /// mesuré sur macOS 27, embedder une requête de 41 caractères coûte
    /// 2,65 ms, soit ~265 ms jetés pour 100 fragments, uniquement pour
    /// recalculer 100 fois le même vecteur.
    ///
    /// Contrat : le tableau renvoyé a TOUJOURS exactement `candidates.count`
    /// éléments, dans le même ordre, chacun dans `[0, 1]`. Aucune
    /// implémentation ne `throw` ni ne renvoie de tableau partiel : un
    /// candidat impossible à évaluer vaut `0` (voir chaque implémentation
    /// pour le détail du repli).
    func similarities(of reference: String, against candidates: [String]) async -> [Double]

    /// Confort pour les comparaisons ponctuelles. Implémentation par défaut
    /// fournie plus bas ; une implémentation peut la surcharger si elle a un
    /// chemin pairwise plus direct.
    func similarity(between a: String, and b: String) async -> Double
}

extension TextSimilarityScoring {
    /// Par défaut, une comparaison de paire est un lot d'un seul candidat.
    /// Conséquence VOULUE : le score d'une paire ne dépend jamais de la
    /// taille du lot dans lequel on la calcule — c'est ce qui permet au
    /// futur 1.3 de comparer des scores entre deux recherches différentes.
    /// Les deux implémentations respectent cette propriété (aucune
    /// pondération de type IDF calculée sur le lot courant).
    nonisolated func similarity(between a: String, and b: String) async -> Double {
        await similarities(of: a, against: [b]).first ?? 0
    }

    /// Classement décroissant des candidats, tronqué à `limit`. Pensé pour
    /// 1.11 (retenir les N meilleurs fragments d'un document) ; 1.3 utilisera
    /// plutôt `similarities` brut, son classement final mêlant la similarité
    /// à d'autres facteurs (position, multiplicateur de domaine).
    ///
    /// Tri STABLE en cas d'égalité : à score identique, l'ordre d'origine est
    /// conservé (départage par index croissant). `sorted(by:)` n'est pas
    /// garanti stable en Swift — d'où le départage explicite, sans quoi deux
    /// exécutions pourraient produire deux classements différents pour la
    /// même entrée.
    nonisolated func rankedMatches(
        of reference: String,
        against candidates: [String],
        limit: Int
    ) async -> [ScoredTextMatch] {
        guard limit > 0, !candidates.isEmpty else { return [] }

        let scores = await similarities(of: reference, against: candidates)
        // Lecture indexée plutôt qu'un `zip` : un `zip` tronquerait
        // silencieusement la liste si une implémentation violait le contrat
        // "un score par candidat" — ici le candidat reste présent, avec un
        // score `0` visible.
        let matches = candidates.indices.map { index in
            ScoredTextMatch(
                index: index,
                text: candidates[index],
                score: index < scores.count ? scores[index] : 0
            )
        }

        let ranked = matches.sorted { lhs, rhs in
            lhs.score == rhs.score ? lhs.index < rhs.index : lhs.score > rhs.score
        }

        return Array(ranked.prefix(limit))
    }
}

/// Un candidat classé : on conserve `index` pour permettre à l'appelant de
/// retrouver l'objet d'origine (un `SearXNGSearchResult`, un fragment de PDF)
/// sans avoir à ré-identifier le texte par son contenu.
struct ScoredTextMatch: Sendable, Equatable {
    let index: Int
    let text: String
    let score: Double
}

/// Boîte à outils vectorielle partagée par les implémentations. Isolée ici
/// pour être testable seule, sans modèle d'embedding ni tokenizer.
enum TextVectorMath {
    /// Cosinus de deux vecteurs denses — port fidèle de `computeSimilarity.ts`
    /// (web), à une différence près : le TypeScript `throw` quand les
    /// longueurs diffèrent, ici on renvoie `nil`.
    ///
    /// Ce `nil` est PORTEUR, pas défensif : les modèles de phrase d'Apple
    /// n'ont pas la même dimension d'une langue à l'autre (vérifié : 512 en
    /// anglais, 640 en français). Comparer un vecteur anglais à un vecteur
    /// français est une erreur de programmation silencieuse qui produirait un
    /// score arbitraire ; `nil` la transforme en score `0` explicite et
    /// documenté côté appelant, sans jamais faire planter une recherche.
    ///
    /// Vecteur nul (norme 0) -> `0`, exactement comme le web (`if (normA === 0
    /// || normB === 0) return 0`) : un vecteur nul n'a pas de direction, donc
    /// aucun angle à mesurer.
    ///
    /// Valeur de retour dans `[-1, 1]` : c'est bien un cosinus brut, pas un
    /// score de pertinence. Passer par `clampedToUnitRange` pour obtenir le
    /// `[0, 1]` exigé par `TextSimilarityScoring`.
    nonisolated static func cosine(_ a: [Double], _ b: [Double]) -> Double? {
        guard a.count == b.count, !a.isEmpty else { return nil }

        var dotProduct = 0.0
        var squaredNormA = 0.0
        var squaredNormB = 0.0

        for index in a.indices {
            dotProduct += a[index] * b[index]
            squaredNormA += a[index] * a[index]
            squaredNormB += b[index] * b[index]
        }

        guard squaredNormA > 0, squaredNormB > 0 else { return 0 }

        // DIVISION PAR `√(‖a‖²·‖b‖²)` ET NON PAR `√‖a‖² × √‖b‖²` : les deux
        // formes sont équivalentes en maths, pas en flottant. Mesuré sur
        // 2 000 vecteurs tirés au hasard, la seconde rend 0,999999999999999 8
        // au lieu de 1 pour un vecteur comparé à lui-même dans un cas sur
        // deux (deux racines arrondies, puis multipliées), là où la première
        // rend exactement 1 dans 2 000 cas sur 2 000 — quand les deux normes
        // sont égales, `d / √(d·d)` se simplifie sans perte.
        // Ce n'est pas de la cosmétique : c'est ce qui rend « similarité(x, x)
        // vaut 1 » vraie au bit près, donc testable sans tolérance et utilisable
        // comme borne haute sûre par 1.3.
        return dotProduct / (squaredNormA * squaredNormB).squareRoot()
    }

    /// Ramène un cosinus `[-1, 1]` dans le `[0, 1]` du contrat.
    ///
    /// CHOIX : on écrase les négatifs à `0` plutôt que de faire une remise à
    /// l'échelle affine `(x + 1) / 2`. L'affine donnerait `0,5` à deux textes
    /// orthogonaux, c'est-à-dire sans aucun rapport — un futur seuil de
    /// pertinence ne voudrait alors plus rien dire ("tout est à moitié
    /// pertinent"). Une corrélation négative n'est pas une demi-pertinence,
    /// c'est une absence de pertinence : elle vaut `0`.
    ///
    /// Le cas négatif est réel et pas théorique : mesuré sur macOS 27, la
    /// distance cosinus Apple entre « j'adore ce film » et « la mitochondrie
    /// produit de l'ATP » vaut 1,0286, soit une similarité de -0,0286.
    /// En revanche le cas extrême souvent cité — distance 2,0 pour une chaîne
    /// vide — n'est PAS atteignable par ce code : `NLEmbedding.vector(for: "")`
    /// renvoie `nil` (vérifié), donc le scorer marque 0 sans jamais appeler ce
    /// cosinus.
    nonisolated static func clampedToUnitRange(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }
}
