//
//  HandoffPlacementTests.swift
//  TrivaTests
//
//  Chantier 2.3 (mission H2) : où s'ouvre la discussion reçue. Mac : dans la fenêtre au premier plan si elle est vide,
//  sinon dans une nouvelle fenêtre. Et : une même activité livrée deux fois n'est traitée qu'une fois.
//

import Foundation
import Testing
@testable import Triva

@MainActor
@Suite("Handoff conversation : placement")
struct HandoffPlacementTests {
    private let routes: [SystemRoute] = [.conversation(HandoffFixtures.conversationID)]

    private final class Window {
        var foreground: Bool
        var empty: Bool
        var applied: [[SystemRoute]] = []
        init(foreground: Bool, empty: Bool) { self.foreground = foreground; self.empty = empty }
    }

    private func register(_ window: Window, in placement: HandoffWindowPlacement) -> UUID {
        let id = UUID()
        placement.register(
            window: id,
            isForeground: { window.foreground },
            isEmpty: { window.empty },
            apply: { window.applied.append($0) }
        )
        return id
    }

    @Test("Fenêtre au premier plan ET vide : la discussion s'y ouvre")
    func foregroundEmptyWindowTakesIt() {
        let placement = HandoffWindowPlacement()
        let window = Window(foreground: true, empty: true)
        _ = register(window, in: placement)
        #expect(placement.placeInForegroundEmptyWindow(routes))
        #expect(window.applied == [routes])
    }

    @Test("Fenêtre au premier plan mais déjà occupée : pas de remplacement (nouvelle fenêtre)")
    func busyForegroundWindowIsLeftAlone() {
        let placement = HandoffWindowPlacement()
        let window = Window(foreground: true, empty: false)
        _ = register(window, in: placement)
        #expect(!placement.placeInForegroundEmptyWindow(routes))
        #expect(window.applied.isEmpty)
    }

    @Test("Fenêtre vide mais à l'arrière-plan : elle n'est pas prise")
    func backgroundEmptyWindowIsLeftAlone() {
        let placement = HandoffWindowPlacement()
        let window = Window(foreground: false, empty: true)
        _ = register(window, in: placement)
        #expect(!placement.placeInForegroundEmptyWindow(routes))
        #expect(window.applied.isEmpty)
    }

    @Test("Plusieurs fenêtres : seule celle qui est devant et vide est prise, une seule fois")
    func onlyOneWindowTakesIt() {
        let placement = HandoffWindowPlacement()
        let back = Window(foreground: false, empty: true)
        let front = Window(foreground: true, empty: true)
        let other = Window(foreground: true, empty: true)
        _ = register(back, in: placement)
        _ = register(front, in: placement)
        _ = register(other, in: placement)
        #expect(placement.placeInForegroundEmptyWindow(routes))
        #expect(back.applied.isEmpty)
        #expect(front.applied.count + other.applied.count == 1)
    }

    @Test("Fenêtre fermée : retirée du registre")
    func unregistered() {
        let placement = HandoffWindowPlacement()
        let window = Window(foreground: true, empty: true)
        let id = register(window, in: placement)
        placement.unregister(window: id)
        #expect(!placement.placeInForegroundEmptyWindow(routes))
    }

    @Test("Aucune fenêtre connue : rien n'est pris, l'appelant ouvre une nouvelle fenêtre")
    func noWindow() {
        #expect(!HandoffWindowPlacement().placeInForegroundEmptyWindow(routes))
    }
}

@Suite("Handoff conversation : doublons")
struct HandoffDuplicateGuardTests {
    @Test("La même activité livrée deux fois de suite n'est traitée qu'une fois")
    func rapidRepeatIsIgnored() {
        var guardian = HandoffDuplicateGuard(window: 3)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let first = guardian.shouldHandle(key: "a", now: start)
        let second = guardian.shouldHandle(key: "a", now: start.addingTimeInterval(1))
        #expect(first)
        #expect(!second)
    }

    @Test("Une autre activité, ou la même bien plus tard, est traitée")
    func differentOrLaterIsHandled() {
        var guardian = HandoffDuplicateGuard(window: 3)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let first = guardian.shouldHandle(key: "a", now: start)
        let other = guardian.shouldHandle(key: "b", now: start.addingTimeInterval(1))
        let later = guardian.shouldHandle(key: "b", now: start.addingTimeInterval(10))
        #expect(first)
        #expect(other)
        #expect(later)
    }
}
