//
//  WeatherWidgetServiceTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 19/09/2026.
//

import Testing
import Foundation
@testable import Triva

/// Provider IA factice, même principe que `MockAIGenerating` dans
/// `QueryClassifierTests.swift`/`SearchOrchestratorTests.swift` : classe
/// simple (pas un acteur personnalisé) pour hériter de l'isolation par
/// défaut du projet sans conflit.
private final class MockAIGenerating: AIGenerating {
    private(set) var receivedPrompts: [String] = []
    private let response: String

    init(response: String) {
        self.response = response
    }

    func generate(prompt: String) async throws -> String {
        receivedPrompts.append(prompt)
        return response
    }
}

private enum MockFetchError: Error, Sendable {
    case transport
}

/// `URLFetching` factice routée PAR HÔTE : `WeatherWidgetService` appelle
/// deux hôtes différents (géocodage puis prévisions) dans le même pipeline
/// `fetchWeather` — une seule réponse fixe (comme `ScrapeServiceTests`, un
/// seul hôte scrapé à la fois) ne suffirait pas à tester le flux complet.
private struct MockURLFetching: URLFetching {
    enum Behavior: Sendable {
        case success(data: Data, statusCode: Int)
        case failure(MockFetchError)
    }

    /// Une entrée par hôte attendu ; un hôte non enregistré ici est une
    /// erreur de test (signale un appel réseau inattendu) plutôt qu'un repli
    /// silencieux qui masquerait un bug de construction d'URL.
    let behaviorByHost: [String: Behavior]

    func fetch(url: URL, timeout: TimeInterval) async throws -> (Data, URLResponse) {
        guard let host = url.host, let behavior = behaviorByHost[host] else {
            Issue.record("Appel réseau inattendu vers un hôte non mocké : \(url.absoluteString)")
            throw MockFetchError.transport
        }
        switch behavior {
        case .success(let data, let statusCode):
            let response = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
            return (data, response)
        case .failure(let error):
            throw error
        }
    }
}

/// Fixtures JSON capturées au format réel des deux endpoints Open-Meteo
/// utilisés (géocodage + prévisions), réduites aux champs demandés par
/// `WeatherWidgetService` — même principe que les fixtures inline de
/// `SearXNGClientTests`/`OpenAICompatibleClientTests`.
private enum Fixtures {
    static let geocodingSuccess = """
    {
      "results": [
        { "id": 2988507, "name": "Paris", "latitude": 48.85341, "longitude": 2.3488, "country": "France", "admin1": "Île-de-France" }
      ],
      "generationtime_ms": 0.5
    }
    """

    static let geocodingEmpty = """
    { "generationtime_ms": 0.4 }
    """

    static let forecastSuccess = """
    {
      "latitude": 48.85,
      "longitude": 2.35,
      "current": {
        "time": "2026-09-19T14:00",
        "interval": 900,
        "temperature_2m": 21.3,
        "relative_humidity_2m": 58,
        "apparent_temperature": 20.7,
        "is_day": 1,
        "weather_code": 2,
        "wind_speed_10m": 12.4
      },
      "daily": {
        "time": ["2026-09-19"],
        "temperature_2m_max": [23.1],
        "temperature_2m_min": [14.6]
      }
    }
    """

    static let forecastMissingDaily = """
    {
      "latitude": 48.85,
      "longitude": 2.35,
      "current": {
        "temperature_2m": 21.3,
        "relative_humidity_2m": 58,
        "apparent_temperature": 20.7,
        "is_day": 1,
        "weather_code": 2,
        "wind_speed_10m": 12.4
      },
      "daily": {
        "time": [],
        "temperature_2m_max": [],
        "temperature_2m_min": []
      }
    }
    """
}

@MainActor
@Suite("WeatherWidgetService")
struct WeatherWidgetServiceTests {
    // MARK: - parseExtraction

    @Test("JSON bien formé avec un nom de lieu")
    func parseExtractionWithLocationName() {
        let raw = """
        { "location": "Paris, France", "lat": 0, "lon": 0, "notPresent": false }
        """
        #expect(WeatherWidgetService.parseExtraction(raw) == .name("Paris, France"))
    }

    @Test("JSON bien formé avec des coordonnées (location vide)")
    func parseExtractionWithCoordinates() {
        let raw = """
        { "location": "", "lat": 48.8534, "lon": 2.3488, "notPresent": false }
        """
        #expect(WeatherWidgetService.parseExtraction(raw) == .coordinates(latitude: 48.8534, longitude: 2.3488))
    }

    @Test("notPresent à true : aucun lieu, quel que soit le reste du JSON")
    func parseExtractionNotPresentTrue() {
        let raw = """
        { "location": "Paris", "lat": 0, "lon": 0, "notPresent": true }
        """
        #expect(WeatherWidgetService.parseExtraction(raw) == nil)
    }

    @Test("location vide ET coordonnées à 0/0 (valeur de remplissage du prompt) : aucun lieu exploitable")
    func parseExtractionEmptyLocationAndZeroCoordinates() {
        let raw = """
        { "location": "", "lat": 0, "lon": 0, "notPresent": false }
        """
        #expect(WeatherWidgetService.parseExtraction(raw) == nil)
    }

    @Test("Sortie bruitée dans un bloc markdown ```json ... ```")
    func parseExtractionFencedMarkdownBlock() {
        let raw = """
        Voici le résultat :
        ```json
        { "location": "Lyon", "lat": 0, "lon": 0, "notPresent": false }
        ```
        Merci de votre patience.
        """
        #expect(WeatherWidgetService.parseExtraction(raw) == .name("Lyon"))
    }

    @Test("Sortie sans accolades du tout : repli nil (pas de crash)")
    func parseExtractionNoJSONAtAll() {
        #expect(WeatherWidgetService.parseExtraction("Je ne sais pas de quel lieu il s'agit.") == nil)
    }

    @Test("Champ notPresent d'un mauvais type (chaîne au lieu de booléen) : candidat rejeté, repli nil")
    func parseExtractionWrongTypeField() {
        let raw = """
        { "location": "Paris", "lat": 0, "lon": 0, "notPresent": "non" }
        """
        #expect(WeatherWidgetService.parseExtraction(raw) == nil)
    }

    @Test("Coordonnées hors bornes valides : rejetées comme non plausibles")
    func parseExtractionOutOfRangeCoordinates() {
        let raw = """
        { "location": "", "lat": 999, "lon": 2.3488, "notPresent": false }
        """
        #expect(WeatherWidgetService.parseExtraction(raw) == nil)
    }

    // MARK: - condition(forWMOCode:)

    @Test("Table WMO : quelques codes documentés donnent le libellé FR et le symbole attendus", arguments: [
        (0, "Ciel dégagé", "sun.max"),
        (3, "Couvert", "cloud"),
        (45, "Brouillard", "cloud.fog"),
        (61, "Pluie faible", "cloud.rain"),
        (71, "Neige faible", "snow"),
        (95, "Orage", "cloud.bolt"),
        (99, "Orage avec grêle forte", "cloud.bolt.rain"),
    ])
    func conditionForKnownWMOCodes(code: Int, expectedLabel: String, expectedSymbol: String) {
        let condition = WeatherWidgetService.condition(forWMOCode: code)
        #expect(condition.label == expectedLabel)
        #expect(condition.systemImageName == expectedSymbol)
    }

    @Test("Tous les codes WMO documentés par Open-Meteo sont couverts (aucun ne retombe sur le défaut)")
    func conditionCoversEveryDocumentedWMOCode() {
        let documentedCodes = [0, 1, 2, 3, 45, 48, 51, 53, 55, 56, 57, 61, 63, 65, 66, 67, 71, 73, 75, 77, 80, 81, 82, 85, 86, 95, 96, 99]
        let defaultLabel = WeatherWidgetService.condition(forWMOCode: -1).label

        for code in documentedCodes {
            #expect(WeatherWidgetService.condition(forWMOCode: code).label != defaultLabel, "Code \(code) ne devrait pas retomber sur le défaut")
        }
    }

    @Test("Code WMO inconnu : repli sûr documenté, jamais de crash")
    func conditionForUnknownWMOCode() {
        let condition = WeatherWidgetService.condition(forWMOCode: 12345)
        #expect(condition.label == "Conditions inconnues")
        #expect(condition.systemImageName == "questionmark.circle")
    }

    // MARK: - geocode

    @Test("Géocodage réussi : coordonnées et nom affiché composé (nom, région, pays)")
    func geocodeSuccess() async throws {
        let fetcher = MockURLFetching(behaviorByHost: [
            "geocoding-api.open-meteo.com": .success(data: Data(Fixtures.geocodingSuccess.utf8), statusCode: 200)
        ])
        let service = WeatherWidgetService(aiProvider: MockAIGenerating(response: ""), fetcher: fetcher)

        let location = try await service.geocode(locationName: "Paris")

        #expect(location.latitude == 48.85341)
        #expect(location.longitude == 2.3488)
        #expect(location.name == "Paris, Île-de-France, France")
    }

    @Test("Géocodage sans résultat : locationNotFound")
    func geocodeNoResults() async {
        let fetcher = MockURLFetching(behaviorByHost: [
            "geocoding-api.open-meteo.com": .success(data: Data(Fixtures.geocodingEmpty.utf8), statusCode: 200)
        ])
        let service = WeatherWidgetService(aiProvider: MockAIGenerating(response: ""), fetcher: fetcher)

        await #expect(throws: WeatherWidgetError.locationNotFound) {
            _ = try await service.geocode(locationName: "Lieuquinexistepas")
        }
    }

    @Test("Erreur réseau de transport pendant le géocodage : transportError")
    func geocodeTransportError() async {
        let fetcher = MockURLFetching(behaviorByHost: [
            "geocoding-api.open-meteo.com": .failure(.transport)
        ])
        let service = WeatherWidgetService(aiProvider: MockAIGenerating(response: ""), fetcher: fetcher)

        await #expect(throws: WeatherWidgetError.transportError) {
            _ = try await service.geocode(locationName: "Paris")
        }
    }

    @Test("Statut HTTP d'erreur pendant le géocodage : httpError avec le bon code")
    func geocodeHTTPError() async {
        let fetcher = MockURLFetching(behaviorByHost: [
            "geocoding-api.open-meteo.com": .success(data: Data(), statusCode: 503)
        ])
        let service = WeatherWidgetService(aiProvider: MockAIGenerating(response: ""), fetcher: fetcher)

        await #expect(throws: WeatherWidgetError.httpError(statusCode: 503)) {
            _ = try await service.geocode(locationName: "Paris")
        }
    }

    @Test("Corps de réponse illisible (pas du JSON) : decodingFailed")
    func geocodeDecodingFailed() async {
        let fetcher = MockURLFetching(behaviorByHost: [
            "geocoding-api.open-meteo.com": .success(data: Data("<html>pas du json</html>".utf8), statusCode: 200)
        ])
        let service = WeatherWidgetService(aiProvider: MockAIGenerating(response: ""), fetcher: fetcher)

        await #expect(throws: WeatherWidgetError.decodingFailed) {
            _ = try await service.geocode(locationName: "Paris")
        }
    }

    // MARK: - forecast

    @Test("Prévisions décodées : tous les champs de WeatherWidgetData sont correctement mappés")
    func forecastDecodesAllFields() async throws {
        let fetcher = MockURLFetching(behaviorByHost: [
            "api.open-meteo.com": .success(data: Data(Fixtures.forecastSuccess.utf8), statusCode: 200)
        ])
        let service = WeatherWidgetService(aiProvider: MockAIGenerating(response: ""), fetcher: fetcher)
        let location = WeatherLocation(name: "Paris, France", latitude: 48.85, longitude: 2.35)

        let data = try await service.forecast(for: location)

        #expect(data.location == location)
        #expect(data.currentTemperatureCelsius == 21.3)
        #expect(data.apparentTemperatureCelsius == 20.7)
        #expect(data.relativeHumidityPercent == 58)
        #expect(data.windSpeedKmh == 12.4)
        #expect(data.isDaytime == true)
        #expect(data.todayMinTemperatureCelsius == 14.6)
        #expect(data.todayMaxTemperatureCelsius == 23.1)
        #expect(data.condition == WeatherCondition(label: "Partiellement nuageux", systemImageName: "cloud.sun"))
    }

    @Test("Tableaux daily vides (jour manquant) : decodingFailed plutôt qu'un crash sur .first")
    func forecastMissingDailyArraysFails() async {
        let fetcher = MockURLFetching(behaviorByHost: [
            "api.open-meteo.com": .success(data: Data(Fixtures.forecastMissingDaily.utf8), statusCode: 200)
        ])
        let service = WeatherWidgetService(aiProvider: MockAIGenerating(response: ""), fetcher: fetcher)
        let location = WeatherLocation(name: "Paris", latitude: 48.85, longitude: 2.35)

        await #expect(throws: WeatherWidgetError.decodingFailed) {
            _ = try await service.forecast(for: location)
        }
    }

    @Test("Timeout réseau pendant les prévisions : transportError")
    func forecastTimeout() async {
        let fetcher = MockURLFetching(behaviorByHost: [
            "api.open-meteo.com": .failure(.transport)
        ])
        let service = WeatherWidgetService(aiProvider: MockAIGenerating(response: ""), fetcher: fetcher)
        let location = WeatherLocation(name: "Paris", latitude: 48.85, longitude: 2.35)

        await #expect(throws: WeatherWidgetError.transportError) {
            _ = try await service.forecast(for: location)
        }
    }

    @Test("URL de prévisions : latitude/longitude/champs current+daily/timezone=auto sont bien présents")
    func forecastBuildsExpectedURL() async throws {
        final class CapturingFetcher: URLFetching, @unchecked Sendable {
            private(set) var capturedURL: URL?
            func fetch(url: URL, timeout: TimeInterval) async throws -> (Data, URLResponse) {
                capturedURL = url
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (Data(Fixtures.forecastSuccess.utf8), response)
            }
        }
        let capturingFetcher = CapturingFetcher()
        let service = WeatherWidgetService(aiProvider: MockAIGenerating(response: ""), fetcher: capturingFetcher)
        let location = WeatherLocation(name: "Paris", latitude: 48.85341, longitude: 2.3488)

        _ = try await service.forecast(for: location)

        let query = try #require(capturingFetcher.capturedURL?.query)
        #expect(query.contains("latitude=48.85341"))
        #expect(query.contains("longitude=2.3488"))
        #expect(query.contains("current=temperature_2m,relative_humidity_2m,apparent_temperature,is_day,weather_code,wind_speed_10m"))
        #expect(query.contains("daily=temperature_2m_max,temperature_2m_min"))
        #expect(query.contains("timezone=auto"))
    }

    @Test("URL de géocodage : un « + » dans le nom de lieu part en %2B, pas en espace")
    func geocodeEncodesLiteralPlus() async throws {
        final class CapturingFetcher: URLFetching, @unchecked Sendable {
            private(set) var capturedURL: URL?
            func fetch(url: URL, timeout: TimeInterval) async throws -> (Data, URLResponse) {
                capturedURL = url
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (Data(Fixtures.geocodingSuccess.utf8), response)
            }
        }
        let capturingFetcher = CapturingFetcher()
        let service = WeatherWidgetService(aiProvider: MockAIGenerating(response: ""), fetcher: capturingFetcher)

        _ = try await service.geocode(locationName: "A+B ville")

        let query = try #require(capturingFetcher.capturedURL?.query(percentEncoded: true))
        #expect(query.contains("name=A%2BB%20ville"))
    }

    // MARK: - fetchWeather (pipeline complet)

    @Test("Pipeline complet avec un nom de lieu : extraction -> géocodage -> prévisions -> llmContext cohérent")
    func fetchWeatherFullPipelineWithLocationName() async {
        let ai = MockAIGenerating(response: """
        { "location": "Paris", "lat": 0, "lon": 0, "notPresent": false }
        """)
        let fetcher = MockURLFetching(behaviorByHost: [
            "geocoding-api.open-meteo.com": .success(data: Data(Fixtures.geocodingSuccess.utf8), statusCode: 200),
            "api.open-meteo.com": .success(data: Data(Fixtures.forecastSuccess.utf8), statusCode: 200),
        ])
        let service = WeatherWidgetService(aiProvider: ai, fetcher: fetcher)

        let result = await service.fetchWeather(forQuery: "Quel temps fait-il à Paris ?", chatHistory: [])

        let unwrapped = try? #require(result)
        #expect(unwrapped?.data.location.name == "Paris, Île-de-France, France")
        #expect(unwrapped?.llmContext.contains("Paris, Île-de-France, France") == true)
        #expect(unwrapped?.llmContext.contains("21°C") == true)
        #expect(unwrapped?.llmContext.contains("partiellement nuageux") == true)
    }

    @Test("Pipeline complet avec des coordonnées directes : géocodage inverse de secours puis prévisions")
    func fetchWeatherFullPipelineWithCoordinates() async {
        let ai = MockAIGenerating(response: """
        { "location": "", "lat": 48.85341, "lon": 2.3488, "notPresent": false }
        """)
        let fetcher = MockURLFetching(behaviorByHost: [
            "api.open-meteo.com": .success(data: Data(Fixtures.forecastSuccess.utf8), statusCode: 200)
        ])
        let service = WeatherWidgetService(aiProvider: ai, fetcher: fetcher)

        let result = await service.fetchWeather(forQuery: "météo ici", chatHistory: [])

        #expect(result?.data.location.latitude == 48.85341)
        #expect(result?.data.location.name == "48.85, 2.35")
    }

    @Test("Le LLM indique notPresent : le widget ne s'affiche pas (nil, pas une erreur)")
    func fetchWeatherReturnsNilWhenLLMSaysNotPresent() async {
        let ai = MockAIGenerating(response: """
        { "location": "", "lat": 0, "lon": 0, "notPresent": true }
        """)
        let service = WeatherWidgetService(aiProvider: ai, fetcher: MockURLFetching(behaviorByHost: [:]))

        let result = await service.fetchWeather(forQuery: "raconte-moi une blague", chatHistory: [])

        #expect(result == nil)
    }

    @Test("Géocodage sans résultat pendant le pipeline complet : nil, pas de crash")
    func fetchWeatherReturnsNilWhenGeocodingFails() async {
        let ai = MockAIGenerating(response: """
        { "location": "Lieuquinexistepas", "lat": 0, "lon": 0, "notPresent": false }
        """)
        let fetcher = MockURLFetching(behaviorByHost: [
            "geocoding-api.open-meteo.com": .success(data: Data(Fixtures.geocodingEmpty.utf8), statusCode: 200)
        ])
        let service = WeatherWidgetService(aiProvider: ai, fetcher: fetcher)

        let result = await service.fetchWeather(forQuery: "météo à un endroit imaginaire", chatHistory: [])

        #expect(result == nil)
    }

    @Test("Sortie LLM totalement injustifiable (aucun JSON) : nil, pas de crash")
    func fetchWeatherReturnsNilWhenLLMOutputUnparseable() async {
        let ai = MockAIGenerating(response: "je ne comprends pas la demande")
        let service = WeatherWidgetService(aiProvider: ai, fetcher: MockURLFetching(behaviorByHost: [:]))

        let result = await service.fetchWeather(forQuery: "bonjour", chatHistory: [])

        #expect(result == nil)
    }

    // MARK: - buildExtractionPrompt

    @Test("Le prompt d'extraction inclut la requête et l'historique tronqué au nombre demandé")
    func buildExtractionPromptIncludesQueryAndTruncatedHistory() {
        let history = (1...10).map { ClassifierChatMessage(role: .user, content: "message \($0)") }

        let prompt = WeatherWidgetService.buildExtractionPrompt(query: "météo à Paris", chatHistory: history, maxHistoryMessages: 3)

        #expect(prompt.contains("<user_query>\nmétéo à Paris\n</user_query>"))
        #expect(prompt.contains("message 8"))
        #expect(prompt.contains("message 10"))
        #expect(!prompt.contains("message 7"))
    }
}
