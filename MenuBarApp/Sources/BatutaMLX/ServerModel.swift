import AppKit
import Foundation
import Observation
import ServiceManagement

// MARK: - Payloads del servidor (solo los campos que usamos)

struct MetricsLatest: Decodable {
    var decodeTokS: Double?
    var prefillTokS: Double?
    var ttftS: Double?
    var promptTokens: Int?
    var generatedTokens: Int?

    enum CodingKeys: String, CodingKey {
        case decodeTokS = "decode_tok_s"
        case prefillTokS = "prefill_tok_s"
        case ttftS = "ttft_s"
        case promptTokens = "prompt_tokens"
        case generatedTokens = "generated_tokens"
    }
}

struct MetricsSummary: Decodable {
    var inFlight: Int

    enum CodingKeys: String, CodingKey {
        case inFlight = "in_flight"
    }
}

struct MetricsServerInfo: Decodable {
    var loadedModel: String?
    var effectiveContextLimit: Int?

    enum CodingKeys: String, CodingKey {
        case loadedModel = "loaded_model"
        case effectiveContextLimit = "effective_context_limit"
    }
}

struct MetricsEnvelope: Decodable {
    var latest: MetricsLatest?
    var recent: [MetricsLatest]
    var summary: MetricsSummary
    var server: MetricsServerInfo
}

// MARK: - Estado

enum ServerState: Equatable {
    case stopped        // conexión rechazada Y sin proceso mlx_vlm.server
    case starting       // proceso vivo pero /metrics aún no responde, o `mlx start` en curso
    case runningIdle    // /metrics OK, in_flight == 0
    case runningBusy(Int) // /metrics OK, in_flight > 0
    case unresponsive   // timeout con proceso vivo
    case stopping       // orden de parada enviada

    var isTransition: Bool {
        self == .starting || self == .stopping
    }
}

// MARK: - Modelo

@Observable
@MainActor
final class ServerModel {
    // Estado publicado
    var state: ServerState = .stopped
    var latest: MetricsLatest?
    var recentSpeeds: [Double] = []
    var modelName: String?
    var contextLimit: Int?
    var lastError: String?
    var panelOpen = false
    /// RSS del proceso del servidor en GiB (nil si está parado).
    var serverMemoryGB: Double?
    /// Estado real del login item de macOS (SMAppService).
    var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled
    /// Arrancar el servidor automáticamente al abrir la app.
    var autoStartServer: Bool {
        didSet { UserDefaults.standard.set(autoStartServer, forKey: Self.autoStartKey) }
    }
    /// Peticiones simultáneas máximas (0 = sin límite). No es un knob en caliente
    /// del servidor (va por env MLX_VLM_MAX_NUM_SEQS) → se aplica al (re)arrancar.
    var desiredMaxSeqs: Int {
        didSet { UserDefaults.standard.set(desiredMaxSeqs, forKey: Self.maxSeqsKey) }
    }
    /// Razonamiento (thinking) por defecto del servidor. Igual que MAXSEQS: va por
    /// env al arrancar; cada petición puede anularlo con `enable_thinking`.
    var thinkingEnabled: Bool {
        didSet { UserDefaults.standard.set(thinkingEnabled, forKey: Self.thinkingKey) }
    }
    /// Raíz de la instalación detectada (nil = sin instalar → asistente).
    var installRoot: String?
    var installed: Bool { installRoot != nil }

    // Contexto elegido por el usuario (tokens); persiste entre sesiones.
    var desiredContext: Int {
        didSet { UserDefaults.standard.set(desiredContext, forKey: Self.contextKey) }
    }

    /// Ventanas de contexto que caben en ESTE Mac. La lista se deriva de la RAM en
    /// vez de ser fija: 262k pide ~17 GB de caché KV y solo tiene sentido en Macs
    /// grandes, pero excluirlo siempre penalizaba a quien tiene 64 o 128 GB.
    let contextOptions: [Int]
    static let maxSeqsOptions = [0, 1, 2, 4]

    /// Pesos del stack (modelo 4-bit + drafter MTP), medidos.
    private static let weightsBytes = 16_000_000_000.0
    /// Caché KV por token: solo 16 de las 64 capas son de atención completa; el
    /// resto son lineales con estado fijo. Medido: ~64 KB/token.
    private static let kvBytesPerToken = 65_536.0

    static func kvBytes(forContext tokens: Int) -> Double {
        Double(tokens) * kvBytesPerToken
    }

    /// Una ventana cabe si pesos + KV entran en el presupuesto que la GPU puede
    /// tener «wired» (~3/4 de la RAM por defecto en Apple Silicon; subirlo exige
    /// sudo, así que se asume el valor de fábrica).
    static func contextOptions(forPhysicalMemory bytes: UInt64) -> [Int] {
        let budget = Double(bytes) * 0.75 - weightsBytes
        let all = [32_768, 65_536, 95_536, 131_072, 262_144]
        let fitting = all.filter { kvBytes(forContext: $0) <= budget }
        return fitting.isEmpty ? [all[0]] : fitting
    }
    private static let contextKey = "desiredContextTokens"
    private static let scriptKey = "mlxScriptPath"
    private static let autoStartKey = "autoStartServer"
    private static let maxSeqsKey = "desiredMaxSeqs"
    private static let thinkingKey = "thinkingEnabled"
    private static let rootOverrideKey = "installRootOverride"
    /// Instalación original de este Mac (nivel 2 de la resolución).
    /// Instalaciones anteriores a `~/MLXServer` (repo clonado a mano). Se migran
    /// escribiendo la clave la primera vez que se encuentran.
    private static var legacyScriptPaths: [String] {
        ["/IA/MLX-VLM-IA/mlx", "/MLX-VLM-IA/mlx"].map { NSHomeDirectory() + $0 }
    }
    /// Raíz por defecto para instalaciones nuevas (independiente del usuario).
    static var defaultRootPath: String { NSHomeDirectory() + "/MLXServer" }

    private let baseURL = URL(string: "http://127.0.0.1:8080")!
    private let session: URLSession

    /// Dirección que debe pegarse en cualquier cliente compatible con OpenAI.
    var apiBaseURL: String { baseURL.appendingPathComponent("v1").absoluteString }

    /// Ruta del script de control de la instalación activa.
    private var scriptPath: String { (installRoot ?? Self.defaultRootPath) + "/mlx" }

    init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 2
        cfg.timeoutIntervalForResource = 4
        session = URLSession(configuration: cfg)
        let options = Self.contextOptions(
            forPhysicalMemory: ProcessInfo.processInfo.physicalMemory)
        contextOptions = options
        // El valor guardado puede no estar ofrecido (p. ej. la app viaja a un Mac
        // con menos memoria): cae al mayor que quepa sin pasar del defecto.
        let saved = UserDefaults.standard.integer(forKey: Self.contextKey)
        desiredContext = options.contains(saved)
            ? saved
            : (options.last { $0 <= 95_536 } ?? options[0])
        autoStartServer = UserDefaults.standard.bool(forKey: Self.autoStartKey)
        let seqs = UserDefaults.standard.integer(forKey: Self.maxSeqsKey)
        desiredMaxSeqs = Self.maxSeqsOptions.contains(seqs) ? seqs : 0
        // Por defecto activado: es el comportamiento validado del stack.
        thinkingEnabled = UserDefaults.standard.object(forKey: Self.thinkingKey) as? Bool ?? true
        resolveInstallation()
        Task { await pollLoop() }
    }

    // MARK: Detección de instalación (4 niveles — hallazgo 1 de la auditoría del plan:
    // la clave de UserDefaults no existía, así que la ruta legacy es un nivel propio
    // con migración explícita, no un fallback implícito)

    /// Una instalación es completa si tiene el marcador final (`mlx`), `serve.sh`
    /// y el venv con el servidor (hallazgo 9: evitar el falso «instalado»).
    private static func installationComplete(at root: String) -> Bool {
        let fm = FileManager.default
        return fm.isExecutableFile(atPath: root + "/mlx")
            && fm.fileExists(atPath: root + "/serve.sh")
            && fm.fileExists(atPath: root + "/.venv/bin/mlx_vlm.server")
    }

    func resolveInstallation() {
        let fm = FileManager.default
        // Nivel 0 (pruebas/simulacros): override por argument domain, no persiste.
        if let override = UserDefaults.standard.string(forKey: Self.rootOverrideKey) {
            installRoot = Self.installationComplete(at: override) ? override : nil
            return
        }
        // Nivel 1: clave persistida.
        if let p = UserDefaults.standard.string(forKey: Self.scriptKey),
           fm.isExecutableFile(atPath: p) {
            installRoot = (p as NSString).deletingLastPathComponent
            return
        }
        // Nivel 2: instalación legacy de este Mac → migrar la clave.
        if let legacy = Self.legacyScriptPaths.first(where: fm.isExecutableFile(atPath:)) {
            UserDefaults.standard.set(legacy, forKey: Self.scriptKey)
            installRoot = (legacy as NSString).deletingLastPathComponent
            return
        }
        // Nivel 3: instalación estándar nueva.
        if Self.installationComplete(at: Self.defaultRootPath) {
            UserDefaults.standard.set(Self.defaultRootPath + "/mlx", forKey: Self.scriptKey)
            installRoot = Self.defaultRootPath
            return
        }
        installRoot = nil
    }

    // MARK: Sondeo

    /// true mientras `start()`/`stop()` (iniciados POR LA APP) están en curso.
    /// Es el único guard del sondeo: un `.starting` impuesto por un arranque
    /// externo NO detiene el bucle, así que se reintenta solo (sin forcePoll)
    /// y no existe el estado-trampa que encontró el verificador de lógica.
    private var appDrivenTransition = false

    func pollLoop() async {
        await pollOnce()
        // Auto-arranque: una sola vez, tras conocer el estado real inicial.
        if autoStartServer && state == .stopped { start() }
        while !Task.isCancelled {
            let interval: UInt64 = panelOpen ? 1_000_000_000 : 3_000_000_000
            try? await Task.sleep(nanoseconds: interval)
            await pollOnce()
        }
    }

    private func pollOnce() async {
        if appDrivenTransition { return }
        do {
            let (data, _) = try await session.data(
                from: baseURL.appendingPathComponent("metrics"))
            // Re-comprobar tras la suspensión: si el usuario pulsó Arrancar/Parar
            // mientras la petición volaba, esta muestra ya es obsoleta (carrera
            // H1 del verificador de invariantes — no pisar la transición).
            if appDrivenTransition { return }
            let env = try JSONDecoder().decode(MetricsEnvelope.self, from: data)
            apply(env)
            await reconcileContext(current: env.server.effectiveContextLimit)
            await sampleMemory()
        } catch {
            await classifyFailure(error)
        }
    }

    private func apply(_ env: MetricsEnvelope) {
        latest = env.latest
        recentSpeeds = env.recent.compactMap(\.decodeTokS)
        modelName = env.server.loadedModel
        contextLimit = env.server.effectiveContextLimit
        state = env.summary.inFlight > 0
            ? .runningBusy(env.summary.inFlight) : .runningIdle
    }

    /// Hallazgo 2 de la auditoría del plan: «parado» exige conexión RECHAZADA y
    /// ausencia de proceso, las dos cosas. Un timeout jamás habilita Arrancar:
    /// ni con proceso vivo (servidor saturado) ni sin él (otro servicio dueño
    /// del puerto 8080 — arrancar ahí cargaría 15,7 GB para morir en el bind).
    private func classifyFailure(_ error: Error) async {
        let refused = (error as? URLError)?.code == .cannotConnectToHost
        let processAlive = await Self.serverProcessAlive()
        // Re-comprobación post-suspensión (carrera H1): la transición manda.
        if appDrivenTransition { return }

        if refused && !processAlive {
            state = .stopped
            serverMemoryGB = nil
            cachedPID = nil
        } else if refused && processAlive {
            // El servidor carga el modelo ANTES de abrir el puerto (uvicorn:
            // lifespan antes del bind) — arranque en curso, aunque lo haya
            // lanzado otro (Terminal). El bucle de sondeo sigue reintentando.
            state = .starting
        } else {
            state = .unresponsive
        }
    }

    // MARK: Memoria del servidor (RSS vía ps, con PID cacheado)

    private var cachedPID: String?

    private func sampleMemory() async {
        if let pid = cachedPID {
            if await readRSS(pid: pid) { return }
            cachedPID = nil
        }
        let pg = await Self.runCommand("/usr/bin/pgrep", ["-f", "mlx_vlm.server"])
        guard pg.code == 0,
              let first = pg.output.split(separator: "\n").first
        else {
            serverMemoryGB = nil
            return
        }
        cachedPID = String(first)
        _ = await readRSS(pid: cachedPID!)
    }

    private func readRSS(pid: String) async -> Bool {
        let r = await Self.runCommand("/bin/ps", ["-o", "rss=", "-p", pid])
        guard r.code == 0,
              let kb = Double(r.output.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return false }
        serverMemoryGB = kb / 1_048_576 // KiB → GiB
        return true
    }

    // MARK: Login item + auto-arranque + log

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = enabled
        } catch {
            lastError = "Inicio de sesión: \(error.localizedDescription)"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    func openLog() {
        let dir = (scriptPath as NSString).deletingLastPathComponent
        NSWorkspace.shared.open(URL(fileURLWithPath: dir + "/server.log"))
    }

    // MARK: Reconciliación del contexto (hallazgo 3: en cada sondeo, no por transición)

    private var reconciling = false

    private func reconcileContext(current: Int?) async {
        guard let current, current != desiredContext, !reconciling else { return }
        reconciling = true
        defer { reconciling = false }
        await patchContext(desiredContext, persistOnSuccess: false)
    }

    func setContext(_ tokens: Int) async {
        await patchContext(tokens, persistOnSuccess: true)
    }

    /// PATCH /v1/settings — verificado en vivo: cambia el límite sin recargar el
    /// modelo y solo afecta a la admisión de peticiones nuevas.
    private func patchContext(_ tokens: Int, persistOnSuccess: Bool) async {
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/settings"))
        req.httpMethod = "PATCH"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["max_kv_size": tokens])
        do {
            let (data, _) = try await session.data(for: req)
            let resp = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let applied = resp?["applied"] as? [String: Any] ?? [:]
            if applied["max_kv_size"] != nil {
                contextLimit = tokens
                if persistOnSuccess { desiredContext = tokens }
            } else {
                lastError = "El servidor rechazó el cambio de contexto."
            }
        } catch {
            // Servidor inalcanzable. Desviación deliberada de la letra del plan
            // («persistir solo con applied»): guardamos la ELECCIÓN igualmente
            // para que la reconciliación la aplique al volver el servidor, y se
            // lo decimos al usuario en vez de fallar en silencio.
            if persistOnSuccess {
                desiredContext = tokens
                lastError = "Servidor parado: el contexto se aplicará al arrancar."
            }
        }
    }

    // MARK: Arrancar / Parar (delegado en ./mlx — una sola fuente de verdad)

    func start() {
        guard state == .stopped, !appDrivenTransition, installed else { return }
        appDrivenTransition = true
        state = .starting
        lastError = nil
        let script = scriptPath
        // MAXSEQS y THINKING no son knobs en caliente: serve.sh los lee del
        // entorno al arrancar.
        var env: [String: String] = ["THINKING": thinkingEnabled ? "1" : "0"]
        if desiredMaxSeqs > 0 { env["MAXSEQS"] = String(desiredMaxSeqs) }
        Task.detached { [weak self] in
            let result = await Self.runCommand(script, ["start"], env: env)
            await self?.finishStart(result)
        }
    }

    private func finishStart(_ result: (code: Int32, output: String)) async {
        if result.code == 0 {
            // PATCH inmediato tras el arranque (hallazgo 4), antes de declarar estado.
            await patchContext(desiredContext, persistOnSuccess: false)
        } else {
            lastError = Self.diagnoseStartFailure(result.output, code: result.code)
        }
        appDrivenTransition = false
        await pollOnce() // fija el estado real (en marcha, o parado si falló)
    }

    func stop() {
        guard state != .stopped, !state.isTransition, !appDrivenTransition else { return }
        appDrivenTransition = true
        state = .stopping
        lastError = nil
        let script = scriptPath
        Task.detached { [weak self] in
            let result = await Self.runCommand(script, ["stop"])
            await self?.finishStop(result)
        }
    }

    private func finishStop(_ result: (code: Int32, output: String)) async {
        if result.code != 0 {
            let line = Self.stripANSI(result.output)
                .split(separator: "\n").last.map(String.init) ?? "No se pudo parar."
            lastError = "\(line) (exit \(result.code))"
        }
        appDrivenTransition = false
        await pollOnce()
    }

    /// Hallazgo 9: el script emite ANSI; se limpia y se prioriza un mensaje útil.
    private static func diagnoseStartFailure(_ raw: String, code: Int32) -> String {
        let clean = stripANSI(raw)
        let lines = clean.split(separator: "\n").map(String.init)
        if let hint = lines.first(where: {
            $0.localizedCaseInsensitiveContains("error")
                || $0.localizedCaseInsensitiveContains("murió")
                || $0.localizedCaseInsensitiveContains("timeout")
        }) {
            return "\(hint) (exit \(code))"
        }
        return lines.last.map { "\($0) (exit \(code))" }
            ?? "El arranque falló (exit \(code)); mira server.log en el proyecto."
    }

    static func stripANSI(_ s: String) -> String {
        s.replacingOccurrences(
            of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
    }

    // MARK: Utilidades de proceso (fuera del MainActor — hallazgo 10)

    nonisolated static func runCommand(
        _ path: String, _ args: [String], env: [String: String] = [:]
    ) async -> (code: Int32, output: String) {
        await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            if !env.isEmpty {
                p.environment = ProcessInfo.processInfo.environment
                    .merging(env) { _, new in new }
            }
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            do {
                try p.run()
            } catch {
                return (Int32(127), error.localizedDescription)
            }
            // Drenar ANTES de esperar la terminación: esperar primero es el
            // interbloqueo clásico si el hijo llena el búfer del pipe (hallazgo
            // H2 del verificador). EOF llega al salir `mlx` — el servidor va
            // con nohup redirigido a server.log y no hereda este pipe.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        }.value
    }

    nonisolated static func serverProcessAlive() async -> Bool {
        let r = await runCommand("/usr/bin/pgrep", ["-f", "mlx_vlm.server"])
        return r.code == 0
    }
}
