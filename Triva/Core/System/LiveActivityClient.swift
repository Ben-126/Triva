//
//  LiveActivityClient.swift
//  Triva
//
//  Chantier 2.1 (mission D) : la couture entre le contrôleur d'activité en direct et ActivityKit. Le contrôleur ne
//  parle qu'à ce protocole : les tests y mettent un faux client, et sur Mac (où ActivityKit n'existe pas) le client
//  « indisponible » dit simplement que rien n'est possible.
//
//  Doc Apple vérifiée (DocumentationSearch, Xcode 27.2) : `Activity.request(attributes:content:pushType:)` (lève
//  `ActivityAuthorizationError`, p. ex. `.visibility` depuis l'arrière-plan, `.denied` si l'utilisateur a coupé les
//  activités), `update(_:)` et `end(_:dismissalPolicy:)` (asynchrones, 4 Ko au plus, utilisables en arrière-plan),
//  `ActivityUIDismissalPolicy` (`.immediate`, `.after(Date)` dans une fenêtre de 4 h),
//  `ActivityAuthorizationInfo().areActivitiesEnabled`.
//

import Foundation
import OSLog
#if os(iOS)
import ActivityKit
#endif

/// Quand l'activité terminée disparaît de l'écran verrouillé.
nonisolated enum LiveActivityEndPolicy: Sendable, Equatable {
    case immediate
    case after(Date)
}

/// Une activité encore affichée (en cours, ou terminée mais pas encore disparue de l'écran verrouillé).
nonisolated struct OpenLiveActivity: Sendable, Equatable {
    let id: String
    let conversationID: UUID?
}

@MainActor
protocol LiveActivityClient: AnyObject {
    /// Faux si l'utilisateur a coupé les activités pour l'app, ou si la plateforme n'en a pas.
    var areActivitiesEnabled: Bool { get }
    /// Démarre une activité et rend son identifiant. Lève si le système refuse (jamais attrapé ici).
    func start(attributes: SearchActivityAttributes, state: SearchActivityState, staleDate: Date) throws -> String
    func update(id: String, state: SearchActivityState, staleDate: Date) async
    func end(id: String, state: SearchActivityState, policy: LiveActivityEndPolicy) async
    /// Termine TOUTES les activités de recherche encore ouvertes (orphelines après un lancement, « Tout effacer »).
    func endAll() async
    /// Les activités de recherche encore affichées, avec leur conversation.
    func openActivities() -> [OpenLiveActivity]
    /// Retire UNE activité de l'écran tout de suite, sans état final (sa conversation a disparu).
    func dismiss(id: String) async
}

/// Mac, et toute plateforme sans ActivityKit : jamais d'activité.
@MainActor
final class UnavailableLiveActivityClient: LiveActivityClient {
    var areActivitiesEnabled: Bool { false }

    func start(attributes: SearchActivityAttributes, state: SearchActivityState, staleDate: Date) throws -> String {
        throw LiveActivityUnavailableError()
    }

    func update(id: String, state: SearchActivityState, staleDate: Date) async {}
    func end(id: String, state: SearchActivityState, policy: LiveActivityEndPolicy) async {}
    func endAll() async {}
    func openActivities() -> [OpenLiveActivity] { [] }
    func dismiss(id: String) async {}
}

nonisolated struct LiveActivityUnavailableError: Error, Equatable {}

#if os(iOS)
/// Le vrai client : ActivityKit, mises à jour LOCALES seulement (`pushType: nil`, pas de serveur).
///
/// `Activity` n'est pas `Sendable` : on n'en garde aucune. Chaque appel retrouve l'activité par son identifiant
/// (`Activity.activities`) dans une fonction `@concurrent`, où elle reste locale (aucune donnée partagée entre acteurs).
@MainActor
final class ActivityKitLiveActivityClient: LiveActivityClient {
    var areActivitiesEnabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    func start(attributes: SearchActivityAttributes, state: SearchActivityState, staleDate: Date) throws -> String {
        let activity = try Activity<SearchActivityAttributes>.request(
            attributes: attributes,
            content: ActivityContent(state: state, staleDate: staleDate),
            pushType: nil
        )
        return activity.id
    }

    func update(id: String, state: SearchActivityState, staleDate: Date) async {
        await Self.update(id: id, content: ActivityContent(state: state, staleDate: staleDate))
    }

    func end(id: String, state: SearchActivityState, policy: LiveActivityEndPolicy) async {
        // Contenu final sans date de péremption : l'état final reste lisible tant que l'activité reste affichée.
        await Self.end(id: id, content: ActivityContent(state: state, staleDate: nil), policy: policy.dismissalPolicy)
    }

    func endAll() async {
        await Self.endAllActivities()
    }

    func openActivities() -> [OpenLiveActivity] {
        Activity<SearchActivityAttributes>.activities.map {
            OpenLiveActivity(id: $0.id, conversationID: $0.attributes.conversationID)
        }
    }

    func dismiss(id: String) async {
        await Self.dismissActivity(id: id)
    }

    @concurrent
    private static func dismissActivity(id: String) async {
        guard let activity = Activity<SearchActivityAttributes>.activities.first(where: { $0.id == id }) else { return }
        await activity.end(nil, dismissalPolicy: .immediate)
    }

    @concurrent
    private static func update(id: String, content: ActivityContent<SearchActivityState>) async {
        guard let activity = Activity<SearchActivityAttributes>.activities.first(where: { $0.id == id }) else { return }
        await activity.update(content)
    }

    @concurrent
    private static func end(id: String, content: ActivityContent<SearchActivityState>, policy: ActivityUIDismissalPolicy) async {
        guard let activity = Activity<SearchActivityAttributes>.activities.first(where: { $0.id == id }) else { return }
        await activity.end(content, dismissalPolicy: policy)
    }

    @concurrent
    private static func endAllActivities() async {
        for activity in Activity<SearchActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}

private extension LiveActivityEndPolicy {
    var dismissalPolicy: ActivityUIDismissalPolicy {
        switch self {
        case .immediate: .immediate
        case .after(let date): .after(date)
        }
    }
}
#endif
