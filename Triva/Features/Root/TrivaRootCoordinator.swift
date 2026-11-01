//
//  TrivaRootCoordinator.swift
//  Triva
//
//  Created by ben podrojsky on 31/10/2026.
//

import Foundation
import OSLog

/// Coordination des cinq espaces d'UNE fenêtre (mission I4b) : la destination
/// affichée, et les actions qui font passer d'un espace à l'autre — ouvrir
/// dans la Recherche une conversation de la Bibliothèque ou d'un favori,
/// « Chercher dans Triva » depuis Découvrir, aller configurer une clé API.
///
/// ## Pourquoi un objet, et pas un empilement de bindings
/// Chaque action entre écrans touche DEUX choses à la fois : la destination et
/// l'état de la Recherche (charger une conversation, remplir la barre de
/// saisie). Avec des bindings, la coquille passerait `selection` et la session
/// à chaque espace, et l'ordre des opérations — créer le chat s'il n'a jamais
/// été affiché, PUIS charger, PUIS basculer — se disperserait dans des
/// closures de vue que rien ne teste. Ici, un seul objet détient ce que ces
/// actions manipulent ensemble (la destination, la `SearchSession`, le modèle
/// de Découvrir) et chaque action est une méthode testée sans interface
/// (`TrivaRootCoordinatorTests`). Les espaces, eux, ne connaissent que leurs
/// closures (`onOpenConversation`, `onSearch`…) : ils restent réutilisables et
/// prévisualisables seuls.
///
/// ## Durée de vie : celle de la coquille, donc du moteur IA
/// Créé par `TrivaRootShell` (un `@State`), lui-même reconstruit à chaque
/// changement de moteur (`.id(selected)` dans `TrivaRootView`, bug 10). Donc
/// un coordinateur par fenêtre ET par moteur :
/// - la session n'est jamais remplacée sous les pieds d'une vue : le moteur
///   affiché par le badge reste celui qui répond ;
/// - deux fenêtres (Mac ⌘N, iPad Split View / Stage Manager) ont chacune leur
///   destination, leur conversation, leur brouillon et leur sujet Découvrir.
///   Seuls les STORES sont communs (`TrivaSharedStores`) ;
/// - écart assumé : un changement de moteur ramène la fenêtre sur Recherche et
///   jette le contenu déjà chargé de Découvrir (rechargé à la visite
///   suivante). C'était déjà le cas avant I4b (la destination était un
///   `@State` du shell), l'événement est rare et remet de toute façon la
///   conversation à zéro (décision de Ben, 2026-10-04).
///
/// L'init n'a aucun effet de bord (ni réseau, ni lecture de store, ni
/// création de `ChatViewModel`) : `State(initialValue:)` réévalue l'expression
/// à chaque reconstruction de la vue parente et ne garde que la PREMIÈRE
/// instance, les suivantes doivent donc ne rien coûter.
@Observable
@MainActor
final class TrivaRootCoordinator {
    /// Destination affichée par la fenêtre. Recherche au lancement, sur une
    /// conversation vierge (décision 1 de Ben) : les anciennes sont dans la
    /// Bibliothèque, rien n'est rouvert automatiquement.
    var selection: TrivaRootDestination = .search

    /// Session de la Recherche (conversation en cours, brouillon de la barre
    /// de saisie, caches du moteur). Une seule pour toute la vie du
    /// coordinateur : voir « Durée de vie ».
    let session: SearchSession

    /// Modèle de Découvrir, UN par coordinateur, donc par fenêtre — et non plus
    /// `DiscoverViewModel.standalone`, partagé par toutes les fenêtres (sujet
    /// sélectionné compris) et construit sur la seule liste SearXNG du bundle.
    /// Détenu ici plutôt que dans la vue : un chargement coûte jusqu'à ~120
    /// requêtes, il ne doit pas repartir à chaque retour sur l'onglet (voir la
    /// documentation de `DiscoverViewModel`).
    let discover: DiscoverViewModel

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Triva",
        category: "TrivaRootCoordinator"
    )

    /// - Parameters:
    ///   - engine: moteur de la fenêtre, figé dans la session (bug 10).
    ///   - stores: instances UNIQUES de l'app, jamais recréées ici.
    init(engine: AIEngineOption, stores: TrivaSharedStores) {
        let session = SearchSession(engine: engine, stores: stores)
        self.session = session
        // Découvrir cherche sur la liste d'instances EFFECTIVE (bundle +
        // modifications de Réglages > Avancé) et à travers le
        // `FailoverManager` de la session : son cache de « dernière instance
        // qui répond » sert ainsi aux deux espaces, et une liste modifiée est
        // prise en compte au chargement suivant (le cache se revalide seul,
        // voir `SearchSession.resolveFailoverManager()`).
        //
        // `weak` : le chargement est une `Task` détenue par le modèle de
        // Découvrir, qui survit à la vue. Une capture forte garderait la
        // session — conversation et modèle MLX préparé compris, plusieurs Go —
        // en vie jusqu'à la fin des requêtes après la fermeture de la fenêtre.
        self.discover = DiscoverViewModel(fetchContent: { [weak session] in
            guard let session else { throw SearchSessionError.sessionEnded }
            return await DiscoverService(failoverManager: session.resolveFailoverManager()).fetchTrending()
        })
    }

    // MARK: - Actions entre espaces

    /// Bibliothèque > une conversation, ou Favoris > « Ouvrir la
    /// conversation » : la rouvre dans la Recherche et y bascule.
    ///
    /// Le `ChatViewModel` est créé ici s'il n'existe pas encore : sur iPad ou
    /// Mac, on peut très bien ouvrir la Bibliothèque avant d'avoir jamais
    /// affiché la Recherche, et `ensureChatViewModel()` n'est sinon appelé
    /// qu'à son apparition. Sans cela, le chargement tomberait dans le vide.
    ///
    /// La bascule a lieu MÊME si le chargement échoue (conversation supprimée
    /// entre-temps, base illisible) : le chat affiche alors l'erreur de
    /// persistance (`persistenceErrorDescription`, p. ex. « Cette
    /// conversation n'existe plus. ») et garde le fil en cours. Rester sur la
    /// Bibliothèque sans rien dire serait un bouton qui ne fait rien.
    ///
    /// Rouvrir une conversation remplace le fil : une réponse en cours dans
    /// cette fenêtre est arrêtée, et sa partie déjà reçue reste enregistrée
    /// dans SA conversation (`ChatViewModel.loadConversation(id:)`, qui passe
    /// par `startNewConversation()`).
    func openConversation(id: UUID) {
        session.ensureChatViewModel()
        session.chatViewModel?.loadConversation(id: id)
        selection = .search
    }

    /// Découvrir > « Chercher dans Triva » : remplit la barre de saisie de la
    /// Recherche avec le titre de l'article, puis y bascule. La question n'est
    /// PAS envoyée : l'utilisateur peut la préciser avant (mission I4b,
    /// « requête pré-remplie »).
    ///
    /// Écart assumé avec le web : Vane envoie aussitôt `Summary: <url>`, que
    /// son action `scrapeURL` sait résumer. Triva n'a pas cette action — une
    /// URL brute envoyée à SearXNG ne trouverait que la page elle-même — d'où
    /// le titre, la meilleure requête de recherche dont on dispose.
    ///
    /// Le brouillon en cours est remplacé : c'est ce que demande ce geste
    /// explicite. Un titre vide (jamais affiché, en pratique) ne l'efface pas.
    func search(_ article: DiscoverArticle) {
        let query = Self.searchQuery(for: article)
        if !query.isEmpty {
            session.draft.text = query
        }
        selection = .search
    }

    /// Recherche > « Configurer une clé API » (moteur cloud sans fournisseur
    /// choisi) : les Réglages de la MÊME fenêtre, où se trouvent « Gérer les
    /// clés API » et « Fournisseur et modèle ».
    func showSettings() {
        selection = .settings
    }

    /// Bibliothèque : une conversation vient d'être supprimée dans cette
    /// fenêtre. Si c'est celle du fil, le chat repart à neuf.
    func conversationWasDeleted(id: UUID) {
        session.chatViewModel?.conversationWasDeleted(id: id)
    }

    /// L'historique a changé, dans n'importe quelle fenêtre : appelée par la
    /// coquille à chaque `ChatHistoryStore.revision`.
    ///
    /// `onConversationDeleted` ne couvre que la Bibliothèque de CETTE fenêtre,
    /// et pas « Tout effacer ». Une suppression faite ailleurs (autre fenêtre
    /// Mac ou iPad) laisserait sinon ici un fil qui n'existe plus : le
    /// prochain envoi créerait une NOUVELLE conversation ne contenant que la
    /// dernière question, sous des messages affichés qui ne seraient plus
    /// enregistrés nulle part.
    ///
    /// Seule une absence CONSTATÉE vide le fil. Une lecture qui échoue
    /// (base momentanément illisible) ne prouve rien : vider le fil sur une
    /// erreur passagère ferait perdre ce que l'utilisateur est en train de
    /// lire. L'erreur est journalisée, et le prochain envoi la remontera dans
    /// le chat s'il échoue à son tour (`persistenceErrorDescription`).
    func historyDidChange() {
        guard let chatViewModel = session.chatViewModel,
              let conversationID = chatViewModel.currentConversationID else { return }
        let stillExists: Bool
        do {
            stillExists = try session.stores.chatHistory.conversation(with: conversationID) != nil
        } catch {
            Self.logger.error("Historique illisible, fil conservé : \(String(describing: error), privacy: .private)")
            return
        }
        guard !stillExists else { return }
        chatViewModel.conversationWasDeleted(id: conversationID)
    }

    // MARK: - Règles pures

    /// Requête tirée d'un article : son titre, blancs fusionnés comme à
    /// l'affichage (`DiscoverArticlePresentation.displayText`) — les titres
    /// SearXNG gardent souvent les retours à la ligne de leur HTML.
    static func searchQuery(for article: DiscoverArticle) -> String {
        DiscoverArticlePresentation.displayText(article.title)
    }
}
