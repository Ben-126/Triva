//
//  InAppBrowser.swift
//  Triva
//
//  Mission C3 (navigateur intégré, demande de Ben).
//

import SwiftUI
#if os(iOS)
import SafariServices
#else
import AppKit
import WebKit
#endif

/// UN point d'entrée pour tous les liens web de l'app : `.opensLinksInApp()`, posé UNE fois sur la
/// racine de chaque fenêtre (`TrivaRootView`, fenêtre Réglages du Mac).
///
/// Il remplace l'action `openURL` de l'environnement, que les feuilles et les fenêtres de
/// présentation héritent. Tout ce qui ouvre un lien — `Link`, lien Markdown d'une réponse, bouton
/// qui appelle `openURL(url)` — passe donc par lui sans changer une ligne de ces vues. Une page
/// `http(s)` s'ouvre dans le navigateur intégré ; le reste (`mailto:`…) revient au système.
///
/// - iPhone, iPad : `SFSafariViewController` (Safari intégré : bloqueurs de contenu, mots de passe,
///   mode lecture, partage) présenté au-dessus de ce qui est affiché, y compris d'une feuille déjà
///   ouverte : une feuille SwiftUI posée sur la racine ne peut pas se présenter par-dessus une
///   autre. Pas de `WKWebView` maison.
/// - Mac : `SFSafariViewController` n'existe pas. Une fenêtre `WebView` (WebKit, SwiftUI) dédiée,
///   à stockage NON persistant (aucun cookie ni historique gardé) et avec un bouton « Ouvrir dans
///   le navigateur » pour retrouver ses réglages de Safari. Une fenêtre plutôt qu'une feuille :
///   une feuille Mac ne peut pas s'ouvrir par-dessus une autre.
extension View {
    func opensLinksInApp() -> some View {
        modifier(OpensLinksInAppModifier())
    }
}

#if os(iOS)

private struct OpensLinksInAppModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.environment(\.openURL, OpenURLAction { url in
            switch LinkRouting.route(for: url) {
            case .inApp:
                BrowserPresenter.present(url) ? .handled : .systemAction
            case .system:
                .systemAction
            }
        })
    }
}

/// Présente Safari au-dessus de l'écran visible. Isolé au main actor (UIKit).
enum BrowserPresenter {
    /// Faux si rien ne peut recevoir la présentation : l'appelant laisse alors faire le système.
    @discardableResult
    static func present(_ url: URL) -> Bool {
        guard let top = topViewController() else { return false }
        // Déjà dans le navigateur : ses propres liens sont gérés par lui.
        guard !(top is SFSafariViewController) else { return false }
        let configuration = SFSafariViewController.Configuration()
        configuration.entersReaderIfAvailable = false
        let controller = SFSafariViewController(url: url, configuration: configuration)
        controller.dismissButtonStyle = .close
        // Explicite : sur iPad, présenter depuis une bulle (popover) sans style propre resterait
        // enfermé dans la bulle.
        controller.modalPresentationStyle = .pageSheet
        top.present(controller, animated: true)
        return true
    }

    /// Ferme Safari intégré s'il est affiché au-dessus de la scène active (une route du système doit être visible).
    static func dismissPresented() {
        guard let top = topViewController(), top is SFSafariViewController else { return }
        top.presentingViewController?.dismiss(animated: true)
    }

    /// Contrôleur le plus haut de la scène active (feuilles, plein écran et bulles comprises).
    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        var top = scene?.keyWindow?.rootViewController ?? scene?.windows.first?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }
}

#else

private struct OpensLinksInAppModifier: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.environment(\.openURL, OpenURLAction { url in
            switch LinkRouting.route(for: url) {
            case .inApp:
                openWindow(value: url)
                return .handled
            case .system:
                return .systemAction
            }
        })
    }
}

/// Contenu de la fenêtre du navigateur intégré du Mac (`TrivaApp` : `WindowGroup(for: URL.self)`).
/// La fenêtre se ferme par son bouton ou ⌘W.
struct MacBrowserWindowContent: View {
    let url: URL

    @State private var page: WebPage

    init(url: URL) {
        self.url = url
        var configuration = WebPage.Configuration()
        // Rien n'est gardé après la fermeture : ni cookies, ni historique, ni cache.
        configuration.websiteDataStore = .nonPersistent()
        _page = State(initialValue: WebPage(configuration: configuration))
    }

    var body: some View {
        WebView(page)
            .navigationTitle(page.title.isEmpty ? (url.host(percentEncoded: false) ?? "") : page.title)
            .toolbar { toolbarContent }
            .frame(minWidth: 640, minHeight: 480)
            .task { _ = page.load(URLRequest(url: url)) }
            .accessibilityIdentifier("browser.window")
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button {
                if let item = page.backForwardList.backList.last { _ = page.load(item) }
            } label: {
                Label("Précédent", systemImage: "chevron.backward")
            }
            .disabled(page.backForwardList.backList.isEmpty)
            .accessibilityIdentifier("browser.back")
            Button {
                if let item = page.backForwardList.forwardList.first { _ = page.load(item) }
            } label: {
                Label("Suivant", systemImage: "chevron.forward")
            }
            .disabled(page.backForwardList.forwardList.isEmpty)
            .accessibilityIdentifier("browser.forward")
        }
        ToolbarItem(placement: .primaryAction) {
            if page.isLoading {
                ProgressView().controlSize(.small)
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                NSWorkspace.shared.open(page.url ?? url)
            } label: {
                Label("Ouvrir dans le navigateur", systemImage: "safari")
            }
            .help("Ouvrir dans le navigateur")
            .accessibilityIdentifier("browser.openExternally")
        }
    }
}

#endif
