//
//  TrivaPlaceholderWidget.swift
//  TrivaWidgets
//
//  Chantier 2.1 (S1) : widget statique minimal, uniquement pour que l'extension compile et se signe.
//  Remplacé par QuickSearchWidget (mission C).
//

import SwiftUI
import WidgetKit

nonisolated struct TrivaPlaceholderEntry: TimelineEntry {
    let date: Date
}

nonisolated struct TrivaPlaceholderProvider: TimelineProvider {
    func placeholder(in context: Context) -> TrivaPlaceholderEntry {
        TrivaPlaceholderEntry(date: .now)
    }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (TrivaPlaceholderEntry) -> Void) {
        completion(TrivaPlaceholderEntry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<TrivaPlaceholderEntry>) -> Void) {
        completion(Timeline(entries: [TrivaPlaceholderEntry(date: .now)], policy: .never))
    }
}

struct TrivaPlaceholderWidget: Widget {
    let kind = "com.benpodrojsky.Triva.Placeholder"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TrivaPlaceholderProvider()) { _ in
            Text("Triva")
                .font(.headline)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Triva")
        .description("Ouvre Triva.")
        .supportedFamilies([.systemSmall])
    }
}
