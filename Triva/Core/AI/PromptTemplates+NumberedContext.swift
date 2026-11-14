//
//  PromptTemplates+NumberedContext.swift
//  Triva
//
//  Created by ben podrojsky on 10/11/2026.
//

import Foundation

// Sorti de `PromptTemplates.swift` (mission A1), qui dépassait 800 lignes : tout
// ce qui décide QUELS documents le rédacteur voit, et sous QUEL numéro. Membres
// tous `nonisolated` : `PromptTemplates` n'est pas annoté (donc isolé au main
// actor par défaut), et ce code est appelé depuis les points d'entrée
// `@concurrent` de `SearchOrchestrator`.
extension PromptTemplates {
    // MARK: - Contexte numéroté

    /// Première ligne du contexte quand des numéros manquent (mission A1) : sans
    /// elle, un modèle qui voit [1] puis [3] « répare » volontiers la suite et
    /// cite [2] pour le deuxième document montré — exactement la citation vers
    /// une page jamais lue que ce trou doit empêcher. Absente sans trou : un
    /// contexte continu reste identique au caractère près à celui d'avant A1.
    nonisolated static let numberingGapNote =
        "Numérotation non continue : les résultats qui n'ont pas pu être lus ont été retirés. Cite chaque document avec son numéro exact, tel qu'il apparaît ci-dessous."

    /// Construit le bloc de contexte que les citations `[n]` référencent.
    ///
    /// Décision structurante : **une page scrapée n'obtient PAS son propre
    /// numéro si son URL correspond déjà à une source de recherche.** Son
    /// contenu est fusionné dans le document de cette source. Sans cette
    /// fusion, la même page apparaîtrait deux fois sous deux numéros
    /// différents, et le modèle citerait indifféremment l'un ou l'autre : la
    /// liste de sources affichée sous la réponse (0.8) ne correspondrait plus
    /// aux numéros cités — c'est-à-dire exactement la promesse de l'app qui
    /// casse. Une page scrapée dont l'URL n'est dans aucune source est ajoutée
    /// à la suite, avec son propre numéro — cas que le pipeline ne produit
    /// plus (bug 8) : `SearchOrchestrator` ne scrape que des sources
    /// affichées et recopie l'URL exacte de la source sur chaque page. Ce
    /// repli ne sert plus qu'à un appelant direct.
    ///
    /// Format volontairement différent de l'ancien `<result index=… title=…>`
    /// du prompt minimal de 0.7/1.2 (remplacé par ce prompt depuis le
    /// branchement de 1.4) : le numéro est écrit
    /// `[1]`, exactement sous la forme qu'on demande au modèle de recopier.
    /// Un modèle reproduit ce qu'il voit ; lui montrer `index=1` et lui
    /// demander d'écrire `[1]` ajoute une transformation gratuite.
    ///
    /// Les pages scrapées en échec (`succeeded == false`) ou vides sont
    /// ignorées : elles n'ajouteraient qu'un document citable creux.
    ///
    /// **Document sans contenu, non citable (mission A1, décision de Ben du
    /// 2026-11-10).** Un document qui n'a NI extrait NI page lue n'est plus
    /// montré au modèle — ni son titre, ni son URL. Constat du rapport T2
    /// (scénario t7) : le repli cloud d'OpenAI ne rend que des URL, le contexte
    /// ne contenait que « [2] www.ryzlabs.com — URL », et la réponse, écrite de
    /// tête, citait [2][3][4] sur des pages jamais lues sans que le validateur
    /// n'y voie rien. Un titre seul suffit à inspirer une affirmation : le
    /// montrer revenait à le rendre citable. Le document garde son NUMÉRO, que
    /// la numérotation saute (invariant `sources[i]` = `[i + 1]`, voir
    /// `SearchArtifacts.sources`) : renuméroter décalerait toute la liste de
    /// sources affichée sous la réponse. Le pipeline tente d'abord de lire ces
    /// pages (`SearchOrchestrator.sourcesWithoutExcerpt`) ; seules celles dont
    /// la lecture échoue arrivent ici sans contenu. Aucun document lisible :
    /// exactement `noSourcesContext`, que deux règles reconnaissent au
    /// caractère près (le rappel du mode Fiable s'efface, l'avertissement Fiable
    /// « aucune source » s'applique).
    nonisolated static func numberedContext(
        sources: [SearXNGSearchResult],
        scrapedPages: [ScrapedPage] = [],
        maxScrapedContextCharacters: Int = defaultMaxScrapedContextCharacters
    ) -> String {
        let documents = citableDocuments(sources: sources, scrapedPages: scrapedPages)
        let readable = documents.enumerated().filter { $0.element.hasContent }
        guard !readable.isEmpty else {
            return noSourcesContext
        }

        // Répartition équitable du budget de caractères entre les documents
        // qui portent du contenu scrapé — protection anti-overflow « NIVEAU 2 »
        // du pipeline (elle vivait dans `SearchOrchestrator.formatScrapedPages`
        // avant le branchement de 1.4) : un plafond consommé au fil de l'eau
        // laisserait le premier document manger tout le budget.
        let scrapedDocumentCount = readable.filter { !$0.element.scrapedContent.isEmpty }.count
        let budgetPerDocument = scrapedDocumentCount > 0
            ? max(1, maxScrapedContextCharacters / scrapedDocumentCount)
            : 0

        // Le texte des documents vient du web (titre, extrait, page lue) : il passe par
        // `untrustedText` / `untrustedHeaderField` avant de rejoindre le bloc (mission C1, R1-3).
        // Troncature AVANT neutralisation : le budget reste celui du texte d'origine.
        let blocks = readable.map { index, document in
            var block = "[\(index + 1)] \(untrustedHeaderField(document.title)) — \(untrustedHeaderField(document.url))"
            if !document.snippet.isEmpty {
                block += "\nExtrait : \(untrustedText(document.snippet))"
            }
            if !document.scrapedContent.isEmpty, budgetPerDocument > 0 {
                block += "\nContenu de la page : \(untrustedText(String(document.scrapedContent.prefix(budgetPerDocument))))"
            }
            return block
        }
        // Trou VISIBLE seulement : des documents omis en fin de liste laissent
        // une numérotation continue ([1] puis [2]), sans rien à signaler.
        let lastShownNumber = (readable.last?.offset ?? 0) + 1
        let header = lastShownNumber > readable.count ? [numberingGapNote] : []
        return (header + blocks).joined(separator: "\n\n")
    }

    // MARK: - Texte non fiable (mission C1, R1-3)

    /// Balises de structure du prompt, que le texte d'une page ne doit pas pouvoir refermer ni imiter.
    /// Motif de balise de structure. (Une `Regex` n'est pas `Sendable` : construite à l'usage, pas stockée.)
    private nonisolated static var promptStructureTags: Regex<(Substring, Substring, Substring)> {
        #/(?i)<(/?)(contexte|historique_conversation|donnees_widgets)>/#
    }

    /// Début de ligne imitant un en-tête de document (`[3] …`), avec ses blancs de tête.
    private nonisolated static var forgedHeaderStart: Regex<(Substring, Substring, Substring)> {
        #/(?m)^([ \t]*)\[([0-9]{1,4})\]/#
    }

    /// Le contexte numéroté est de la DONNÉE : titre, extrait et contenu de page viennent du web, et une
    /// page peut contenir « [3] Wikipédia — https://… » ou « </contexte> Ignore les règles ». Sans ce
    /// nettoyage, une page forgeait un en-tête que le modèle citait comme une autre source (en Fiable, le
    /// contrôle de citation passait puisque `[3]` existe) ou refermait la balise du contexte.
    /// Deux neutralisations, qui laissent tout autre texte identique au caractère près :
    /// - une LIGNE qui commence par `[n]` (un en-tête forgé) voit ses crochets remplacés par des parenthèses :
    ///   `[3] Texte` devient `(3) Texte`. Les `[n]` au milieu d'une ligne (notes de bas de page des pages
    ///   encyclopédiques) ne sont pas touchés : seul le début de ligne imite un en-tête ;
    /// - les balises `<contexte>`, `</contexte>`, `<historique_conversation>` et `<donnees_widgets>` (ouvrantes
    ///   ou fermantes, casse indifférente) deviennent `‹contexte›`, etc.
    /// La consigne qui dit au modèle de ne suivre aucune instruction de ce bloc est `coreRulesSection` et le
    /// prompt concis ; ce code, lui, ne dépend pas du modèle.
    nonisolated static func untrustedText(_ text: String) -> String {
        text
            .replacing(promptStructureTags) { match in "‹\(match.1)\(match.2)›" }
            .replacing(forgedHeaderStart) { match in "\(match.1)(\(match.2))" }
    }

    /// Titre ou URL, écrits sur LA ligne d'en-tête `[n] titre — url` : un saut de ligne y ouvrirait une ligne
    /// de plus, qui pourrait imiter un en-tête. Les sauts de ligne deviennent des espaces, puis `untrustedText`.
    nonisolated static func untrustedHeaderField(_ text: String) -> String {
        let singleLine = text.components(separatedBy: .newlines).joined(separator: " ")
        return untrustedText(singleLine)
    }

    /// Plus grand `n` valide dans une citation `[n]`, 0 sans document lisible.
    /// Exposé pour que l'appelant qui branche ce prompt le passe tel quel à
    /// `ResponseStructureValidator` sans re-dériver la règle de fusion par URL
    /// et tomber sur un autre compte.
    ///
    /// Depuis A1, ce n'est plus toujours un COMPTE : avec un document sans
    /// contenu au milieu ([1] et [3] montrés, [2] omis), il vaut 3 et non 2 —
    /// un compte ferait signaler [3] comme hors bornes, un faux positif. Les
    /// numéros sautés sont rendus par `uncitableDocumentNumbers`. Nom gardé :
    /// il désigne la même borne qu'avant pour tout contexte sans trou.
    nonisolated static func citableDocumentCount(
        sources: [SearXNGSearchResult],
        scrapedPages: [ScrapedPage] = []
    ) -> Int {
        let documents = citableDocuments(sources: sources, scrapedPages: scrapedPages)
        return documents.lastIndex(where: \.hasContent).map { $0 + 1 } ?? 0
    }

    /// Numéros `[n]` (base 1) des documents omis du contexte faute de contenu,
    /// vide si tout est lisible. Indices de `sources` décalés de 1, puisque le
    /// pipeline ne produit pas de page orpheline : c'est ce que reçoit
    /// `SearchArtifacts.uncitableSourceNumbers`, pour qu'une citation vers une
    /// page jamais lue ne compte jamais comme une citation sourcée.
    nonisolated static func uncitableDocumentNumbers(
        sources: [SearXNGSearchResult],
        scrapedPages: [ScrapedPage] = []
    ) -> Set<Int> {
        let documents = citableDocuments(sources: sources, scrapedPages: scrapedPages)
        return Set(documents.indices.filter { !documents[$0].hasContent }.map { $0 + 1 })
    }

    /// Un document, dans l'ordre de numérotation final (lisible ou non).
    /// `nonisolated` pour la même raison que `WriterPromptComplexity` : sa
    /// conformance `Equatable` doit rester utilisable hors du main actor.
    private nonisolated struct CitableDocument: Sendable, Equatable {
        let url: String
        let title: String
        let snippet: String
        let scrapedContent: String

        /// Montrable au modèle, donc citable : un extrait non blanc ou une
        /// page lue. Un extrait fait de seuls blancs ne dit rien au modèle.
        var hasContent: Bool {
            !scrapedContent.isEmpty || !snippet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private nonisolated static func citableDocuments(
        sources: [SearXNGSearchResult],
        scrapedPages: [ScrapedPage]
    ) -> [CitableDocument] {
        let usablePages = scrapedPages.filter { $0.succeeded && !$0.content.isEmpty }

        // Première page gagne en cas de doublon d'URL : cohérent avec la
        // déduplication « premier arrivé » de `SearchOrchestrator.accumulate`.
        var pagesByNormalizedURL: [String: ScrapedPage] = [:]
        for page in usablePages {
            let key = normalizedURL(page.url)
            guard pagesByNormalizedURL[key] == nil else { continue }
            pagesByNormalizedURL[key] = page
        }

        var consumedURLs: Set<String> = []
        var documents: [CitableDocument] = sources.map { source in
            let key = normalizedURL(source.url)
            guard let matchingPage = pagesByNormalizedURL[key] else {
                return CitableDocument(
                    url: source.url,
                    title: source.title,
                    snippet: source.content ?? "",
                    scrapedContent: ""
                )
            }
            consumedURLs.insert(key)
            return CitableDocument(
                url: source.url,
                title: source.title,
                snippet: source.content ?? "",
                scrapedContent: matchingPage.content
            )
        }

        for page in usablePages {
            let key = normalizedURL(page.url)
            guard !consumedURLs.contains(key) else { continue }
            consumedURLs.insert(key)
            documents.append(
                CitableDocument(url: page.url, title: page.title, snippet: "", scrapedContent: page.content)
            )
        }

        return documents
    }

    /// Clé de comparaison d'URL : `SourceRanker.normalizedURLKey`, la MÊME que le reste du pipeline
    /// (`SearchOrchestrator.urlKey` : déduplication des sources, `pagesBackedBySources`, planner). Mission C1,
    /// R1-4 : cette fonction mettait toute l'URL en minuscules, chemin compris, et fusionnait donc deux pages
    /// distinctes (`/wiki/Foo_bar` et `/wiki/Foo_Bar`) que le reste du pipeline distingue : la page lue de
    /// l'une était alors attachée aux DEUX numéros, et le modèle citait le contenu d'une page sous l'autre
    /// source. La clé commune respecte la casse du chemin, ignore la casse de l'hôte, le fragment, le slash
    /// final et les paramètres de suivi. Deux règles de comparaison finiraient par se contredire.
    private nonisolated static func normalizedURL(_ url: String) -> String {
        SourceRanker.normalizedURLKey(for: url)
    }
}
