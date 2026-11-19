//
//  EmbeddedBrowserDataClearer.swift
//  Triva
//
//  Mission T1 (2026-11-19) : « Tout effacer » ne doit jamais rester bloqué sur le navigateur intégré.
//

import Foundation
import OSLog
import Synchronization
#if os(iOS)
import SafariServices
#endif

/// Résultat d'un vidage du navigateur intégré.
nonisolated enum EmbeddedBrowserClearOutcome: Sendable, Equatable {
    case completed
    /// Le service de Safari n'a jamais répondu dans le délai : l'effacement continue sans l'attendre.
    case timedOut
}

/// Vide les données du navigateur intégré (iPhone, iPad) en un seul vidage à la fois, avec un délai maximal.
///
/// Pourquoi (mesuré le 2026-11-19 sur simulateur iPhone, `SFSafariViewController.DataStore.clearWebsiteData()`) :
/// - chaque appel ouvre une session vers `SafariViewService` ; des appels SIMULTANÉS s'invalident
///   entre eux (« View service session ended with error … Invalidation requested ») et leur
///   `await` ne reprend jamais. Les suites de tests Swift Testing, qui tournent en parallèle, se
///   figeaient ainsi. Les appels qui arrivent pendant un vidage en cours attendent donc CE vidage.
/// - si le service ne répond jamais, « Tout effacer » resterait bloqué à l'écran : au bout du délai on
///   continue (l'échec est journalisé, jamais avalé en silence).
@MainActor
final class EmbeddedBrowserDataClearer {
    /// Utilisé par `LocalDataEraser` ; le vidage réel de Safari sur iPhone/iPad, rien sur Mac (la fenêtre
    /// `WebView` du Mac n'a pas de stockage persistant, voir `InAppBrowser.swift`).
    static let shared = EmbeddedBrowserDataClearer(timeout: .seconds(10), operation: EmbeddedBrowserDataClearer.clearSafariData)

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Triva",
        category: "EmbeddedBrowserDataClearer"
    )

    private let timeout: Duration
    private let operation: @MainActor () async -> Void
    private var inFlight: Task<EmbeddedBrowserClearOutcome, Never>?

    init(timeout: Duration, operation: @escaping @MainActor () async -> Void) {
        self.timeout = timeout
        self.operation = operation
    }

    /// Vide, ou rejoint le vidage déjà en cours. Ne bloque jamais plus longtemps que le délai.
    @discardableResult
    func clear() async -> EmbeddedBrowserClearOutcome {
        if let inFlight {
            return await inFlight.value
        }
        let task = Task { await self.runWithTimeout() }
        inFlight = task
        let outcome = await task.value
        inFlight = nil
        if outcome == .timedOut {
            Self.logger.error("Navigateur intégré : pas de réponse de Safari en \(self.timeout.description, privacy: .public), effacement poursuivi")
        }
        return outcome
    }

    /// Course entre l'opération et le délai ; le premier qui finit reprend l'attente. Pas de `TaskGroup` :
    /// il attendrait aussi l'opération bloquée, qui ne réagit pas à l'annulation.
    private func runWithTimeout() async -> EmbeddedBrowserClearOutcome {
        let operation = operation
        let timeout = timeout
        return await withCheckedContinuation { continuation in
            let race = OneShotResume(continuation)
            Task {
                await operation()
                race.resume(with: .completed)
            }
            Task {
                try? await Task.sleep(for: timeout)
                race.resume(with: .timedOut)
            }
        }
    }

    @MainActor
    private static func clearSafariData() async {
        #if os(iOS)
        await SFSafariViewController.DataStore.default.clearWebsiteData()
        #endif
    }
}

/// Reprend une continuation une seule fois, quel que soit le nombre d'appelants.
private nonisolated final class OneShotResume: Sendable {
    private let continuation: Mutex<CheckedContinuation<EmbeddedBrowserClearOutcome, Never>?>

    init(_ continuation: CheckedContinuation<EmbeddedBrowserClearOutcome, Never>) {
        self.continuation = Mutex(continuation)
    }

    func resume(with outcome: EmbeddedBrowserClearOutcome) {
        let pending = continuation.withLock { current in
            defer { current = nil }
            return current
        }
        pending?.resume(returning: outcome)
    }
}
