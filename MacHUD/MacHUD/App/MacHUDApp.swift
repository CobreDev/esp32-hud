import SwiftUI

@main
struct MacHUDApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environmentObject(state)
        } label: {
            Image(systemName: menuBarSymbol)
        }
        .menuBarExtraStyle(.window)
    }

    private var menuBarSymbol: String {
        switch state.linkStatus {
        case .connected: return state.hudEnabled ? "circle.inset.filled" : "circle"
        case .released: return "circle.slash"
        default: return "circle.dotted"
        }
    }
}
