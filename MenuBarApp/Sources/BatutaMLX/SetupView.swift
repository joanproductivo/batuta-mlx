import SwiftUI

struct SetupView: View {
    @Bindable var setup: SetupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Instalar el servidor MLX").font(.headline)
                Text("Qwen3.8-27B + speculative decoding, en \(abbreviatedRoot)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if setup.ramTier == .blocked {
                Label {
                    Text(setup.blockReason ?? "Este Mac no puede ejecutar el modelo.")
                        .font(.caption)
                } icon: {
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                }
            } else {
                stepsList

                if !setup.running && !setup.finished {
                    Text("Se descargarán 16,3 GB (10–40 min según la conexión). "
                        + "Todo se instala en tu carpeta de usuario, sin contraseña.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    if setup.running {
                        Button("Cancelar", role: .cancel) { setup.cancel() }
                    } else {
                        Button {
                            setup.install()
                        } label: {
                            Label(hasFailure ? "Reintentar" : "Instalar",
                                  systemImage: "arrow.down.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Spacer()
                    Button("Salir") { NSApp.terminate(nil) }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    private var abbreviatedRoot: String {
        setup.root.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private var hasFailure: Bool {
        setup.steps.contains { if case .failed = $0.state { return true } else { return false } }
    }

    private var stepsList: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(setup.steps) { step in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    stepIcon(step.state)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(step.title).font(.caption)
                        if step.id == 3, setup.running,
                           let f = setup.downloadFraction {
                            ProgressView(value: f)
                                .controlSize(.small)
                            Text(setup.downloadDetail)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        } else if !step.detail.isEmpty {
                            Text(step.detail)
                                .font(.system(size: 10))
                                .foregroundStyle(detailColor(step.state))
                                .lineLimit(2)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func stepIcon(_ state: SetupStepState) -> some View {
        switch state {
        case .pending:
            Image(systemName: "circle").foregroundStyle(.tertiary)
        case .running:
            ProgressView().controlSize(.mini)
        case .ok:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }

    private func detailColor(_ state: SetupStepState) -> Color {
        if case .failed = state { return .red }
        return .secondary
    }
}
