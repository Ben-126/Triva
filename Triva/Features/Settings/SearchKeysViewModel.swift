//
//  SearchKeysViewModel.swift
//  Triva
//
//  Created by ben podrojsky on 04/11/2026.
//

import Foundation

// MARK: - Pages d'obtention des clés

nonisolated extension BYOKSearchSource {
    /// Page où créer sa clé, `Link` de l'écran « Clés de recherche ». Facultative par prudence
    /// (`URL(string:)`), jamais `nil` en pratique : `SearchKeysViewModelTests` vérifie les deux.
    ///
    /// Vérifiées le 2026-11-04. Brave demande d'abord de se connecter ou de créer un compte, puis
    /// redirige vers les clés. Tavily : l'adresse donnée par son démarrage rapide.
    var keyPageURL: URL? {
        switch self {
        case .brave: URL(string: "https://api-dashboard.search.brave.com/app/keys")
        case .tavily: URL(string: "https://app.tavily.com")
        }
    }
}

// MARK: - État d'une source

/// Résultat de la dernière action sur une clé, affiché sous sa section.
///
/// Textes FIXES, y compris pour un serveur qui répondrait n'importe quoi : aucune clé, aucun corps
/// de réponse ne peut y entrer (`WebSearchError` et `SearchKeyStoreError` n'en portent pas).
///
/// Isolé au main actor par défaut, contrairement à une donnée pure ordinaire : il porte
/// `SearchKeyStoreError`, qui l'est aussi. Seuls l'écran et son modèle le manipulent.
enum SearchKeyFeedback: Sendable, Equatable {
    case valid
    /// La clé est RECONNUE, son quota est épuisé : jamais présenté comme un refus (voir
    /// `SearchKeyValidationOutcome.validQuotaReached`).
    case validQuotaReached
    /// La clé saisie n'a pas passé le test : rien n'est enregistré. Y compris si le service ne
    /// répond pas : une clé non vérifiée pourrait être fausse, et la chaîne de recherche paierait
    /// à chaque envoi une requête vouée à l'échec.
    case draftRejected(WebSearchError)
    /// La clé enregistrée n'a pas passé un nouveau test. Elle est gardée : une panne passagère ne
    /// doit pas effacer une clé que le service ne laisse parfois voir qu'une fois.
    case storedKeyFailed(WebSearchError)
    /// Saisie vide, ou trousseau qui refuse l'opération.
    case storage(SearchKeyStoreError)

    var message: String {
        switch self {
        case .valid: "Clé valide."
        case .validQuotaReached: "Clé valide, quota atteint pour le moment."
        case .draftRejected(let error): "\(error.userFacingMessage) La clé n'a pas été enregistrée."
        case .storedKeyFailed(let error): error.userFacingMessage
        case .storage(let error): error.userFacingMessage
        }
    }

    /// Seul le succès prend la couleur d'accent, comme le test des instances SearXNG.
    var isPositive: Bool {
        switch self {
        case .valid, .validQuotaReached: true
        case .draftRejected, .storedKeyFailed, .storage: false
        }
    }
}

/// Ce que l'écran doit savoir d'une source. Jamais la clé elle-même : elle reste dans le trousseau
/// une fois enregistrée, et dans le `@State` du champ tant qu'elle ne l'est pas.
struct SearchKeyEntry: Sendable, Equatable {
    var hasStoredKey = false
    /// Un test est en cours. Il consomme une requête du quota de l'utilisateur : tant qu'il dure,
    /// les boutons sont désactivés, et un second appel ne repart pas.
    var isTesting = false
    var feedback: SearchKeyFeedback?

    /// Le bouton « Tester et enregistrer » n'a rien à envoyer pour une saisie vide ou blanche.
    func canSubmit(draft: String) -> Bool {
        !isTesting && !SearchSecret(draft).isEmpty
    }
}

// MARK: - Modèle de l'écran

/// Logique de l'écran « Clés de recherche » (mission RI2) : tester une clé AVANT de l'enregistrer,
/// la retester, la supprimer. Sans vue et sans réseau, donc testable (`SearchKeysViewModelTests`).
///
/// S'appuie sur `SearchKeyStore`, qui gère déjà le trousseau (service SÉPARÉ de celui des clés IA)
/// et que la chaîne de recherche relit à chaque envoi (`SearchSession.resolveWebSearchChain`) :
/// une clé enregistrée ici vaut donc dès la question suivante, dans toutes les fenêtres.
///
/// INIT SANS EFFET DE BORD : aucune lecture du trousseau, `reload()` s'en charge à l'apparition de
/// l'écran. L'expression qui le construit est réévaluée à chaque rendu du parent
/// (`State(initialValue:)` ne garde que la première instance) : une lecture synchrone ici serait
/// refaite à chaque fois sur le main actor (le piège décrit dans `BYOKProvidersView`).
///
/// QUOTA : chaque test consomme une requête du quota de l'utilisateur (`SearchKeyValidating`). Rien
/// n'est donc testé à l'apparition ni à la frappe, seulement sur appui d'un bouton.
///
/// Écart assumé avec `APIKeysViewModel` (clés IA, 0.6) : tout échec du trousseau s'affiche ici, au
/// lieu d'un `try?` qui annoncerait « supprimée » une clé restée en place.
@Observable
@MainActor
final class SearchKeysViewModel {
    private var entries: [BYOKSearchSource: SearchKeyEntry] = [:]

    private let store: SearchKeyStore
    private let makeValidator: @MainActor (SearchKeyCredentials) -> any SearchKeyValidating

    /// - Parameters:
    ///   - store: le vrai trousseau par défaut, les tests passent un faux `APIKeyStoring`.
    ///   - makeValidator: test d'une clé, par un vrai appel au service par défaut.
    init(
        store: SearchKeyStore = SearchKeyStore(),
        makeValidator: @escaping @MainActor (SearchKeyCredentials) -> any SearchKeyValidating = { $0.makeProvider() }
    ) {
        self.store = store
        self.makeValidator = makeValidator
    }

    func entry(for source: BYOKSearchSource) -> SearchKeyEntry {
        entries[source, default: SearchKeyEntry()]
    }

    /// Relit le trousseau, à chaque apparition : une clé ajoutée ou supprimée dans une autre fenêtre
    /// (Mac, iPad) s'affiche au retour sur l'écran.
    ///
    /// Trousseau illisible (appareil verrouillé, par exemple) : l'écran le dit et montre le champ de
    /// saisie. Un échec de lecture n'est pas effacé par le silence, mais par la lecture réussie suivante.
    func reload() {
        for source in BYOKSearchSource.preferenceOrder {
            do {
                let isConfigured = try store.isConfigured(source)
                update(source) { entry in
                    if entry.hasStoredKey != isConfigured || Self.isStorageFailure(entry.feedback) {
                        entry.feedback = nil
                    }
                    entry.hasStoredKey = isConfigured
                }
            } catch {
                update(source) { entry in
                    entry.hasStoredKey = false
                    entry.feedback = .storage(Self.storeError(from: error))
                }
            }
        }
    }

    /// Teste `rawKey`, puis l'enregistre seulement si le service la reconnaît, quota atteint compris.
    ///
    /// Annulation : retour à l'état neutre, ni message ni enregistrement. Ce n'est ni un échec ni
    /// une validation.
    func testAndSave(rawKey: String, for source: BYOKSearchSource) async {
        guard !entry(for: source).isTesting else { return }
        let credentials = SearchKeyCredentials(source: source, apiKey: rawKey)
        guard !credentials.apiKey.isEmpty else {
            update(source) { $0.feedback = .storage(.emptyKey) }
            return
        }

        update(source) { entry in
            entry.isTesting = true
            entry.feedback = nil
        }
        let result = await validate(credentials)

        var isSaved = false
        var feedback: SearchKeyFeedback?
        switch result {
        case nil:
            break
        case .failure(let error):
            feedback = .draftRejected(error)
        case .success(let outcome):
            do {
                try store.save(credentials)
                isSaved = true
                feedback = Self.feedback(for: outcome)
            } catch {
                feedback = .storage(Self.storeError(from: error))
            }
        }
        update(source) { entry in
            entry.isTesting = false
            entry.feedback = feedback
            entry.hasStoredKey = entry.hasStoredKey || isSaved
        }
    }

    /// Retest de la clé enregistrée, à la demande. Elle est gardée même si le test échoue (voir
    /// `SearchKeyFeedback.storedKeyFailed`). Clé disparue entre-temps (autre fenêtre) : l'écran
    /// repasse simplement sur le champ de saisie.
    func testStoredKey(for source: BYOKSearchSource) async {
        guard !entry(for: source).isTesting else { return }
        let credentials: SearchKeyCredentials
        do {
            guard let stored = try store.credentials(for: source) else {
                update(source) { entry in
                    entry.hasStoredKey = false
                    entry.feedback = nil
                }
                return
            }
            credentials = stored
        } catch {
            update(source) { $0.feedback = .storage(Self.storeError(from: error)) }
            return
        }

        update(source) { entry in
            entry.isTesting = true
            entry.feedback = nil
        }
        let result = await validate(credentials)
        update(source) { entry in
            entry.isTesting = false
            switch result {
            case nil: entry.feedback = nil
            case .failure(let error): entry.feedback = .storedKeyFailed(error)
            case .success(let outcome): entry.feedback = Self.feedback(for: outcome)
            }
        }
    }

    /// Supprime la clé. Si le trousseau refuse, elle est toujours là et l'écran le dit.
    func deleteKey(for source: BYOKSearchSource) {
        do {
            try store.delete(source)
            update(source) { entry in
                entry.hasStoredKey = false
                entry.feedback = nil
            }
        } catch {
            update(source) { $0.feedback = .storage(Self.storeError(from: error)) }
        }
    }

    // MARK: Utilitaires

    private func update(_ source: BYOKSearchSource, _ change: (inout SearchKeyEntry) -> Void) {
        var entry = entry(for: source)
        change(&entry)
        entries[source] = entry
    }

    /// Issue d'un test, `nil` si annulé. Une erreur hors contrat (`SearchKeyValidating` ne doit lever
    /// que des `WebSearchError`) vaut `.unavailable`, jamais son texte : il pourrait citer la clé.
    private func validate(_ credentials: SearchKeyCredentials) async -> Result<SearchKeyValidationOutcome, WebSearchError>? {
        do {
            return .success(try await makeValidator(credentials).validateKey())
        } catch {
            if SearchOrchestrator.isCancellation(error) { return nil }
            return .failure((error as? WebSearchError) ?? .unavailable)
        }
    }

    private static func feedback(for outcome: SearchKeyValidationOutcome) -> SearchKeyFeedback {
        switch outcome {
        case .valid: .valid
        case .validQuotaReached: .validQuotaReached
        }
    }

    /// `SearchKeyStore` ne lève que des `SearchKeyStoreError` ; une autre erreur vaut un refus du
    /// trousseau, jamais son texte.
    private static func storeError(from error: any Error) -> SearchKeyStoreError {
        (error as? SearchKeyStoreError) ?? .keychainFailure
    }

    private static func isStorageFailure(_ feedback: SearchKeyFeedback?) -> Bool {
        if case .storage = feedback { return true }
        return false
    }
}
