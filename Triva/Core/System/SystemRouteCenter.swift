//
//  SystemRouteCenter.swift
//  Triva
//
//  Chantier 2.1 (mission A) : où arrivent les routes du système (URL `triva://`, intents, plus tard partage et
//  Spotlight). UNE règle : une route NAVIGUE, elle n'ENVOIE JAMAIS une question.
//

import Foundation
import Observation

/// Reçoit les routes et les remet à la bonne fenêtre.
///
/// - **Mac** (`windowLauncher` non `nil`) : la route est confiée à `ExternalSearchLauncher`, qui ouvre ou ramène
///   la bonne fenêtre ; un texte y est déposé avec l'origine `.draft`, donc jamais envoyé par la fenêtre. La file
///   ci-dessous reste vide.
/// - **iPhone et iPad** (`windowLauncher` `nil`) : la route attend dans une file, et UNE fenêtre active la prend
///   (`drain()` ne rend chaque route qu'une fois : jamais deux fenêtres pour une route). Tant qu'aucune fenêtre ne
///   peut la prendre (onboarding, choix du moteur), elle attend.
@Observable
@MainActor
final class SystemRouteCenter {
    /// Routes en attente au plus : si personne ne les prend, la file ne grossit pas. 32 : dix partages (la limite de la
    /// boîte de partage) peuvent chacun apporter un fichier et un texte, plus les trois informations communes (texte
    /// coupé, fichier non copié, partages retirés) : 23 routes, et de la marge pour d'autres routes arrivées en même temps.
    static let maxPending = 32

    /// Exemplaire de l'app. Les tests construisent le leur.
    static let shared = SystemRouteCenter(windowLauncher: platformWindowLauncher)

    /// Augmente à chaque dépôt (jamais à la lecture) : déclencheur des `onChange` des fenêtres.
    private(set) var revision = 0

    /// Une route en attente, et ce qu'il faut faire quand une fenêtre l'a prise (ou qu'elle est jetée).
    private struct Pending {
        let route: SystemRoute
        let whenDrained: (@MainActor () -> Void)?
    }

    @ObservationIgnored private var pending: [Pending] = []
    @ObservationIgnored private let windowLauncher: ExternalSearchLauncher?
    /// Racine du coffre de pièces jointes : un fichier partagé n'est accepté que dans `<racine>/_deposits/`.
    @ObservationIgnored private let depositRoot: URL

    /// Mac : dit si une conversation existe (branché au lancement par `SystemIntegrations.start()`). Sans lui, tout
    /// identifiant est accepté. Une lecture qui échoue doit rendre `true` (la fenêtre affichera elle-même l'erreur).
    @ObservationIgnored var conversationExists: (@MainActor (UUID) -> Bool)?
    /// Mac : un appel identique (nouvelle recherche, même conversation) qui revient dans cet intervalle est ignoré.
    static let repeatWindow: TimeInterval = 1
    @ObservationIgnored private var lastForwarded: (route: SystemRoute, date: Date)?
    @ObservationIgnored private let now: @MainActor () -> Date

    init(
        windowLauncher: ExternalSearchLauncher?,
        depositRoot: URL = AttachmentFileVault.defaultRootDirectory,
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.windowLauncher = windowLauncher
        self.depositRoot = depositRoot
        self.now = now
    }

    /// Le Mac ouvre des fenêtres par `ExternalSearchLauncher` ; l'iPhone et l'iPad par la file.
    private static var platformWindowLauncher: ExternalSearchLauncher? {
        #if os(macOS)
        ExternalSearchLauncher.shared
        #else
        nil
        #endif
    }

    // MARK: Dépôt

    /// Une route du système. Un brouillon est assaini ici (`ExternalQuerySanitizer`) ; vide ou illisible, il est jeté.
    ///
    /// - Parameter whenDrained: appelé quand une fenêtre a PRIS la route (`drain()`), ou quand elle est jetée : la
    ///   boîte de partage n'efface son entrée qu'à ce moment-là, pour qu'une app tuée avant l'application ne perde rien.
    func submit(_ route: SystemRoute, whenDrained: (@MainActor () -> Void)? = nil) {
        guard let route = sanitized(route) else {
            whenDrained?()
            return
        }
        if let windowLauncher {
            forward(route, to: windowLauncher)
            whenDrained?()
            return
        }
        pending.append(Pending(route: route, whenDrained: whenDrained))
        if pending.count > Self.maxPending {
            // Une route fichier évincée emporte son dépôt : rien ne doit traîner.
            let evicted = Array(pending.prefix(pending.count - Self.maxPending))
            pending.removeFirst(evicted.count)
            for item in evicted {
                discardDeposit(of: item.route)
                item.whenDrained?()
            }
        }
        revision += 1
    }

    /// Une URL reçue par l'app (`onOpenURL`). `false` si ce n'est pas une des nôtres : rien n'est fait.
    @discardableResult
    func open(url: URL) -> Bool {
        guard let route = TrivaURLRoute.parse(url) else { return false }
        submit(route)
        return true
    }

    /// Rend les routes en attente et vide la file.
    func drain() -> [SystemRoute] {
        let taken = pending
        pending.removeAll()
        taken.forEach { $0.whenDrained?() }
        return taken.map(\.route)
    }

    /// « Tout effacer » : les routes qui attendent une fenêtre (un texte et un fichier partagés) sont jetées, avec leurs dépôts.
    func discardPending() {
        let taken = pending
        pending.removeAll()
        for item in taken {
            discardDeposit(of: item.route)
            item.whenDrained?()
        }
    }

    // MARK: Privé

    /// Un brouillon est assaini ; un fichier n'est accepté que dans les dépôts de l'app (jamais un fichier de
    /// l'utilisateur, jamais une adresse web : la route peut être jetée, jamais détournée).
    private func sanitized(_ route: SystemRoute) -> SystemRoute? {
        switch route {
        case .draft(let text):
            return ExternalQuerySanitizer.sanitize(text).map(SystemRoute.draft)
        case .attachment(let url):
            return Self.isDeposit(url, root: depositRoot) ? route : nil
        case .newQuestion, .conversation, .notice:
            return route
        }
    }

    /// Vrai pour un fichier SOUS `<racine>/_deposits/<id>/` (chemin normalisé : `..` n'y échappe pas).
    static func isDeposit(_ url: URL, root: URL) -> Bool {
        guard url.isFileURL else { return false }
        let deposits = root.appendingPathComponent(AttachmentFileVault.depositsFolderName, isDirectory: true).standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(deposits) else { return false }
        return path.dropFirst(deposits.count).contains("/")
    }

    private func discardDeposit(of route: SystemRoute) {
        guard case .attachment(let url) = route else { return }
        AttachmentFileVault.discardDeposit(url, rootDirectory: depositRoot)
    }

    /// Une page ou une app qui ouvre `triva://new` ou `triva://conversation/<UUID>` en rafale ne doit pas ouvrir une
    /// fenêtre par appel ni activer Triva à chaque fois : un appel identique rapproché est ignoré.
    private func isRapidRepeat(_ route: SystemRoute) -> Bool {
        let date = now()
        defer { lastForwarded = (route, date) }
        guard let last = lastForwarded, last.route == route else { return false }
        return date.timeIntervalSince(last.date) < Self.repeatWindow
    }

    private func forward(_ route: SystemRoute, to launcher: ExternalSearchLauncher) {
        switch route {
        case .newQuestion:
            guard !isRapidRepeat(route) else { return }
            launcher.requestNewSearch()
        case .draft(let text):
            // Origine `.draft` EXPLICITE : seul le panneau de la barre des menus a le droit de faire envoyer.
            launcher.requestSearch(question: text, origin: .draft)
        case .conversation(let id):
            // Un identifiant inconnu n'ouvre pas de fenêtre (ni n'active Triva) : rien à montrer.
            guard conversationExists?(id) ?? true, !isRapidRepeat(route) else { return }
            launcher.requestConversation(id)
        case .attachment:
            // L'extension de partage n'existe pas sur Mac (les Services couvrent ce besoin) : un fichier qui
            // arriverait quand même est effacé, jamais ouvert.
            discardDeposit(of: route)
        case .notice:
            // Les informations du partage (texte coupé, fichier non copié) n'ont pas d'objet sur Mac.
            break
        }
    }
}
