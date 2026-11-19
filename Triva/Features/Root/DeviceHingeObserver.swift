//
//  DeviceHingeObserver.swift
//  Triva
//
//  Mission I2 (2.0, iPhone Duo déplié).
//

#if DEBUG
import OSLog
#endif
import SwiftUI

extension EnvironmentValues {
    /// L'appareil a une charnière (iPhone Duo). Faux par défaut, et toujours faux sur iPad, Mac et iPhone
    /// ordinaire : voir `View.observesDeviceHinge(_:)`. Les aperçus le forcent à vrai.
    @Entry var trivaHasHinge: Bool = false
}

extension View {
    /// Tient `hasHinge` à jour : vrai tant que le système fournit une charnière (`DeviceHingeContext.hinge`).
    ///
    /// `onHingeChange` est `anyAppleOS 27.1` (le projet cible 27.0) : sous 27.1 il n'y a rien à observer, la
    /// valeur reste fausse et l'app se comporte exactement comme avant. Sur Mac et iPad, le contexte n'a pas de
    /// charnière : la valeur reste fausse.
    ///
    /// NON VÉRIFIÉ sur appareil déplié : la doc ne dit pas si l'action est appelée dès l'apparition de la vue
    /// (la signature n'a pas de paramètre `initial:`). Le journal debug (catégorie `DeviceHinge`) permet de le
    /// constater ; voir le rapport de la mission I2.
    @ViewBuilder
    func observesDeviceHinge(_ hasHinge: Binding<Bool>) -> some View {
        if #available(iOS 27.1, macOS 27.1, *) {
            onHingeChange { _, newContext in
                let newValue = newContext.hinge != nil
                #if DEBUG
                DeviceHingeLog.logger.debug("Charnière : \(newValue, privacy: .public)")
                #endif
                if hasHinge.wrappedValue != newValue { hasHinge.wrappedValue = newValue }
            }
        } else {
            self
        }
    }
}

#if DEBUG
/// Journal de vérification, compilé seulement en DEBUG (revue R1, M4).
private enum DeviceHingeLog {
    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Triva", category: "DeviceHinge")
}
#endif
