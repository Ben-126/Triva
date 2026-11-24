//
//  SystemRouteDispatcher.swift
//  TrivaShared
//
//  Chantier 2.1 (mission A) : pont entre les intents et le routeur de l'app. Les intents (`OpenComposerIntent`)
//  sont compilés aussi dans l'extension Widgets, qui ne voit aucun type de l'app : ils déposent leur route ici, et
//  l'app y branche son routeur au lancement (`TrivaApp.init`).
//
//  Lancement à froid : l'intent peut s'exécuter AVANT ce branchement. La route attend alors dans une petite
//  mémoire (8 au plus, les plus anciennes sont oubliées) et part dès que le routeur est branché.
//

import Foundation

@MainActor
final class SystemRouteDispatcher {
    /// Routes gardées au plus tant qu'aucun routeur n'est branché.
    static let bufferCapacity = 8

    /// Exemplaire de l'app. Les tests construisent le leur.
    static let shared = SystemRouteDispatcher()

    private var handler: (@MainActor (SystemRoute) -> Void)?
    private var buffered: [SystemRoute] = []

    init() {}

    /// Nombre de routes qui attendent le routeur.
    var bufferedCount: Int { buffered.count }

    /// Remet la route au routeur, ou la garde jusqu'à son branchement.
    func submit(_ route: SystemRoute) {
        if let handler {
            handler(route)
            return
        }
        buffered.append(route)
        if buffered.count > Self.bufferCapacity {
            buffered.removeFirst(buffered.count - Self.bufferCapacity)
        }
    }

    /// Branche le routeur et lui livre, dans l'ordre, ce qui attendait.
    func install(_ handler: @escaping @MainActor (SystemRoute) -> Void) {
        self.handler = handler
        let waiting = buffered
        buffered = []
        for route in waiting { handler(route) }
    }
}
