//
//  WeatherWidgetView.swift
//  Triva
//
//  Created by ben podrojsky on 01/10/2026.
//

import Foundation
import SwiftUI

// MARK: - Présentation (logique pure, testable)

/// Une information complémentaire de la carte météo : un libellé et une
/// valeur déjà mise en forme. Un type nommé plutôt qu'un tuple : la liste est
/// construite par une fonction pure testable
/// (`WeatherWidgetPresentation.details`), puis rendue par un `ForEach`, qui
/// exige un `Identifiable`.
///
/// `id` = libellé : un libellé n'apparaît qu'une fois par carte.
nonisolated struct WeatherWidgetDetail: Sendable, Equatable, Identifiable {
    let label: String
    let value: String

    var id: String { label }
}

/// Mise en forme de `WeatherWidgetData` pour la carte ET pour VoiceOver.
///
/// Toutes les fonctions sont `nonisolated` et ne prennent que des types
/// primitifs (`Double`, `Int`, `String`, `Bool`), jamais `WeatherWidgetData`
/// lui-même : ce struct n'est pas annoté `nonisolated` dans
/// `WeatherWidgetService.swift`, il est donc isolé au main actor sous
/// `-default-isolation=MainActor`. Ne dépendre que de primitives garde cette
/// logique utilisable et testable depuis n'importe quel contexte.
///
/// ## Unités métriques fixes (°C, km/h)
/// Pas de `Measurement` avec `usage: .weather`, qui convertirait en °F selon
/// la préférence système : la réponse rédigée par le modèle s'appuie sur
/// `WeatherWidgetService.llmContext`, écrit en °C et km/h. Afficher « 64° »
/// dans la carte pendant que la réponse juste en dessous parle de « 18 °C »
/// serait incohérent. Respecter la préférence °F demanderait de changer le
/// service en même temps : piste V2, pas une décision à prendre dans une vue.
///
/// ## Arrondi : jamais « -0° », jamais de plantage
/// `String(format: "%.0f", -0.4)` comme `NumberFormatter` affichent « -0 »
/// (zéro signé). On arrondit donc d'abord, puis on convertit avec
/// `Int(exactly:)` : un `Int` n'a pas de zéro négatif, et contrairement à
/// `Int(_:)` — qui fait planter l'app sur `nan`, l'infini ou une valeur hors
/// plage — `Int(exactly:)` renvoie `nil`, affiché « — ». Les valeurs viennent
/// d'une API externe : un plantage sur une donnée aberrante est exclu par le
/// projet, même si `JSONDecoder` refuse déjà `nan` et l'infini en amont.
nonisolated enum WeatherWidgetPresentation {
    /// Valeur absente ou aberrante. Un tiret cadratin plutôt que « 0 » (ce
    /// serait une fausse température) ou « ? » (ça ferait bug).
    static let unavailableValue = "—"

    /// Ce que VoiceOver lit à la place de `unavailableValue`, qu'il
    /// prononcerait « tiret cadratin ».
    static let unavailableSpokenValue = "valeur indisponible"

    /// Espace insécable entre un nombre et son unité (typographie française).
    /// Elle empêche aussi « 12 » et « km/h » de se retrouver sur deux lignes
    /// dans une fenêtre Mac étroite.
    static let numberUnitSeparator = "\u{00A0}"

    /// Équivalents de nuit des symboles « soleil » produits par
    /// `WeatherWidgetService.condition(forWMOCode:)`. Le service dérive le
    /// symbole du seul code WMO, sans tenir compte de `is_day` : un ciel
    /// dégagé à 23 h s'afficherait avec un soleil. La version web d'origine choisit l'icône
    /// selon `is_day` (`clear-night.svg`…), d'où cette table, alignée
    /// EXACTEMENT sur les deux seuls symboles solaires du service (codes 0-1
    /// et 2). Tous les autres (nuages, brouillard, pluie, neige, orage) valent
    /// de jour comme de nuit et passent tels quels.
    private static let nightSymbolNames: [String: String] = [
        "sun.max": "moon.stars",
        "cloud.sun": "cloud.moon",
    ]

    /// Arrondi au plus proche (0,5 s'éloigne de zéro), ou `nil` si la valeur
    /// n'a pas d'entier correspondant (`nan`, infini, hors de la plage d'`Int`).
    static func roundedInteger(_ value: Double) -> Int? {
        Int(exactly: value.rounded())
    }

    /// « 18° ». Pas de « C » : le degré seul est la convention des apps météo
    /// françaises, et l'unité est fixe dans toute l'app (voir plus haut).
    static func temperatureText(_ celsius: Double) -> String {
        guard let degrees = roundedInteger(celsius) else { return unavailableValue }
        return "\(degrees)°"
    }

    /// « 12° / 22° » : minimum puis maximum, dans l'ordre que le libellé
    /// « Min. / max. » annonce.
    static func temperatureRangeText(minimumCelsius: Double, maximumCelsius: Double) -> String {
        "\(temperatureText(minimumCelsius)) / \(temperatureText(maximumCelsius))"
    }

    /// « 12 km/h », avec une espace insécable.
    static func windSpeedText(_ kmh: Double) -> String {
        guard let speed = roundedInteger(kmh) else { return unavailableValue }
        return "\(speed)\(numberUnitSeparator)km/h"
    }

    /// Le ressenti n'est montré que s'il APPORTE quelque chose : connu, et
    /// différent de la température une fois arrondi. « 18° — Ressenti 18° »
    /// serait du remplissage, « Ressenti — » aussi.
    static func showsApparentTemperature(currentCelsius: Double, apparentCelsius: Double) -> Bool {
        guard let apparent = roundedInteger(apparentCelsius) else { return false }
        return roundedInteger(currentCelsius) != apparent
    }

    /// Symbole à afficher : celui du service, remplacé par son équivalent de
    /// nuit quand il fait nuit au lieu demandé (voir `nightSymbolNames`).
    static func symbolName(serviceSymbolName: String, isDaytime: Bool) -> String {
        guard !isDaytime else { return serviceSymbolName }
        return nightSymbolNames[serviceSymbolName] ?? serviceSymbolName
    }

    /// Les informations complémentaires, TROIS au plus, dans l'ordre
    /// d'utilité : la plage du jour (répond d'avance à « va-t-il faire plus
    /// chaud ? »), le ressenti, puis le vent.
    ///
    /// L'humidité, pourtant présente dans `WeatherWidgetData`, n'est pas
    /// affichée : le ressenti d'Open-Meteo (température apparente) l'intègre
    /// déjà avec le vent, et une quatrième case diluerait une carte censée
    /// rester compacte. Elle reste dans `llmContext` : la réponse rédigée peut
    /// la citer si la question porte dessus.
    static func details(
        minimumCelsius: Double,
        maximumCelsius: Double,
        currentCelsius: Double,
        apparentCelsius: Double,
        windSpeedKmh: Double
    ) -> [WeatherWidgetDetail] {
        let range = WeatherWidgetDetail(
            label: "Min. / max.",
            value: temperatureRangeText(minimumCelsius: minimumCelsius, maximumCelsius: maximumCelsius)
        )
        let apparent = showsApparentTemperature(currentCelsius: currentCelsius, apparentCelsius: apparentCelsius)
            ? [WeatherWidgetDetail(label: "Ressenti", value: temperatureText(apparentCelsius))]
            : []
        let wind = WeatherWidgetDetail(label: "Vent", value: windSpeedText(windSpeedKmh))
        return [range] + apparent + [wind]
    }

    // MARK: VoiceOver

    /// « 18 degrés », « moins 1 degré ».
    static func spokenTemperature(_ celsius: Double) -> String {
        guard let degrees = roundedInteger(celsius) else { return unavailableSpokenValue }
        return spokenQuantity(degrees, singular: "degré", plural: "degrés")
    }

    /// « 12 kilomètres-heure » : écrit en toutes lettres, parce que la
    /// synthèse vocale peut épeler « km/h » ou lire la barre oblique.
    static func spokenWindSpeed(_ kmh: Double) -> String {
        guard let speed = roundedInteger(kmh) else { return unavailableSpokenValue }
        return spokenQuantity(speed, singular: "kilomètre-heure", plural: "kilomètres-heure")
    }

    /// Accord français : singulier sous 2 en valeur absolue (« 0 degré »,
    /// « 1 degré », « moins 1 degré »), pluriel au-delà. Le signe est écrit en
    /// toutes lettres plutôt que laissé au trait d'union, que la synthèse peut
    /// lire « tiret ». `magnitude` plutôt que `abs` : `abs(Int.min)` fait
    /// planter, `magnitude` jamais.
    static func spokenQuantity(_ value: Int, singular: String, plural: String) -> String {
        let unit = value.magnitude < 2 ? singular : plural
        let sign = value < 0 ? "moins " : ""
        return "\(sign)\(value.magnitude) \(unit)"
    }

    /// Libellé unique de la carte pour VoiceOver : les mêmes informations que
    /// l'écran, dans le même ordre, en phrases courtes. Le ressenti n'y figure
    /// que s'il est affiché (même règle que `details`), pour qu'un utilisateur
    /// de VoiceOver n'entende ni plus ni moins que ce que les autres voient.
    static func accessibilityLabel(
        locationName: String,
        conditionLabel: String,
        currentCelsius: Double,
        apparentCelsius: Double,
        minimumCelsius: Double,
        maximumCelsius: Double,
        windSpeedKmh: Double
    ) -> String {
        let trimmedLocation = locationName.trimmingCharacters(in: .whitespacesAndNewlines)
        let heading = trimmedLocation.isEmpty ? "Météo." : "Météo à \(trimmedLocation)."
        let apparent = showsApparentTemperature(currentCelsius: currentCelsius, apparentCelsius: apparentCelsius)
            ? ["Ressenti \(spokenTemperature(apparentCelsius))."]
            : []
        let sentences = [
            heading,
            "\(spokenTemperature(currentCelsius)).",
            "\(conditionLabel).",
            "Minimum \(spokenTemperature(minimumCelsius)), maximum \(spokenTemperature(maximumCelsius)).",
        ] + apparent + ["Vent \(spokenWindSpeed(windSpeedKmh))."]
        return sentences.joined(separator: " ")
    }
}

// MARK: - Vue

/// Carte du widget météo (1.5), affichée AU-DESSUS de la réponse quand
/// `WeatherWidgetService` a produit une donnée. Port de
/// la carte météo de la version web d'origine, refait selon `DESIGN.md`.
///
/// ## Ce qui est montré, et pourquoi pas plus
/// Le lieu (il confirme lequel a été géocodé : « Paris, Île-de-France,
/// France » et pas Paris au Texas), le symbole, la température, le libellé du
/// temps, puis au plus trois informations complémentaires — voir
/// `WeatherWidgetPresentation.details` pour leur choix.
///
/// ## Écarts assumés vis-à-vis de la version web d'origine
/// - Pas de dégradé de ciel par condition ni d'ombre portée : interdits par la
///   DA (« ne doit jamais faire IA »). La carte est en verre neutre, comme la
///   bulle assistant qu'elle surmonte.
/// - Pas de prévision sur 6 jours ni d'heure locale : `WeatherWidgetService`
///   ne demande que le jour courant à Open-Meteo et ne conserve pas
///   `current.time`. Les afficher demanderait de changer le service, ce qui
///   sort du rôle d'une vue.
/// - Pas de pastilles floutées autour de chaque détail : en verre, ce serait
///   du verre sur du verre, et sur du texte statique.
/// - Symbole en rendu `.monochrome`, teinté à l'accent comme la loupe de
///   `TrivaHomeReferenceView`. Ni `.multicolor` — le soleil jaune et la pluie
///   bleue ajouteraient des couleurs à côté de l'accent unique de la DA — ni
///   `.hierarchical`, qui dessine les calques secondaires du symbole (le
///   soleil derrière le nuage, les gouttes) en opacité réduite : posés sur du
///   verre, leur couleur changerait selon ce qui défile derrière, exactement
///   le « calque semi-transparent » que DESIGN.md interdit. Le mode est écrit
///   explicitement plutôt que laissé par défaut : sans lui, SwiftUI applique
///   le mode PRÉFÉRÉ de chaque symbole, qui n'est pas forcément monochrome.
///
/// ## Typographie
/// Uniquement des styles de texte (`.title`, `.subheadline`, `.caption`), qui
/// suivent Dynamic Type — pas les tailles fixes de `TrivaHomeReferenceView`
/// (`.system(size: 28)` ne grandit pas). Sur iOS, `.title.weight(.semibold)`
/// vaut exactement les 28 pt semibold de la DA à la taille de texte par
/// défaut ; sur macOS, `.title` mesure 22 pt, l'échelle native du Mac, à
/// laquelle le reste de la fenêtre est aussi rendu.
///
/// ## Mise en page : `ViewThatFits` plutôt qu'un test de Dynamic Type
/// Les détails (et le couple symbole + température) passent d'une ligne à une
/// colonne dès qu'ils ne tiennent plus en largeur. Tester
/// `dynamicTypeSize.isAccessibilitySize` ne couvrirait que le très grand
/// texte ; `ViewThatFits` couvre AUSSI une fenêtre Mac étroite en taille de
/// texte normale, qui pose exactement le même problème.
///
/// ## Intégration (faite à l'étape suivante, pas ici)
/// À poser comme FRÈRE de la bulle assistant, jamais à l'intérieur (verre sur
/// verre), et dans le même `GlassEffectContainer` que ses frères de verre :
/// DESIGN.md impose un seul conteneur pour des éléments de verre voisins. La
/// carte n'en ouvre pas elle-même — un conteneur pour un seul élément ne sert
/// à rien, et des conteneurs imbriqués seraient faux.
///
/// ## Pas d'état d'erreur, par construction
/// Il n'existe pas de « donnée météo en erreur » : `fetchWeather` renvoie
/// `nil` dès qu'une étape échoue, et `nil` veut dire « pas de carte ». Une
/// valeur isolée aberrante (non finie, hors plage) s'affiche « — ».
///
/// `Equatable` (synthétisée à partir de `data`) : même raison que
/// `MessageBubbleView` — le fil de chat peut appliquer `.equatable()` pour ne
/// pas réévaluer la carte à chaque token reçu pendant le streaming.
struct WeatherWidgetView: View, Equatable {
    let data: WeatherWidgetData

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !locationName.isEmpty {
                Text(locationName)
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            currentConditions
            detailsRow
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        // Un seul élément VoiceOver pour toute la carte, avec un libellé
        // écrit pour l'oreille : lus un par un, « 18° », « 12° / 22° » et
        // « 12 km/h » donneraient une suite de symboles sans contexte.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var locationName: String {
        data.location.name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var currentConditions: some View {
        VStack(alignment: .leading, spacing: 4) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    conditionSymbol
                    temperature
                }
                VStack(alignment: .leading, spacing: 4) {
                    conditionSymbol
                    temperature
                }
            }
            Text(data.condition.label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var conditionSymbol: some View {
        Image(systemName: WeatherWidgetPresentation.symbolName(
            serviceSymbolName: data.condition.systemImageName,
            isDaytime: data.isDaytime
        ))
        .font(.title)
        .symbolRenderingMode(.monochrome)
        .foregroundStyle(.tint)
        // Décoratif : le libellé du temps, juste en dessous, porte la même
        // information en texte, et le libellé VoiceOver de la carte la reprend.
        .accessibilityHidden(true)
    }

    private var temperature: some View {
        Text(WeatherWidgetPresentation.temperatureText(data.currentTemperatureCelsius))
            .font(.title.weight(.semibold))
    }

    private var detailsRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 20) {
                detailItems
            }
            VStack(alignment: .leading, spacing: 12) {
                detailItems
            }
        }
    }

    private var detailItems: some View {
        ForEach(details) { detail in
            VStack(alignment: .leading, spacing: 4) {
                Text(detail.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail.value)
                    .font(.subheadline.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var details: [WeatherWidgetDetail] {
        WeatherWidgetPresentation.details(
            minimumCelsius: data.todayMinTemperatureCelsius,
            maximumCelsius: data.todayMaxTemperatureCelsius,
            currentCelsius: data.currentTemperatureCelsius,
            apparentCelsius: data.apparentTemperatureCelsius,
            windSpeedKmh: data.windSpeedKmh
        )
    }

    private var accessibilityLabel: String {
        WeatherWidgetPresentation.accessibilityLabel(
            locationName: data.location.name,
            conditionLabel: data.condition.label,
            currentCelsius: data.currentTemperatureCelsius,
            apparentCelsius: data.apparentTemperatureCelsius,
            minimumCelsius: data.todayMinTemperatureCelsius,
            maximumCelsius: data.todayMaxTemperatureCelsius,
            windSpeedKmh: data.windSpeedKmh
        )
    }
}

// MARK: - Previews

/// Données factices construites avec la VRAIE table WMO du service
/// (`WeatherWidgetService.condition(forWMOCode:)`) plutôt qu'avec des
/// libellés et symboles inventés ici : une preview qui afficherait un symbole
/// que le service ne produit jamais ne prouverait rien.
private extension WeatherWidgetData {
    static func preview(
        locationName: String = "Paris, Île-de-France, France",
        wmoCode: Int = 2,
        current: Double = 18.4,
        apparent: Double = 16.6,
        windSpeed: Double = 12.4,
        isDaytime: Bool = true,
        minimum: Double = 12.2,
        maximum: Double = 22.7
    ) -> WeatherWidgetData {
        WeatherWidgetData(
            location: WeatherLocation(name: locationName, latitude: 48.85, longitude: 2.35),
            condition: WeatherWidgetService.condition(forWMOCode: wmoCode),
            currentTemperatureCelsius: current,
            apparentTemperatureCelsius: apparent,
            relativeHumidityPercent: 58,
            windSpeedKmh: windSpeed,
            isDaytime: isDaytime,
            todayMinTemperatureCelsius: minimum,
            todayMaxTemperatureCelsius: maximum
        )
    }
}

#Preview("Météo — jour") {
    WeatherWidgetView(data: .preview())
        .padding(20)
}

#Preview("Météo — nuit dégagée, sombre") {
    WeatherWidgetView(data: .preview(
        wmoCode: 0,
        current: 9.6,
        apparent: 7.2,
        isDaytime: false,
        minimum: 6.1,
        maximum: 15.8
    ))
    .padding(20)
    .preferredColorScheme(.dark)
}

/// État dégradé : code WMO inconnu (« Conditions inconnues »), lieu réduit
/// aux coordonnées (repli du géocodage inverse du service), température de
/// -0,4 qui doit s'afficher « 0° » et non « -0° », ressenti identique une fois
/// arrondi, donc masqué.
#Preview("Météo — dégradée") {
    WeatherWidgetView(data: .preview(
        locationName: "48.85, 2.35",
        wmoCode: 42,
        current: -0.4,
        apparent: -0.3,
        windSpeed: 3,
        minimum: -2.6,
        maximum: 4.1
    ))
    .padding(20)
}

#Preview("Météo — très grand texte, fenêtre étroite") {
    WeatherWidgetView(data: .preview(
        locationName: "Saint-Rémy-de-Provence, Provence-Alpes-Côte d'Azur, France",
        wmoCode: 65,
        current: 12.8,
        apparent: 10.1,
        windSpeed: 38.2,
        minimum: 9.4,
        maximum: 14.9
    ))
    .frame(width: 280)
    .padding(20)
    .dynamicTypeSize(.accessibility5)
}
