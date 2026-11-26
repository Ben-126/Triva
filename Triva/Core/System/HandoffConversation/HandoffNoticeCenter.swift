//
//  HandoffNoticeCenter.swift
//  Triva
//
//  Chantier 2.3 (mission H2) : le message clair quand la discussion n'a pas pu arriver (seul le texte est repris).
//  Un canal à lui : les informations du partage (`SystemNotice`) appartiennent à une autre mission. La fenêtre active le
//  prend UNE fois (`HandoffAdvertiser`) et l'affiche sous la barre de saisie.
//

import Foundation
import Observation

@Observable
@MainActor
final class HandoffNoticeCenter {
    static let shared = HandoffNoticeCenter()

    /// Augmente à chaque message posé : déclencheur des `onChange` des fenêtres.
    private(set) var revision = 0
    @ObservationIgnored private var pending: (message: String, date: Date)?

    /// Un message que personne n'a pris (aucune fenêtre devant) ne reste pas : il n'aurait plus de sens plus tard.
    static let lifetime: TimeInterval = 15

    init() {}

    func post(_ message: String, now: Date = Date()) {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        pending = (message, now)
        revision += 1
    }

    /// Rend le message en attente et l'efface : une seule fenêtre l'affiche.
    func take(now: Date = Date()) -> String? {
        defer { pending = nil }
        guard let pending, now.timeIntervalSince(pending.date) <= Self.lifetime else { return nil }
        return pending.message
    }
}
