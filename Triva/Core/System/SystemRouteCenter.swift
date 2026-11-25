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
    /// Routes en attente au plus : si personne ne les prend, la file ne grossit pas.
    static let maxPending = 8

    /// Exemplaire de l'app. Les tests construisent le leur.
    static let shared = SystemRouteCenter(windowLauncher: platformWindowLauncher)

    /// Augmente à chaque dépôt (jamais à la lecture) : déclencheur des `onChange` des fenêtres.
    private(set) var revision = 0

    @ObservationIgnored private var pending: [SystemRoute] = []
    @ObservationIgnored private let windowLauncher: ExternalSearchLauncher?
    /// Racine du coffre de pièces jointes : un fichier partagé n'est accepté que dans `<racine>/_deposits/`.
    @ObservationIgnored private let depositRoot: URL

    init(windowLauncher: ExternalSearchLauncher?, depositRoot: URL = AttachmentFileVault.defaultRootDirectory) {
        self.windowLauncher = windowLauncher
        self.depositRoot = depositRoot
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
    func submit(_ route: SystemRoute) {
        guard let route = sanitized(route) else { return }
        if let windowLauncher {
            forward(route, to: windowLauncher)
            return
        }
        pending.append(route)
        if pending.count > Self.maxPending {
            // Une route fichier évincée emporte son dépôt : rien ne doit traîner.
            let evicted = pending.prefix(pending.count - Self.maxPending)
            evicted.forEach(discardDeposit(of:))
            pending.removeFirst(evicted.count)
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
        let routes = pending
        pending.removeAll()
        return routes
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
        case .newQuestion, .conversation:
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

    private func forward(_ route: SystemRoute, to launcher: ExternalSearchLauncher) {
        switch route {
        case .newQuestion:
            launcher.requestNewSearch()
        case .draft(let text):
            // Origine `.draft` EXPLICITE : seul le panneau de la barre des menus a le droit de faire envoyer.
            launcher.requestSearch(question: text, origin: .draft)
        case .conversation(let id):
            launcher.requestConversation(id)
        case .attachment:
            // L'extension de partage n'existe pas sur Mac (les Services couvrent ce besoin) : un fichier qui
            // arriverait quand même est effacé, jamais ouvert.
            discardDeposit(of: route)
        }
    }
}
