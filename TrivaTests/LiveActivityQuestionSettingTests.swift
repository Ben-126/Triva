//
//  LiveActivityQuestionSettingTests.swift
//  TrivaTests
//
//  Chantier 2.1 (mission I, décision de Ben du 25/11) : le réglage « Afficher la question » de l'activité en direct :
//  son défaut, sa clé, et l'écoute des réglages qui aligne tout de suite les activités (question retirée de l'écran
//  verrouillé, de la Dynamic Island et de la montre, activité en cours comprise).
//

import Foundation
import Testing
@testable import Triva

@MainActor
private final class RefreshCounter {
    var value = 0
}

@MainActor
@Suite("Activité en direct : « Afficher la question »")
struct LiveActivityQuestionSettingTests {
    private let defaults: UserDefaults
    private let suiteName = "LiveActivityQuestionSettingTests-\(UUID().uuidString)"
    private let refreshes = RefreshCounter()

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
    }

    private var preferences: SystemIntegrationPreferences { SystemIntegrationPreferences(defaults: defaults) }

    private func makeIntegrations() -> SystemIntegrations {
        let refreshes = refreshes
        return SystemIntegrations(
            spotlightClient: FakeSpotlightClient(),
            spotlightDelay: .zero,
            endLiveActivities: {},
            endOrphanedLiveActivities: { _ in },
            refreshLiveActivityQuestion: { refreshes.value += 1 },
            routes: SystemRouteCenter(windowLauncher: nil),
            defaults: defaults,
            isMac: true
        )
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<150 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test("Par défaut, la question est montrée (décision de Ben, 25/11)")
    func defaultIsOn() {
        #expect(preferences.showsQuestionInLiveActivity)
        #expect(SystemIntegrationPreferences.liveActivityQuestionDefault)
    }

    @Test("Le réglage s'écrit et se relit, sans toucher à l'activité en direct elle-même")
    func independentFromTheLiveActivitySetting() {
        preferences.showsQuestionInLiveActivity = false
        #expect(!preferences.showsQuestionInLiveActivity)
        #expect(preferences.isLiveActivityEnabled)
        #expect(defaults.object(forKey: "system.liveActivity.showsQuestion") as? Bool == false)
    }

    @Test("Une valeur d'un autre type ne vaut pas « faux » : retour au défaut (question montrée)")
    func wrongTypeFallsBackToDefault() {
        defaults.set("non", forKey: SystemIntegrationPreferences.liveActivityQuestionKey)
        #expect(preferences.showsQuestionInLiveActivity)
    }

    @Test("Basculer le réglage depuis n'importe quel écran aligne les activités, dans les deux sens")
    func observedChangeRefreshesActivities() async throws {
        let integrations = makeIntegrations()
        integrations.start()
        try await Task.sleep(for: .milliseconds(100))
        let baseline = refreshes.value

        preferences.showsQuestionInLiveActivity = false
        try await waitUntil { refreshes.value > baseline }
        #expect(refreshes.value == baseline + 1)

        preferences.showsQuestionInLiveActivity = true
        try await waitUntil { refreshes.value > baseline + 1 }
        #expect(refreshes.value == baseline + 2)
    }

    @Test("Un autre réglage qui change n'aligne pas les activités")
    func otherSettingsDoNotRefresh() async throws {
        let integrations = makeIntegrations()
        integrations.start()
        try await Task.sleep(for: .milliseconds(100))
        let baseline = refreshes.value

        preferences.isLiveActivityEnabled = false
        preferences.isSpotlightEnabled = false
        try await Task.sleep(for: .milliseconds(150))

        #expect(refreshes.value == baseline)
    }

    @Test("La bascule explicite (écran des Réglages) aligne aussi les activités")
    func explicitChangeRefreshesActivities() async throws {
        let integrations = makeIntegrations()
        preferences.showsQuestionInLiveActivity = false
        integrations.preferencesDidChange()
        try await waitUntil { refreshes.value >= 1 }
        #expect(refreshes.value == 1)
    }
}
