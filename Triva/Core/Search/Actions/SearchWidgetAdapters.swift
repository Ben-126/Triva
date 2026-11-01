//
//  SearchWidgetAdapters.swift
//  Triva
//
//  Created by ben podrojsky on 28/10/2026.
//

import Foundation

// Branchement des widgets (1.5) dans le pipeline de recherche : adaptateurs
// des services météo et calcul vers `SearchWidget`, et liste de production
// passée au `WidgetExecutor` de `SearchOrchestrator`. Rangé avec les actions
// parce que, comme elles, un widget est déclenché par la classification ;
// l'exécuteur, lui, reste générique (`Core/Widgets/WidgetExecutor.swift`).

/// Charges utiles affichables : la vue retrouve la donnée typée par un simple
/// cast (`SearchWidgetOutput.weatherData`, `.calculationData`).
extension WeatherWidgetData: SearchWidgetPayload {}
extension CalculationWidgetData: SearchWidgetPayload {}

/// Widget météo pour `WidgetExecutor` : délègue tout à `WeatherWidgetServing`
/// (extraction du lieu par LLM, géocodage, prévisions Open-Meteo). Ne lève
/// jamais : le service rend `nil` à la moindre étape manquée, et `nil` veut
/// dire « pas de widget », pas « échec ».
///
/// `shouldExecute` ne lit QUE `showWeatherWidget` : sans lui, aucun appel
/// LLM d'extraction de lieu n'est lancé (contrat « aucun appel inutile »).
nonisolated struct WeatherSearchWidget: SearchWidget {
    private let service: any WeatherWidgetServing

    init(service: any WeatherWidgetServing) {
        self.service = service
    }

    var kind: SearchWidgetKind { .weather }

    func shouldExecute(for classification: QueryClassification) -> Bool {
        classification.showWeatherWidget
    }

    func execute(_ input: SearchWidgetInput) async throws -> SearchWidgetOutput? {
        guard let result = await service.fetchWeather(forQuery: input.query, chatHistory: input.chatHistory) else {
            return nil
        }
        return SearchWidgetOutput(kind: .weather, llmContext: result.llmContext, payload: result.data)
    }
}

/// Widget calcul pour `WidgetExecutor` : extraction de l'expression par LLM,
/// puis évaluation LOCALE (`CalculationWidgetService`), sans réseau — c'est
/// ce qui permet à un calcul pur de répondre hors ligne (bug 15). Même
/// contrat que `WeatherSearchWidget`.
nonisolated struct CalculationSearchWidget: SearchWidget {
    private let service: any CalculationWidgetServing

    init(service: any CalculationWidgetServing) {
        self.service = service
    }

    var kind: SearchWidgetKind { .calculation }

    func shouldExecute(for classification: QueryClassification) -> Bool {
        classification.showCalculationWidget
    }

    func execute(_ input: SearchWidgetInput) async throws -> SearchWidgetOutput? {
        guard let result = await service.computeCalculation(forQuery: input.query, chatHistory: input.chatHistory) else {
            return nil
        }
        return SearchWidgetOutput(kind: .calculation, llmContext: result.llmContext, payload: result.data)
    }
}

extension SearchOrchestrator {
    /// Liste de PRODUCTION des widgets (1.5), dans l'ordre d'affichage : météo
    /// puis calcul (`WidgetExecutionReport` suit l'ordre d'injection, pas
    /// l'ordre d'arrivée). Aucun widget bourse : hors champ, faute d'API
    /// gratuite sans clé (`SearchWidgetKind` n'a même pas de cas pour lui).
    ///
    /// Valeur par défaut des deux inits de l'orchestrateur ; les tests passent
    /// leurs propres widgets (le vrai service météo sort sur le réseau).
    /// `@MainActor` : les deux services sont des types non annotés.
    @MainActor
    static func defaultWidgets(aiProvider: any AIGenerating) -> [any SearchWidget] {
        [
            WeatherSearchWidget(service: WeatherWidgetService(aiProvider: aiProvider)),
            CalculationSearchWidget(service: CalculationWidgetService(aiProvider: aiProvider)),
        ]
    }
}

extension SearchWidgetOutput {
    /// Donnée du widget météo, ou `nil` pour un autre widget.
    nonisolated var weatherData: WeatherWidgetData? {
        payload as? WeatherWidgetData
    }

    /// Donnée du widget calcul, ou `nil` pour un autre widget.
    nonisolated var calculationData: CalculationWidgetData? {
        payload as? CalculationWidgetData
    }
}
