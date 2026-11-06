//
//  DiscoverCacheTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 04/11/2026.
//

import Foundation
import Testing
@testable import Triva

// MARK: - Outils

private enum Offline: Error { case offline }

@MainActor
private func article(_ topic: DiscoverTopic, _ url: String, title: String = "Titre") -> DiscoverArticle {
    DiscoverArticle(topic: topic, title: title, url: url, snippet: "Extrait", imageURL: URL(string: "https://img.example/a.jpg"))
}

@MainActor
private func section(_ topic: DiscoverTopic, _ url: String) -> DiscoverTopicSection {
    DiscoverTopicSection(topic: topic, articles: [article(topic, url)])
}

/// Cache en mémoire : garde ce qu'on lui donne, compte les écritures.
private actor MemoryCache: DiscoverContentCaching {
    private var snapshot: DiscoverCacheSnapshot?
    private(set) var saveCount = 0

    init(_ snapshot: DiscoverCacheSnapshot? = nil) {
        self.snapshot = snapshot
    }

    var current: DiscoverCacheSnapshot? { snapshot }

    func load() async -> DiscoverCacheSnapshot? { snapshot }

    func save(_ snapshot: DiscoverCacheSnapshot) async {
        self.snapshot = snapshot
        saveCount += 1
    }
}

/// Retient le chargement jusqu'à `release`, pour regarder l'état PENDANT.
@MainActor
private final class HeldSource {
    private var continuation: CheckedContinuation<Result<DiscoverContent, any Error>, Never>?
    private(set) var onTopicFinished: DiscoverViewModel.TopicHandler?
    private(set) var callCount = 0

    var isHolding: Bool { continuation != nil }

    func load(_ handler: @escaping DiscoverViewModel.TopicHandler) async throws -> DiscoverContent {
        callCount += 1
        onTopicFinished = handler
        let result = await withCheckedContinuation { continuation = $0 }
        return try result.get()
    }

    func release(_ result: Result<DiscoverContent, any Error>) {
        continuation?.resume(returning: result)
        continuation = nil
    }
}

@MainActor
private func waitUntil(_ message: String, _ condition: () -> Bool) async {
    for _ in 0..<500 {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(1))
    }
    Issue.record("Timeout : \(message)")
}

private let oldDate = Date(timeIntervalSince1970: 1_000_000)
private let laterDate = oldDate.addingTimeInterval(3 * 3_600)

private func cachedSection(_ topic: String, _ url: String, at date: Date = oldDate) -> DiscoverCacheSnapshot.Section {
    DiscoverCacheSnapshot.Section(
        topic: topic,
        fetchedAt: date,
        articles: [.init(title: "Ancien \(topic)", url: url, snippet: nil, imageURL: nil)]
    )
}

// MARK: - Cache disque

@Suite("DiscoverDiskCache")
struct DiscoverDiskCacheTests {
    private func temporaryFile() -> URL {
        URL.temporaryDirectory.appending(path: "discover-test-\(UUID().uuidString).json")
    }

    private let snapshot = DiscoverCacheSnapshot(sections: [
        DiscoverCacheSnapshot.Section(
            topic: "tech",
            fetchedAt: Date(timeIntervalSince1970: 1_000),
            articles: [.init(title: "Titre", url: "https://a.example", snippet: "Extrait", imageURL: "https://img.example/a.jpg")]
        ),
    ])

    @Test("ce qui est écrit se relit à l'identique")
    func roundTrip() async {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let cache = DiscoverDiskCache(fileURL: file)

        await cache.save(snapshot)

        #expect(await cache.load() == snapshot)
    }

    @Test("fichier absent : aucun cache, aucune erreur")
    func missingFile() async {
        #expect(await DiscoverDiskCache(fileURL: temporaryFile()).load() == nil)
    }

    @Test(
        "fichier abîmé : ignoré sans planter",
        arguments: ["", "pas du json", "{\"version\":1}", "{\"version\":1,\"sections\":[{\"topic\":3}]}"]
    )
    func corruptFile(contents: String) async throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(contents.utf8).write(to: file)

        #expect(await DiscoverDiskCache(fileURL: file).load() == nil)
    }

    @Test("autre version du format : ignorée")
    func otherVersion() async throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }
        try JSONEncoder().encode(DiscoverCacheSnapshot(version: 99, sections: snapshot.sections)).write(to: file)

        #expect(await DiscoverDiskCache(fileURL: file).load() == nil)
    }

    @Test("dossier impossible à écrire : pas de plantage")
    func unwritableLocation() async {
        let file = URL(filePath: "/nonexistent-\(UUID().uuidString)/discover.json")
        await DiscoverDiskCache(fileURL: file).save(snapshot)
        #expect(await DiscoverDiskCache(fileURL: file).load() == nil)
    }
}

// MARK: - Cache et modèle

@MainActor
@Suite("DiscoverViewModel — cache")
struct DiscoverViewModelCacheTests {
    @Test("les articles de la dernière visite s'affichent avant toute réponse du réseau")
    func cachedArticlesAppearBeforeNetwork() async {
        let cache = MemoryCache(DiscoverCacheSnapshot(sections: [cachedSection("tech", "https://ancien.example/a")]))
        let source = HeldSource()
        let model = DiscoverViewModel(cache: cache, now: { laterDate }, loadContent: source.load)

        let load = Task { await model.loadIfNeeded() }
        await waitUntil("réseau en attente") { source.isHolding }

        guard case .loaded(let shown) = model.phase else {
            Issue.record("pas de contenu restauré : \(model.phase)")
            source.release(.success(.empty))
            await load.value
            return
        }
        #expect(shown.sections.map(\.topic) == [.tech])
        #expect(model.isUpdatingRestoredContent)
        #expect(model.pendingTopics.isEmpty)
        #expect(model.staleNotice(calendar: .current) == nil, "aucun avertissement tant que la mise à jour n'a pas échoué")

        let fresh = DiscoverContent(sections: [section(.tech, "https://neuf.example/a")], failedTopics: [])
        source.release(.success(fresh))
        await load.value

        #expect(model.phase == .loaded(fresh))
        #expect(!model.isUpdatingRestoredContent)
        #expect(!model.isLoading)
        #expect(model.sectionDates[.tech] == laterDate)
        let saved = await cache.current
        #expect(saved?.sections.first?.articles.first?.url == "https://neuf.example/a")
    }

    @Test("le cache n'est lu qu'avant le tout premier chargement")
    func refreshDoesNotReadTheCacheAgain() async {
        let cache = MemoryCache()
        let contentA = DiscoverContent(sections: [section(.tech, "https://a.example/a")], failedTopics: [])
        let contentB = DiscoverContent(sections: [section(.art, "https://b.example/a")], failedTopics: [])
        var outcomes = [contentA, contentB]
        let model = DiscoverViewModel(cache: cache, loadContent: { _ in outcomes.removeFirst() })

        await model.loadIfNeeded()
        await model.refresh()

        #expect(model.phase == .loaded(contentB))
        #expect(await cache.saveCount == 2)
    }

    @Test("mise à jour impossible : anciens articles, message honnête avec leur âge, cache intact")
    func offlineKeepsRestoredArticles() async {
        let original = DiscoverCacheSnapshot(sections: [cachedSection("tech", "https://ancien.example/a")])
        let cache = MemoryCache(original)
        let model = DiscoverViewModel(
            cache: cache,
            now: { laterDate },
            loadContent: { _ in DiscoverContent(sections: [], failedTopics: DiscoverTopic.allCases) }
        )

        await model.loadIfNeeded()

        guard case .loaded(let shown) = model.phase else {
            Issue.record("les articles ont disparu : \(model.phase)")
            return
        }
        #expect(shown.sections.map(\.topic) == [.tech])
        #expect(model.refreshDidFail)
        let notice = model.staleNotice(calendar: .current)
        #expect(notice?.hasPrefix("Actualisation impossible.") == true)
        #expect(notice?.contains("il\u{00A0}y\u{00A0}a\u{00A0}3\u{00A0}heures") == true, "\(notice ?? "nil")")
        #expect(await cache.saveCount == 0)
        #expect(await cache.current == original)
        #expect(model.completionAnnouncement == "Actualisation impossible")
    }

    @Test("un sujet en échec garde ses anciens articles et sa date, les autres sont neufs")
    func partialFailureKeepsOnlyFailedTopics() async {
        let cache = MemoryCache(DiscoverCacheSnapshot(sections: [
            cachedSection("tech", "https://ancien.example/tech"),
            cachedSection("finance", "https://ancien.example/finance"),
        ]))
        let model = DiscoverViewModel(cache: cache, now: { laterDate }, loadContent: { _ in
            DiscoverContent(sections: [section(.tech, "https://neuf.example/tech")], failedTopics: [.finance, .sports])
        })

        await model.loadIfNeeded()

        guard case .loaded(let shown) = model.phase else {
            Issue.record("pas de contenu : \(model.phase)")
            return
        }
        #expect(shown.sections.map(\.topic) == [.tech, .finance])
        #expect(shown.sections[0].articles[0].url == "https://neuf.example/tech")
        #expect(shown.sections[1].articles[0].url == "https://ancien.example/finance")
        #expect(shown.failedTopics == [.sports])
        #expect(model.staleTopics == [.finance])
        #expect(model.sectionDates[.tech] == laterDate)
        #expect(model.sectionDates[.finance] == oldDate)
        #expect(!model.refreshDidFail)
        let notice = model.staleNotice(calendar: .current)
        #expect(notice?.hasPrefix("Finance n'a pas pu être actualisé.") == true, "\(notice ?? "nil")")

        let saved = await cache.current
        #expect(saved?.sections.first { $0.topic == "finance" }?.fetchedAt == oldDate, "la date ancienne reste vraie au lancement suivant")
    }

    /// Un fichier sur disque est une donnée externe, comme une réponse d'instance.
    @Test("un article restauré au lien dangereux n'est jamais affiché")
    func restoredContentIsSanitized() async {
        let cache = MemoryCache(DiscoverCacheSnapshot(sections: [
            cachedSection("tech", "tel:0102030405"),
            cachedSection("inconnu", "https://a.example/b"),
        ]))
        let source = HeldSource()
        let model = DiscoverViewModel(cache: cache, loadContent: source.load)

        let load = Task { await model.loadIfNeeded() }
        await waitUntil("réseau en attente") { source.isHolding }

        #expect(model.phase == .loading, "rien d'affichable : comme sans cache")
        #expect(!model.isUpdatingRestoredContent)
        source.release(.success(.empty))
        await load.value
    }

    @Test("sujets restaurés dans l'ordre du catalogue, quel que soit l'ordre du fichier")
    func restoredInCatalogOrder() {
        let snapshot = DiscoverCacheSnapshot(sections: [
            cachedSection("sports", "https://a.example/s"),
            cachedSection("tech", "https://a.example/t"),
        ])
        #expect(snapshot.restored().content.sections.map(\.topic) == [.tech, .sports])
    }

    @Test("aller-retour du contenu vers le format du cache, sans perte")
    func contentRoundTrip() {
        let content = DiscoverContent(sections: [section(.art, "https://a.example/x")], failedTopics: [])
        let snapshot = DiscoverCacheSnapshot(content: content, dates: [.art: oldDate], fallbackDate: laterDate)
        let restored = snapshot.restored()
        #expect(restored.content == content)
        #expect(restored.dates[.art] == oldDate)
    }

    @Test("l'app écrit sur le disque, tests et aperçus non")
    func onlyLiveStoresUseTheDisk() throws {
        #expect(TrivaSharedStores.live().discoverCache is DiscoverDiskCache)
        #expect(TrivaSharedStores.preview().discoverCache is DiscoverNoCache)
    }
}

// MARK: - Premier chargement progressif

@MainActor
@Suite("DiscoverViewModel — premier chargement progressif")
struct DiscoverViewModelProgressiveTests {
    @Test("chaque sujet apparaît dès qu'il est prêt, à sa place dans le catalogue")
    func topicsAppearInCatalogOrder() async throws {
        let source = HeldSource()
        let model = DiscoverViewModel(loadContent: source.load)

        let load = Task { await model.loadIfNeeded() }
        await waitUntil("réseau en attente") { source.isHolding }
        #expect(model.phase == .loading)
        #expect(model.pendingTopics == Set(DiscoverTopic.allCases))
        let handler = try #require(source.onTopicFinished)

        // Finance avant Tech : Tech reste quand même au-dessus.
        handler(.finance, [article(.finance, "https://f.example/a")])
        guard case .loaded(let afterFinance) = model.phase else {
            Issue.record("Finance n'est pas affiché")
            return
        }
        #expect(afterFinance.sections.map(\.topic) == [.finance])
        #expect(model.isLoading)
        #expect(!model.isRefreshing)

        handler(.tech, [article(.tech, "https://t.example/a")])
        guard case .loaded(let afterTech) = model.phase else { return }
        #expect(afterTech.sections.map(\.topic) == [.tech, .finance])

        // Un sujet en échec libère sa place sans devenir une section.
        handler(.art, [])
        #expect(!model.pendingTopics.contains(.art))

        let final = DiscoverContent(
            sections: [section(.tech, "https://t.example/a"), section(.finance, "https://f.example/a")],
            failedTopics: [.art, .sports, .entertainment]
        )
        source.release(.success(final))
        await load.value

        #expect(model.phase == .loaded(final))
        #expect(model.pendingTopics.isEmpty)
        #expect(!model.isLoading)
        #expect(model.completionAnnouncement == "Actualité chargée")
    }

    @Test("les places de « Tout » gardent l'ordre du catalogue : un sujet arrivé ne déplace rien au-dessus")
    func overviewSlotsKeepCatalogOrder() {
        let content = DiscoverContent(sections: [section(.finance, "https://f.example/a")], failedTopics: [])
        let slots = DiscoverViewModel.overviewSlots(content: content, pending: [.tech, .sports])
        #expect(slots.map(\.id) == ["tech", "finance", "sports"])
        #expect(slots[0] == .pending(topicID: "tech"))
        #expect(slots[1] == .ready(content.sections[0]))
    }

    @Test("tous les sujets échouent au premier chargement : état d'erreur")
    func allTopicsFailing() async throws {
        let source = HeldSource()
        let model = DiscoverViewModel(loadContent: source.load)

        let load = Task { await model.loadIfNeeded() }
        await waitUntil("réseau en attente") { source.isHolding }
        let handler = try #require(source.onTopicFinished)
        for topic in DiscoverTopic.allCases {
            handler(topic, [])
        }
        source.release(.success(DiscoverContent(sections: [], failedTopics: DiscoverTopic.allCases)))
        await load.value

        #expect(model.phase == .failed)
        #expect(model.completionAnnouncement == "Actualité indisponible")
    }

    /// Erreur levée après qu'un sujet s'est affiché : pas question de l'effacer.
    @Test("une erreur après un premier sujet garde ce sujet")
    func errorAfterFirstTopicKeepsIt() async throws {
        let source = HeldSource()
        let model = DiscoverViewModel(loadContent: source.load)

        let load = Task { await model.loadIfNeeded() }
        await waitUntil("réseau en attente") { source.isHolding }
        let handler = try #require(source.onTopicFinished)
        handler(.tech, [article(.tech, "https://t.example/a")])
        source.release(.failure(Offline.offline))
        await load.value

        guard case .loaded(let shown) = model.phase else {
            Issue.record("le sujet a disparu : \(model.phase)")
            return
        }
        #expect(shown.sections.map(\.topic) == [.tech])
        #expect(model.refreshDidFail)
        #expect(model.pendingTopics.isEmpty)
    }

    /// Du contenu à l'écran ne bouge qu'à la fin du chargement.
    @Test("pendant un rafraîchissement, les sujets reçus ne touchent pas à l'écran")
    func refreshIgnoresProgress() async throws {
        let contentA = DiscoverContent(sections: [section(.tech, "https://a.example/a")], failedTopics: [])
        let contentB = DiscoverContent(sections: [section(.tech, "https://b.example/a")], failedTopics: [])
        let source = HeldSource()
        let model = DiscoverViewModel(loadContent: source.load)

        let first = Task { await model.loadIfNeeded() }
        await waitUntil("premier chargement") { source.isHolding }
        source.release(.success(contentA))
        await first.value

        let refresh = Task { await model.refresh() }
        await waitUntil("rafraîchissement") { source.isHolding }
        let handler = try #require(source.onTopicFinished)
        handler(.tech, contentB.sections[0].articles)
        #expect(model.phase == .loaded(contentA))
        #expect(model.pendingTopics.isEmpty)

        source.release(.success(contentB))
        await refresh.value
        #expect(model.phase == .loaded(contentB))
        #expect(model.completionAnnouncement == "Actualité mise à jour")
    }
}

// MARK: - Avertissement

@Suite("DiscoverStaleNotice")
struct DiscoverStaleNoticeTests {
    private let now = Date(timeIntervalSince1970: 2_000_000)
    private let calendar = Calendar(identifier: .gregorian)

    @Test("rien à signaler : pas de message")
    func nothingToReport() {
        #expect(DiscoverStaleNotice.text(refreshDidFail: false, staleTitles: [], oldestDate: now, now: now, calendar: calendar) == nil)
    }

    @Test("contenu tout juste chargé : pas d'âge, juste le conseil")
    func recentContentHasNoAge() {
        #expect(
            DiscoverStaleNotice.text(refreshDidFail: true, staleTitles: [], oldestDate: now.addingTimeInterval(-30), now: now, calendar: calendar)
                == "Actualisation impossible. Vérifie ta connexion."
        )
    }

    @Test("contenu ancien : son âge, en minuscules dans la phrase")
    func oldContentShowsAge() {
        #expect(
            DiscoverStaleNotice.text(refreshDidFail: true, staleTitles: [], oldestDate: now.addingTimeInterval(-3 * 3_600), now: now, calendar: calendar)
                == "Actualisation impossible. Dernière mise à jour\u{00A0}: il\u{00A0}y\u{00A0}a\u{00A0}3\u{00A0}heures."
        )
    }

    /// Vu à l'écran : « il / y a 8 minutes » sur iPhone 18 Pro, « il y a / 8 minutes » sur iPad mini.
    /// Aucune espace ordinaire ne doit rester dans l'expression, ni devant le « : ».
    @Test("l'âge ne se coupe pas : espaces insécables dans toute l'expression et devant le deux-points")
    func ageExpressionDoesNotBreak() throws {
        let text = try #require(
            DiscoverStaleNotice.text(refreshDidFail: true, staleTitles: [], oldestDate: now.addingTimeInterval(-8 * 60), now: now, calendar: calendar)
        )
        #expect(text.hasSuffix("jour\u{00A0}: il\u{00A0}y\u{00A0}a\u{00A0}8\u{00A0}minutes."))
        #expect(!text.contains("jour :"))
    }

    @Test("plusieurs sujets : liste en français, accord au pluriel")
    func severalTopics() {
        let text = DiscoverStaleNotice.text(
            refreshDidFail: false,
            staleTitles: ["Finance", "Sport"],
            oldestDate: now.addingTimeInterval(-3 * 3_600),
            now: now,
            calendar: calendar
        )
        #expect(text == "Finance et Sport n'ont pas pu être actualisés. Dernière mise à jour\u{00A0}: il\u{00A0}y\u{00A0}a\u{00A0}3\u{00A0}heures.")
    }
}
