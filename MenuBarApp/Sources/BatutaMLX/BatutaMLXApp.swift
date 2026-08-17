import SwiftUI

@main
struct BatutaMLXApp: App {
    // SIN valor por defecto: un inicializador aquí correría ANTES del init() y
    // crearía un segundo ServerModel huérfano cuyo pollLoop se auto-retiene
    // (GRAVE-1 de los verificadores: zombi sondeando + doble auto-arranque).
    @State private var model: ServerModel
    // El chat y el asistente viven aquí (no en el panel) para que sobrevivan
    // a abrir/cerrar el MenuBarExtra.
    @State private var chat = ChatModel()
    @State private var setup: SetupModel

    init() {
        let m = ServerModel()
        _model = State(initialValue: m)
        _setup = State(initialValue: SetupModel(server: m))
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: model, chat: chat, setup: setup)
        } label: {
            // Una única Image parametrizada: mantiene la identidad de la vista
            // entre cambios de estado (hallazgo 13 de la auditoría).
            Image(systemName: symbolName)
        }
        .menuBarExtraStyle(.window)
    }

    private var symbolName: String {
        switch model.state {
        case .stopped: "brain"
        case .starting, .stopping: "hourglass"
        case .runningIdle: "brain.fill"
        case .runningBusy: "bolt.fill" // distinto y llamativo mientras genera
        case .unresponsive: "questionmark.circle"
        }
    }
}
