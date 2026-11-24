//
//  QuickSearchWidgetViews.swift
//  TrivaWidgets
//
//  Chantier 2.1 (mission C) : les vues du widget « Recherche rapide ». DA : `DESIGN.md` (police système, couleurs
//  sémantiques et accent, grille 4/8/12/16/20, aucun dégradé, aucun emoji, SF Symbols seulement).
//
//  Un widget petit n'a qu'une zone tactile (`widgetURL`) : « Nouvelle question ». Le moyen a deux `Link` :
//  « Reprendre » (la dernière conversation) et « Nouvelle question ». La question affichée est marquée
//  `privacySensitive` : sur l'écran verrouillé, elle est masquée tant que l'appareil n'est pas déverrouillé.
//

import SwiftUI
import WidgetKit

struct QuickSearchWidgetView: View {
    let entry: QuickSearchEntry

    @Environment(\.widgetFamily) private var family

    var body: some View {
        content
            .containerBackground(.fill.tertiary, for: .widget)
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .systemMedium:
            QuickSearchMediumView(content: entry.content)
        #if os(iOS)
        case .accessoryCircular:
            QuickSearchCircularView(content: entry.content)
        case .accessoryRectangular:
            QuickSearchRectangularView(content: entry.content)
        #endif
        default:
            QuickSearchSmallView(content: entry.content)
        }
    }
}

// MARK: - Pièces communes

/// Le geste principal : toujours le même libellé et le même symbole.
private struct NewQuestionLabel: View {
    var body: some View {
        Label("Nouvelle question", systemImage: "square.and.pencil")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.tint)
    }
}

/// « Dernière recherche » + son titre, ou la phrase d'historique vide. Rien pour la vue neutre.
private struct LastSearchText: View {
    let content: QuickSearchContent
    var lineLimit = 3

    var body: some View {
        switch content {
        case .conversation(_, let title):
            VStack(alignment: .leading, spacing: 4) {
                Text("Dernière recherche")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(lineLimit)
                    .privacySensitive()
            }
        case .noHistory:
            Text("Aucune recherche pour l'instant")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        case .neutral:
            EmptyView()
        }
    }
}

// MARK: - Petit

struct QuickSearchSmallView: View {
    let content: QuickSearchContent

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if content == .neutral {
                Image(systemName: "square.and.pencil")
                    .font(.title2)
                    .foregroundStyle(.tint)
                Spacer(minLength: 0)
                Text("Nouvelle question")
                    .font(.headline)
            } else {
                LastSearchText(content: content)
                Spacer(minLength: 0)
                NewQuestionLabel()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .widgetURL(content.newQuestionURL)
    }
}

// MARK: - Moyen

struct QuickSearchMediumView: View {
    let content: QuickSearchContent

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            if case .conversation = content, let resumeURL = content.resumeURL {
                Link(destination: resumeURL) { resumeColumn }
                Divider()
            } else if content == .noHistory {
                LastSearchText(content: content)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                Divider()
            }
            newQuestionColumn
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .widgetURL(content.newQuestionURL)
    }

    private var resumeColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            LastSearchText(content: content, lineLimit: 4)
            Spacer(minLength: 0)
            Label("Reprendre", systemImage: "arrow.uturn.forward")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.tint)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var newQuestionColumn: some View {
        if let url = content.newQuestionURL {
            Link(destination: url) {
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: "square.and.pencil")
                        .font(.title2)
                        .foregroundStyle(.tint)
                    Spacer(minLength: 0)
                    Text("Nouvelle question")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }
}

// MARK: - Écran verrouillé (iOS)

#if os(iOS)
struct QuickSearchCircularView: View {
    let content: QuickSearchContent

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            Image(systemName: "square.and.pencil")
                .font(.title3)
                .widgetAccentable()
        }
        .widgetURL(content.newQuestionURL)
        .accessibilityLabel("Nouvelle question")
    }
}

struct QuickSearchRectangularView: View {
    let content: QuickSearchContent

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Nouvelle question", systemImage: "square.and.pencil")
                .font(.headline)
                .widgetAccentable()
            if let title = content.lastTitle {
                Text(title)
                    .font(.caption)
                    .lineLimit(2)
                    .privacySensitive()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(content.newQuestionURL)
    }
}
#endif
