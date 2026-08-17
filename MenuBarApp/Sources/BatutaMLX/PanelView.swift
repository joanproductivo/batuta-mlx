import SwiftUI

struct PanelView: View {
    @Bindable var model: ServerModel
    @Bindable var chat: ChatModel
    var setup: SetupModel
    @State private var showChat = false
    @State private var showSettings = false

    var body: some View {
        if model.installed {
            installedBody
        } else {
            SetupView(setup: setup)
        }
    }

    private var installedBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            latestRequest
            sparkline
            Divider()
            connectionInfo
            Divider()
            contextPicker
            Divider()
            chatSection
            settingsSection
            if let err = model.lastError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }
            Divider()
            actions
        }
        .padding(14)
        .frame(width: 300)
        .onAppear { model.panelOpen = true }
        .onDisappear { model.panelOpen = false }
    }

    // MARK: Chat de prueba

    private var serverIsRunning: Bool {
        if case .runningIdle = model.state { return true }
        if case .runningBusy = model.state { return true }
        return false
    }

    @ViewBuilder
    private var chatSection: some View {
        DisclosureGroup(isExpanded: $showChat) {
            ChatView(
                chat: chat,
                modelName: model.modelName ?? "mlx-community/Qwen3.8-27B-4bit",
                serverRunning: serverIsRunning)
        } label: {
            Label("Probar el modelo", systemImage: "message")
                .font(.caption)
        }
    }

    // MARK: Ajustes

    @ViewBuilder
    private var settingsSection: some View {
        DisclosureGroup(isExpanded: $showSettings) {
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Abrir Batuta al iniciar sesión", isOn: loginBinding)
                Toggle("Arrancar el servidor al abrir la app", isOn: $model.autoStartServer)
                Toggle("Razonamiento (thinking) por defecto", isOn: $model.thinkingEnabled)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Peticiones simultáneas")
                        .foregroundStyle(.secondary)
                    Picker("Peticiones simultáneas", selection: $model.desiredMaxSeqs) {
                        ForEach(ServerModel.maxSeqsOptions, id: \.self) { opt in
                            Text(opt == 0 ? "Sin límite" : "\(opt)").tag(opt)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    // Ni MAXSEQS ni THINKING son knobs en caliente: van por env al arrancar.
                    Text("Razonamiento y peticiones se aplican al (re)arrancar el servidor.")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .padding(.top, 2)
                Button {
                    model.openLog()
                } label: {
                    Label("Ver log del servidor", systemImage: "doc.text.magnifyingglass")
                }
                .buttonStyle(.link)
            }
            .font(.caption)
            .toggleStyle(.checkbox)
            .padding(.top, 4)
        } label: {
            Label("Ajustes", systemImage: "gearshape")
                .font(.caption)
        }
    }

    private var loginBinding: Binding<Bool> {
        Binding(
            get: { model.launchAtLogin },
            set: { model.setLaunchAtLogin($0) }
        )
    }

    // MARK: Cabecera

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(stateColor)
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(stateText).font(.headline)
                if let name = model.modelName {
                    Text(shortModelName(name))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if let ctx = model.contextLimit {
                    Text("\(ctx / 1000)k ctx")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if let mem = model.serverMemoryGB {
                    Text(String(format: "%.1f GB", mem))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var stateColor: Color {
        switch model.state {
        case .stopped: .gray
        case .starting, .stopping: .yellow
        case .runningIdle: .green
        case .runningBusy: .blue
        case .unresponsive: .orange
        }
    }

    private var stateText: String {
        switch model.state {
        case .stopped: "Parado"
        case .starting: "Arrancando…"
        case .stopping: "Parando…"
        case .runningIdle: "En marcha"
        case .runningBusy(let n): n == 1 ? "En uso (1 petición)" : "En uso (\(n) peticiones)"
        case .unresponsive: "No responde"
        }
    }

    private func shortModelName(_ full: String) -> String {
        full.split(separator: "/").last.map(String.init) ?? full
    }

    // MARK: Última petición

    @ViewBuilder
    private var latestRequest: some View {
        if let l = model.latest, let decode = l.decodeTokS {
            VStack(alignment: .leading, spacing: 6) {
                Text("Última petición")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(String(format: "%.1f", decode))
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("tok/s").foregroundStyle(.secondary)
                    Spacer()
                }
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 2) {
                    GridRow {
                        stat("prefill", l.prefillTokS.map { String(format: "%.0f tok/s", $0) })
                        stat("ttft", l.ttftS.map { String(format: "%.2f s", $0) })
                    }
                    GridRow {
                        stat("entrada", l.promptTokens.map { "\($0) tok" })
                        stat("salida", l.generatedTokens.map { "\($0) tok" })
                    }
                }
            }
        } else {
            Text("Sin peticiones todavía")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func stat(_ label: String, _ value: String?) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.secondary)
            Text(value ?? "—").monospacedDigit()
        }
        .font(.caption)
    }

    // MARK: Mini-gráfica (máx. 32 puntos — la API no expone más)

    @ViewBuilder
    private var sparkline: some View {
        if model.recentSpeeds.count >= 2 {
            let speeds = model.recentSpeeds
            let maxV = max(speeds.max() ?? 1, 1)
            Canvas { ctx, size in
                var path = Path()
                let step = size.width / CGFloat(speeds.count - 1)
                for (i, v) in speeds.enumerated() {
                    let x = CGFloat(i) * step
                    let y = size.height - (CGFloat(v / maxV) * size.height * 0.9)
                    if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                    else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
                ctx.stroke(path, with: .color(.accentColor), lineWidth: 1.5)
            }
            .frame(height: 36)
            .overlay(alignment: .topTrailing) {
                Text(String(format: "máx %.0f", maxV))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: Conexión (dirección + modelo para pegar en otros clientes)

    @State private var copiedField: String?

    private var connectionInfo: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Conexión (API compatible OpenAI)")
                .font(.caption)
                .foregroundStyle(.secondary)
            copyRow(id: "url", value: model.apiBaseURL,
                    help: "Copiar la dirección del servidor")
            copyRow(id: "model",
                    value: model.modelName ?? "mlx-community/Qwen3.8-27B-4bit",
                    help: "Copiar el nombre del modelo")
        }
    }

    private func copyRow(id: String, value: String, help: String) -> some View {
        HStack(spacing: 6) {
            Text(value)
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
                copiedField = id
                Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    if copiedField == id { copiedField = nil }
                }
            } label: {
                Image(systemName: copiedField == id ? "checkmark" : "doc.on.doc")
                    .foregroundStyle(copiedField == id ? .green : .secondary)
            }
            .buttonStyle(.plain)
            .help(help)
        }
    }

    // MARK: Contexto

    private var contextPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Ventana de contexto")
                    .foregroundStyle(.secondary)
                Spacer()
                // El coste de memoria de la opción elegida, para que la decisión
                // se tome con el dato delante.
                Text(String(format: "caché KV ≈ %.1f GB",
                            ServerModel.kvBytes(forContext: model.desiredContext) / 1e9))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            .font(.caption)
            Picker("Contexto", selection: contextBinding) {
                // Solo las ventanas que caben en este Mac (derivadas de la RAM).
                ForEach(model.contextOptions, id: \.self) { opt in
                    Text("\(opt / 1000)k").tag(opt)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private var contextBinding: Binding<Int> {
        Binding(
            get: { model.desiredContext },
            set: { newValue in Task { await model.setContext(newValue) } }
        )
    }

    // MARK: Acciones

    private var actions: some View {
        HStack {
            switch model.state {
            case .stopped:
                Button {
                    model.start()
                } label: {
                    Label("Arrancar", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
            case .starting, .stopping:
                ProgressView().controlSize(.small)
                Text(model.state == .starting ? "Cargando el modelo…" : "Parando…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            default:
                // Parar interrumpe peticiones en curso (pkill): rol destructivo
                // y etiqueta explícita cuando hay trabajo en vuelo (hallazgo H4).
                Button(role: .destructive) {
                    model.stop()
                } label: {
                    if case .runningBusy(let n) = model.state {
                        Label("Parar (\(n) en curso)", systemImage: "stop.fill")
                    } else {
                        Label("Parar", systemImage: "stop.fill")
                    }
                }
            }
            Spacer()
            Button("Salir") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Chat de prueba

struct ChatView: View {
    @Bindable var chat: ChatModel
    var modelName: String
    var serverRunning: Bool

    var body: some View {
        VStack(spacing: 6) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        if chat.messages.isEmpty {
                            Text(serverRunning
                                ? "Escribe abajo para probar el modelo."
                                : "Arranca el servidor para poder chatear.")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        ForEach(chat.messages) { m in
                            bubble(m)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
                .frame(height: 200)
                .onChange(of: chat.messages) {
                    if let last = chat.messages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            if let e = chat.error {
                Text(e)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
            HStack(spacing: 6) {
                TextField("Escribe un mensaje…", text: $chat.input)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .onSubmit { chat.send(modelName: modelName) }
                if chat.isGenerating {
                    Button {
                        chat.cancel()
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .help("Detener la generación")
                } else {
                    Button {
                        chat.send(modelName: modelName)
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .disabled(chat.input.trimmingCharacters(in: .whitespaces).isEmpty
                              || !serverRunning)
                    .help("Enviar")
                }
                Button {
                    chat.clear()
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(chat.messages.isEmpty)
                .help("Vaciar la conversación")
            }
        }
    }

    @ViewBuilder
    private func bubble(_ m: ChatMessage) -> some View {
        HStack {
            if m.role == .user { Spacer(minLength: 30) }
            Text(m.text.isEmpty && m.role == .assistant ? "…" : m.text)
                .font(.caption)
                .textSelection(.enabled)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    m.role == .user
                        ? AnyShapeStyle(Color.accentColor.opacity(0.25))
                        : AnyShapeStyle(.quaternary),
                    in: RoundedRectangle(cornerRadius: 8))
            if m.role == .assistant { Spacer(minLength: 30) }
        }
        .id(m.id)
    }
}
