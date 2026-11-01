//
//  MediaResultsPresentationTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 02/10/2026.
//

import Testing
import Foundation
@testable import Triva

/// Logique pure des vues de résultats médias (1.6) : `MediaResultsPresentation`
/// et `MediaResultsKind`, déclarés dans `Triva/Features/Chat/MediaResultsComponents.swift`.
///
/// Suites NON isolées : tout ce qu'elles testent est `nonisolated` et ne
/// manipule que des primitives. Aucune comparaison de `ImageSearchResult` /
/// `VideoSearchResult` ici : leur `Equatable` est isolé au main actor.
@Suite("MediaResultsPresentation")
struct MediaResultsPresentationTests {

    // MARK: Colonnes et capacité de la grille

    @Test("Colonnes : 2 en compact, 3 ailleurs, 1 aux tailles d'accessibilité")
    func columnCountFollowsWidthAndTextSize() {
        #expect(MediaResultsPresentation.columnCount(isCompactWidth: true, isAccessibilitySize: false) == 2)
        #expect(MediaResultsPresentation.columnCount(isCompactWidth: false, isAccessibilitySize: false) == 3)
        #expect(MediaResultsPresentation.columnCount(isCompactWidth: true, isAccessibilitySize: true) == 1)
        #expect(MediaResultsPresentation.columnCount(isCompactWidth: false, isAccessibilitySize: true) == 1)
    }

    @Test("Capacité : deux rangées pleines, 4 cases au minimum", arguments: zip([1, 2, 3], [4, 4, 6]))
    func gridCapacityIsTwoFullRowsWithMinimumFour(columns: Int, expected: Int) {
        #expect(MediaResultsPresentation.gridCapacity(columnCount: columns) == expected)
    }

    @Test(
        "Capacité : colonnes aberrantes bornées, sans dépassement d'entier",
        arguments: zip([0, -5, 4, Int.max, Int.min], [4, 4, 6, 6, 4])
    )
    func gridCapacityClampsAbsurdColumnCounts(columns: Int, expected: Int) {
        #expect(MediaResultsPresentation.gridCapacity(columnCount: columns) == expected)
    }

    // MARK: Repli de la grille

    @Test("Grille : tout s'affiche tant que la capacité suffit")
    func gridShowsEverythingWithinCapacity() {
        #expect(MediaResultsPresentation.gridLayout(totalCount: 4, capacity: 4) == MediaInlineLayout(visibleCount: 4, hiddenCount: 0))
        #expect(MediaResultsPresentation.gridLayout(totalCount: 1, capacity: 4) == MediaInlineLayout(visibleCount: 1, hiddenCount: 0))
        #expect(MediaResultsPresentation.gridLayout(totalCount: 0, capacity: 4) == MediaInlineLayout(visibleCount: 0, hiddenCount: 0))
    }

    @Test("Grille : règle du web, 3 images + « +N » au-delà de 4")
    func gridMatchesWebRuleBeyondCapacity() {
        #expect(MediaResultsPresentation.gridLayout(totalCount: 5, capacity: 4) == MediaInlineLayout(visibleCount: 3, hiddenCount: 2))
        #expect(MediaResultsPresentation.gridLayout(totalCount: 10, capacity: 4) == MediaInlineLayout(visibleCount: 3, hiddenCount: 7))
        #expect(MediaResultsPresentation.gridLayout(totalCount: 50, capacity: 6) == MediaInlineLayout(visibleCount: 5, hiddenCount: 45))
    }

    @Test("Grille : la case « +N » cache toujours au moins 2 images", arguments: 0...60)
    func gridNeverHidesASingleImage(total: Int) {
        let layout = MediaResultsPresentation.gridLayout(totalCount: total, capacity: 4)
        #expect(layout.visibleCount + layout.hiddenCount == total)
        #expect(layout.hiddenCount == 0 || layout.hiddenCount >= 2)
    }

    @Test("Grille : capacité ramenée à 2, total négatif compté zéro")
    func gridClampsDegenerateInputs() {
        #expect(MediaResultsPresentation.gridLayout(totalCount: 5, capacity: 0) == MediaInlineLayout(visibleCount: 1, hiddenCount: 4))
        #expect(MediaResultsPresentation.gridLayout(totalCount: -3, capacity: 4) == MediaInlineLayout(visibleCount: 0, hiddenCount: 0))
    }

    @Test("Grille dépliée : capacité égale au total, plus rien de caché")
    func expandedGridShowsEverything() {
        #expect(MediaResultsPresentation.gridLayout(totalCount: 50, capacity: 50) == MediaInlineLayout(visibleCount: 50, hiddenCount: 0))
    }

    // MARK: Repli de la liste de vidéos

    @Test("Liste : 3 vidéos, puis le bouton seulement s'il en cache au moins 2")
    func listHidesAtLeastTwoVideos() {
        #expect(MediaResultsPresentation.listLayout(totalCount: 3, limit: 3) == MediaInlineLayout(visibleCount: 3, hiddenCount: 0))
        #expect(MediaResultsPresentation.listLayout(totalCount: 4, limit: 3) == MediaInlineLayout(visibleCount: 4, hiddenCount: 0))
        #expect(MediaResultsPresentation.listLayout(totalCount: 5, limit: 3) == MediaInlineLayout(visibleCount: 3, hiddenCount: 2))
        #expect(MediaResultsPresentation.listLayout(totalCount: 10, limit: 3) == MediaInlineLayout(visibleCount: 3, hiddenCount: 7))
    }

    @Test("Liste : entrées dégénérées sans plantage")
    func listClampsDegenerateInputs() {
        #expect(MediaResultsPresentation.listLayout(totalCount: 0, limit: 3) == MediaInlineLayout(visibleCount: 0, hiddenCount: 0))
        #expect(MediaResultsPresentation.listLayout(totalCount: -2, limit: 3) == MediaInlineLayout(visibleCount: 0, hiddenCount: 0))
        #expect(MediaResultsPresentation.listLayout(totalCount: 3, limit: 0) == MediaInlineLayout(visibleCount: 1, hiddenCount: 2))
        #expect(MediaResultsPresentation.listLayout(totalCount: 3, limit: Int.max) == MediaInlineLayout(visibleCount: 3, hiddenCount: 0))
    }

    @Test("Liste dépliée : limite égale au total, plus rien de caché")
    func expandedListShowsEverything() {
        #expect(MediaResultsPresentation.listLayout(totalCount: 10, limit: 10) == MediaInlineLayout(visibleCount: 10, hiddenCount: 0))
    }

    // MARK: Domaine de la source

    @Test("Domaine : minuscules, sans www., sous-domaines conservés")
    func sourceDomainIsNormalizedHost() throws {
        let lemonde = try #require(URL(string: "https://www.lemonde.fr/animaux/article.html"))
        let wikipedia = try #require(URL(string: "https://FR.Wikipedia.org/wiki/Chat"))
        #expect(MediaResultsPresentation.sourceDomain(of: lemonde) == "lemonde.fr")
        #expect(MediaResultsPresentation.sourceDomain(of: wikipedia) == "fr.wikipedia.org")
    }

    @Test("Domaine : nil pour une URL https sans hôte, jamais un domaine inventé")
    func sourceDomainIsNilWithoutHost() throws {
        let hostless = try #require(URL(string: "https:chemin/image.jpg"))
        #expect(MediaResultsPresentation.sourceDomain(of: hostless) == nil)
    }

    // MARK: Déduplication

    @Test("Déduplication : première occurrence gardée, ordre conservé")
    func removingDuplicatesKeepsFirstOccurrenceInOrder() {
        let items = ["a", "b", "a", "c", "b"]
        #expect(MediaResultsPresentation.removingDuplicates(items, by: { $0 }) == ["a", "b", "c"])
        #expect(MediaResultsPresentation.removingDuplicates([String](), by: { $0 }).isEmpty)
    }

    @Test("Déduplication : sur la clé fournie, pas sur l'élément entier")
    func removingDuplicatesUsesTheProvidedKey() {
        let items = [(1, "chat.jpg"), (2, "chat.jpg"), (3, "chien.jpg")]
        let kept = MediaResultsPresentation.removingDuplicates(items, by: { $0.1 })
        #expect(kept.map(\.0) == [1, 3])
    }

    // MARK: Visionneuse

    @Test("Position : « 3 sur 10 », rien pour une image seule ou un index hors bornes")
    func positionTextFormatsOrRefuses() {
        #expect(MediaResultsPresentation.positionText(index: 2, count: 10) == "3 sur 10")
        #expect(MediaResultsPresentation.positionText(index: 9, count: 10) == "10 sur 10")
        #expect(MediaResultsPresentation.positionText(index: 0, count: 1) == nil)
        #expect(MediaResultsPresentation.positionText(index: 10, count: 10) == nil)
        #expect(MediaResultsPresentation.positionText(index: -1, count: 10) == nil)
        #expect(MediaResultsPresentation.positionText(index: 0, count: -3) == nil)
    }

    @Test("Voisin : pas de bouclage aux extrémités, pas de plantage sur un décalage aberrant")
    func neighborIndexStaysInBounds() {
        #expect(MediaResultsPresentation.neighborIndex(of: 2, offset: 1, count: 5) == 3)
        #expect(MediaResultsPresentation.neighborIndex(of: 2, offset: -1, count: 5) == 1)
        #expect(MediaResultsPresentation.neighborIndex(of: 0, offset: -1, count: 5) == nil)
        #expect(MediaResultsPresentation.neighborIndex(of: 4, offset: 1, count: 5) == nil)
        #expect(MediaResultsPresentation.neighborIndex(of: Int.max, offset: 1, count: 5) == nil)
        #expect(MediaResultsPresentation.neighborIndex(of: 0, offset: Int.min, count: 5) == nil)
        #expect(MediaResultsPresentation.neighborIndex(of: 0, offset: 1, count: -1) == nil)
    }

    // MARK: VoiceOver

    @Test("Libellé : « titre, domaine », comme SourcesListView")
    func accessibilityLabelCombinesTitleAndDomain() {
        #expect(MediaResultsPresentation.accessibilityLabel(title: "Chat noir", domain: "lemonde.fr") == "Chat noir, lemonde.fr")
        #expect(MediaResultsPresentation.accessibilityLabel(title: "  Chat noir  ", domain: nil) == "Chat noir")
        #expect(MediaResultsPresentation.accessibilityLabel(title: "Chat noir", domain: "") == "Chat noir")
        #expect(MediaResultsPresentation.accessibilityLabel(title: "   ", domain: "lemonde.fr") == "lemonde.fr")
    }
}

@Suite("MediaResultsKind")
struct MediaResultsKindTests {

    @Test("Annonce de fin de recherche : accord en nombre et état vide")
    func resultsAnnouncementAgreesInNumber() {
        #expect(MediaResultsKind.images.resultsAnnouncement(count: 0) == "Aucune image trouvée")
        #expect(MediaResultsKind.images.resultsAnnouncement(count: 1) == "1 image trouvée")
        #expect(MediaResultsKind.images.resultsAnnouncement(count: 8) == "8 images trouvées")
        #expect(MediaResultsKind.videos.resultsAnnouncement(count: 1) == "1 vidéo trouvée")
        #expect(MediaResultsKind.videos.resultsAnnouncement(count: 3) == "3 vidéos trouvées")
        #expect(MediaResultsKind.videos.resultsAnnouncement(count: -1) == "Aucune vidéo trouvée")
    }

    @Test("Bouton « afficher plus » : ce que fait le bouton, pas « +7 »")
    func showMoreLabelDescribesTheAction() {
        #expect(MediaResultsKind.images.showMoreLabel(hiddenCount: 7) == "Afficher les 7 autres images")
        #expect(MediaResultsKind.videos.showMoreLabel(hiddenCount: 2) == "Afficher les 2 autres vidéos")
        #expect(MediaResultsKind.videos.showMoreLabel(hiddenCount: 1) == "Afficher 1 autre vidéo")
        #expect(MediaResultsKind.images.showMoreLabel(hiddenCount: 0) == "Tout afficher")
    }

    /// Attendus typés `CGFloat` HORS de `#expect`, volontairement. Écrit
    /// `#expect(ratio == 4.0 / 3.0)`, ce test échoue alors que les deux côtés
    /// s'affichent 1.3333333333333333 ; la même comparaison évaluée hors de la
    /// macro est vraie (vérifié le 2026-10-03, Swift 6.4). Cause probable : la
    /// macro capture chaque sous-expression à part (`4.0`, `3.0`, leur
    /// quotient), et les littéraux y perdent le contexte `CGFloat` du membre
    /// de gauche.
    @Test("Proportions : 4:3 pour les images, 16:9 pour les vidéos")
    func thumbnailAspectRatios() {
        let fourThirds: CGFloat = 4.0 / 3.0
        let sixteenNinths: CGFloat = 16.0 / 9.0
        #expect(MediaResultsKind.images.thumbnailAspectRatio == fourThirds)
        #expect(MediaResultsKind.videos.thumbnailAspectRatio == sixteenNinths)
    }

    /// Un libellé vide donnerait un bouton sans texte ; un point final ferait
    /// d'un état (« Image indisponible ») une phrase, contre la convention
    /// documentée sur `MediaResultsKind`.
    @Test("Libellés : non vides, sans point final", arguments: [MediaResultsKind.images, .videos])
    func labelsAreNonEmptyStatesWithoutFinalPeriod(kind: MediaResultsKind) {
        let labels = [
            kind.sectionTitle, kind.searchButtonTitle, kind.loadingText,
            kind.emptyText, kind.failureText, kind.thumbnailFailureText,
        ]
        for label in labels {
            #expect(!label.isEmpty)
            #expect(!label.hasSuffix("."))
        }
    }
}
