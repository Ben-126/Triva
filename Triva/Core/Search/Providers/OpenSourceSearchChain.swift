//
//  OpenSourceSearchChain.swift
//  Triva
//
//  Created by ben podrojsky on 27/10/2026.
//

import Foundation

/// Fabrique des sources ouvertes SANS CLÉ (Wikipédia, OpenAlex, arXiv, Marginalia), dernier
/// recours de la chaîne de repli décrite dans `WebSearchProviding` : quand ni clé personnelle,
/// ni instance SearXNG, ni recherche du fournisseur IA ne répondent, ces quatre services
/// publics permettent encore d'ancrer la réponse sur de vraies sources citables.
///
/// Cette fabrique est volontairement PURE : elle dit quelles sources essayer et dans quel
/// ordre, rien de plus. La boucle de repli (essayer la suivante sur `.unavailable`,
/// `.rateLimited`, `.timeout`…, s'arrêter sur une annulation) appartient à `WebSearchChain`.
///
/// ORDRES CHOISIS (et pourquoi)
/// - `general` : Wikipédia puis Marginalia. Wikipédia est la plus stable (infrastructure
///   Wikimedia, aucune protection anti-robot) et renvoie des introductions rédigées, idéales
///   comme contexte. Marginalia vient ensuite : elle ouvre sur le web indépendant, mais sa clé
///   `public` est partagée entre tous ses utilisateurs et plafonne souvent.
/// - `academic` : OpenAlex, arXiv, puis Wikipédia. OpenAlex couvre toutes les disciplines
///   (plusieurs centaines de millions d'œuvres) ; arXiv ne couvre que physique, maths,
///   informatique et disciplines voisines, d'où son rang 2 ; Wikipédia ferme la chaîne pour
///   les questions « académiques » de culture générale (un concept, une personne) que les
///   deux bases scientifiques traitent mal.
/// - `discussion` : Marginalia puis Wikipédia. Aucune source ouverte sans clé n'indexe de
///   vrais forums ; Marginalia, qui favorise blogs et sites personnels, est la moins
///   éloignée. Wikipédia garantit au moins un contexte neutre.
///
/// COHÉRENCE ORDRE / CATÉGORIES : chaque source renvoyée pour une catégorie accepte cette
/// catégorie (jamais de `.unsupportedCategory` dans la chaîne). C'est pourquoi Wikipédia
/// accepte les trois catégories alors que sa catégorie « naturelle » est `general`.
/// Un test le vérifie pour les trois catégories.
nonisolated struct OpenSourceSearchChain: Sendable {
    private let requester: any HTTPDataRequesting
    private let openAlexContactEmail: String?
    private let arXivSpacer: ArXivRequestSpacer

    /// - Parameters:
    ///   - openAlexContactEmail: e-mail de contact transmis à OpenAlex (`mailto`), vide par
    ///     défaut : l'app ne met JAMAIS de donnée personnelle de son auteur dans une requête.
    ///   - arXivSpacer: espaceur partagé par défaut, de sorte que toutes les recherches de
    ///     l'app respectent ensemble la pause de 3 s demandée par arXiv.
    init(
        requester: any HTTPDataRequesting = URLSessionDataRequester(),
        openAlexContactEmail: String? = nil,
        arXivSpacer: ArXivRequestSpacer = .shared
    ) {
        self.requester = requester
        self.openAlexContactEmail = openAlexContactEmail
        self.arXivSpacer = arXivSpacer
    }

    /// Ordre d'essai pour une catégorie, sans rien instancier (utile pour l'affichage).
    static func kinds(for category: WebSearchCategory) -> [WebSearchSourceKind] {
        switch category {
        case .general: [.wikipedia, .marginalia]
        case .academic: [.openAlex, .arXiv, .wikipedia]
        case .discussion: [.marginalia, .wikipedia]
        }
    }

    /// Sources à essayer, dans l'ordre, pour une catégorie.
    func providers(for category: WebSearchCategory) -> [any WebSearchProviding] {
        Self.kinds(for: category).map(makeProvider(for:))
    }

    private func makeProvider(for kind: WebSearchSourceKind) -> any WebSearchProviding {
        switch kind {
        case .openAlex:
            OpenAlexSearchProvider(contactEmail: openAlexContactEmail, requester: requester)
        case .arXiv:
            ArXivSearchProvider(requester: requester, spacer: arXivSpacer)
        case .marginalia:
            MarginaliaSearchProvider(requester: requester)
        default:
            // `kinds(for:)` ne renvoie que des sources ouvertes ; Wikipédia est le seul autre cas.
            WikipediaSearchProvider(requester: requester)
        }
    }
}

// MARK: - Espacement des requêtes arXiv

/// Impose un délai minimal entre deux requêtes arXiv.
///
/// Source : manuel de l'API arXiv (https://info.arxiv.org/help/api/user-manual.html) :
/// « we encourage you to play nice and incorporate a 3 second delay in your code ». Ce n'est
/// pas une limite stricte mais une demande explicite ; un client qui l'ignore s'expose au
/// blocage de son IP, et ce serait l'IP de l'utilisateur.
///
/// Un `actor` (état partagé : l'instant du prochain créneau libre). Le créneau est RÉSERVÉ
/// avant de dormir : deux appels concurrents reçoivent deux créneaux distincts espacés de
/// l'intervalle, au lieu de se réveiller ensemble. Si l'attente est annulée, le créneau reste
/// consommé : on perd au pire quelques secondes d'avance, jamais le respect du débit.
///
/// L'horloge et le sommeil sont injectables pour que les tests ne dorment jamais pour de vrai.
actor ArXivRequestSpacer {
    /// Instance partagée par toute l'app : le délai vaut pour l'IP, pas pour une recherche.
    static let shared = ArXivRequestSpacer()

    private let interval: Duration
    private let now: @Sendable () -> ContinuousClock.Instant
    private let sleep: @Sendable (Duration) async throws -> Void
    private var nextSlot: ContinuousClock.Instant?

    init(
        interval: Duration = .seconds(3),
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.interval = interval
        self.now = now
        self.sleep = sleep
    }

    /// Rend la main quand la requête peut partir. Propage `CancellationError`.
    func waitForTurn() async throws {
        let current = now()
        let start = max(current, nextSlot ?? current)
        nextSlot = start + interval
        let delay = start - current
        if delay > .zero {
            try await sleep(delay)
        }
    }
}

// MARK: - Éléments communs aux quatre sources

/// En-têtes et classification d'erreurs partagés par les sources ouvertes.
nonisolated enum OpenSourceSearchHTTP {
    /// Contact joint au User-Agent. Valeur GÉNÉRIQUE : l'adresse du dépôt du projet, jamais
    /// une adresse e-mail ni un identifiant personnel. À ajuster si le projet change d'adresse
    /// publique (page d'assistance, site de l'app…).
    static let contact = "https://github.com/Ben-126/Triva"

    /// User-Agent identifiable, envoyé par les quatre sources.
    ///
    /// Politique Wikimedia (https://foundation.wikimedia.org/wiki/Policy:Wikimedia_Foundation_User-Agent_Policy,
    /// consultée le 2026-10-27) : `<client>/<version> (<contact>) …`, le contact pouvant être
    /// un site web ; ne pas copier celui d'un navigateur, ne pas utiliser un agent générique
    /// (un agent absent ou générique peut recevoir un 403). Les bonnes pratiques d'API de
    /// MediaWiki, d'OpenAlex et d'arXiv demandent la même chose, d'où un seul texte pour tous.
    static let userAgent = "Triva/1.0 (app iOS/macOS; \(contact))"

    /// Requête GET avec les en-têtes communs.
    static func makeRequest(url: URL, accept: String) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: BYOKSearchHTTP.timeout)
        request.httpMethod = "GET"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        return request
    }

    /// Statut HTTP -> erreur pour une source SANS clé.
    ///
    /// Écart avec `BYOKSearchHTTP.defaultError` : 401/403 y signifient « clé refusée »
    /// (`.unauthorized`, message « La clé de recherche a été refusée »), ce qui n'a aucun sens
    /// ici. Un 403 de Wikimedia veut dire « User-Agent refusé » ou blocage d'IP : la source est
    /// simplement indisponible pour cet appareil. `.unavailable` fait passer à la source
    /// suivante sans accuser une clé que l'utilisateur n'a jamais saisie.
    static func classifyKeyless(status: Int, body: Data) -> WebSearchError {
        switch status {
        case 401, 403: .unavailable
        default: BYOKSearchHTTP.defaultError(forStatus: status)
        }
    }
}
