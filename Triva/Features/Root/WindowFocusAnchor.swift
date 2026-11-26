//
//  WindowFocusAnchor.swift
//  Triva
//
//  Mission F3 : ramener une fenêtre de recherche au premier plan (Mac, iPad).
//

import SwiftUI
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

/// Poignée sur la fenêtre système qui héberge une coquille de recherche : sait la ramener devant.
///
/// Une valeur de scène identique est déjà ramenée par le système (`openWindow(value:)`), mais pas la fenêtre dont
/// une réponse écrit encore dans une conversation qu'elle n'affiche plus : le registre des fenêtres
/// (`WindowConversationRegistry.focusHolder`) appelle donc cette poignée directement.
///
/// - Mac : `NSWindow.makeKeyAndOrderFront`, fenêtre rangée dans le Dock rouverte au passage.
/// - iPad : `UIApplication.activateSceneSession(for:)` sur la session de la scène de la vue.
@MainActor
final class WindowFocusHandle {
    #if os(macOS)
    fileprivate weak var window: NSWindow?
    #elseif os(iOS)
    fileprivate weak var sceneSession: UISceneSession?
    #endif

    /// La fenêtre (ou la scène) est-elle devant, celle que l'utilisateur utilise ? Mac : fenêtre clé ; iPhone et iPad : scène active
    /// au premier plan. `false` si elle n'est pas connue. Sert à Handoff (chantier 2.3) : où poser la discussion reçue.
    var isForeground: Bool {
        #if os(macOS)
        return window?.isKeyWindow ?? false
        #elseif os(iOS)
        return sceneSession?.scene?.activationState == .foregroundActive
        #else
        return false
        #endif
    }

    /// - Returns: `false` si la fenêtre système n'est pas (ou plus) connue : rien n'a été ramené.
    @discardableResult
    func bringToFront() -> Bool {
        #if os(macOS)
        guard let window else { return false }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        return true
        #elseif os(iOS)
        guard let sceneSession else { return false }
        UIApplication.shared.activateSceneSession(for: UISceneSessionActivationRequest(session: sceneSession))
        return true
        #else
        return false
        #endif
    }
}

extension View {
    /// Renseigne `handle` avec la fenêtre (ou la scène) qui héberge cette vue.
    func anchorsWindowFocus(_ handle: WindowFocusHandle) -> some View {
        background(WindowFocusAnchor(handle: handle).frame(width: 0, height: 0).accessibilityHidden(true))
    }
}

#if os(macOS)
private struct WindowFocusAnchor: NSViewRepresentable {
    let handle: WindowFocusHandle

    func makeNSView(context: Context) -> AnchorView {
        AnchorView(handle: handle)
    }

    func updateNSView(_ nsView: AnchorView, context: Context) {
        nsView.handle = handle
        nsView.handle.window = nsView.window
    }

    final class AnchorView: NSView {
        var handle: WindowFocusHandle

        init(handle: WindowFocusHandle) {
            self.handle = handle
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            handle.window = window
        }
    }
}
#elseif os(iOS)
private struct WindowFocusAnchor: UIViewRepresentable {
    let handle: WindowFocusHandle

    func makeUIView(context: Context) -> AnchorView {
        AnchorView(handle: handle)
    }

    func updateUIView(_ uiView: AnchorView, context: Context) {
        uiView.handle = handle
        uiView.handle.sceneSession = uiView.window?.windowScene?.session
    }

    final class AnchorView: UIView {
        var handle: WindowFocusHandle

        init(handle: WindowFocusHandle) {
            self.handle = handle
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            handle.sceneSession = window?.windowScene?.session
        }
    }
}
#endif
