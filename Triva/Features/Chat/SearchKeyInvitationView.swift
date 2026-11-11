//
//  SearchKeyInvitationView.swift
//  Triva
//
//  Created by ben podrojsky on 04/11/2026.
//

import SwiftUI

// MARK: - Logique pure

/// Invitation posée sous le bandeau d'erreur du chat quand la recherche a échoué parce que TOUTES
/// les sources de la chaîne ont levé une erreur (`WebSearchChainError.allSourcesFailed`, mission RI2).
/// Depuis la mission A2, aussi après une réponse RÉUSSIE venue d'une source de secours parce que
/// SearXNG n'a rien donné (`init(afterFallback:retainedSource:)`) : même place, en bas du fil, sans
/// bandeau puisqu'il n'y a pas d'erreur.
///
/// Le constat lui-même (« Aucune source de recherche n'a répondu… ») reste dans le bandeau
/// (`ChatViewModel.errorDescription`) : l'invitation n'ajoute que ce qu'il ne dit pas, sans le répéter.
///
/// DEUX FORMES, parce qu'inviter à « ajouter » une clé à qui en a déjà une serait faux :
/// - aucune clé personnelle dans les échecs : l'utilisateur n'en a pas, on lui propose d'en ajouter ;
/// - une clé dans les échecs (refusée, quota épuisé, ou illisible dans le trousseau) : on nomme le
///   service et on propose d'aller la vérifier. L'écran des clés, avec son bouton « Tester », donne
///   alors la cause exacte : rien ne la recopie ici, un motif technique n'aiderait pas dans le fil.
///
/// JAMAIS d'invitation pour une autre erreur : une panne du moteur IA ne se règle pas avec une clé de
/// recherche. « Toutes les sources ont répondu à vide » n'est pas non plus un échec : la question n'a
/// simplement aucun résultat, et une réponse part quand même (`WebSearchChain`).
///
/// Pas d'invitation non plus si l'appareil est hors ligne (décision de Ben) : toutes les sources
/// échouent, mais une clé n'y changerait rien, et le bandeau dit déjà de se reconnecter
/// (`WebSearchChainError.isDeviceOffline`). Le cas se déduit des erreurs reçues.
///
/// `nonisolated` : donnée pure, construite et testée hors de toute vue.
nonisolated struct SearchKeyInvitation: Sendable, Equatable {
    static let addKeyTitle = "Ajouter une clé de recherche"
    static let checkKeysTitle = "Vérifier les clés de recherche"
    static let addKeyExplanation = "Une clé de recherche personnelle rend les résultats plus fiables."

    /// Une phrase, sous le bandeau d'erreur. Texte fixe : les noms viennent de l'app, jamais du réseau.
    let explanation: String
    /// Titre du bouton qui ouvre l'écran des clés.
    let actionTitle: String

    /// `nil` si `error` n'est pas un échec de toutes les sources, ou si l'appareil est hors ligne :
    /// pas d'invitation.
    init?(for error: any Error) {
        guard let chainError = error as? WebSearchChainError,
              !chainError.isDeviceOffline,
              case .allSourcesFailed(let failures) = chainError else { return nil }
        let failedKinds = failures.map(\.source)
        // Ordre de préférence, le même que l'écran des clés, quel que soit celui des échecs.
        let failedKeys = BYOKSearchSource.preferenceOrder.filter { failedKinds.contains($0.kind) }
        if failedKeys.isEmpty {
            explanation = Self.addKeyExplanation
            actionTitle = Self.addKeyTitle
        } else {
            explanation = Self.failedKeysExplanation(failedKeys)
            actionTitle = Self.checkKeysTitle
        }
    }

    /// Invitation DISCRÈTE après une réponse obtenue sans SearXNG (mission A2, décision 7 de Ben) :
    /// la chaîne l'a laissé de côté (en échec, à vide ou hors sujet) et une source de secours a
    /// répondu. Mesuré (rapport T1) : sans clé, toutes les réponses venaient de Wikipédia, et
    /// l'invitation, posée seulement quand TOUT échoue, ne s'affichait jamais.
    ///
    /// `nil`, pas d'invitation :
    /// - sans recherche web, ou si SearXNG n'a pas été laissé de côté (il a fourni les résultats,
    ///   ou une clé personnelle a répondu AVANT lui) ;
    /// - sans aucune source web affichée (`webSourceCount`, fichiers joints exclus) : toutes les
    ///   sources ont répondu à vide, la question n'a simplement aucun résultat (décision D3 de
    ///   RI1b, même règle que `init(for:)`) ;
    /// - si la réponse retenue vient d'une clé personnelle (meilleure réponse écartée, retenue faute
    ///   de mieux) : en ajouter une n'y changerait rien ;
    /// - si une clé a répondu sans rien de retenu : elle marche, en ajouter une autre n'est pas la
    ///   réponse. Une clé en ÉCHEC (refusée, quota, illisible) donne la forme « Vérifier ».
    init?(afterFallback report: WebSearchChainReport, retainedSource: WebSearchSourceKind?, webSourceCount: Int) {
        let keySources = BYOKSearchSource.preferenceOrder
        guard webSourceCount > 0,
              let retainedSource,
              !keySources.contains(where: { $0.kind == retainedSource }),
              report.passedOver.contains(where: { $0.source == .searxng }) else { return nil }
        let keyAttempts = report.passedOver.filter { attempt in keySources.contains { $0.kind == attempt.source } }
        let failedKeys = keySources.filter { source in
            keyAttempts.contains { $0.source == source.kind && $0.reason != .noUsableAnswer }
        }
        if !failedKeys.isEmpty {
            explanation = Self.failedKeysExplanation(failedKeys)
            actionTitle = Self.checkKeysTitle
        } else if keyAttempts.isEmpty {
            explanation = Self.addKeyExplanation
            actionTitle = Self.addKeyTitle
        } else {
            return nil
        }
    }

    private static func failedKeysExplanation(_ sources: [BYOKSearchSource]) -> String {
        let names = sources.map(\.displayName).joined(separator: " et ")
        return sources.count > 1
            ? "Tes clés \(names) n'ont pas fonctionné."
            : "Ta clé \(names) n'a pas fonctionné."
    }
}

// MARK: - Environnement

/// Ouvre l'écran des clés de recherche dans la fenêtre : `action()`, comme `OpenURLAction`.
///
/// Un type comparable plutôt qu'une closure nue : SwiftUI ne sait pas comparer deux closures, or
/// chaque rendu de la coquille en fabrique une nouvelle. Toute vue qui lit cette valeur, `ChatView`
/// en tête, serait réévaluée à chaque fois (avertissement de `@Entry`). Deux actions du même
/// propriétaire font la même chose : c'est lui qu'on compare. La closure retient son propriétaire,
/// son adresse ne peut donc pas resservir tant que l'action existe.
nonisolated struct OpenSearchKeySettingsAction: Sendable, Equatable {
    private let ownerID: ObjectIdentifier
    private let handler: @MainActor () -> Void

    /// - Parameter owner: l'objet stable qui détient cette action (`TrivaRootCoordinator`).
    init(owner: AnyObject, handler: @escaping @MainActor () -> Void) {
        ownerID = ObjectIdentifier(owner)
        self.handler = handler
    }

    @MainActor
    func callAsFunction() {
        handler()
    }

    static func == (lhs: OpenSearchKeySettingsAction, rhs: OpenSearchKeySettingsAction) -> Bool {
        lhs.ownerID == rhs.ownerID
    }
}

extension EnvironmentValues {
    /// Posée par la coquille (`TrivaRootShell`, sur `TrivaRootCoordinator.showSearchKeys()`), lue
    /// par `ChatView`.
    ///
    /// Par l'environnement plutôt qu'en paramètre de `ChatView` : elle est construite par
    /// `EngineStatusView`, qui n'a pas à connaître cette action et ne ferait que la relayer.
    /// `nil` (aperçus, chat hors coquille) : pas de bouton, plutôt qu'un bouton qui ne fait rien.
    @Entry var openSearchKeySettings: OpenSearchKeySettingsAction? = nil
}

// MARK: - Vue

/// L'explication et le bouton de l'invitation, sous le bandeau d'erreur.
///
/// Son `GlassEffectContainer` est le sien, comme celui de `SuggestionsView` : elle vit hors du
/// conteneur des bulles de `ChatView`, sous le bandeau, et deux conteneurs imbriqués seraient faux.
/// `.glass` et non `.glassProminent` : l'action principale de l'écran reste d'envoyer une question.
struct SearchKeyInvitationView: View {
    let invitation: SearchKeyInvitation
    let onOpen: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(invitation.explanation)
                .font(.footnote)
                .foregroundStyle(.secondary)

            GlassEffectContainer(spacing: 8) {
                Button(invitation.actionTitle, systemImage: "key", action: onOpen)
                    .font(.subheadline)
                    .buttonStyle(.glass)
                    .accessibilityIdentifier("chat.searchKeyInvitation")
            }
        }
    }
}

// MARK: - Aperçus

#Preview("Aucune clé") {
    let error = WebSearchChainError.allSourcesFailed([
        WebSearchSourceFailure(source: .searxng, reason: .searchFailed(.unavailable)),
        WebSearchSourceFailure(source: .wikipedia, reason: .searchFailed(.rateLimited)),
    ])
    if let invitation = SearchKeyInvitation(for: error) {
        SearchKeyInvitationView(invitation: invitation, onOpen: {})
            .padding(20)
    }
}

#Preview("Clé Brave en échec — sombre") {
    let error = WebSearchChainError.allSourcesFailed([
        WebSearchSourceFailure(source: .braveSearch, reason: .searchFailed(.unauthorized)),
        WebSearchSourceFailure(source: .searxng, reason: .searchFailed(.unavailable)),
    ])
    if let invitation = SearchKeyInvitation(for: error) {
        SearchKeyInvitationView(invitation: invitation, onOpen: {})
            .padding(20)
            .preferredColorScheme(.dark)
    }
}
