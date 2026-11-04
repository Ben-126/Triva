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
