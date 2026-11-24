//
//  QuickSearchWidget.swift
//  TrivaWidgets
//
//  Chantier 2.1 (mission C) : le widget « Recherche rapide » (iPhone, iPad, Mac ; écran verrouillé sur iOS).
//  Il LIT `widget-snapshot.json` dans l'App Group et rien d'autre : il n'écrit jamais, n'ouvre jamais la base de
//  l'historique, ne fait aucun réseau. L'app le recharge quand l'instantané change : politique `.never`.
//
//  Sans fichier (réglage « Dernière question dans le widget » éteint, ou rien d'écrit encore), il n'affiche
//  aucune question : seulement le geste « Nouvelle question ».
//

import SwiftUI
import WidgetKit

nonisolated struct QuickSearchEntry: TimelineEntry {
    let date: Date
    let content: QuickSearchContent
}

nonisolated struct QuickSearchProvider: TimelineProvider {
    /// Exemple montré dans la galerie des widgets : jamais une vraie question de l'utilisateur.
    private static let gallerySample = QuickSearchContent.conversation(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000000") ?? UUID(),
        title: "Quelle est la capitale de l'Australie ?"
    )

    func placeholder(in context: Context) -> QuickSearchEntry {
        QuickSearchEntry(date: .now, content: Self.gallerySample)
    }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (QuickSearchEntry) -> Void) {
        let content = context.isPreview ? Self.gallerySample : Self.currentContent()
        completion(QuickSearchEntry(date: .now, content: content))
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<QuickSearchEntry>) -> Void) {
        let entry = QuickSearchEntry(date: .now, content: Self.currentContent())
        completion(Timeline(entries: [entry], policy: .never))
    }

    /// Ce que dit le fichier de l'App Group ; App Group absent ou fichier illisible = vue neutre.
    static func currentContent() -> QuickSearchContent {
        let store = AppGroupFileStore.live().map { WidgetSnapshotStore(files: $0) }
        return QuickSearchContent(snapshot: store?.load())
    }
}

struct QuickSearchWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: TrivaWidgetKind.quickSearch, provider: QuickSearchProvider()) { entry in
            QuickSearchWidgetView(entry: entry)
        }
        .configurationDisplayName("Recherche rapide")
        .description("Une nouvelle question en un toucher. Ta dernière recherche s'affiche si tu l'actives dans les Réglages de Triva.")
        .supportedFamilies(Self.families)
    }

    private static var families: [WidgetFamily] {
        #if os(iOS)
        [.systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular]
        #else
        [.systemSmall, .systemMedium]
        #endif
    }
}

#Preview("Petit, avec une recherche", as: .systemSmall) {
    QuickSearchWidget()
} timeline: {
    QuickSearchEntry(date: .now, content: .conversation(id: UUID(), title: "Recette de crêpes sans lait"))
}

#Preview("Moyen, avec une recherche", as: .systemMedium) {
    QuickSearchWidget()
} timeline: {
    QuickSearchEntry(date: .now, content: .conversation(id: UUID(), title: "Recette de crêpes sans lait"))
}

#Preview("Petit, neutre", as: .systemSmall) {
    QuickSearchWidget()
} timeline: {
    QuickSearchEntry(date: .now, content: .neutral)
    QuickSearchEntry(date: .now, content: .noHistory)
}
