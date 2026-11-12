//
//  SearchArtifacts.swift
//  Triva
//
//  Created by ben podrojsky on 06/09/2026.
//

import Foundation

/// Tout ce que le pipeline produit À CÔTÉ du texte de réponse (I1b). Connu en
/// entier AVANT que l'appelant itère `StreamingAnswer.textStream` : contrat
/// de 0.8, étendu des sources aux widgets, médias et indicateurs de
/// validation — la vue peut tout afficher avant le premier token.
///
/// `sources` est dans l'ORDRE DES CITATIONS et cet ordre fait foi :
/// `sources[i]` est le document `[i + 1]` du prompt de rédaction
/// (`PromptTemplates.numberedContext` numérote dans l'ordre reçu). Les
/// fichiers joints viennent EN TÊTE (`attachmentSourceCount` premiers
/// éléments, URL `triva-attachment:<UUID>`, voir `UploadsSearchResultBuilder`),
/// puis les résultats web dans l'ordre du classement. Réordonner ce tableau
/// côté interface casserait la correspondance citation -> source affichée.
///
/// `nonisolated` (comme les types suivants) : construit par les points
/// d'entrée `@concurrent`, hors du main actor.
nonisolated struct SearchArtifacts: Sendable {
    let sources: [SearXNGSearchResult]
    /// Nombre de sources de tête qui sont des fichiers joints (1.11).
    let attachmentSourceCount: Int
    /// Widgets aboutis (1.5), dans l'ordre d'injection (météo puis calcul).
    /// Leur `llmContext` est déjà dans le prompt ; à afficher AU-DESSUS de la
    /// réponse (`SearchWidgetOutput.weatherData`, `.calculationData`).
    let widgets: [SearchWidgetOutput]
    /// Recherches média (1.6), `.notRequested` sauf demande de l'appelant.
    let images: MediaSearchOutcome<ImageSearchResult>
    let videos: MediaSearchOutcome<VideoSearchResult>
    /// Mode de réponse appliqué (1.13).
    let mode: ResponseMode
    /// Verbosité des consignes envoyées : à passer à
    /// `ResponseStructureValidator.validate(_:mode:complexity:citableSourceCount:)`.
    let promptComplexity: WriterPromptComplexity
    /// Plus grand numéro `[n]` citable du prompt (`PromptTemplates.citableDocumentCount`),
    /// 0 sans recherche ou sans document lisible : le `citableSourceCount` du
    /// validateur. Depuis la mission A1, ce n'est plus un compte dès que la
    /// numérotation a un trou ([1] et [3] montrés : 3) ; les numéros sautés
    /// sont dans `uncitableSourceNumbers`.
    let citableSourceCount: Int
    /// Vrai si une recherche (web ou fichiers joints) a eu lieu ; faux sur le
    /// chemin sans recherche (salutation, calcul pur, météo répondue par son
    /// widget), où aucune source n'est attendue.
    let searchPerformed: Bool
    /// Sujet de recherche effectif : la reformulation autonome du classifieur
    /// (`SearchOrchestrator.effectiveQuery`, bug 1), ou la question.
    let searchQuery: String
    /// Source web qui a fourni les sources web (RI1b) : `.searxng` sans chaîne
    /// de repli, la source retenue par `WebSearchChain` sinon. `nil` sans
    /// recherche web (route sans recherche, fichiers joints seuls). `var` avec
    /// défaut, seule forme qui garde l'init memberwise compatible avec les
    /// appels existants (dont les tests) : un ajout, pas une rupture.
    var webSourceKind: WebSearchSourceKind? = nil
    /// Numéros `[n]` des sources affichées mais NON CITABLES (mission A1) :
    /// sans extrait et dont la page n'a pas pu être lue, elles ne sont pas
    /// montrées au modèle (`PromptTemplates.uncitableDocumentNumbers`). Elles
    /// restent dans `sources` à leur rang : les retirer décalerait tous les
    /// numéros suivants.
    /// Une citation vers l'une d'elles ne compte jamais comme sourcée
    /// (`citesReadSource(in:)`). Vide par défaut, même raison que
    /// `webSourceKind`.
    var uncitableSourceNumbers: Set<Int> = []
    /// Constat de la chaîne de repli (mission A2) : sources laissées de côté,
    /// réponse probablement hors sujet. Vide hors recherche web ou sans chaîne.
    var webSearchReport = WebSearchChainReport()
    /// Réponse rédigée SANS AUCUNE recherche, ni widget, à autre chose qu'une
    /// salutation : la bulle le dit (« Réponse sans recherche », décision 3 de
    /// Ben, `SearchArtifacts.answersWithoutSearch`). Décidé ICI, où la question
    /// brute est connue : la reformulation d'un « Bonjour » n'en est plus un.
    var answeredWithoutSearch = false
    /// Appareil hors connexion et réponse rédigée sans recherche ni widget, hors salutation (tâche 1.16,
    /// `SearchOrchestrator.isOffline`) : la bulle porte « Hors connexion, sans source » à la place de
    /// « Réponse sans recherche ». Voir `SearchArtifacts+Offline.swift`.
    var answeredOffline = false
    /// Hors connexion, la météo était demandée : son widget n'a PAS été lancé (aucune tentative dans le
    /// vide). `ChatViewModel` répond par un message fixe, le modèle n'invente pas de météo.
    var offlineWeatherSkipped = false
}

/// Résultat du pipeline (0.7) : le texte généré et ses `artifacts`.
///
/// Plus `Equatable` depuis I1b : `SearchWidgetOutput` ne l'est pas (charge
/// utile existentielle), et l'`Equatable` des résultats média est isolé au
/// main actor. Aucun appelant ne comparait deux résultats entiers.
nonisolated struct SearchOrchestratorResult: Sendable {
    let answer: String
    let artifacts: SearchArtifacts

    /// Raccourci historique (0.7) : `artifacts.sources`.
    var sources: [SearXNGSearchResult] { artifacts.sources }
}

/// Résultat du pipeline en streaming (0.8) : `artifacts` est déjà complet
/// (classification, recherche, planner, widgets et médias sont terminés et
/// awaited) au moment où l'appelant le reçoit ; seul le texte arrive
/// progressivement via `textStream`. `Equatable` non conformé : un
/// `AsyncThrowingStream` ne l'est pas.
///
/// ## Suggestions (1.7)
/// Jamais générées ici : elles demandent la réponse COMPLÈTE, et les
/// attendre retarderait le premier token. Une fois `textStream` terminé sans
/// erreur ni annulation et le texte non vide, l'appelant lance
/// `SuggestionsService.generateSuggestions(chatHistory:)` avec l'historique
/// que rend `suggestionsHistory(previousTurns:query:answer:)` (méthode de
/// l'orchestrateur qui a répondu : mêmes bornes), dans une tâche à annuler
/// si l'utilisateur envoie autre chose. Le service ne lève jamais : un échec
/// rend `[]`, aucune erreur à afficher.
nonisolated struct StreamingAnswer: Sendable {
    let artifacts: SearchArtifacts
    let textStream: AsyncThrowingStream<String, Error>

    /// Raccourci historique (0.8) : `artifacts.sources`.
    var sources: [SearXNGSearchResult] { artifacts.sources }
}
