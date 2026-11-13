//
//  WebSearchChain+Assembly.swift
//  Triva
//
//  Created by ben podrojsky on 03/11/2026.
//

import Foundation
import OSLog

extension WebSearchChain {
    /// Chaîne d'UN envoi, assemblée par `SearchSession` (qui connaît le moteur, la sélection cloud
    /// et les trousseaux) juste après la résolution de son `FailoverManager`.
    ///
    /// `@MainActor` : `SearchKeyStore`, `APIKeyStoring` et `CloudWebSearchProvider.make` sont isolés
    /// au main actor (trousseau). Les clés sont lues ICI, puis la chaîne, valeur `Sendable` qui
    /// contient ses providers autonomes, part vers l'orchestrateur sans aucun accès au trousseau
    /// en arrière-plan. Relue à chaque envoi : une clé ajoutée ou retirée dans les Réglages, ou une
    /// sélection cloud changée dans une autre fenêtre, vaut dès la question suivante.
    ///
    /// RECHERCHE CLOUD : seulement si `engine == .cloudBYOK`, le moteur FIGÉ de la session, jamais
    /// un store relu. Une autre fenêtre peut enregistrer une sélection cloud valide pendant que
    /// celle-ci reste sur Apple Intelligence (forme exacte du bug 10) : la question partirait alors
    /// chez un fournisseur cloud, payante, sous un badge « Sur l'appareil ». Fournisseur sans
    /// recherche web (Mistral, personnalisé…) ou sans clé : étape absente (`make` rend `nil`).
    ///
    /// TROUSSEAU ILLISIBLE : la source concernée est sautée, journalisée et comptée comme échec
    /// `.keychainUnreadable` (`WebSearchChainError.allSourcesFailed` la rapporte si tout échoue).
    /// Faire échouer tout l'envoi perdrait une réponse que SearXNG ou Wikipédia auraient donnée,
    /// pour une clé de recherche FACULTATIVE ; l'erreur n'est pas avalée pour autant.
    ///
    /// - Parameters:
    ///   - cloudSelection: sélection cloud courante (`stores.cloudSelection.selection`), lue
    ///     seulement pour un moteur cloud.
    ///   - cloudKeyStore: trousseau des clés IA (`stores.keyStore`), JAMAIS le défaut de `make` :
    ///     les tests y substituent un faux trousseau d'un bout à l'autre.
    ///   - searchKeys: clés de recherche personnelles (service Keychain séparé).
    ///   - failoverManager: celui de la session, pour l'étape SearXNG.
    ///   - fallbackLanguage: langue de l'appareil, quand celle de la question n'est pas reconnue
    ///     (`SearchSession.fallbackSearchLanguage`, voir « LANGUE » de `WebSearchChain`).
    ///   - openSources: sources ouvertes ; les tests y injectent un faux réseau.
    @MainActor
    static func assemble(
        engine: AIEngineOption,
        cloudSelection: CloudProviderSelection?,
        cloudKeyStore: any APIKeyStoring,
        searchKeys: SearchKeyStore,
        failoverManager: FailoverManager,
        fallbackLanguage: String?,
        openSources: OpenSourceSearchChain = OpenSourceSearchChain()
    ) -> WebSearchChain {
        let keyed = keyedProviders(from: searchKeys)
        let cloud = activeCloudProvider(engine: engine, selection: cloudSelection, keyStore: cloudKeyStore)
        return WebSearchChain(
            keyedProviders: keyed.providers,
            searxng: SearXNGWebSearchProvider(failover: failoverManager),
            cloudProvider: cloud.provider,
            openSources: openSources,
            unreadableKeySources: keyed.unreadable + (cloud.keyUnreadable ? [.cloudProviderWebSearch] : []),
            fallbackLanguage: fallbackLanguage
        )
        .retryingTransientFailures(after: transientRetryDelay)
    }

    /// Pause avant la seconde passe sur les sources ouvertes (voir « SECONDE PASSE »).
    static let transientRetryDelay: Duration = .seconds(2)

    /// Providers des clés de recherche enregistrées, dans l'ordre de préférence, et sources dont
    /// la clé n'a pas pu être lue. Lecture source par source : une clé illisible n'empêche pas
    /// d'utiliser l'autre.
    @MainActor
    private static func keyedProviders(
        from searchKeys: SearchKeyStore
    ) -> (providers: [any WebSearchProviding], unreadable: [WebSearchSourceKind]) {
        var providers: [any WebSearchProviding] = []
        var unreadable: [WebSearchSourceKind] = []
        for source in BYOKSearchSource.preferenceOrder {
            do {
                if let provider = try searchKeys.provider(for: source) {
                    providers.append(provider)
                }
            } catch {
                logger.error("Clé de recherche \(source.rawValue, privacy: .public) illisible dans le trousseau : source sautée")
                unreadable.append(source.kind)
            }
        }
        return (providers, unreadable)
    }

    /// Recherche web du fournisseur cloud actif, ou `nil` (voir « RECHERCHE CLOUD »).
    @MainActor
    private static func activeCloudProvider(
        engine: AIEngineOption,
        selection: CloudProviderSelection?,
        keyStore: any APIKeyStoring
    ) -> (provider: (any WebSearchProviding)?, keyUnreadable: Bool) {
        guard engine == .cloudBYOK else { return (nil, false) }
        do {
            return (try CloudWebSearchProvider.make(for: selection, keyStore: keyStore), false)
        } catch {
            logger.error("Clé du fournisseur IA illisible dans le trousseau : recherche cloud sautée")
            return (nil, true)
        }
    }
}
