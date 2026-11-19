//
//  TrivaMacAppDelegate.swift
//  Triva
//
//  Chantier 2.2 (M7) : délégué AppKit du Mac, pour ce que SwiftUI ne couvre pas (Services, menu du Dock).
//

#if os(macOS)
import AppKit

/// Branché par `@NSApplicationDelegateAdaptor` dans `TrivaApp`. Trois rôles seulement :
/// - installer le fournisseur de Services (`TrivaServicesProvider`) ;
/// - donner son menu au Dock (clic droit sur l'icône) : « Nouvelle recherche » ;
/// - effacer les copies temporaires de pièces jointes à la sortie de l'app (⌘Q : les fenêtres ne sont pas fermées une
///   à une, leurs coffres ne se vident donc pas d'eux-mêmes).
final class TrivaMacAppDelegate: NSObject, NSApplicationDelegate {
    /// Titre de l'entrée du menu du Dock ; même libellé que Fichier > Nouvelle recherche.
    static let dockNewSearchTitle = "Nouvelle recherche"

    private let launcher: ExternalSearchLauncher
    private let servicesProvider: TrivaServicesProvider
    /// Dossier des copies temporaires à effacer à la sortie ; `nil` : rien à effacer (app qui héberge les tests
    /// unitaires, dont le dossier temporaire est celui de la vraie app).
    private let attachmentVaultRoot: URL?

    init(launcher: ExternalSearchLauncher, attachmentVaultRoot: URL? = AttachmentFileVault.defaultRootDirectory) {
        self.launcher = launcher
        self.attachmentVaultRoot = attachmentVaultRoot
        self.servicesProvider = TrivaServicesProvider(launcher: launcher)
        super.init()
    }

    /// Initialiseur que demande `@NSApplicationDelegateAdaptor`.
    override convenience init() {
        self.init(
            launcher: .shared,
            attachmentVaultRoot: TrivaTestHost.isHostingUnitTests() ? nil : AttachmentFileVault.defaultRootDirectory
        )
    }

    /// Dès « will » et non « did » : quand le système lance Triva pour un Service, il envoie la demande aussitôt
    /// l'app prête.
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = servicesProvider
    }

    /// Documents de l'utilisateur copiés dans `tmp` (Coup d'œil, glisser-déposer) : rien ne doit y survivre à la sortie.
    func applicationWillTerminate(_ notification: Notification) {
        guard let attachmentVaultRoot else { return }
        AttachmentFileVault.purgeAll(rootDirectory: attachmentVaultRoot)
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        makeDockMenu()
    }

    /// Menu du Dock, séparé du protocole pour être testé.
    func makeDockMenu() -> NSMenu {
        let menu = NSMenu()
        let item = NSMenuItem(
            title: Self.dockNewSearchTitle,
            action: #selector(newSearchFromDock),
            keyEquivalent: ""
        )
        item.target = self
        menu.addItem(item)
        return menu
    }

    @objc func newSearchFromDock() {
        launcher.requestNewSearch()
        NSApp.activate()
    }
}
#endif
