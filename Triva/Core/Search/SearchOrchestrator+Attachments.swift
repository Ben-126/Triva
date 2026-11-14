//
//  SearchOrchestrator+Attachments.swift
//  Triva
//
//  Created by ben podrojsky on 12/11/2026.
//

import Foundation

/// Fichiers joints : routage et budgets (découpage E1b). L'action « fichiers joints » elle-même
/// (`uploadsAction`, `consultedDocuments`) reste privée dans `SearchOrchestrator.swift`.
extension SearchOrchestrator {
    /// Décision (b) de Ben (2026-10-29) : des fichiers joints sont TOUJOURS
    /// consultés, quels que soient le mode et la classification (le
    /// classifieur ne sait pas qu'il y en a). La route « aucune recherche »
    /// devient donc « fichiers joints » ; les routes web les consultent dès le
    /// tour seedé (`gather`) ; `.attachments` et `.webUnlessWeatherAnswered`
    /// (résolue plus tard par `runResearch`) sont inchangées.
    ///
    /// Écart assumé avec la piste « forcer `personalSearch` » : la règle 1 de
    /// `SearchRoute.resolve` enverrait alors TOUTE question d'une conversation
    /// à fichier joint sur `.attachments` — recherche web coupée jusqu'au
    /// retrait du fichier, puisque les capsules restent d'une question à
    /// l'autre. Pour ce comportement-là, rendre `.attachments` dès que
    /// `hasAttachments` est vrai.
    /// `case .none = route` et non `route == .none` : comparé par `==`, `.none`
    /// serait pris pour `Optional<SearchRoute>.none`, toujours différent.
    nonisolated static func routeConsultingAttachments(_ route: SearchRoute, hasAttachments: Bool) -> SearchRoute {
        guard hasAttachments, case .none = route else { return route }
        return .attachments
    }

    /// Fichiers joints qui comptent comme SOURCES d'une réponse web (mission C1, R1-1, arbitrage
    /// provisoire de l'agent principal, à confirmer par Ben : option (a)).
    ///
    /// Le défaut corrigé : `AttachmentSearchIndex.search` rend toujours les N meilleurs fragments,
    /// sans seuil de pertinence (`AttachmentStore`). Un PDF sans rapport avec la question donnait donc
    /// toujours des « sources », et `SearchArtifacts.attachmentSourceCount > 0` désactivait en Fiable
    /// le refus du hors-sujet (`hasOnlyOffTopicWebSources`) et le contrôle « aucune source fiable »
    /// (`lacksReliableSources`) : la réponse citait un document sans rapport, ou une source web hors
    /// sujet, et passait le contrôle de citation.
    ///
    /// En Fiable, sur la route web, un fichier joint n'est donc gardé que si ses extraits reprennent
    /// assez de mots de la question (`LexicalRelevance`, le test déjà appliqué aux sources web de ce mode :
    /// pas de seuil de score, qu'`AttachmentStore` interdit, ni de nouveau test). Un fichier pertinent
    /// reste une source fiable, comme avant ; un fichier sans rapport quitte le contexte ET le décompte.
    /// Même limite connue que `hasOnlyOffTopicWebSources` : un test sur les MOTS, pas sur le sens ; un faux
    /// rejet reste sûr (« Aucune source fiable » avec le bouton de relance en Rapide ; la route « fichiers
    /// joints seuls », elle, consulte toujours les fichiers). Hors Fiable : inchangé, tous les fichiers sont gardés.
    nonisolated static func documentsCountingAsSources(
        _ documents: [SearXNGSearchResult],
        query: String,
        mode: ResponseMode
    ) -> [SearXNGSearchResult] {
        guard case .reliable = mode else { return documents }
        let relevance = LexicalRelevance(query: query)
        return documents.filter { relevance.matches($0) }
    }

    /// Longueur minimale UTILE d'un extrait de fichier joint : celle d'un
    /// extrait SearXNG (~300 caractères, l'ordre de grandeur que les tests de
    /// pire cas donnent aux résultats web). En dessous, un extrait n'est plus
    /// qu'une phrase tronquée.
    nonisolated static let minimumAttachmentExcerptCharacters = 300

    /// Nombre d'extraits de fichiers joints pour un budget donné (I1b) : les
    /// 10 de la version web d'origine (`UploadsSearchResultBuilder.defaultMaxFragments`), sauf si
    /// le budget ne leur laisse pas `minimumAttachmentExcerptCharacters`
    /// chacun. Chaque extrait coûte aussi ~90 caractères d'en-tête dans le
    /// prompt (`[n]`, nom du fichier, URL synthétique `triva-attachment:<UUID>`) :
    /// sous 1 500 caractères (Apple Intelligence, fichiers joints ajoutés à
    /// une recherche web), 10 extraits de 150 caractères coûtaient 900
    /// caractères d'en-têtes pour un contenu à peine lisible ; 5 extraits de
    /// 300 disent plus pour moins. Seuls changent Apple Intelligence (5
    /// extraits sur la route web) et MLX léger (8) ; le cloud et la route
    /// « fichiers joints seuls » gardent 10. Toujours au moins 1.
    nonisolated static func attachmentFragmentLimit(forBudget budget: Int) -> Int {
        min(UploadsSearchResultBuilder.defaultMaxFragments, max(1, budget / minimumAttachmentExcerptCharacters))
    }

    /// Budget des pages scrapées dans le prompt final, une fois servis les
    /// fichiers joints (I1b) : `maxScrapedContextCharacters` borne TOUT le
    /// contenu long du prompt, pages ET fichiers joints. Avant, les fichiers
    /// trouvés par le planner s'ajoutaient aux pages au lieu de partager leur
    /// budget : sous Apple Intelligence, 1 500 caractères de documents plus
    /// 3 000 de pages, et le pire cas mesuré montait à 11 269 caractères, au-
    /// delà des 10 000 que la fenêtre de ~4 096 tokens tolère
    /// (`UploadsSearchPipelineTests`).
    ///
    /// Jamais nul quand des pages sont scrapées : sur la route web, les
    /// fichiers joints ont au plus la MOITIÉ de ce budget (voir `gather`), il
    /// en reste donc au moins la moitié aux pages. Ce point compte :
    /// `PromptTemplates.numberedContext` ramènerait un budget nul à 1
    /// caractère par page. Sur la route « fichiers joints seuls », aucune page
    /// n'est scrapée, un reste nul n'y change rien. Seule la route web avec
    /// fichiers joints (consultés dès le tour seedé, décision (b)) est
    /// concernée : sans fichier joint, le budget des pages est inchangé.
    nonisolated static func scrapedContextBudget(total: Int, attachmentSources: [SearXNGSearchResult]) -> Int {
        let attachmentCharacters = attachmentSources.reduce(0) { $0 + ($1.content?.count ?? 0) }
        return max(0, total - attachmentCharacters)
    }
}
