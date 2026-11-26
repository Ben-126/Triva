//
//  SearchSession+Sending.swift
//  Triva
//
//  Created by ben podrojsky on 27/08/2026.
//

import Foundation

/// Préparation d'un envoi par la session de recherche : budget du pipeline, consentement cloud et chaîne de
/// recherche web. Rangé à part de `SearchSession.swift` (rangement W4-R, code déplacé à l'identique).
extension SearchSession {
    /// Budget de recherche et de contexte du moteur qui a produit le provider
    /// de l'envoi en cours (bug 6). `ChatViewModel` l'appelle juste après
    /// `resolveProvider`, sans suspension entre les deux. Interne pour les
    /// tests.
    ///
    /// Apple Intelligence et cloud : `engine` est figé, le budget aussi. MLX :
    /// le budget dépend du MODÈLE (compact ou non), donc il est rangé avec le
    /// provider préparé, calculé sur le même `modelID` que lui. Relire
    /// `stores.mlxSelection` ici serait faux : une autre fenêtre peut changer
    /// de modèle pendant le `prepare()` de cet envoi, qui garde pourtant le
    /// modèle qu'il a chargé. Sans provider préparé (jamais en pratique : la
    /// résolution a échoué avant), le budget compact, le plus prudent.
    func pipelineConfigurationForSending() -> SearchPipelineConfiguration {
        switch engine {
        case .appleIntelligence:
            // Cloud privé ou appareil : le modèle retenu par CE même envoi (mission A4).
            return appleModel.pipelineConfigurationForSending()
        case .cloudBYOK:
            return SearchPipelineConfiguration.preset(for: engine)
        case .mlxLocal:
            return preparedMLXProvider?.configuration ?? SearchPipelineConfiguration.preset(for: .mlxLocal)
        }
    }

    /// Demande de consentement à montrer AVANT un envoi : `nil` pour Apple Intelligence et MLX (sur
    /// l'appareil), sans fournisseur choisi (l'envoi échouera de lui-même), ou accord déjà donné.
    /// Interne pour les tests. La porte qui bloque réellement est `CloudAIConsentGate`.
    func cloudConsentRequestForSending() -> CloudAIConsentRequest? {
        guard engine == .cloudBYOK, let selection = stores.cloudSelection.selection else { return nil }
        guard !stores.cloudConsent.isGranted(providerID: selection.providerID) else { return nil }
        return CloudAIConsentCatalog.request(
            providerID: selection.providerID,
            customPresets: stores.customProviders.customPresets
        )
    }

    /// Chaîne de repli de la recherche web pour un envoi (RI1b) : clés de
    /// recherche personnelles, SearXNG sur `failoverManager` (celui que
    /// `ChatViewModel` vient de résoudre), recherche du fournisseur cloud,
    /// sources ouvertes (`WebSearchChain.assemble`). Interne pour les tests.
    ///
    /// Reconstruite à chaque envoi, jamais mise en cache, comme les providers
    /// Apple Intelligence et cloud (voir « Des caches qui se revalident
    /// seuls ») : une clé ajoutée ou retirée, une sélection cloud changée
    /// ailleurs, vaut dès la question suivante. La recherche cloud dépend de
    /// `engine`, le moteur FIGÉ de cette session (bug 10), jamais d'un store
    /// relu : une session Apple Intelligence ne l'utilise jamais, même si une
    /// autre fenêtre a enregistré une sélection cloud avec sa clé.
    func resolveWebSearchChain(failoverManager: FailoverManager) -> WebSearchChain {
        WebSearchChain.assemble(
            engine: engine,
            cloudSelection: stores.cloudSelection.selection,
            cloudKeyStore: stores.keyStore,
            searchKeys: searchKeyStore,
            failoverManager: failoverManager,
            fallbackLanguage: Self.fallbackSearchLanguage(),
            cloudConsent: stores.cloudConsent.storage
        )
    }

    /// Langue de la recherche quand celle de la question n'est pas reconnue (noms propres, mots
    /// isolés, voir « LANGUE » de `WebSearchChain`) : la langue de l'appareil, avec la règle FR/EN de
    /// Découvrir (`DiscoverLanguage.preferred`). `Locale.preferredLanguages`, jamais
    /// `Locale.current` : sans localisation française dans le projet, cette dernière peut valoir
    /// l'anglais sur un appareil réglé en français (voir `AnswerExcerpt.swift`).
    static func fallbackSearchLanguage(preferredLanguages: [String] = Locale.preferredLanguages) -> String {
        DiscoverLanguage.preferred(for: Locale(identifier: preferredLanguages.first ?? "en")).rawValue
    }
}
