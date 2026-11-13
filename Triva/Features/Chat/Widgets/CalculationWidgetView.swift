//
//  CalculationWidgetView.swift
//  Triva
//
//  Created by ben podrojsky on 02/10/2026.
//

import Foundation
import SwiftUI

// MARK: - Présentation (logique pure, testable)

/// Mise en forme de `CalculationWidgetData` pour la carte ET pour VoiceOver.
///
/// `nonisolated`, et uniquement des `String` en entrée, jamais
/// `CalculationWidgetData` lui-même : ce struct n'est pas annoté dans
/// `CalculationWidgetService.swift`, il est donc isolé au main actor sous
/// `-default-isolation=MainActor`. Même choix, pour la même raison, que
/// `WeatherWidgetPresentation` : cette logique reste utilisable et testable
/// depuis n'importe quel contexte.
///
/// ## L'expression est typographiée, jamais réécrite
/// `CalculationWidgetData.expression` est l'expression TELLE QUE LE MODÈLE
/// L'A ÉCRITE, dans la grammaire ASCII que le prompt lui impose
/// (« 15% * 240 », « sqrt(16) + 2^10 »). Affichée telle quelle, elle aurait
/// l'air d'une ligne de code au milieu d'une interface française.
/// `displayExpression` remplace donc chaque symbole par son équivalent
/// typographique (`*` → `×`, `/` → `÷`, `-` → `−`, `sqrt` → `√`, point
/// décimal → virgule, espace insécable avant `%`), et rien d'autre : ni
/// réévaluation, ni reformatage des nombres.
///
/// Écarté : re-tokeniser avec `CalculationExpressionEvaluator.tokenize` puis
/// reformater chaque opérande avec `CalculationResultFormatter`. Ce formateur
/// plafonne à 10 décimales et bascule en notation scientifique dès 1e15 : la
/// carte aurait montré des opérandes différents de ceux que le modèle a écrits
/// et que l'évaluateur a réellement calculés (« 1e3 » devenu « 1 000 »,
/// « 3.14159265358979 » arrondi), et le tokeniseur efface le plus unaire.
///
/// ### Pourquoi chaque substitution est sûre
/// Une `CalculationWidgetData` n'existe que si `evaluate` a réussi (voir
/// `CalculationWidgetService.makeResult`) : l'expression respecte donc la
/// grammaire de l'évaluateur, et chaque remplacement est un synonyme strict.
/// - La virgule est REFUSÉE par l'évaluateur (`allowedSymbols`) : tout point
///   d'une expression valide est un séparateur décimal. Le remplacer par une
///   virgule ne crée aucune ambiguïté à l'AFFICHAGE — celle qui justifie le
///   refus ne concerne que l'ANALYSE d'une virgule écrite par un modèle — et
///   aligne l'expression sur le résultat, déjà formaté en fr_FR (« 1,5 × 4 »
///   au-dessus de « 6 », pas « 1.5 × 4 »).
/// - `**` passe AVANT `*`, sinon `2**10` deviendrait « 2××10 ».
/// - Le moins devient le signe moins typographique U+2212, celui que la police
///   dessine à la largeur de `+` et `×`. Le signe d'un résultat NÉGATIF reste,
///   lui, le trait d'union-moins de `CalculationResultFormatter` (fr_FR,
///   mesuré) : la vue ne retouche pas une valeur que le service a formatée.
/// - L'espacement autour des opérateurs reste celui du modèle (les blancs
///   multiples et les retours à la ligne sont seulement ramenés à une espace) :
///   distinguer un moins binaire d'un moins unaire pour l'espacer demanderait
///   de ré-analyser l'expression, et les exemples du prompt sont déjà espacés.
nonisolated enum CalculationWidgetPresentation {
    /// Espace insécable entre un nombre et « % » (typographie française) :
    /// c'est le caractère que `NumberFormatter` place lui-même avant « % » en
    /// fr_FR (mesuré), et celui de `WeatherWidgetPresentation.numberUnitSeparator`
    /// avant « km/h ». Il empêche aussi « 15 » et « % » de se séparer en fin de
    /// ligne dans une fenêtre étroite.
    static let percentSeparator = "\u{00A0}"

    /// Signe moins typographique (U+2212), distinct du trait d'union-moins.
    static let minusSign = "\u{2212}"

    /// Séparateur de milliers de `CalculationResultFormatter` en fr_FR :
    /// l'espace fine INSÉCABLE (U+202F, mesuré : « 1 500 000 »).
    static let groupingSeparator = "\u{202F}"

    /// Même largeur que `groupingSeparator`, mais sécable : voir `displayResult`.
    static let breakableGroupingSeparator = "\u{2009}"

    /// Un `struct` nommé plutôt qu'un tuple, comme les `Replacement` de
    /// `CalculationExpressionEvaluator` : `$0.0` / `$0.1` se relisent mal.
    private struct Substitution: Sendable {
        let source: String
        let target: String
    }

    /// **L'ordre compte** : `**` avant `*`. Les synonymes Unicode que
    /// `CalculationExpressionEvaluator.normalize` accepte déjà (`·`, `⋅`, `∕`,
    /// `–`, `—`) sont ramenés au même glyphe, pour qu'une expression s'affiche
    /// pareil quel que soit le moteur (Apple Intelligence, MLX, BYOK) qui l'a
    /// écrite.
    private static let typographicSubstitutions: [Substitution] = [
        Substitution(source: "**", target: "^"),
        Substitution(source: "*", target: "\u{00D7}"),        // ×
        Substitution(source: "\u{00B7}", target: "\u{00D7}"), // · → ×
        Substitution(source: "\u{22C5}", target: "\u{00D7}"), // ⋅ → ×
        Substitution(source: "/", target: "\u{00F7}"),        // ÷
        Substitution(source: "\u{2215}", target: "\u{00F7}"), // ∕ → ÷
        Substitution(source: "-", target: minusSign),
        Substitution(source: "\u{2013}", target: minusSign),  // – → −
        Substitution(source: "\u{2014}", target: minusSign),  // — → −
        Substitution(source: ".", target: ","),
    ]

    /// Mots lus par VoiceOver à la place de chaque symbole. Écrits en toutes
    /// lettres plutôt que confiés à la synthèse vocale : `*` et `^` seraient
    /// lus « astérisque » et « accent circonflexe », et selon la voix et le
    /// niveau de ponctuation réglé, les parenthèses sont sautées —
    /// « 2 × (3 + 4) » serait entendu « 2 fois 3 plus 4 », un autre calcul.
    ///
    /// Le trait d'union-moins n'apparaît plus dans une expression affichée (il
    /// est devenu `minusSign`) : il est là pour le signe d'un RÉSULTAT négatif.
    private static let spokenWords: [Substitution] = [
        Substitution(source: "\u{00D7}", target: " fois "),
        Substitution(source: "\u{00F7}", target: " divisé par "),
        Substitution(source: "+", target: " plus "),
        Substitution(source: minusSign, target: " moins "),
        Substitution(source: "-", target: " moins "),
        Substitution(source: "^", target: " puissance "),
        Substitution(source: "\u{221A}", target: " racine carrée de "),
        Substitution(source: "%", target: " pour cent "),
        Substitution(source: "(", target: " parenthèse ouvrante "),
        Substitution(source: ")", target: " parenthèse fermante "),
    ]

    // MARK: Affichage

    /// L'expression du modèle, typographiée (voir la documentation du type).
    /// « 15% * 240 » → « 15 % × 240 », « sqrt(16)+2**10 » → « √(16)+2^10 ».
    static func displayExpression(_ expression: String) -> String {
        let collapsed = expression
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let substituted = typographicSubstitutions.reduce(collapsed) { text, substitution in
            text.replacingOccurrences(of: substitution.source, with: substitution.target)
        }
        return substituted
            // `sqrt` quelle que soit la casse : l'évaluateur passe tout en
            // minuscules, `SQRT(16)` est donc une expression valide.
            .replacingOccurrences(of: "sqrt", with: "\u{221A}", options: .caseInsensitive)
            // `sqrt (16)` est licite (blancs tolérés avant la parenthèse) ;
            // « √ (16) » se lirait mal.
            .replacingOccurrences(of: #"\x{221A}\s+"#, with: "\u{221A}", options: .regularExpression)
            // Exactement une espace insécable avant `%`, qu'il y ait eu zéro,
            // une ou plusieurs espaces ordinaires.
            .replacingOccurrences(of: #"\s*%"#, with: percentSeparator + "%", options: .regularExpression)
    }

    /// Le résultat tel que `CalculationResultFormatter` l'a écrit, à un
    /// caractère près : son séparateur de milliers insécable devient une
    /// espace fine sécable de même largeur.
    ///
    /// Sans cela, un résultat à 15 chiffres (« 123 456 789 012 345 ») ne
    /// contient AUCUN point de coupure : en très grand texte ou dans une
    /// fenêtre Mac étroite, il serait coupé au milieu d'un groupe de chiffres.
    /// Avec, il passe à la ligne ENTRE deux groupes. Tronquer, ou réduire la
    /// police avec `minimumScaleFactor`, est exclu : un nombre tronqué est un
    /// résultat faux, et une police réduite annule Dynamic Type. Aucun effet
    /// visible quand le nombre tient sur une ligne, c'est-à-dire presque
    /// toujours. VoiceOver, lui, reçoit la valeur intacte (`accessibilityLabel`).
    static func displayResult(_ formattedResult: String) -> String {
        formattedResult.replacingOccurrences(of: groupingSeparator, with: breakableGroupingSeparator)
    }

    // MARK: VoiceOver

    /// Texte typographié (expression affichée ou résultat formaté) converti en
    /// mots, dans cet ordre :
    /// 1. une racine dont l'argument est un simple nombre se lit « racine
    ///    carrée de 16 », sans « parenthèse ouvrante… fermante ». SAUF si un `%`
    ///    ou un `^` la suit : « racine carrée de 16 pour cent » s'entendrait
    ///    √(16 %) alors que l'expression vaut √(16) %, les parenthèses
    ///    restent alors prononcées ;
    /// 2. l'exposant d'une notation scientifique (« 1,5e−3 », « 1e+3 ») se lit
    ///    « fois 10 puissance » — sinon « 1,5 e moins 3 » ;
    /// 3. chaque symbole restant devient son mot (`spokenWords`) ;
    /// 4. les blancs multiples créés par les mots sont ramenés à une espace.
    ///    L'espace fine insécable U+202F n'y est PAS comptée : c'est le
    ///    séparateur de milliers d'un résultat (« 1 500 000 »), la remplacer
    ///    par une espace ordinaire ferait entendre trois nombres.
    static func spokenText(_ text: String) -> String {
        let withRoots = text.replacingOccurrences(
            of: #"\x{221A}\(([0-9]+(?:,[0-9]+)?)\)(?!\s*[%^])"#,
            with: "racine carrée de $1",
            options: .regularExpression
        )
        let withExponents = withRoots.replacingOccurrences(
            of: #"(?<=[0-9,])[eE]\+?(?=[\x{2212}\-]?[0-9])"#,
            with: " fois 10 puissance ",
            options: .regularExpression
        )
        let words = spokenWords.reduce(withExponents) { text, substitution in
            text.replacingOccurrences(of: substitution.source, with: substitution.target)
        }
        return words
            .replacingOccurrences(of: #"[ \x{00A0}]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// « 15 pour cent fois 240 ».
    static func spokenExpression(_ expression: String) -> String {
        spokenText(displayExpression(expression))
    }

    /// « moins 1,5 », « 1,152921505 fois 10 puissance 18 ».
    static func spokenResult(_ formattedResult: String) -> String {
        spokenText(formattedResult)
    }

    /// Libellé unique de la carte pour VoiceOver : la même information que
    /// l'écran, dans le même ordre. « Calcul. » en tête annonce de quoi il
    /// s'agit, comme « Météo à Paris. » sur la carte météo.
    static func accessibilityLabel(expression: String, formattedResult: String) -> String {
        let spokenCalculation = Self.spokenExpression(expression)
        let spokenValue = Self.spokenResult(formattedResult)
        guard !spokenCalculation.isEmpty else { return "Calcul. Résultat \(spokenValue)." }
        return "Calcul. \(spokenCalculation) égale \(spokenValue)."
    }
}

// MARK: - Vue

/// Carte du widget calculatrice (1.5), affichée AU-DESSUS de la réponse quand
/// `CalculationWidgetService` a produit un résultat. Port de
/// la carte calculatrice de la version web d'origine, refait selon `DESIGN.md`.
///
/// ## Hiérarchie : celle de l'accroche de `TrivaHomeReferenceView`
/// L'expression en `.subheadline` secondaire, le résultat juste en dessous en
/// `.title` semibold, 4 pt entre les deux : exactement le couple « Bonjour » /
/// « Que veux-tu explorer ? » de la référence. C'est aussi la disposition de la
/// Calculette d'Apple — le calcul en petit, le résultat en grand —, si bien
/// qu'aucun intitulé n'est nécessaire pour savoir lequel est lequel.
/// Sur iOS, `.title.weight(.semibold)` vaut les 28 pt semibold de la DA à la
/// taille de texte par défaut (22 pt sur macOS, l'échelle native du Mac),
/// mais suit Dynamic Type, contrairement au `.system(size: 28)` de la
/// référence.
///
/// ## Écarts assumés vis-à-vis de la version web d'origine
/// - Pas d'intitulés « Expression » / « Result » ni d'icônes calculatrice et
///   égal : la hiérarchie typographique dit déjà tout, ce serait le
///   remplissage que DESIGN.md interdit.
/// - Pas de police à chasse fixe (`font-mono`) : la DA n'utilise que le design
///   `.default`. Pas de chiffres tabulaires (`tabular-nums`) non plus : ils
///   alignent des colonnes de nombres, il n'y a qu'un nombre ici.
/// - Pas de cadres bordés imbriqués : une seule carte en verre neutre, comme la
///   bulle assistant qu'elle surmonte et comme la carte météo.
///
/// ## Jamais tronqué
/// Ni `lineLimit(1)` ni `minimumScaleFactor` : les deux textes passent à la
/// ligne quand la place manque (très grand texte, fenêtre Mac étroite), le
/// résultat entre deux groupes de chiffres (voir
/// `CalculationWidgetPresentation.displayResult`).
///
/// ## Intégration (faite à l'étape suivante, pas ici)
/// Mêmes règles que `WeatherWidgetView` : à poser comme FRÈRE de la bulle
/// assistant, jamais à l'intérieur (verre sur verre), dans le même
/// `GlassEffectContainer` que ses frères de verre ; la carte n'en ouvre pas
/// elle-même.
///
/// ## Pas d'état d'erreur, par construction
/// `computeCalculation` renvoie `nil` dès que l'extraction ou l'évaluation
/// échoue (division par zéro, expression invalide…), et `nil` veut dire « pas
/// de carte ». Une donnée qui existe a donc toujours un résultat fini et
/// formaté : il n'y a ni état vide ni état d'erreur à dessiner.
///
/// `Equatable` (synthétisée à partir de `data`) : même raison que
/// `MessageBubbleView` — le fil de chat peut appliquer `.equatable()` pour ne
/// pas réévaluer la carte à chaque token reçu pendant le streaming.
struct CalculationWidgetView: View, Equatable {
    let data: CalculationWidgetData

    var body: some View {
        let expression = CalculationWidgetPresentation.displayExpression(data.expression)

        VStack(alignment: .leading, spacing: 4) {
            if !expression.isEmpty {
                Text(expression)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(CalculationWidgetPresentation.displayResult(data.formattedResult))
                .font(.title.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        // Un seul élément VoiceOver, avec un libellé écrit pour l'oreille :
        // lus tels quels, « × », « ^ » et les parenthèses seraient prononcés
        // de façon incertaine (voir `CalculationWidgetPresentation.spokenWords`).
        .accessibilityElement(children: .combine)
        .accessibilityLabel(CalculationWidgetPresentation.accessibilityLabel(
            expression: data.expression,
            formattedResult: data.formattedResult
        ))
    }
}

// MARK: - Previews

/// Données produites par le VRAI service (`CalculationWidgetService.makeResult`,
/// sans appel au modèle) plutôt qu'écrites à la main : une preview dont le
/// résultat ne correspondrait pas à l'expression ne prouverait rien. Une
/// expression refusée par l'évaluateur s'affiche comme telle au lieu d'être
/// maquillée par une fausse donnée.
private struct CalculationWidgetPreview: View {
    let expression: String

    var body: some View {
        if let data = CalculationWidgetService.makeResult(forExpression: expression)?.data {
            CalculationWidgetView(data: data)
        } else {
            Text("Expression refusée par l'évaluateur : \(expression)")
                .foregroundStyle(.secondary)
        }
    }
}

#Preview("Calcul — pourcentage") {
    CalculationWidgetPreview(expression: "15% * 240")
        .padding(20)
}

#Preview("Calcul — racine et puissance, sombre") {
    CalculationWidgetPreview(expression: "sqrt(144) + 2**10 - 15% * 240")
        .padding(20)
        .preferredColorScheme(.dark)
}

/// Cas limites du résultat (il n'existe pas d'état d'erreur, voir la vue) :
/// décimal négatif, puis notation scientifique au-delà de 1e15.
#Preview("Calcul — négatif et scientifique") {
    VStack(spacing: 12) {
        CalculationWidgetPreview(expression: "(2.5 - 7) / 3")
        CalculationWidgetPreview(expression: "2^60")
    }
    .padding(20)
}

#Preview("Calcul — très grand texte, fenêtre étroite") {
    CalculationWidgetPreview(expression: "123456789 * 1000000 + sqrt(2) / 3")
        .frame(width: 280)
        .padding(20)
        .dynamicTypeSize(.accessibility5)
}
