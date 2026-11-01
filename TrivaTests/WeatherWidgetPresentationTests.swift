//
//  WeatherWidgetPresentationTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 02/10/2026.
//

import Testing
import Foundation
@testable import Triva

// Suites NON isolées, volontairement : `WeatherWidgetPresentation` est
// `nonisolated` et ne prend que des primitives (voir sa documentation dans
// `WeatherWidgetView.swift`). L'appeler de façon synchrone depuis un contexte
// non isolé est donc, en soi, la preuve à la compilation que cette logique
// reste utilisable hors du main actor. Seule la suite qui lit la table WMO de
// `WeatherWidgetService` (isolé au main actor par défaut) porte `@MainActor`.

/// Tous les codes documentés de la table WMO du service, plus un code inconnu
/// (42) pour couvrir la branche `default` (« Conditions inconnues »).
private let wmoCodesUnderTest = [
    0, 1, 2, 3, 45, 48, 51, 53, 55, 56, 57, 61, 63, 65, 66, 67,
    71, 73, 75, 77, 80, 81, 82, 85, 86, 95, 96, 99, 42,
]

// MARK: - Mise en forme

@Suite("WeatherWidgetPresentation — mise en forme des valeurs")
struct WeatherWidgetPresentationFormattingTests {
    @Test(
        "Température arrondie au plus proche, 0,5 s'éloignant de zéro",
        arguments: [
            (18.4, "18°"),
            (18.5, "19°"),
            (22.7, "23°"),
            (-2.5, "-3°"),
        ]
    )
    func temperatureIsRounded(celsius: Double, expected: String) {
        #expect(WeatherWidgetPresentation.temperatureText(celsius) == expected)
    }

    /// `String(format: "%.0f", -0.4)` afficherait « -0 » : le passage par
    /// `Int(exactly:)` est ce qui l'empêche.
    @Test("Jamais de « -0° »", arguments: [-0.4, -0.0, 0.3])
    func neverNegativeZero(celsius: Double) {
        #expect(WeatherWidgetPresentation.temperatureText(celsius) == "0°")
    }

    /// Boucle plutôt que `arguments:` : `nan` ne se compare pas à lui-même,
    /// ce qui rendrait l'identification des cas paramétrés peu fiable.
    @Test("Valeur aberrante : tiret cadratin, jamais de plantage")
    func aberrantValuesAreUnavailable() {
        for value in [Double.nan, .infinity, -.infinity, 1e300] {
            #expect(
                WeatherWidgetPresentation.temperatureText(value) == WeatherWidgetPresentation.unavailableValue,
                "température \(value)"
            )
            #expect(
                WeatherWidgetPresentation.windSpeedText(value) == WeatherWidgetPresentation.unavailableValue,
                "vent \(value)"
            )
        }
    }

    @Test("Vent : espace insécable entre le nombre et l'unité")
    func windSpeedUsesNoBreakSpace() {
        #expect(WeatherWidgetPresentation.windSpeedText(12.4) == "12\u{00A0}km/h")
    }

    @Test("Plage du jour : minimum puis maximum, dans l'ordre du libellé")
    func temperatureRange() {
        #expect(
            WeatherWidgetPresentation.temperatureRangeText(minimumCelsius: 12.2, maximumCelsius: 22.7) == "12° / 23°"
        )
    }
}

// MARK: - Informations complémentaires

@Suite("WeatherWidgetPresentation — informations complémentaires")
struct WeatherWidgetPresentationDetailsTests {
    @Test("Ressenti montré seulement s'il diffère une fois arrondi")
    func apparentShownOnlyWhenDifferent() {
        #expect(WeatherWidgetPresentation.showsApparentTemperature(currentCelsius: 18.4, apparentCelsius: 16.6))
        #expect(!WeatherWidgetPresentation.showsApparentTemperature(currentCelsius: 18.4, apparentCelsius: 18.3))
        // -0,4 et 0,3 s'affichent tous deux « 0° » : le ressenti n'apporte rien.
        #expect(!WeatherWidgetPresentation.showsApparentTemperature(currentCelsius: -0.4, apparentCelsius: 0.3))
    }

    @Test("Ressenti inconnu : masqué plutôt qu'affiché « — »")
    func unknownApparentIsHidden() {
        #expect(!WeatherWidgetPresentation.showsApparentTemperature(currentCelsius: 18, apparentCelsius: .nan))
    }

    @Test("Trois informations au plus, dans l'ordre plage, ressenti, vent")
    func detailsWithApparent() {
        let details = WeatherWidgetPresentation.details(
            minimumCelsius: 12.2,
            maximumCelsius: 22.7,
            currentCelsius: 18.4,
            apparentCelsius: 16.6,
            windSpeedKmh: 12.4
        )
        #expect(details == [
            WeatherWidgetDetail(label: "Min. / max.", value: "12° / 23°"),
            WeatherWidgetDetail(label: "Ressenti", value: "17°"),
            WeatherWidgetDetail(label: "Vent", value: "12\u{00A0}km/h"),
        ])
    }

    @Test("Sans ressenti utile, deux informations seulement")
    func detailsWithoutApparent() {
        let details = WeatherWidgetPresentation.details(
            minimumCelsius: 12.2,
            maximumCelsius: 22.7,
            currentCelsius: 18.4,
            apparentCelsius: 18.1,
            windSpeedKmh: 12.4
        )
        #expect(details.map(\.label) == ["Min. / max.", "Vent"])
    }
}

// MARK: - Symbole de jour et de nuit

@MainActor
@Suite("WeatherWidgetPresentation — symbole de jour et de nuit")
struct WeatherWidgetPresentationSymbolTests {
    @Test(
        "La nuit, les deux symboles solaires du service passent à la lune",
        arguments: [
            ("sun.max", "moon.stars"),
            ("cloud.sun", "cloud.moon"),
        ]
    )
    func solarSymbolsSwitchAtNight(serviceSymbol: String, expected: String) {
        #expect(WeatherWidgetPresentation.symbolName(serviceSymbolName: serviceSymbol, isDaytime: false) == expected)
    }

    /// Garde-fou contre une dérive silencieuse : la table de nuit de la vue
    /// est alignée À LA MAIN sur les symboles de `WeatherWidgetService`. Si le
    /// service change un symbole solaire (`sun.max` → `sun.max.fill`), ce
    /// test échoue au lieu de laisser un soleil s'afficher à 23 h.
    @Test("Aucun code WMO n'affiche de soleil la nuit", arguments: wmoCodesUnderTest)
    func noSunAtNight(code: Int) {
        let serviceSymbol = WeatherWidgetService.condition(forWMOCode: code).systemImageName
        let nightSymbol = WeatherWidgetPresentation.symbolName(serviceSymbolName: serviceSymbol, isDaytime: false)
        #expect(!nightSymbol.contains("sun"))
    }

    @Test("Le jour, le symbole du service est affiché tel quel", arguments: wmoCodesUnderTest)
    func daytimeKeepsServiceSymbol(code: Int) {
        let serviceSymbol = WeatherWidgetService.condition(forWMOCode: code).systemImageName
        #expect(WeatherWidgetPresentation.symbolName(serviceSymbolName: serviceSymbol, isDaytime: true) == serviceSymbol)
    }
}

// MARK: - VoiceOver

@Suite("WeatherWidgetPresentation — VoiceOver")
struct WeatherWidgetPresentationAccessibilityTests {
    @Test(
        "Accord : singulier sous 2 en valeur absolue, signe en toutes lettres",
        arguments: [
            (-12.0, "moins 12 degrés"),
            (-1.0, "moins 1 degré"),
            (-0.4, "0 degré"),
            (0.2, "0 degré"),
            (1.0, "1 degré"),
            (18.4, "18 degrés"),
        ]
    )
    func spokenTemperature(celsius: Double, expected: String) {
        #expect(WeatherWidgetPresentation.spokenTemperature(celsius) == expected)
    }

    @Test("Vent écrit en toutes lettres, jamais « km/h »")
    func spokenWindSpeed() {
        #expect(WeatherWidgetPresentation.spokenWindSpeed(1) == "1 kilomètre-heure")
        #expect(WeatherWidgetPresentation.spokenWindSpeed(12.4) == "12 kilomètres-heure")
    }

    @Test("Valeur aberrante annoncée, jamais lue « tiret cadratin »")
    func spokenUnavailableValue() {
        #expect(WeatherWidgetPresentation.spokenTemperature(.nan) == WeatherWidgetPresentation.unavailableSpokenValue)
        #expect(WeatherWidgetPresentation.spokenWindSpeed(.infinity) == WeatherWidgetPresentation.unavailableSpokenValue)
    }

    /// `abs(Int.min)` fait planter l'app ; `magnitude` jamais.
    @Test("Int.min ne fait pas planter l'accord")
    func spokenQuantityHandlesIntMin() {
        #expect(
            WeatherWidgetPresentation.spokenQuantity(.min, singular: "degré", plural: "degrés")
                == "moins 9223372036854775808 degrés"
        )
    }

    @Test("Libellé de carte : les informations de l'écran, dans le même ordre")
    func fullCardLabel() {
        let label = WeatherWidgetPresentation.accessibilityLabel(
            locationName: "Paris, Île-de-France, France",
            conditionLabel: "Partiellement nuageux",
            currentCelsius: 18.4,
            apparentCelsius: 16.6,
            minimumCelsius: 12.2,
            maximumCelsius: 22.7,
            windSpeedKmh: 12.4
        )
        #expect(label == "Météo à Paris, Île-de-France, France. 18 degrés. Partiellement nuageux. "
            + "Minimum 12 degrés, maximum 23 degrés. Ressenti 17 degrés. Vent 12 kilomètres-heure.")
    }

    @Test("Lieu vide et ressenti inutile : ni « Météo à . », ni ressenti")
    func cardLabelWithoutLocationNorApparent() {
        let label = WeatherWidgetPresentation.accessibilityLabel(
            locationName: "  ",
            conditionLabel: "Couvert",
            currentCelsius: 5,
            apparentCelsius: 5.2,
            minimumCelsius: 1,
            maximumCelsius: 7,
            windSpeedKmh: 0
        )
        #expect(label == "Météo. 5 degrés. Couvert. Minimum 1 degré, maximum 7 degrés. Vent 0 kilomètre-heure.")
    }
}
