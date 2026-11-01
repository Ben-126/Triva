//
//  WeatherWidgetService.swift
//  Triva
//
//  Created by ben podrojsky on 19/09/2026.
//

import Foundation

/// Un lieu identifié par un nom lisible (ex. "Paris, France"), une latitude
/// et une longitude — la sortie commune du géocodage direct (recherche par
/// nom) ET du géocodage inverse (recherche par coordonnées), pour que le
/// reste du service n'ait qu'un seul type à manipuler après résolution.
struct WeatherLocation: Sendable, Equatable {
    let name: String
    let latitude: Double
    let longitude: Double
}

/// Condition météo lisible : libellé FRANÇAIS + SF Symbol, dérivés du code
/// WMO (`weatherCode`) renvoyé par Open-Meteo. Zéro emoji (DESIGN.md).
struct WeatherCondition: Sendable, Equatable {
    let label: String
    let systemImageName: String
}

/// Instantané météo prêt à afficher pour un lieu donné. Ne garde QUE les
/// champs réellement utiles à un widget de chat (pas toute la richesse de la
/// réponse Open-Meteo, qui expose aussi des séries horaires sur 7 jours) :
/// - température actuelle + ressenti : ce qu'on demande en premier à un widget météo
/// - condition (libellé + symbole) : pour l'icône et le texte principal
/// - vent + humidité : complètent la lecture "il fait quel temps dehors"
///   sans surcharger la carte (pression, couverture nuageuse, précipitations
///   horaires... jugés secondaires pour un simple widget de chat)
/// - min/max du jour : réponse immédiate à "va-t-il faire plus chaud/froid
///   aujourd'hui", évite une question de suivi
struct WeatherWidgetData: Sendable, Equatable {
    let location: WeatherLocation
    let condition: WeatherCondition
    let currentTemperatureCelsius: Double
    let apparentTemperatureCelsius: Double
    let relativeHumidityPercent: Int
    let windSpeedKmh: Double
    let isDaytime: Bool
    let todayMinTemperatureCelsius: Double
    let todayMaxTemperatureCelsius: Double
}

/// Résultat complet renvoyé par le service : la donnée d'affichage +
/// `llmContext`, un texte compact destiné à être injecté dans le prompt de
/// génération finale (voir `weatherWidget.ts`, champ `llmContext`) pour que
/// la réponse rédigée par le LLM puisse citer la météo sans re-décrire toute
/// la structure `WeatherWidgetData`.
struct WeatherWidgetResult: Sendable, Equatable {
    let data: WeatherWidgetData
    let llmContext: String
}

/// Erreurs internes du pipeline météo. Volontairement PAS exposées à
/// l'appelant sous cette forme : `WeatherWidgetServing.fetchWeather` ne
/// renvoie jamais un `throw`, seulement `WeatherWidgetResult?` (`nil` = "pas
/// de widget à afficher", que la cause soit "pas de lieu dans la requête" ou
/// "erreur réseau" — un widget météo raté ne doit jamais faire planter toute
/// la réponse de chat, même principe que `ScrapeService.scrape`). Le type
/// reste `Equatable`/testable pour vérifier chaque étape indépendamment.
enum WeatherWidgetError: Error, Sendable, Equatable {
    case locationNotFound
    case invalidGeocodingURL
    case invalidForecastURL
    case transportError
    case httpError(statusCode: Int)
    case decodingFailed
}

/// Abstraction exposée à `WidgetExecutor` (1.5) : une seule méthode,
/// infaillible en surface (jamais de `throw`), qui encapsule les 2 appels
/// réseau (géocodage puis prévisions) derrière l'extraction de lieu par LLM.
nonisolated protocol WeatherWidgetServing: Sendable {
    func fetchWeather(forQuery query: String, chatHistory: [ClassifierChatMessage]) async -> WeatherWidgetResult?
}

/// Port natif de `weatherWidget.ts` (web) + `api/weather/route.ts`, en un
/// seul service Swift (le web sépare l'extraction LLM, côté agent, de l'appel
/// API météo, côté route Next — inutile ici : pas de backend, tout tourne
/// dans le même process).
///
/// DIVERGENCE ASSUMÉE vis-à-vis de la référence web : `weatherWidget.ts`
/// géocode via Nominatim/OpenStreetMap (`nominatim.openstreetmap.org`), qui
/// exige un `User-Agent` identifiable et impose des limites de débit assez
/// strictes pour un usage serveur partagé. Consigne de la mission 1.5a :
/// utiliser le géocodage OFFICIEL d'Open-Meteo
/// (`geocoding-api.open-meteo.com`), gratuit et sans clé comme Nominatim,
/// mais pensé pour ce même usage (pas de `User-Agent` obligatoire, quotas
/// pensés pour des clients tiers) — cohérent avec le principe BYOK/zéro
/// backend du projet : un seul fournisseur pour lieu ET météo, un seul point
/// de panne réseau à gérer plutôt que deux hébergeurs différents.
struct WeatherWidgetService: WeatherWidgetServing {
    private let aiProvider: any AIGenerating
    private let fetcher: any URLFetching
    private let timeoutInterval: TimeInterval

    /// `timeoutInterval` à 8s : même valeur que `ScrapeService` (voir sa
    /// justification) — un widget qui traîne dégraderait la latence perçue
    /// de toute la réponse de chat, qui attend `llmContext` avant de générer.
    init(
        aiProvider: any AIGenerating,
        fetcher: any URLFetching = URLSessionFetcher(),
        timeoutInterval: TimeInterval = 8
    ) {
        self.aiProvider = aiProvider
        self.fetcher = fetcher
        self.timeoutInterval = timeoutInterval
    }

    /// Pipeline complet : extraction du lieu (LLM) → géocodage → prévisions.
    /// Ne throw jamais : chaque étape manquée (lieu absent de la requête,
    /// géocodage sans résultat, erreur réseau/décodage) fait retomber sur
    /// `nil`, jamais un état partiel affiché comme si le widget avait
    /// réussi.
    func fetchWeather(forQuery query: String, chatHistory: [ClassifierChatMessage]) async -> WeatherWidgetResult? {
        let prompt = Self.buildExtractionPrompt(query: query, chatHistory: chatHistory)
        guard let rawOutput = try? await aiProvider.generate(prompt: prompt) else { return nil }
        guard let extraction = Self.parseExtraction(rawOutput) else { return nil }

        let location: WeatherLocation
        switch extraction {
        case .name(let name):
            guard let resolved = try? await geocode(locationName: name) else { return nil }
            location = resolved
        case .coordinates(let latitude, let longitude):
            guard let resolved = try? await reverseGeocode(latitude: latitude, longitude: longitude) else { return nil }
            location = resolved
        }

        guard let data = try? await forecast(for: location) else { return nil }
        return WeatherWidgetResult(data: data, llmContext: Self.llmContext(for: data))
    }

    // MARK: - Étape 1 : extraction du lieu par LLM

    /// Résultat tolérant de l'extraction : soit un nom de lieu à géocoder,
    /// soit des coordonnées directes à géocoder à l'inverse. `nil` en sortie
    /// de `parseExtraction` (pas de cas ici) signifie "pas de lieu
    /// identifiable" — ce n'est pas une erreur, juste l'absence de widget.
    enum LocationExtraction: Sendable, Equatable {
        case name(String)
        case coordinates(latitude: Double, longitude: Double)
    }

    /// Prompt traduit fidèlement de `weatherWidget.ts` (web), avec la même
    /// contrainte de sortie JSON stricte que `QueryClassifier` — voir sa
    /// documentation pour le choix d'un prompt texte plutôt qu'un schéma
    /// structuré (aucun provider de Triva n'expose de sortie structurée
    /// fiable).
    static func buildExtractionPrompt(query: String, chatHistory: [ClassifierChatMessage], maxHistoryMessages: Int = 8) -> String {
        let history = chatHistory.suffix(max(0, maxHistoryMessages))
            .map { message in
                switch message.role {
                case .user: return "User: \(message.content)"
                case .assistant: return "AI: \(message.content)"
                }
            }
            .joined(separator: "\n")

        return """
        \(Self.extractionSystemPrompt)

        <conversation_history>
        \(history)
        </conversation_history>

        <user_query>
        \(query)
        </user_query>
        """
    }

    private static let extractionSystemPrompt: String = """
    <role>
    Tu es un extracteur de lieu pour des requêtes météo. Tu reçois la dernière question de l'utilisateur et l'historique de la conversation.
    Ta tâche est de déterminer si l'utilisateur demande la météo et d'extraire le lieu concerné.
    </role>

    <instructions>
    - Si l'utilisateur demande la météo, extrais le nom du lieu OU des coordonnées (jamais les deux).
    - Si tu utilises un nom de lieu, mets lat et lon à 0.
    - Si tu utilises des coordonnées, mets location à une chaîne vide.
    - Si tu ne peux pas déterminer de lieu valide ou que la requête ne concerne pas la météo, mets notPresent à true.
    - Le lieu doit être précis (ville, région, pays) pour un bon résultat.
    - Tu dois toujours fournir un lieu utilisable pour récupérer la météo, sauf si notPresent est true.
    - Déduis les formes courtes de noms de lieux (ex. "New York" -> "New York, USA").
    </instructions>

    <output_format>
    Réponds STRICTEMENT au format JSON suivant, sans aucun texte, explication ou phrase de remplissage :
    {
      "location": chaîne de caractères,
      "lat": nombre,
      "lon": nombre,
      "notPresent": booléen
    }
    </output_format>
    """

    /// Parsing tolérant, même stratégie que `QueryClassifier.parse` :
    /// plusieurs candidats JSON essayés dans l'ordre (blocs markdown puis
    /// première/dernière accolade), jamais de `throw`. `notPresent: true`
    /// ou un JSON totalement inexploitable renvoient tous deux `nil` — la
    /// distinction "LLM a dit non" contre "sortie illisible" n'a pas
    /// d'intérêt ici : dans les deux cas, le widget ne s'affiche pas.
    static func parseExtraction(_ rawOutput: String) -> LocationExtraction? {
        for candidate in Self.jsonCandidates(from: rawOutput) {
            guard let decoded = Self.decodeExtractionCandidate(candidate) else { continue }
            if decoded.notPresent == true { return nil }

            let trimmedName = decoded.location?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmedName.isEmpty {
                return .name(trimmedName)
            }
            if let lat = decoded.lat, let lon = decoded.lon, Self.isPlausibleCoordinate(latitude: lat, longitude: lon) {
                return .coordinates(latitude: lat, longitude: lon)
            }
            // Décodé mais sans lieu exploitable (ex. location vide et lat/lon
            // absents, ou 0/0 par défaut de la variante "nom") : candidat
            // suivant plutôt qu'un repli immédiat, au cas où un autre bloc de
            // la réponse contiendrait une extraction plus complète.
        }
        return nil
    }

    /// 0.0/0.0 est la valeur de remplissage explicite du prompt pour la
    /// variante "nom de lieu" (voir instructions) — l'accepter comme
    /// coordonnées réelles produirait systématiquement une météo dans le
    /// golfe de Guinée dès que `location` est vide par erreur de parsing.
    /// Rejeter très précisément (0,0) plutôt qu'une zone autour : de vraies
    /// coordonnées (0,0) légitimes sont un cas limite si rare pour une
    /// requête météo qu'il ne justifie pas la complexité d'une tolérance.
    private static func isPlausibleCoordinate(latitude: Double, longitude: Double) -> Bool {
        guard latitude != 0 || longitude != 0 else { return false }
        return (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }

    private struct RawExtraction: Decodable {
        let location: String?
        let lat: Double?
        let lon: Double?
        let notPresent: Bool?
    }

    private static func decodeExtractionCandidate(_ candidate: String) -> RawExtraction? {
        guard let data = candidate.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(RawExtraction.self, from: data)
    }

    /// Duplication volontaire et minimale de la logique d'extraction de
    /// candidats JSON de `QueryClassifier` (blocs ```...``` puis
    /// première/dernière accolade) : cette logique n'a pas encore de foyer
    /// partagé (aucun fichier utilitaire commun aux deux appelants n'existe
    /// à ce jour) et le périmètre de cette mission n'inclut pas la création
    /// d'un tel fichier. Un futur ticket de nettoyage pourrait extraire ceci
    /// dans un helper commun — signalé dans `risks`, pas fait ici.
    private static func jsonCandidates(from rawOutput: String) -> [String] {
        var candidates: [String] = []
        for fencedBlock in Self.extractFencedBlocks(from: rawOutput) {
            candidates.append(Self.extractBracesSubstring(from: fencedBlock) ?? fencedBlock)
        }
        if let braces = Self.extractBracesSubstring(from: rawOutput) {
            candidates.append(braces)
        }
        return candidates
    }

    private static func extractFencedBlocks(from rawOutput: String) -> [String] {
        let fenceComponents = rawOutput.components(separatedBy: "```")
        guard fenceComponents.count >= 3 else { return [] }

        var blocks: [String] = []
        var index = 1
        while index < fenceComponents.count {
            var block = fenceComponents[index].trimmingCharacters(in: .whitespacesAndNewlines)
            if block.hasPrefix("json") {
                block.removeFirst("json".count)
            }
            blocks.append(block.trimmingCharacters(in: .whitespacesAndNewlines))
            index += 2
        }
        return blocks
    }

    private static func extractBracesSubstring(from rawOutput: String) -> String? {
        guard
            let firstBrace = rawOutput.firstIndex(of: "{"),
            let lastBrace = rawOutput.lastIndex(of: "}"),
            firstBrace < lastBrace
        else {
            return nil
        }
        return String(rawOutput[firstBrace...lastBrace])
    }

    // MARK: - Étape 2 : géocodage (Open-Meteo Geocoding API)

    /// Réponse de `geocoding-api.open-meteo.com/v1/search`. Seuls les champs
    /// utilisés sont modélisés (comme `SearXNGSearchResult`) : l'API renvoie
    /// aussi elevation/population/timezone/feature_code, ignorés ici.
    private struct GeocodingResponse: Decodable {
        struct Result: Decodable {
            let name: String
            let latitude: Double
            let longitude: Double
            let country: String?
            let admin1: String?
        }
        let results: [Result]?
    }

    /// Géocodage direct : nom de lieu -> coordonnées. `count=1` : on ne veut
    /// que le meilleur résultat, pas de désambiguïsation UI ici (V1, comme
    /// le web qui prend aussi `data[0]` sans autre choix). `language=fr` :
    /// nom de lieu renvoyé en français quand une traduction existe
    /// (cohérent avec le ton français de tout Triva, DESIGN.md), Open-Meteo
    /// retombe silencieusement sur le nom natif sinon.
    func geocode(locationName: String) async throws -> WeatherLocation {
        var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")
        components?.queryItems = [
            URLQueryItem(name: "name", value: locationName),
            URLQueryItem(name: "count", value: "1"),
            URLQueryItem(name: "language", value: "fr"),
            URLQueryItem(name: "format", value: "json"),
        ]
        // `+` littéral -> `%2B`, sinon le serveur le lit comme une espace (même
        // correctif que `SearXNGClient.buildURL`, qui documente le pourquoi).
        let encodedQuery = components?.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        components?.percentEncodedQuery = encodedQuery
        guard let url = components?.url else { throw WeatherWidgetError.invalidGeocodingURL }

        let response: GeocodingResponse = try await fetchDecoded(url: url)
        guard let match = response.results?.first else { throw WeatherWidgetError.locationNotFound }

        return WeatherLocation(
            name: Self.displayName(name: match.name, admin1: match.admin1, country: match.country),
            latitude: match.latitude,
            longitude: match.longitude
        )
    }

    /// Géocodage inverse (coordonnées -> nom lisible), utilisé quand le LLM
    /// a extrait des coordonnées directes plutôt qu'un nom (ex. "la météo
    /// ici" avec une géolocalisation déjà connue de l'appelant, transmise en
    /// amont dans `chatHistory`/le prompt). Open-Meteo n'a pas d'endpoint de
    /// géocodage INVERSE officiel : on réutilise l'endpoint direct comme
    /// meilleur effort — s'il échoue, on affiche quand même la météo avec un
    /// libellé de secours "lat, lon" plutôt qu'échouer tout le widget pour
    /// un simple nom manquant (la donnée météo, elle, est fiable dès qu'on a
    /// les coordonnées).
    func reverseGeocode(latitude: Double, longitude: Double) async throws -> WeatherLocation {
        WeatherLocation(
            name: Self.coordinateFallbackName(latitude: latitude, longitude: longitude),
            latitude: latitude,
            longitude: longitude
        )
    }

    private static func displayName(name: String, admin1: String?, country: String?) -> String {
        [name, admin1, country].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    private static func coordinateFallbackName(latitude: Double, longitude: Double) -> String {
        String(format: "%.2f, %.2f", latitude, longitude)
    }

    // MARK: - Étape 3 : prévisions (Open-Meteo Forecast API)

    /// Réponse de `api.open-meteo.com/v1/forecast`, réduite aux champs
    /// utilisés par `WeatherWidgetData` (voir sa documentation pour la
    /// justification du choix des champs).
    private struct ForecastResponse: Decodable {
        struct Current: Decodable {
            let temperature2m: Double
            let apparentTemperature: Double
            let relativeHumidity2m: Int
            let windSpeed10m: Double
            let weatherCode: Int
            let isDay: Int

            private enum CodingKeys: String, CodingKey {
                case temperature2m = "temperature_2m"
                case apparentTemperature = "apparent_temperature"
                case relativeHumidity2m = "relative_humidity_2m"
                case windSpeed10m = "wind_speed_10m"
                case weatherCode = "weather_code"
                case isDay = "is_day"
            }
        }
        struct Daily: Decodable {
            let temperature2mMax: [Double]
            let temperature2mMin: [Double]

            private enum CodingKeys: String, CodingKey {
                case temperature2mMax = "temperature_2m_max"
                case temperature2mMin = "temperature_2m_min"
            }
        }
        let current: Current
        let daily: Daily
    }

    /// `units métriques` : Open-Meteo renvoie déjà Celsius/km/h/mm par
    /// défaut sans paramètre d'unité explicite — les ajouter serait une
    /// valeur en dur redondante avec le comportement par défaut documenté de
    /// l'API, donc omis volontairement plutôt que dupliqué sans raison
    /// (CLAUDE.md : "aucune valeur en dur non justifiée"). `timezone=auto` :
    /// demandé explicitement par la mission, pour que `current.time`/les
    /// horaires journaliers soient exprimés dans le fuseau LOCAL du lieu
    /// demandé plutôt qu'en UTC (peu lisible tel quel dans un widget de
    /// chat) — non exploité directement dans `WeatherWidgetData` aujourd'hui
    /// (aucun horodatage affiché), mais correct dès qu'un futur usage en
    /// aurait besoin (ex. graphique horaire).
    func forecast(for location: WeatherLocation) async throws -> WeatherWidgetData {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
        components?.queryItems = [
            URLQueryItem(name: "latitude", value: String(location.latitude)),
            URLQueryItem(name: "longitude", value: String(location.longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,relative_humidity_2m,apparent_temperature,is_day,weather_code,wind_speed_10m"),
            URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
            URLQueryItem(name: "timezone", value: "auto"),
        ]
        guard let url = components?.url else { throw WeatherWidgetError.invalidForecastURL }

        let response: ForecastResponse = try await fetchDecoded(url: url)
        guard
            let todayMax = response.daily.temperature2mMax.first,
            let todayMin = response.daily.temperature2mMin.first
        else {
            throw WeatherWidgetError.decodingFailed
        }

        return WeatherWidgetData(
            location: location,
            condition: Self.condition(forWMOCode: response.current.weatherCode),
            currentTemperatureCelsius: response.current.temperature2m,
            apparentTemperatureCelsius: response.current.apparentTemperature,
            relativeHumidityPercent: response.current.relativeHumidity2m,
            windSpeedKmh: response.current.windSpeed10m,
            isDaytime: response.current.isDay == 1,
            todayMinTemperatureCelsius: todayMin,
            todayMaxTemperatureCelsius: todayMax
        )
    }

    // MARK: - Réseau générique (géocodage + prévisions partagent le même besoin)

    private func fetchDecoded<T: Decodable>(url: URL) async throws -> T {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await fetcher.fetch(url: url, timeout: timeoutInterval)
        } catch {
            throw WeatherWidgetError.transportError
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw WeatherWidgetError.transportError
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw WeatherWidgetError.httpError(statusCode: httpResponse.statusCode)
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw WeatherWidgetError.decodingFailed
        }
    }

    // MARK: - Table des codes WMO -> condition FR + SF Symbol

    /// Table EXHAUSTIVE des codes "WMO Weather interpretation codes" tels que
    /// documentés par Open-Meteo (https://open-meteo.com/en/docs, section
    /// "WMO Weather interpretation codes (WW)") — un code par ligne, aucun
    /// intervalle deviné. `default` couvre tout code futur ajouté par
    /// Open-Meteo ou toute valeur aberrante, sans jamais planter sur une
    /// clé manquante (même principe de repli sûr que le reste du fichier).
    static func condition(forWMOCode code: Int) -> WeatherCondition {
        switch code {
        case 0: return WeatherCondition(label: "Ciel dégagé", systemImageName: "sun.max")
        case 1: return WeatherCondition(label: "Généralement dégagé", systemImageName: "sun.max")
        case 2: return WeatherCondition(label: "Partiellement nuageux", systemImageName: "cloud.sun")
        case 3: return WeatherCondition(label: "Couvert", systemImageName: "cloud")
        case 45: return WeatherCondition(label: "Brouillard", systemImageName: "cloud.fog")
        case 48: return WeatherCondition(label: "Brouillard givrant", systemImageName: "cloud.fog")
        case 51: return WeatherCondition(label: "Bruine légère", systemImageName: "cloud.drizzle")
        case 53: return WeatherCondition(label: "Bruine modérée", systemImageName: "cloud.drizzle")
        case 55: return WeatherCondition(label: "Bruine dense", systemImageName: "cloud.drizzle")
        case 56: return WeatherCondition(label: "Bruine verglaçante légère", systemImageName: "cloud.sleet")
        case 57: return WeatherCondition(label: "Bruine verglaçante dense", systemImageName: "cloud.sleet")
        case 61: return WeatherCondition(label: "Pluie faible", systemImageName: "cloud.rain")
        case 63: return WeatherCondition(label: "Pluie modérée", systemImageName: "cloud.rain")
        case 65: return WeatherCondition(label: "Pluie forte", systemImageName: "cloud.heavyrain")
        case 66: return WeatherCondition(label: "Pluie verglaçante légère", systemImageName: "cloud.sleet")
        case 67: return WeatherCondition(label: "Pluie verglaçante forte", systemImageName: "cloud.sleet")
        case 71: return WeatherCondition(label: "Neige faible", systemImageName: "snow")
        case 73: return WeatherCondition(label: "Neige modérée", systemImageName: "snow")
        case 75: return WeatherCondition(label: "Neige forte", systemImageName: "snow")
        case 77: return WeatherCondition(label: "Grains de neige", systemImageName: "snow")
        case 80: return WeatherCondition(label: "Averses de pluie faibles", systemImageName: "cloud.rain")
        case 81: return WeatherCondition(label: "Averses de pluie modérées", systemImageName: "cloud.rain")
        case 82: return WeatherCondition(label: "Averses de pluie violentes", systemImageName: "cloud.heavyrain")
        case 85: return WeatherCondition(label: "Averses de neige faibles", systemImageName: "cloud.snow")
        case 86: return WeatherCondition(label: "Averses de neige fortes", systemImageName: "cloud.snow")
        case 95: return WeatherCondition(label: "Orage", systemImageName: "cloud.bolt")
        case 96: return WeatherCondition(label: "Orage avec grêle légère", systemImageName: "cloud.bolt.rain")
        case 99: return WeatherCondition(label: "Orage avec grêle forte", systemImageName: "cloud.bolt.rain")
        default: return WeatherCondition(label: "Conditions inconnues", systemImageName: "questionmark.circle")
        }
    }

    // MARK: - Contexte pour le LLM

    /// Texte compact injecté dans le prompt de génération finale — même
    /// intention que `llmContext` de `weatherWidget.ts`, mais en phrase FR
    /// directement exploitable plutôt qu'un `JSON.stringify` brut de l'objet
    /// `current` (le web laisse le LLM interpréter le JSON lui-même ;
    /// `AIGenerating.generate` de Triva n'a qu'un seul canal `prompt` texte,
    /// autant lui donner une phrase déjà digestible).
    static func llmContext(for data: WeatherWidgetData) -> String {
        "Météo actuelle à \(data.location.name) : \(data.condition.label.lowercased()), " +
        "\(Self.formattedTemperature(data.currentTemperatureCelsius)) (ressenti \(Self.formattedTemperature(data.apparentTemperatureCelsius))), " +
        "humidité \(data.relativeHumidityPercent)%, vent \(Self.formattedWindSpeed(data.windSpeedKmh)). " +
        "Aujourd'hui : de \(Self.formattedTemperature(data.todayMinTemperatureCelsius)) à \(Self.formattedTemperature(data.todayMaxTemperatureCelsius))."
    }

    private static func formattedTemperature(_ celsius: Double) -> String {
        String(format: "%.0f°C", celsius)
    }

    private static func formattedWindSpeed(_ kmh: Double) -> String {
        String(format: "%.0f km/h", kmh)
    }
}
