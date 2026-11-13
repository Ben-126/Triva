//
//  CitationParser.swift
//  Triva
//
//  Created by ben podrojsky on 22/09/2026.
//

import Foundation

/// Un morceau du texte de réponse, après découpage des marqueurs de citation.
///
/// `text` contient TOUJOURS la sous-chaîne d'origine, à l'octet près : pour un
/// segment de citation c'est `"[3]"` avec ses crochets, pas `"3"`. C'est ce qui
/// rend vérifiable l'invariant central du parseur (voir
/// `CitationParseResult.reconstructedText`) : le parseur découpe, il ne
/// réécrit jamais. La vue est libre d'afficher autre chose à la place, mais
/// elle part d'un texte qu'elle peut reconstituer exactement — indispensable
/// pour un « Copier » fidèle ou un export.
///
/// `id` est le RANG du segment dans la liste. Choix volontaire plutôt qu'un
/// `UUID` : pendant le streaming, le texte ne fait que grossir par la fin,
/// donc les segments déjà émis gardent leur rang d'un instantané au suivant.
/// Un `ForEach` SwiftUI ne recrée donc pas toute la réponse à chaque token,
/// alors qu'un identifiant aléatoire ferait clignoter le fil entier.
nonisolated struct CitationSegment: Sendable, Equatable, Identifiable {

    /// Nature du segment. Un cas `citation` porte l'indice 1-based écrit par
    /// le modèle, déjà validé comme étant dans les bornes de la liste de
    /// sources (voir `CitationParser.parse`) : la vue peut appeler
    /// `CitationParser.source(forCitationIndex:in:)` sans re-tester.
    enum Kind: Sendable, Equatable {
        case text
        case citation(index: Int)
    }

    let id: Int
    let kind: Kind
    let text: String

    /// Indice 1-based de la source citée, ou `nil` pour un segment de texte.
    /// Raccourci de confort pour la vue, qui n'a alors pas à filtrer sur
    /// `kind` avec un `switch` à chaque itération.
    var citationIndex: Int? {
        switch kind {
        case .text: nil
        case .citation(let index): index
        }
    }
}

/// Résultat complet d'une analyse.
///
/// ## Pourquoi `pendingSuffix` existe
///
/// C'est la pièce qui traite le cas le plus important du plan : le streaming.
/// Le texte arrive par instantanés successifs et peut se terminer AU MILIEU
/// d'un marqueur (`"…comme ceci[1"`). Afficher ce fragment tel quel ferait
/// apparaître un `[1` orphelin pendant une fraction de seconde, puis le voir
/// se transformer en badge : exactement le genre de scintillement qui donne
/// l'impression d'une UI bricolée.
///
/// Le parseur RETIENT donc ce fragment au lieu de l'émettre, et le range ici.
/// Deux conséquences à connaître pour qui consomme ce type :
/// - `segments` seul ne restitue pas le texte d'origine quand un marqueur est
///   tronqué — c'est voulu, c'est précisément le fragment qu'on ne veut pas
///   afficher ;
/// - `reconstructedText`, lui, le restitue toujours exactement.
///
/// Un fragment qui ne pourra JAMAIS devenir un marqueur (`"…ceci[a"`) n'est
/// pas retenu : il part en texte immédiatement. Retenir sans raison ferait
/// disparaître du texte légitime pendant tout le reste du stream.
nonisolated struct CitationParseResult: Sendable, Equatable {

    /// Les segments à afficher, dans l'ordre, sans aucun marqueur partiel.
    let segments: [CitationSegment]

    /// Fin de texte retenue parce qu'elle pourrait encore devenir un marqueur
    /// au prochain instantané. Vide dans l'immense majorité des cas.
    ///
    /// CONTRAT D'APPEL, que la vue de la tâche 1.12 doit honorer : pendant le
    /// streaming on l'IGNORE — c'est tout son intérêt ; une fois le stream
    /// terminé on l'affiche comme du TEXTE BRUT, à la suite des segments.
    /// Le parseur est sans état : il ne peut pas savoir qu'aucun token ne
    /// viendra plus, donc il ne peut pas relâcher le fragment de lui-même.
    /// Sans ce flush final, une réponse qui se terminerait vraiment par `[`
    /// ou `[1` perdrait ces caractères à l'écran.
    let pendingSuffix: String

    /// Le texte d'origine, à l'identique. C'est l'invariant que les tests
    /// vérifient sur toutes les entrées : le parseur ne perd rien, n'ajoute
    /// rien, ne normalise rien.
    var reconstructedText: String {
        segments.map(\.text).joined() + pendingSuffix
    }

    /// Les indices cités, dans leur ordre d'apparition, doublons compris.
    var citationIndices: [Int] {
        segments.compactMap(\.citationIndex)
    }

    /// Les indices cités, dédoublonnés et triés. Sert à une vue qui veut
    /// mettre en avant les sources réellement citées parmi toutes celles
    /// récupérées — une réponse courte n'en cite souvent que trois sur dix.
    var distinctCitationIndices: [Int] {
        Array(Set(citationIndices)).sorted()
    }

    /// Vrai si l'analyse n'a trouvé aucune citation exploitable.
    var hasNoCitation: Bool {
        citationIndices.isEmpty
    }
}

/// Analyseur des marqueurs de citation `[n]` d'une réponse générée (tâche 1.12).
///
/// Porté de la gestion des citations de la version web d'origine, qui remplace les marqueurs par
/// des balises `<citation href=… title=…>` avant de laisser `markdown-to-jsx`
/// les rendre via un composant dédié. Ici pas de
/// HTML intermédiaire : on produit directement une structure typée, ce qui
/// supprime au passage tout le risque d'échappement de la version web d'origine (le titre de la
/// source y est injecté dans un attribut, d'où le `replace(/"/g, '&quot;')`).
///
/// LOGIQUE 100 % PURE : aucun état, aucun réseau, aucun accès disque. Le même
/// texte donne toujours le même découpage, ce qui rend les cas limites
/// couvrables exhaustivement en test.
///
/// ## Écarts assumés vis-à-vis de la version web d'origine
///
/// 1. **Indice hors bornes : on garde le texte.** La version web d'origine supprime purement et
///    simplement le marqueur quand la source n'existe pas (branche
///    `return \`\`` de la version web d'origine). On ne fait pas ça, pour une raison
///    précise à Triva : les sources sont attachées au message AVANT que le
///    texte ne commence à streamer (voir `ChatViewModel.send(query:)`, où
///    `message.sources = streamingAnswer.sources` précède la boucle de
///    tokens). Un `[9]` avec 3 sources n'est donc jamais une course entre
///    texte et sources : c'est le modèle qui a inventé un numéro. Effacer
///    silencieusement fait disparaître du texte sous les yeux de
///    l'utilisateur ; afficher un badge qui n'ouvre rien est pire encore.
///    On laisse `[9]` tel quel : c'est visible, c'est honnête, et ça se
///    diagnostique.
/// 2. **Pas de liste `[1,2]`.** La version web d'origine accepte `[1, 2]` et le développe en
///    plusieurs liens. Nos prompts interdisent explicitement cette forme
///    (`PromptTemplates.citationSection` : « Jamais [1,2] », on demande
///    `[1][2]`). La supporter ici obligerait un segment à référencer
///    plusieurs sources, donc compliquerait la vue, pour couvrir une forme
///    qu'on a demandé au modèle de ne pas produire. `[1,2]` reste donc du
///    texte brut.
/// 3. **Pas de tolérance aux espaces.** `[ 1 ]` n'est pas une citation. La
///    version web d'origine les tolère via un `trim()`. Ici toute tolérance supplémentaire
///    augmente mécaniquement le risque de faux positif sur du texte
///    ordinaire, sans contrepartie : le modèle recopie le format qu'on lui
///    montre dans le prompt.
///
/// ## Faux positifs écartés
///
/// `[0]` (pas d'index 0), `[1.5]`, `[abc]`, `[voir plus]`, `[x] tâche` d'une
/// liste markdown, et le lien markdown `[texte](url)`. Ce dernier mérite une
/// note : `[1](https://…)` passerait tous les tests de forme d'un marqueur, on
/// l'écarte donc sur ce qui SUIT le crochet fermant — un `(` immédiat signe un
/// lien markdown, jamais une citation.
///
/// Cas volontairement NON traité : le lien markdown par référence
/// `[texte][1]`, où `[1]` est une étiquette et non une citation. On ne peut
/// pas le distinguer de `[1][2]` — deux sources pour un même fait — sans
/// heuristique fragile, et `[1][2]` est une forme que nos prompts demandent
/// explicitement. Le cas fréquent l'emporte sur le cas rare.
///
/// ## Coût, parce qu'il compte ici
///
/// L'analyse est relancée à CHAQUE instantané de streaming, sur un texte qui
/// grossit : le coût total sur une réponse est donc quadratique en sa
/// longueur. C'est assumé pour un texte de quelques kilo-octets, et c'est le
/// prix d'un parseur sans état (qui n'a donc aucun moyen de se désynchroniser
/// du texte affiché). Ce qui est évité en revanche :
/// - **aucune expression régulière**, ni `Regex` ni `NSRegularExpression` :
///   pas de construction ni de compilation de motif à chaque appel, là où la
///   version web d'origine reconstruit deux regex littérales par bloc de texte ;
/// - **une seule passe de découpage**, précédée d'un pré-filtre sur les
///   octets UTF-8 qui sort immédiatement si le texte ne contient aucun `[` —
///   le cas d'une réponse conversationnelle sans source, où l'on évite alors
///   tout le découpage en `Character` ;
/// - **aucun tampon intermédiaire** : les segments sont découpés directement
///   dans la chaîne d'origine.
///
/// L'itération se fait sur les `Character` et non sur les octets : ce sont les
/// seuls index garantis alignés sur une frontière de grappe, donc les seuls
/// avec lesquels découper une `String` est sûr quel que soit le contenu
/// (accents combinants, emoji composés, écritures non latines).
/// `nonisolated` : analyse de texte 100 % pure, sans état partagé, appelée
/// aussi bien depuis une vue (`@MainActor`) que depuis des contextes non
/// isolés — dont les tests. Sous `-default-isolation=MainActor` elle
/// hériterait de `@MainActor`, ce que le mode de langage Swift 6 refuse au
/// point d'appel. Même convention que les modèles SearXNG et `URLFetching`.
nonisolated struct CitationParser: Sendable {

    /// Nombre maximum de chiffres acceptés dans un marqueur.
    ///
    /// 4 chiffres, soit jusqu'à `[9999]`. Une réponse s'appuie au grand
    /// maximum sur quelques dizaines de sources (`SourceRanker` tronque bien
    /// avant), donc la marge est énorme. Cette borne a deux effets utiles :
    /// elle empêche `[99999999999999999999]` de faire déborder `Int`, et elle
    /// évite de retenir indéfiniment un fragment absurde en fin de stream.
    static let maxCitationDigits = 4

    // MARK: - API publique

    /// Découpe `text` en segments, en ne retenant comme citations que les
    /// indices effectivement présents dans `sources`.
    ///
    /// Surcharge de confort pour la vue, qui a la liste sous la main.
    static func parse(_ text: String, sources: [SearXNGSearchResult]) -> CitationParseResult {
        parse(text, sourceCount: sources.count)
    }

    /// Découpe `text` en segments. `sourceCount` est le nombre de sources
    /// attachées au message : tout indice hors de `1...sourceCount` reste du
    /// texte (voir l'écart n°1 documenté sur le type).
    ///
    /// Ne lève jamais, ne produit jamais de `fatalError` : l'entrée vient d'un
    /// modèle de langue, donc tout est possible. Le pire cas est un texte
    /// rendu tel quel, sans aucune citation — jamais un crash ni une perte.
    static func parse(_ text: String, sourceCount: Int) -> CitationParseResult {
        // Texte vide : aucun segment du tout, plutôt qu'un segment vide.
        // Une vue qui itère dessus n'affiche alors rien, ce qui est le
        // comportement attendu avant le premier token d'une réponse.
        guard !text.isEmpty else {
            return CitationParseResult(segments: [], pendingSuffix: "")
        }

        // Pré-filtre : sans aucun `[`, il ne peut y avoir ni citation ni
        // fragment retenu. Comparaison octet par octet sur la vue UTF-8, bien
        // moins chère que le découpage en grappes — et c'est le cas d'une
        // réponse sans source, donc un cas fréquent.
        guard text.utf8.contains(Self.openingBracketByte) else {
            return CitationParseResult(
                segments: [CitationSegment(id: 0, kind: .text, text: text)],
                pendingSuffix: ""
            )
        }

        return scan(text, sourceCount: sourceCount)
    }

    /// Comme `parse(_:sourceCount:)`, mais une citation vers un numéro de `unread` reste du
    /// TEXTE (mission C1, rapport E2) : ces sources sont affichées à leur rang sans avoir été
    /// lues (`SearchArtifacts.uncitableSourceNumbers`), le modèle n'a pu les citer qu'en
    /// inventant. Une pastille touchable vers elles présenterait comme sourcée une phrase qui
    /// ne l'est pas. Le texte d'origine est conservé tel quel (`reconstructedText` inchangé),
    /// et les identifiants des segments aussi.
    static func parse(_ text: String, sourceCount: Int, unread: Set<Int>) -> CitationParseResult {
        let result = parse(text, sourceCount: sourceCount)
        guard !unread.isEmpty else { return result }
        let segments = result.segments.map { segment in
            guard let index = segment.citationIndex, unread.contains(index) else { return segment }
            return CitationSegment(id: segment.id, kind: .text, text: segment.text)
        }
        return CitationParseResult(segments: segments, pendingSuffix: result.pendingSuffix)
    }

    /// Renvoie la source désignée par un indice 1-based, ou `nil` si l'indice
    /// tombe hors de la liste.
    ///
    /// Le `nil` reste possible même si `parse` a déjà validé les bornes : la
    /// vue peut très bien afficher un résultat analysé avec une liste de
    /// sources et le rapprocher d'une autre (message rejoué, historique
    /// rechargé). Mieux vaut un optionnel qu'un plantage d'index.
    static func source(
        forCitationIndex index: Int,
        in sources: [SearXNGSearchResult]
    ) -> SearXNGSearchResult? {
        guard index >= 1, index <= sources.count else { return nil }
        return sources[index - 1]
    }

    // MARK: - Découpage

    private static let openingBracketByte = UInt8(ascii: "[")

    /// Passe unique de découpage.
    ///
    /// `flushStart` marque le début du texte brut pas encore émis : tant qu'on
    /// ne rencontre pas de citation, on ne coupe rien. Les suites de texte se
    /// retrouvent donc naturellement fusionnées en un seul segment, y compris
    /// quand elles contiennent des crochets écartés en cours de route.
    private static func scan(_ text: String, sourceCount: Int) -> CitationParseResult {
        var segments: [CitationSegment] = []
        var pendingSuffix = ""
        var flushStart = text.startIndex
        var cursor = text.startIndex

        while cursor < text.endIndex {
            guard text[cursor] == "[" else {
                cursor = text.index(after: cursor)
                continue
            }

            switch readMarker(in: text, from: cursor, sourceCount: sourceCount) {
            case .citation(let index, let end):
                append(text[flushStart..<cursor], to: &segments)
                segments.append(
                    CitationSegment(
                        id: segments.count,
                        kind: .citation(index: index),
                        text: String(text[cursor..<end])
                    )
                )
                cursor = end
                flushStart = end

            case .notAMarker(let resumeFrom):
                // On ne coupe rien : ces caractères resteront dans le segment
                // de texte courant. On reprend juste l'analyse après la partie
                // déjà examinée, pour ne jamais la réexaminer (passe unique).
                cursor = resumeFrom

            case .truncated:
                append(text[flushStart..<cursor], to: &segments)
                pendingSuffix = String(text[cursor...])
                flushStart = text.endIndex
                cursor = text.endIndex
            }
        }

        append(text[flushStart..<text.endIndex], to: &segments)

        return CitationParseResult(segments: segments, pendingSuffix: pendingSuffix)
    }

    /// Ajoute un segment de texte, en ignorant les tranches vides — deux
    /// citations collées (`[1][2]`) ne doivent pas produire un segment de
    /// texte vide entre elles.
    private static func append(_ slice: Substring, to segments: inout [CitationSegment]) {
        guard !slice.isEmpty else { return }
        segments.append(CitationSegment(id: segments.count, kind: .text, text: String(slice)))
    }

    /// Issue de la tentative de lecture d'un marqueur commençant à un `[`.
    private enum MarkerScan {
        /// Marqueur valide et dans les bornes. `end` est l'index juste APRÈS
        /// le `]`.
        case citation(index: Int, end: String.Index)
        /// Pas un marqueur exploitable. `resumeFrom` dit où reprendre la
        /// passe — au plus tôt juste après le `[`, pour qu'un crochet
        /// imbriqué garde sa chance d'ouvrir une citation (`[[1]]`).
        case notAMarker(resumeFrom: String.Index)
        /// Le texte se termine au milieu d'un marqueur possible : à retenir.
        case truncated
    }

    /// Examine le texte à partir d'un `[` pour décider s'il ouvre une citation.
    ///
    /// `start` pointe forcément sur un `[`.
    private static func readMarker(
        in text: String,
        from start: String.Index,
        sourceCount: Int
    ) -> MarkerScan {
        var cursor = text.index(after: start)
        var digits = ""

        // Les chiffres sont testés en ASCII strict : `Character.isNumber` seul
        // accepterait les chiffres arabes-indiens ou dévanagari (`[١٢٣]`), que
        // `Int(_:)` refuserait ensuite — autant les écarter tout de suite.
        while cursor < text.endIndex, text[cursor].isASCII, text[cursor].isNumber {
            guard digits.count < maxCitationDigits else {
                return .notAMarker(resumeFrom: cursor)
            }
            digits.append(text[cursor])
            cursor = text.index(after: cursor)
        }

        // Fin de texte atteinte alors qu'on n'a vu que `[` et des chiffres :
        // c'est le cas du streaming. Le prochain instantané apportera peut-être
        // le `]` manquant, donc on retient plutôt que d'afficher `[1`.
        guard cursor < text.endIndex else {
            return .truncated
        }

        // `[abc`, `[ 1]`, `[1.5]`, `[1,2]`… : rien qui ressemble à un marqueur.
        // On reprend juste après le `[` et non après ce qu'on vient de lire :
        // un `[` imbriqué (`[[1]]`) doit encore pouvoir ouvrir une citation.
        guard !digits.isEmpty, text[cursor] == "]" else {
            return .notAMarker(resumeFrom: text.index(after: start))
        }

        let end = text.index(after: cursor)

        // Lien markdown `[1](https://…)` : la forme est celle d'un marqueur,
        // l'intention ne l'est pas. Seul ce qui suit permet de trancher.
        //
        // Limite connue et acceptée : si le texte s'arrête pile après le `]`,
        // on ne sait pas encore si un `(` suit. On émet la citation, quitte à
        // la voir redevenir du texte à l'instantané suivant. Retenir à la
        // place ferait disparaître la dernière citation d'une réponse qui se
        // termine par `[3]` — bien plus visible qu'un clignotement d'une image
        // sur un lien markdown, forme que nos prompts ne demandent jamais.
        if end < text.endIndex, text[end] == "(" {
            return .notAMarker(resumeFrom: end)
        }

        // `Int(digits)` ne peut pas échouer ici (au plus 4 chiffres ASCII),
        // mais on refuse de le supposer sur une entrée venue d'un modèle.
        guard let index = Int(digits), index >= 1, index <= sourceCount else {
            return .notAMarker(resumeFrom: end)
        }

        return .citation(index: index, end: end)
    }
}
