//
//  DuoPaneLayout.swift
//  Triva
//
//  Mission I2 (2.0, iPhone Duo déplié).
//

import CoreGraphics
import SwiftUI

/// Combien de volets montrer côte à côte, et la barre latérale doit-elle se masquer, sur un appareil à
/// charnière (iPhone Duo).
///
/// Principe (HIG « Designing for iPhone Duo » : « show an additional level of hierarchy on the larger inner
/// display ») : l'écran intérieur déplié en paysage est assez large pour deux volets, chacun à peu près de la
/// largeur du Duo plié (466 pt, mesure D0). Partout ailleurs (iPhone ordinaire, iPad, Mac, Duo plié, Duo déplié
/// en portrait), rien ne change : la règle exige une charnière, donc ne bouge jamais un appareil qui n'en a pas,
/// même à largeur égale (un iPad 13" en paysage offre 1046 pt et garde une seule colonne).
///
/// Type pur, sans dépendance à une vue : testable aux tailles réelles.
nonisolated enum DuoPaneLayout {
    /// Largeur minimale d'UN volet : deux volets tiennent chacun à peu près dans le Duo plié.
    static let minimumPaneWidth: CGFloat = 340

    /// Espace entre les deux volets (grille d'espacement : 20).
    static let paneSpacing: CGFloat = 20

    /// 1 ou 2 colonnes.
    ///
    /// - Parameters:
    ///   - hasHinge: l'appareil a une charnière (`DeviceHingeContext.hinge != nil`).
    ///   - horizontalSizeClass: `.regular` sur l'écran intérieur, `.compact` sur l'écran extérieur (plié).
    ///   - verticalSizeClass: lue pour mémoire, volontairement ignorée : la classe verticale du paysage déplié
    ///     n'est pas vérifiée sur appareil, et l'exiger rendrait toute la mission invisible si elle valait
    ///     `.compact`.
    ///   - detailWidth: largeur MESURÉE de la zone de contenu (barre latérale déduite si elle est visible).
    static func columnCount(
        hasHinge: Bool,
        horizontalSizeClass: UserInterfaceSizeClass?,
        verticalSizeClass: UserInterfaceSizeClass?,
        detailWidth: CGFloat
    ) -> Int {
        guard hasHinge, horizontalSizeClass == .regular else { return 1 }
        return detailWidth >= 2 * minimumPaneWidth + paneSpacing ? 2 : 1
    }

    /// La barre latérale se masque-t-elle à l'arrivée ? Vrai seulement pour le Duo DÉPLIÉ en paysage : plié
    /// en paysage (678 x 466), la classe de largeur est `compact`, donc exclu ; un iPad ou un Mac n'a pas de
    /// charnière. Appliqué UNE seule fois par la coquille : ensuite le choix de l'utilisateur est respecté.
    static func initialSidebarHidden(
        hasHinge: Bool,
        horizontalSizeClass: UserInterfaceSizeClass?,
        windowWidth: CGFloat,
        windowHeight: CGFloat
    ) -> Bool {
        hasHinge && horizontalSizeClass == .regular && windowWidth > windowHeight
    }
}
