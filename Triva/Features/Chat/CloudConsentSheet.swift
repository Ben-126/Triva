//
//  CloudConsentSheet.swift
//  Triva
//
//  Created by ben podrojsky on 14/11/2026.
//

import SwiftUI

/// Feuille de consentement avant le premier envoi à une IA cloud (mission C2, App Store 5.1.2(i)).
/// Textes : `CloudAIConsentText` (`textes/ecrans.md` section A). « Annuler » est l'action
/// d'annulation (Échap sur Mac) ; rien n'est envoyé tant que « Autoriser » n'a pas été touché.
/// iPhone, iPad et Mac : le contenu défile (Dynamic Type), les deux boutons restent en bas.
struct CloudConsentSheet: View {
    let request: CloudAIConsentRequest
    let onAllow: () -> Void
    let onCancel: () -> Void

    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(CloudAIConsentText.title(request))
                        .font(.title2.bold())
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("consent.title")

                    Text(CloudAIConsentText.intro(request))

                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(CloudAIConsentText.items, id: \.self) { item in
                            Label {
                                Text(item)
                            } icon: {
                                Image(systemName: "circle.fill").font(.system(size: 5)).padding(.top, 7)
                            }
                            .labelStyle(.titleAndIcon)
                        }
                    }
                    .padding(.leading, 4)

                    ForEach(request.extras, id: \.self) { extra in
                        Text(CloudAIConsentText.extra(extra, request))
                            .foregroundStyle(.secondary)
                    }

                    Text(CloudAIConsentText.direct(request))
                    Text(CloudAIConsentText.terms(request))
                    links
                    Text(CloudAIConsentText.minor).foregroundStyle(.secondary)
                    Text(CloudAIConsentText.revoke).foregroundStyle(.secondary)
                }
                .font(.body)
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { buttons }
            .navigationBarTitleDisplayModeInline()
        }
        .interactiveDismissDisabled()
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 520, minHeight: 520, idealHeight: 600)
        #endif
    }

    @ViewBuilder private var links: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let privacy = request.privacyURL {
                Link(CloudAIConsentText.privacyLink(request), destination: privacy)
                    .accessibilityIdentifier("consent.privacyLink")
            } else {
                Text(CloudAIConsentText.noLink(request)).foregroundStyle(.secondary)
            }
            if let terms = request.termsURL {
                Link(CloudAIConsentText.termsLink, destination: terms)
            }
        }
    }

    private var buttons: some View {
        VStack(spacing: 8) {
            Button(action: onAllow) {
                Text(CloudAIConsentText.allow).frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .accessibilityIdentifier("consent.allow")

            Button(action: onCancel) {
                Text(CloudAIConsentText.cancel).frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier("consent.cancel")
        }
        .controlSize(.large)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }
}

private extension View {
    /// Titre de barre en ligne sur iOS ; sans objet sur Mac.
    @ViewBuilder func navigationBarTitleDisplayModeInline() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}

#Preview {
    CloudConsentSheet(
        request: CloudAIConsentCatalog.request(providerID: "gemini", customPresets: [])!,
        onAllow: {},
        onCancel: {}
    )
}
