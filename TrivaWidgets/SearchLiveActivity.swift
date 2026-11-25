//
//  SearchLiveActivity.swift
//  TrivaWidgets
//
//  Chantier 2.1 (mission D) : la présentation de l'activité en direct d'une recherche, sur l'écran verrouillé et dans la
//  Dynamic Island (iPhone et iPad ; ActivityKit n'existe pas sur Mac). L'extension LIT seulement : l'état vient de
//  l'app (`SearchActivityState`). DA : `DESIGN.md` (police système, couleurs sémantiques, SF Symbols, aucun dégradé).
//
//  La question est marquée `privacySensitive` : sur un écran verrouillé, le système la masque tant que l'appareil n'est
//  pas déverrouillé. Le toucher ouvre la conversation (`triva://conversation/<id>`), ou simplement l'app.
//

#if os(iOS)
import ActivityKit
import SwiftUI
import WidgetKit

struct SearchLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SearchActivityAttributes.self) { context in
            SearchActivityLockScreenView(
                question: context.attributes.question,
                state: context.state.displayed(isStale: context.isStale)
            )
            .widgetURL(context.attributes.tapURL)
        } dynamicIsland: { context in
            let state = context.state.displayed(isStale: context.isStale)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: state.symbolName)
                        .font(.title3)
                        .foregroundStyle(.tint)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.question)
                        .font(.subheadline)
                        .lineLimit(2)
                        .privacySensitive()
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(state.statusText)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            } compactLeading: {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.tint)
            } compactTrailing: {
                SearchActivityCompactTrailing(state: state)
            } minimal: {
                Image(systemName: state.symbolName)
                    .foregroundStyle(.tint)
            }
            .widgetURL(context.attributes.tapURL)
        }
    }
}

/// Écran verrouillé et bannière : l'étape, puis la question sur deux lignes au plus.
private struct SearchActivityLockScreenView: View {
    let question: String
    let state: SearchActivityState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(state.statusText, systemImage: state.symbolName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.tint)
            Text(question)
                .font(.callout)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .privacySensitive()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }
}

/// Dynamic Island compacte, côté droit : le nombre de sources lues, ou une coche quand la réponse est prête.
/// Sur iPhone Duo, en paysage ou avec deux activités, la Dynamic Island compacte est plus étroite : la doc Apple demande
/// alors de laisser vide le côté droit (le système le masque), le symbole de gauche suffit.
private struct SearchActivityCompactTrailing: View {
    let state: SearchActivityState

    @Environment(\.isDynamicIslandLimitedInWidth) private var isLimitedInWidth

    var body: some View {
        if !isLimitedInWidth {
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state.stage {
        case .ready:
            Image(systemName: "checkmark")
                .foregroundStyle(.tint)
        case .interrupted, .failed:
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(.secondary)
        default:
            if state.sourceCount > 0 {
                Text("\(state.sourceCount)")
                    .font(.footnote.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.tint)
            } else {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private extension SearchActivityState {
    /// Symbole SF de l'étape (jamais d'emoji : `DESIGN.md`).
    var symbolName: String {
        switch stage {
        case .searching: "magnifyingglass"
        case .reading: "doc.text"
        case .writing: "text.alignleft"
        case .ready: "checkmark.circle"
        case .interrupted, .failed: "exclamationmark.circle"
        }
    }
}
#endif
