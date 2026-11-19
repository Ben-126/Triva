//
//  TrivaServicesProvider.swift
//  Triva
//
//  Chantier 2.2 (M7) : Service du Mac « Rechercher avec Triva ».
//

#if os(macOS)
import AppKit

/// Reçoit le texte sélectionné dans une autre app (clic droit > Services > Rechercher avec Triva).
///
/// Déclaré dans `Config/Triva-macOS-Info.plist` (`NSServices`, `NSMessage = searchWithTriva`) et installé par
/// `NSApp.servicesProvider` (`TrivaMacAppDelegate`). Le texte est une entrée EXTERNE : il est assaini avant tout
/// usage, puis ouvre une fenêtre de recherche dont le champ est pré-rempli, sans envoi.
final class TrivaServicesProvider: NSObject {
    /// Sélecteur Objective-C que `NSMessage` désigne : si le nom change ici, le plist doit changer aussi (un test
    /// le vérifie).
    static let serviceSelector = Selector(("searchWithTriva:userData:error:"))

    private let launcher: ExternalSearchLauncher

    init(launcher: ExternalSearchLauncher = .shared) {
        self.launcher = launcher
        super.init()
    }

    /// Point d'entrée appelé par le système, sur le fil principal.
    @objc func searchWithTriva(
        _ pboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        if let message = deliver(text: pboard.string(forType: .string)) {
            error.pointee = message as NSString
        }
    }

    /// Cœur testable : rend le message d'erreur à afficher, ou `nil` si une recherche va s'ouvrir.
    func deliver(text: String?) -> String? {
        guard launcher.requestSearch(question: text) else {
            return ExternalSearchLauncher.noTextMessage
        }
        return nil
    }
}
#endif
