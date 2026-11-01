//
//  LibraryFavoritesPresentationTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 04/10/2026.
//

import Testing
import Foundation
import SwiftData
@testable import Triva

/// Logique pure de la Bibliothèque (1.9) et des Favoris (1.10) :
/// - `AnswerExcerpt` et `RelativeDateLabel` (`Triva/Core/Text/AnswerExcerpt.swift`) ;
/// - `AnswerExcerptCache` (`Triva/Features/Library/HistoryListSupport.swift`) ;
/// - `LibraryPeriod` et `LibraryGrouping` (`Triva/Features/Library/LibraryView.swift`) ;
/// - `FavoritePresentation` (`Triva/Features/Favorites/FavoritesView.swift`).
///
/// Dates : calendrier grégorien `Europe/Paris`, semaine commençant le lundi
/// (`firstWeekday = 2`), et un `now` FIXE — dimanche 4 octobre 2026, 13:00 UTC
/// (15:00 à Paris). Aucun test ne dépend de l'horloge.
///
/// Les suites qui touchent `AnswerExcerptCache`, les stores ou des modèles
/// SwiftData sont `@MainActor` (isolation par défaut de ces types côté app) ;
/// les autres ne testent que du `nonisolated`.

// MARK: - Outils

private let parisCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
    calendar.firstWeekday = 2
    calendar.locale = Locale(identifier: "fr_FR")
    return calendar
}()

/// Dimanche 4 octobre 2026, 13:00 UTC.
private let referenceNow: Date = DateComponents(
    calendar: parisCalendar, timeZone: TimeZone(identifier: "UTC"),
    year: 2026, month: 10, day: 4, hour: 13
).date!

/// Date à l'heure de Paris.
private func paris(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    DateComponents(calendar: parisCalendar, year: year, month: month, day: day, hour: hour, minute: minute).date!
}

private func summary(_ title: String, updatedAt: Date) -> LibraryConversationSummary {
    LibraryConversationSummary(id: UUID(), title: title, updatedAt: updatedAt, preview: nil)
}

private func makeSource(_ index: Int) -> SearXNGSearchResult {
    SearXNGSearchResult(
        title: "Source \(index)", url: "https://exemple\(index).fr/article", content: "Extrait \(index)",
        imgSrc: nil, thumbnailSrc: nil, thumbnail: nil, author: nil, iframeSrc: nil
    )
}

/// Les deux stores de l'app sur le MÊME conteneur en mémoire neuf, comme
/// `FavoritesStoreTests` : jamais `TrivaModelContainer.shared`.
@MainActor
private struct Stores {
    let history: ChatHistoryStore
    let favorites: FavoritesStore

    init() throws {
        let container = try TrivaModelContainer.makeInMemory()
        let locale = Locale(identifier: "fr_FR")
        history = ChatHistoryStore(container: container, locale: locale)
        favorites = FavoritesStore(container: container, locale: locale)
    }
}

// MARK: - AnswerExcerpt

@Suite("AnswerExcerpt")
struct AnswerExcerptTests {

    @Test("Raisonnement, titre, gras et citations retirés")
    func stripsReasoningMarkdownAndCitations() {
        let answer = "<think>Je réfléchis en anglais.</think>## En bref\nLa **photosynthèse** convertit l'énergie [1]. Elle a lieu dans les chloroplastes[2]."
        #expect(AnswerExcerpt.make(from: answer) == "En bref La photosynthèse convertit l'énergie. Elle a lieu dans les chloroplastes.")
    }

    @Test("Le TL;DR passe avant le corps")
    func prefersTLDR() {
        let answer = "<tldr>Une phrase résumé.</tldr>\n## Détails\nUn long corps de réponse [1]."
        #expect(AnswerExcerpt.make(from: answer) == "Une phrase résumé.")
    }

    @Test("Espace gardée devant ; et ?, retirée devant . (typographie française)")
    func citationRemovalRespectsFrenchSpacing() {
        #expect(AnswerExcerpt.make(from: "Vrai [1] ; faux [2] ? Oui [3].") == "Vrai ; faux ? Oui.")
    }

    @Test("Aucun texte affichable : nil")
    func blankAnswerGivesNil() {
        #expect(AnswerExcerpt.make(from: "") == nil)
        #expect(AnswerExcerpt.make(from: "  \n\t ") == nil)
        #expect(AnswerExcerpt.make(from: "<think></think>") == nil)
    }

    @Test("<think> jamais refermé : le raisonnement sert d'aperçu")
    func unclosedThinkFallsBackToReasoning() {
        #expect(AnswerExcerpt.make(from: "<think>Raisonnement interrompu") == "Raisonnement interrompu")
    }

    @Test("<br> remplacé par une espace, jamais supprimé (non-régression)")
    func lineBreakTagBecomesSpace() {
        #expect(AnswerExcerpt.make(from: "Ligne<br>suivante") == "Ligne suivante")
    }

    @Test("Réponse longue : coupée à 250 caractères au plus, avec « … »")
    func longAnswerIsTruncated() throws {
        let answer = (1...400).map { "mot\($0)" }.joined(separator: " ")
        let excerpt = try #require(AnswerExcerpt.make(from: answer))
        #expect(excerpt.count <= AnswerExcerpt.defaultMaxLength)
        #expect(excerpt.hasSuffix("…"))
        #expect(excerpt.hasPrefix("mot1 mot2 "))
    }

    @Test("Tableau et filet : lignes structurelles retirées, barres remplacées")
    func tableAndRuleAreFlattened() {
        let answer = "| A | B |\n|---|---|\n| 1 | 2 |\n\n---\nFin."
        #expect(AnswerExcerpt.make(from: answer) == "A B 1 2 Fin.")
    }

    @Test("Puces, citations et code : marqueurs retirés, « #hashtag » gardé")
    func blockMarkersAreStripped() {
        #expect(AnswerExcerpt.make(from: "- un\n- deux\n> cité\n1. trois") == "un deux cité trois")
        #expect(AnswerExcerpt.make(from: "```swift\nlet x = 1\n```") == "let x = 1")
        #expect(AnswerExcerpt.make(from: "#hashtag et *italique*") == "#hashtag et italique")
    }

    @Test("Comparaisons « a < b » intactes")
    func lessThanIsNotATag() {
        #expect(AnswerExcerpt.make(from: "a < b et 3 <5") == "a < b et 3 <5")
    }
}

// MARK: - RelativeDateLabel

@Suite("RelativeDateLabel")
struct RelativeDateLabelTests {

    @Test("Il y a 2 heures")
    func twoHoursAgo() {
        let text = RelativeDateLabel.text(for: referenceNow.addingTimeInterval(-2 * 3600), relativeTo: referenceNow, calendar: parisCalendar)
        #expect(text == "Il y a 2 heures")
    }

    @Test("Date future ramenée à « Maintenant »")
    func futureDateIsNow() {
        let text = RelativeDateLabel.text(for: referenceNow.addingTimeInterval(7200), relativeTo: referenceNow, calendar: parisCalendar)
        #expect(text == "Maintenant")
    }

    @Test("Date longue : « 4 octobre 2026 »")
    func longDate() {
        #expect(RelativeDateLabel.longDate(referenceNow, calendar: parisCalendar) == "4 octobre 2026")
    }

    @Test("Locale forcée en français")
    func localeIsFrench() {
        #expect(RelativeDateLabel.locale.identifier == "fr_FR")
    }
}

// MARK: - LibraryPeriod

@Suite("LibraryPeriod")
struct LibraryPeriodTests {

    @Test("Aujourd'hui : depuis minuit, heure de Paris")
    func today() {
        #expect(LibraryPeriod.of(referenceNow.addingTimeInterval(-3600), now: referenceNow, calendar: parisCalendar) == .today)
        #expect(LibraryPeriod.of(paris(2026, 10, 4, 0), now: referenceNow, calendar: parisCalendar) == .today)
    }

    @Test("Du lundi au samedi de la même semaine : cette semaine")
    func thisWeek() {
        #expect(LibraryPeriod.of(paris(2026, 9, 28, 10), now: referenceNow, calendar: parisCalendar) == .thisWeek)
        #expect(LibraryPeriod.of(paris(2026, 10, 3, 23, 59), now: referenceNow, calendar: parisCalendar) == .thisWeek)
    }

    @Test("Le dimanche précédent : plus ancien (semaine calendaire, pas 7 jours)")
    func previousSundayIsOlder() {
        #expect(LibraryPeriod.of(paris(2026, 9, 27, 12), now: referenceNow, calendar: parisCalendar) == .older)
    }

    @Test("Un lundi, hier est déjà plus ancien")
    func onMondayYesterdayIsOlder() {
        let monday = paris(2026, 9, 28, 12)
        #expect(LibraryPeriod.of(paris(2026, 9, 27, 12), now: monday, calendar: parisCalendar) == .older)
    }

    @Test("Date future rangée avec aujourd'hui")
    func futureIsToday() {
        #expect(LibraryPeriod.of(referenceNow.addingTimeInterval(86_400 * 3), now: referenceNow, calendar: parisCalendar) == .today)
    }

    @Test("Ordre et titres des sections")
    func orderAndTitles() {
        #expect(LibraryPeriod.allCases == [.today, .thisWeek, .older])
        #expect(LibraryPeriod.allCases.map(\.title) == ["Aujourd'hui", "Cette semaine", "Plus ancien"])
    }
}

// MARK: - LibraryGrouping

@Suite("LibraryGrouping")
struct LibraryGroupingTests {

    @Test("Sections non vides, dans l'ordre des périodes, ordre du store gardé")
    func sectionsKeepPeriodAndStoreOrder() {
        let todayA = summary("A", updatedAt: referenceNow.addingTimeInterval(-60))
        let todayB = summary("B", updatedAt: referenceNow.addingTimeInterval(-120))
        let old = summary("C", updatedAt: paris(2026, 1, 1, 12))
        let sections = LibraryGrouping.sections(for: [todayA, todayB, old], now: referenceNow, calendar: parisCalendar)
        #expect(sections.map(\.period) == [.today, .older])
        #expect(sections[0].conversations.map(\.title) == ["A", "B"])
        #expect(sections[1].conversations.map(\.title) == ["C"])
    }

    @Test("Aucune conversation : aucune section")
    func emptyGivesNoSection() {
        #expect(LibraryGrouping.sections(for: [], now: referenceNow, calendar: parisCalendar).isEmpty)
    }

    @Test("Retrait : une section vidée disparaît, les autres restent")
    func removingEmptiesSection() {
        let today = summary("A", updatedAt: referenceNow.addingTimeInterval(-60))
        let week = summary("B", updatedAt: paris(2026, 9, 29, 9))
        let sections = LibraryGrouping.sections(for: [today, week], now: referenceNow, calendar: parisCalendar)
        let remaining = LibraryGrouping.removing(today.id, from: sections)
        #expect(remaining.map(\.period) == [.thisWeek])
        #expect(remaining[0].conversations == [week])
    }

    @Test("Retrait d'un identifiant inconnu : sections inchangées")
    func removingUnknownIdKeepsSections() {
        let sections = LibraryGrouping.sections(
            for: [summary("A", updatedAt: referenceNow)], now: referenceNow, calendar: parisCalendar
        )
        #expect(LibraryGrouping.removing(UUID(), from: sections) == sections)
    }
}

// MARK: - AnswerExcerptCache

@MainActor
@Suite("AnswerExcerptCache")
struct AnswerExcerptCacheTests {

    @Test("Même version : calcul fait une seule fois ; nouvelle version : recalcul")
    func computesOncePerVersion() {
        let cache = AnswerExcerptCache()
        let id = UUID()
        var calls = 0
        let first = cache.excerpt(for: id, version: referenceNow) { calls += 1; return "un" }
        let again = cache.excerpt(for: id, version: referenceNow) { calls += 1; return "autre" }
        let updated = cache.excerpt(for: id, version: referenceNow.addingTimeInterval(1)) { calls += 1; return "deux" }
        #expect(first == "un")
        #expect(again == "un")
        #expect(updated == "deux")
        #expect(calls == 2)
    }

    @Test("Un aperçu nil est mémorisé lui aussi")
    func nilExcerptIsCached() {
        let cache = AnswerExcerptCache()
        let id = UUID()
        var calls = 0
        _ = cache.excerpt(for: id, version: referenceNow) { calls += 1; return nil }
        let again = cache.excerpt(for: id, version: referenceNow) { calls += 1; return "tard" }
        #expect(again == nil)
        #expect(calls == 1)
    }

    @Test("retainOnly oublie les identifiants disparus")
    func retainOnlyDropsOthers() {
        let cache = AnswerExcerptCache()
        let kept = UUID()
        let dropped = UUID()
        _ = cache.excerpt(for: kept, version: referenceNow) { "gardé" }
        _ = cache.excerpt(for: dropped, version: referenceNow) { "oublié" }
        cache.retainOnly([kept])
        #expect(cache.excerpt(for: kept, version: referenceNow) { "recalculé" } == "gardé")
        #expect(cache.excerpt(for: dropped, version: referenceNow) { "recalculé" } == "recalculé")
    }
}

// MARK: - FavoritePresentation

@Suite("FavoritePresentation")
struct FavoritePresentationTests {

    @Test("Question de ligne : nil sans caractère visible, espaces insécables comprises")
    func rowQuestionIsNilWhenInvisible() {
        #expect(FavoritePresentation.rowQuestion(from: "") == nil)
        #expect(FavoritePresentation.rowQuestion(from: "  \n ") == nil)
        #expect(FavoritePresentation.rowQuestion(from: "\u{00A0}\u{00A0}") == nil)
    }

    @Test("Question de ligne : blancs normalisés")
    func rowQuestionCollapsesWhitespace() {
        #expect(FavoritePresentation.rowQuestion(from: "Ligne 1\n\nLigne   2") == "Ligne 1 Ligne 2")
    }

    @Test("Question de ligne : 60 caractères au plus")
    func rowQuestionIsBounded() throws {
        let long = String(repeating: "Pourquoi le ciel est-il bleu ? ", count: 10)
        let row = try #require(FavoritePresentation.rowQuestion(from: long))
        #expect(row.count <= ConversationTitleBuilder.maxTitleLength)
        #expect(row.hasSuffix("…"))
    }

    @Test("Question du détail : rognée, nil si vide")
    func detailQuestionTrimsOrRefuses() {
        #expect(FavoritePresentation.detailQuestion(from: "  Pourquoi ?\n") == "Pourquoi ?")
        #expect(FavoritePresentation.detailQuestion(from: "Ligne 1\n\nLigne 2") == "Ligne 1\n\nLigne 2")
        #expect(FavoritePresentation.detailQuestion(from: " \n ") == nil)
    }

    @Test("Source reconstruite : l'extrait redevient content, pas de champ média")
    func searchResultMapsSnippetToContent() {
        let result = FavoritePresentation.searchResult(title: "T", url: "https://exemple.fr", snippet: "Extrait")
        #expect(result.title == "T")
        #expect(result.url == "https://exemple.fr")
        #expect(result.content == "Extrait")
        #expect(result.imgSrc == nil && result.thumbnail == nil && result.iframeSrc == nil)
    }
}

// MARK: - FavoritePresentation avec SwiftData

@MainActor
@Suite("FavoritePresentation (stores en mémoire)")
struct FavoritePresentationStoreTests {

    @Test("citationSources retrie par order, snippet → content")
    func citationSourcesAreSortedByOrder() throws {
        let container = try TrivaModelContainer.makeInMemory()
        try withExtendedLifetime(container) {
            let unordered = [
                StoredFavoriteSource(title: "Trois", url: "https://c.fr", snippet: "c", order: 2),
                StoredFavoriteSource(title: "Un", url: "https://a.fr", snippet: "a", order: 0),
                StoredFavoriteSource(title: "Deux", url: "https://b.fr", snippet: nil, order: 1),
            ]
            let sources = FavoritePresentation.citationSources(from: unordered)
            #expect(sources.map(\.title) == ["Un", "Deux", "Trois"])
            #expect(sources.map(\.content) == ["a", nil, "c"])
        }
    }

    @Test("detailContent garde question, réponse, sources dans l'ordre et conversationID")
    func detailContentCopiesEverything() throws {
        let stores = try Stores()
        let messageID = UUID()
        let conversationID = UUID()
        let sources = [makeSource(1), makeSource(2), makeSource(3)]
        try stores.favorites.mark(
            messageID: messageID, conversationID: conversationID,
            question: "Pourquoi ?", answer: "Parce que [1][3].",
            sources: sources, now: referenceNow
        )

        let favorite = try #require(try stores.favorites.favorite(forMessageID: messageID))
        let detail = FavoritePresentation.detailContent(copying: favorite)
        #expect(detail.messageID == messageID)
        #expect(detail.conversationID == conversationID)
        #expect(detail.question == "Pourquoi ?")
        #expect(detail.answer == "Parce que [1][3].")
        #expect(detail.sources == sources)
        #expect(detail.savedAt == referenceNow)
    }

    @Test("Le favori survit à la suppression de sa conversation")
    func favoriteSurvivesConversationDeletion() throws {
        let stores = try Stores()
        let conversation = try stores.history.createConversation(title: "Marées", now: referenceNow)
        try stores.history.appendUserMessage(to: conversation, text: "Qu'est-ce qu'une marée ?", now: referenceNow)
        let answer = try stores.history.appendAssistantMessage(
            to: conversation, text: "Une variation du niveau de la mer [1].",
            sources: [makeSource(1)], now: referenceNow
        )
        let messageID = answer.id
        let conversationID = conversation.id
        try stores.favorites.mark(answer, now: referenceNow)

        try stores.history.delete(conversation)

        #expect(try stores.history.conversation(with: conversationID) == nil)
        let favorite = try #require(try stores.favorites.favorite(forMessageID: messageID))
        let detail = FavoritePresentation.detailContent(copying: favorite)
        #expect(detail.question == "Qu'est-ce qu'une marée ?")
        #expect(detail.answer == "Une variation du niveau de la mer [1].")
        #expect(detail.sources.map(\.url) == [makeSource(1).url])
        #expect(detail.conversationID == conversationID)
    }

    @Test("Un second unmark renvoie false")
    func secondUnmarkReturnsFalse() throws {
        let stores = try Stores()
        let messageID = UUID()
        try stores.favorites.mark(
            messageID: messageID, conversationID: nil,
            question: "Q", answer: "R", now: referenceNow
        )
        #expect(try stores.favorites.unmark(messageID: messageID))
        #expect(try !stores.favorites.unmark(messageID: messageID))
        #expect(try stores.favorites.favorite(forMessageID: messageID) == nil)
    }
}
