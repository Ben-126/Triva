//
//  HandoffWindowPlacement.swift
//  Triva
//
//  Chantier 2.3 (mission H2) : où s'ouvre la discussion reçue sur Mac. Dans la fenêtre au premier plan si elle est vide ;
//  sinon une nouvelle fenêtre (le lanceur de fenêtres, `SystemRouteCenter`). Chaque fenêtre dit si elle est devant et
//  vide, et sait appliquer des routes ; ce registre n'en choisit qu'une.
//

import Foundation

@MainActor
final class HandoffWindowPlacement {
    static let shared = HandoffWindowPlacement()

    private struct Entry {
        let isForeground: @MainActor () -> Bool
        let isEmpty: @MainActor () -> Bool
        let apply: @MainActor ([SystemRoute]) -> Void
    }

    private var windows: [UUID: Entry] = [:]

    init() {}

    func register(
        window: UUID,
        isForeground: @escaping @MainActor () -> Bool,
        isEmpty: @escaping @MainActor () -> Bool,
        apply: @escaping @MainActor ([SystemRoute]) -> Void
    ) {
        windows[window] = Entry(isForeground: isForeground, isEmpty: isEmpty, apply: apply)
    }

    func unregister(window: UUID) {
        windows[window] = nil
    }

    /// - Returns: `true` si une fenêtre au premier plan ET vide a pris les routes ; `false` : l'appelant ouvre une nouvelle fenêtre.
    func placeInForegroundEmptyWindow(_ routes: [SystemRoute]) -> Bool {
        guard let entry = windows.values.first(where: { $0.isForeground() && $0.isEmpty() }) else { return false }
        entry.apply(routes)
        return true
    }
}

/// Une même activité Handoff livrée deux fois de suite (SwiftUI peut la remettre à deux fenêtres) n'est traitée qu'une fois :
/// les flux ne se demandent qu'une fois, et « copie si la fenêtre la tient » ne serait pas idempotente.
nonisolated struct HandoffDuplicateGuard {
    private let window: TimeInterval
    private var last: (key: String, date: Date)?

    init(window: TimeInterval) {
        self.window = window
    }

    mutating func shouldHandle(key: String, now: Date) -> Bool {
        defer { last = (key, now) }
        guard let last, last.key == key else { return true }
        return now.timeIntervalSince(last.date) >= window
    }
}
