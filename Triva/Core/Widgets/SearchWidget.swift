//
//  SearchWidget.swift
//  Triva
//
//  Created by ben podrojsky on 17/09/2026.
//

import Foundation

/// Identité stable d'un widget. Remplace le `type: string` libre du web
/// (`types.ts`, `Widget.type`) par un enum fermé : côté Swift, une chaîne
/// libre n'apporte rien (personne n'enregistre de widget dynamiquement dans
/// une app compilée) et coûte un risque de faute de frappe silencieuse entre
/// le service qui produit la sortie et la vue qui la consomme.
///
/// **Le widget bourse est absent VOLONTAIREMENT, ce n'est pas un oubli.** La
/// décision produit (Ben, V1) est que le cours d'action est hors champ : les
/// APIs boursières gratuites sans clé n'existent pas de façon fiable, et
/// Triva n'a ni backend ni clé partagée pour en héberger une. Conséquence
/// directe : `QueryClassification.showStockWidget` peut valoir `true` (le
/// classifieur 1.1 porte fidèlement les 7 champs du web), mais AUCUN widget
/// ne peut se déclarer pour lui — il n'existe pas de `case stock` à adopter.
/// `WidgetExecutor` n'a donc rien de spécial à filtrer : l'exclusion est
/// garantie par le type, pas par une condition qu'on pourrait oublier.
///
/// Conséquence assumée d'un enum fermé : ajouter un 3e widget demande
/// d'éditer CE fichier (ajouter un `case`), pas seulement d'écrire un
/// nouveau service. C'est le prix du dispatch sûr à la compilation, et
/// l'ajout d'un widget reste un événement rare et délibéré.
nonisolated enum SearchWidgetKind: String, Sendable, CaseIterable, Equatable {
    case weather
    case calculation
}

/// Marqueur adopté par les données typées d'un widget (météo, calcul).
/// Volontairement VIDE : il n'existe aucune opération commune honnête entre
/// un relevé météo (une dizaine de champs hétérogènes — température, vent,
/// humidité, symbole de condition, min/max du jour) et le résultat d'une
/// expression arithmétique (une expression, un nombre, sa mise en forme).
/// Inventer une exigence partagée — un titre, une liste de champs
/// « affichables » — forcerait les deux widgets à s'aplatir dans un format
/// générique, et la vue météo perdrait précisément ce qui fait sa carte : la
/// distinction entre la température réelle et le ressenti, le symbole SF
/// associé au code WMO, la borne basse et la borne haute du jour.
///
/// Ce marqueur est la contrepartie typée du `data: any` du web : la donnée
/// reste précise au moment où elle est CRÉÉE (le service météo renvoie son
/// propre type) et au moment où elle est AFFICHÉE (la vue fait un
/// `as? WeatherWidgetData`), et seul le trajet entre les deux — à travers
/// `WidgetExecutor`, qui n'a aucune raison de connaître les widgets — passe
/// par l'existentiel. C'est aussi ce qui permet à l'exécuteur d'être écrit
/// et testé sans dépendre des deux services concrets.
///
/// POURQUOI PAS UN ENUM à la place (`case weather(WeatherWidgetData)`,
/// `case calculation(CalculationWidgetData)`), qui aurait l'avantage de
/// rendre la sortie `Equatable` et de supprimer le `as?` côté vue : parce
/// qu'il forcerait CE fichier — le contrat commun, volontairement neutre — à
/// importer les types concrets des deux services widgets. C'est exactement
/// l'inverse du sens de dépendance voulu : l'exécuteur et son contrat doivent
/// pouvoir être écrits, compilés et testés sans qu'aucun widget concret
/// n'existe, et l'ajout d'un widget ne doit pas rouvrir le contrat. L'enum
/// rendrait aussi impossible d'écrire ce fichier et les deux services en
/// parallèle, ce qui est précisément l'organisation retenue pour 1.5.
///
/// La conformance est rétroactive : un type de données déjà écrit n'a pas
/// besoin d'être modifié, une `extension MonType: SearchWidgetPayload {}`
/// d'une ligne suffit. C'est à l'assemblage (celui qui branche les widgets
/// concrets dans `WidgetExecutor`) d'écrire ces deux lignes, pas ici.
nonisolated protocol SearchWidgetPayload: Sendable {}

/// Tout ce dont un widget a besoin pour s'exécuter. Port de `WidgetInput`
/// (web, `types.ts`) avec les mêmes 4 éléments : historique, requête,
/// classification, moteur IA.
///
/// `classification` est présente EN PLUS de l'argument de `shouldExecute`
/// (comme côté web) parce qu'elle porte `standaloneFollowUp` — la
/// reformulation autonome de la requête produite par 1.1. C'est très souvent
/// une meilleure entrée que `query` brute pour extraire un paramètre : sur
/// « et à Lyon ? », `query` ne contient aucune mention de météo, alors que
/// `standaloneFollowUp` vaut « Quel temps fait-il à Lyon ? ». Le widget
/// choisit laquelle des deux il utilise.
///
/// Pas d'`Equatable` : `aiProvider` est un existentiel non comparable.
nonisolated struct SearchWidgetInput: Sendable {
    /// Requête utilisateur telle quelle (le `followUp` du web).
    let query: String
    let chatHistory: [ClassifierChatMessage]
    let classification: QueryClassification
    /// Provider IA DÉJÀ résolu (Apple Intelligence / MLX / BYOK cloud) :
    /// un widget n'a jamais à savoir lequel des 3 moteurs tourne, ni à
    /// toucher au Keychain.
    ///
    /// Un widget a le droit de ne PAS s'en servir, et ce n'est pas le signe
    /// que le champ est de trop : les deux services de 1.5 reçoivent déjà
    /// leur provider à la construction (`WeatherWidgetService(aiProvider:)`,
    /// `CalculationWidgetService(aiProvider:)`), leurs adaptateurs ignoreront
    /// donc ce champ. Il reste dans l'entrée parce qu'un futur widget écrit
    /// directement comme `SearchWidget`, sans service séparé, n'aurait aucun
    /// autre moyen d'atteindre le moteur actif — et parce que c'est la forme
    /// du `WidgetInput` du web qu'on porte.
    let aiProvider: any AIGenerating

    init(
        query: String,
        chatHistory: [ClassifierChatMessage] = [],
        classification: QueryClassification,
        aiProvider: any AIGenerating
    ) {
        self.query = query
        self.chatHistory = chatHistory
        self.classification = classification
        self.aiProvider = aiProvider
    }
}

/// Sortie unifiée d'un widget. Port de `WidgetOutput` (web) : un identifiant,
/// le texte injecté dans le prompt de rédaction, et la donnée à afficher.
///
/// `Identifiable` par `kind` : un `ForEach` SwiftUI sur les sorties d'un même
/// tour de conversation n'a besoin de rien de plus, puisqu'un `kind` ne peut
/// apparaître qu'une fois par tour (un seul widget par type). Même approche
/// que `ImageSearchResult` (1.6), qui calcule aussi son `id`.
///
/// Pas d'`Equatable` : `payload` est un existentiel, deux existentiels ne
/// sont pas comparables sans exigence supplémentaire sur le protocole — et
/// cette exigence ne servirait qu'aux tests. Les tests comparent `kind` et
/// `llmContext`, qui sont des valeurs simples.
nonisolated struct SearchWidgetOutput: Sendable, Identifiable {
    var id: SearchWidgetKind { kind }

    let kind: SearchWidgetKind

    /// Texte prêt à être concaténé au prompt de rédaction, en français et
    /// autoportant (« La météo à Paris est ... »). C'est ce qui permet au
    /// modèle de commenter le widget au lieu de répondre à côté. Peut être
    /// vide si le widget n'a rien d'utile à dire au modèle — dans ce cas
    /// `WidgetExecutionReport.combinedLLMContext` l'ignore.
    let llmContext: String

    /// Donnée typée à afficher, ou `nil` si le widget n'a produit que du
    /// contexte pour le modèle sans rien à montrer à l'écran.
    let payload: (any SearchWidgetPayload)?

    init(kind: SearchWidgetKind, llmContext: String, payload: (any SearchWidgetPayload)? = nil) {
        self.kind = kind
        self.llmContext = llmContext
        self.payload = payload
    }
}

/// Contrat commun des widgets. Port de `Widget` (web, `types.ts`) : un type,
/// un prédicat d'éligibilité, une exécution asynchrone optionnelle.
///
/// `nonisolated` explicite (même modèle que `SearXNGSearching`,
/// `WeatherWidgetServing`, `CalculationWidgetServing`) : sous
/// `-default-isolation=MainActor`, un widget doit
/// pouvoir s'exécuter depuis le `TaskGroup` de `WidgetExecutor` sans être
/// épinglé au thread principal — un appel réseau ou une génération MLX ne
/// doit jamais bloquer l'UI.
///
/// ## Règle `nil` contre `throw` (à respecter par TOUTE implémentation)
/// Les deux ne veulent PAS dire la même chose, et la distinction est le
/// cœur de ce contrat :
/// - **`nil` = ce widget n'a rien à afficher, et c'est normal.** Cas
///   attendus : le LLM a répondu `notPresent: true` (la requête ne demandait
///   finalement pas de météo/calcul), ou sa sortie JSON était inexploitable.
///   Ce dernier point est la règle générale du projet, déjà appliquée par
///   `QueryClassifier.parse` et `SearchOrchestrator.decideNextAction` : le
///   parsing d'une sortie de LLM ne throw JAMAIS, il retombe sur un repli
///   sûr documenté. Pour un widget, le repli sûr est « pas de widget ».
/// - **`throw` = une infrastructure censée marcher a échoué.** Cas
///   attendus : réseau indisponible, statut HTTP d'erreur, décodage impossible
///   de la réponse d'une API au schéma pourtant connu et stable (les deux
///   APIs Open-Meteo — géocodage puis prévisions). L'exécuteur l'absorbe et
///   l'enregistre comme échec : une `throw` ne fait donc jamais tomber la
///   réponse, elle laisse juste une trace exploitable en développement.
nonisolated protocol SearchWidget: Sendable {
    var kind: SearchWidgetKind { get }

    /// Décision purement locale et synchrone, à partir de la classification
    /// de 1.1 (typiquement `classification.showWeatherWidget`). Volontairement
    /// sans effet de bord ni appel réseau : `WidgetExecutor` l'appelle sur
    /// TOUS les widgets avant de lancer quoi que ce soit, pour ne payer le
    /// coût d'une tâche parallèle que pour les widgets réellement concernés.
    func shouldExecute(for classification: QueryClassification) -> Bool

    /// Voir la règle `nil` contre `throw` ci-dessus.
    func execute(_ input: SearchWidgetInput) async throws -> SearchWidgetOutput?
}
