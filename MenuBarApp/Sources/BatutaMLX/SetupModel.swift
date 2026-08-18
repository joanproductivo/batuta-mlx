import Foundation
import Observation

enum SetupStepState: Equatable {
    case pending, running, ok
    case failed(String)
}

struct SetupStep: Identifiable {
    let id: Int
    let title: String
    var state: SetupStepState = .pending
    var detail: String = ""
}

enum RamTier {
    case blocked   // < 32 GB: el límite wired de GPU no admite ni los pesos
    case reduced   // 32 GB: viable con contexto 32k
    case full      // ≥ 36 GB: stack completo (ctx 95k)
}

/// Motor del asistente de instalación. Idempotente y cancelable (SIGINT, para que
/// el `finally` de huggingface_hub limpie sus temporales — hallazgo 2 del plan).
@Observable
@MainActor
final class SetupModel {
    var steps: [SetupStep] = [
        .init(id: 0, title: "Comprobar este Mac"),
        .init(id: 1, title: "Herramienta de entornos (uv)"),
        .init(id: 2, title: "Entorno Python + mlx-vlm"),
        .init(id: 3, title: "Modelos (16,3 GB)"),
        .init(id: 4, title: "Scripts del servidor"),
        .init(id: 5, title: "Arrancar y probar"),
    ]
    var running = false
    var finished = false
    var ramTier: RamTier = .full
    var blockReason: String?
    var downloadFraction: Double? // 0…1 durante el paso 3
    var downloadDetail = ""

    private weak var server: ServerModel?
    private var currentProcess: Process?
    private var progressTask: Task<Void, Never>?
    private var runTask: Task<Void, Never>?
    /// Token de generación: cancelar lo incrementa e invalida el run() en curso,
    /// incluso si estaba suspendido en un await sin proceso (GRAVE-2 de los
    /// verificadores: URLSession de totales o petición de prueba).
    private var generation = 0

    let root = ServerModel.defaultRootPath
    private var uvPath: String { NSHomeDirectory() + "/.local/bin/uv" }
    private var hfCache: String { NSHomeDirectory() + "/.cache/huggingface/hub" }
    private static let repos = [
        ("mlx-community/Qwen3.8-27B-4bit", 16_081_490_933),
        ("mlx-community/Qwen3.8-27B-MTP-4bit", 270_000_000),
    ]
    /// Versión de mlx-vlm que se instala. Es un release publicado en PyPI (con
    /// wheel: nada que compilar), no el `main` de GitHub — así dos instalaciones
    /// en fechas distintas montan exactamente el mismo servidor. Para subirla:
    /// cambia el número, comprueba que el stack sigue arrancando y publica.
    static let mlxVLMVersion = "0.6.14"
    private static var pipSpec: String { "mlx-vlm==\(mlxVLMVersion)" }

    init(server: ServerModel) {
        self.server = server
        checkMacTier()
        // Instalación desatendida (p. ej. `open Batuta.app --args -autoInstallOnLaunch YES`).
        // También es el gancho del simulacro de verificación sin clics.
        if UserDefaults.standard.bool(forKey: "autoInstallOnLaunch"),
           !server.installed {
            install()
        }
    }

    // MARK: Paso 0 — comprobaciones (también en init, para bloquear la UI pronto)

    private func checkMacTier() {
        let ram = ProcessInfo.processInfo.physicalMemory
        // Límite wired de GPU ≈ 2/3–3/4 de la RAM: <32 GB no admite ni los pesos
        // (15,95 GB); 32 GB solo con contexto reducido (hallazgo 3, confirmado).
        if ram < 30_000_000_000 {
            ramTier = .blocked
            blockReason = """
            Este Mac tiene \(ram / 1_073_741_824) GB de memoria. El modelo ocupa \
            16 GB solo en pesos y la GPU únicamente puede usar ~2/3 de la RAM, \
            así que se necesitan 32 GB como mínimo (36 GB recomendados).
            """
        } else if ram < 35_000_000_000 {
            ramTier = .reduced
        } else {
            ramTier = .full
        }
    }

    // MARK: Control

    func install() {
        guard !running, ramTier != .blocked else { return }
        running = true
        generation += 1
        let gen = generation
        runTask = Task { await run(gen) }
    }

    func cancel() {
        generation += 1 // invalida la secuencia en curso pase por donde pase
        runTask?.cancel()
        progressTask?.cancel()
        // SIGINT primero: los finally de Python limpian sus temporales. hf puede
        // tardar en morir (sus hilos rematan los shards en vuelo — H4), así que
        // se escala a SIGTERM a los 5 s si sigue vivo.
        if let p = currentProcess {
            p.interrupt()
            Task.detached {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if p.isRunning { p.terminate() }
            }
        }
        running = false
        for i in steps.indices where steps[i].state == .running {
            steps[i].state = .failed("Cancelado")
        }
    }

    // MARK: Secuencia

    private func run(_ gen: Int) async {
        defer { if gen == generation { running = false } }
        for i in steps.indices where steps[i].state != .ok {
            steps[i].state = .pending
            steps[i].detail = ""
        }
        // gen se re-comprueba tras CADA paso: un cancel() durante un await sin
        // proceso (totales, petición de prueba) no debe dejar avanzar la secuencia.
        guard await step0Checks(), gen == generation else { return }
        guard await step1Uv(), gen == generation else { return }
        guard await step2Venv(), gen == generation else { return }
        guard await step3Models(), gen == generation else { return }
        guard await step4Scripts(), gen == generation else { return }
        guard await step5Start(), gen == generation else { return }
        finished = true
        server?.resolveInstallation()
    }

    private func begin(_ i: Int, _ detail: String = "") {
        steps[i].state = .running
        steps[i].detail = detail
    }

    private func ok(_ i: Int, _ detail: String = "") {
        steps[i].state = .ok
        steps[i].detail = detail
    }

    private func fail(_ i: Int, _ msg: String) -> Bool {
        steps[i].state = .failed(ServerModel.stripANSI(msg)
            .split(separator: "\n").last.map(String.init) ?? msg)
        return false
    }

    // MARK: Pasos

    private func step0Checks() async -> Bool {
        begin(0)
        checkMacTier()
        if ramTier == .blocked { return fail(0, blockReason ?? "RAM insuficiente") }
        let free = (try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage) ?? 0
        if free < 25_000_000_000 {
            return fail(0, "Hacen falta 25 GB libres; hay \(free / 1_000_000_000) GB.")
        }
        // H6 de los verificadores: no pisar un ~/MLXServer ajeno. Se acepta si no
        // existe, está vacío, o tiene pinta de instalación nuestra (parcial o completa).
        let fm = FileManager.default
        if fm.fileExists(atPath: root) {
            let contents = (try? fm.contentsOfDirectory(atPath: root)) ?? []
            let ours = contents.isEmpty
                || contents.contains(".venv")
                || contents.contains("serve.sh")
                || contents.contains("mlx")
            if !ours {
                return fail(0, "\(root) ya existe con contenido ajeno; muévelo o bórralo.")
            }
        }
        let ramNote = ramTier == .reduced
            ? "32 GB: se instalará con contexto reducido (32k)" : "memoria suficiente"
        ok(0, "\(ramNote) · \(free / 1_000_000_000) GB libres")
        return true
    }

    private func step1Uv() async -> Bool {
        begin(1)
        if FileManager.default.isExecutableFile(atPath: uvPath) {
            ok(1, "ya instalado")
            return true
        }
        // UV_INSTALL_DIR fija el destino aunque el usuario tenga XDG_*;
        // UV_NO_MODIFY_PATH evita que el instalador edite los shell profiles
        // (hallazgo 7 — el install.sh lo hace por defecto).
        let r = await runCancellable("/bin/sh",
            ["-c", "curl -LsSf https://astral.sh/uv/install.sh | sh"],
            env: ["UV_INSTALL_DIR": NSHomeDirectory() + "/.local/bin",
                  "UV_NO_MODIFY_PATH": "1"])
        guard r.code == 0, FileManager.default.isExecutableFile(atPath: uvPath) else {
            return fail(1, r.output.isEmpty ? "No se pudo descargar uv (¿hay red?)" : r.output)
        }
        ok(1)
        return true
    }

    private func step2Venv() async -> Bool {
        begin(2, "esto tarda unos minutos…")
        let venvPy = root + "/.venv/bin/python"
        if FileManager.default.fileExists(atPath: root + "/.venv/bin/mlx_vlm.server") {
            ok(2, "ya instalado")
            return true
        }
        try? FileManager.default.createDirectory(
            atPath: root, withIntermediateDirectories: true)
        // only-managed: que uv jamás ejecute el stub de python3 de macOS, que sin
        // Command Line Tools dispara el diálogo de Apple (hallazgo 6).
        let envUv = ["UV_PYTHON_PREFERENCE": "only-managed"]
        let v = await runCancellable(uvPath,
            ["venv", "--python", "3.12", root + "/.venv"], env: envUv)
        guard v.code == 0 else { return fail(2, v.output) }
        begin(2, "instalando mlx-vlm y dependencias…")
        let p = await runCancellable(uvPath,
            ["pip", "install", "--python", venvPy, Self.pipSpec], env: envUv)
        guard p.code == 0,
              FileManager.default.fileExists(atPath: root + "/.venv/bin/mlx_vlm.server")
        else { return fail(2, p.output) }
        ok(2)
        return true
    }

    private func step3Models() async -> Bool {
        begin(3, "preparando descarga…")
        // Huérfanos de cancelaciones bruscas anteriores: envenenan el du y
        // desperdician disco (hallazgo 2).
        for (repo, _) in Self.repos {
            let dir = repoCacheDir(repo)
            _ = await runCancellable("/usr/bin/find",
                [dir + "/blobs", "-name", "*.incomplete", "-delete"])
        }
        let totals = await fetchTotals()
        let totalBytes = totals.reduce(0, +)
        startProgressWatcher(totalBytes: totalBytes)
        defer {
            progressTask?.cancel()
            downloadFraction = nil
        }
        for (repo, _) in Self.repos {
            begin(3, "descargando \(repo.split(separator: "/").last ?? "")…")
            let r = await runCancellable(root + "/.venv/bin/hf", ["download", repo])
            guard r.code == 0 else {
                // La reanudación es por fichero completado; un shard a medias
                // (hasta 5,3 GB) se repite — granularidad honesta del plan.
                return fail(3, r.output.isEmpty ? "Descarga interrumpida; reintenta." : r.output)
            }
        }
        ok(3, "16,3 GB en la caché de Hugging Face")
        return true
    }

    private func step4Scripts() async -> Bool {
        begin(4)
        let maxKv = ramTier == .reduced ? "32768" : "95536"
        let files: [(String, String, Bool)] = [
            ("serve.sh", Templates.serveSh.replacingOccurrences(of: "__MAXKV__", with: maxKv), true),
            ("bench.py", Templates.benchPy, true),
            ("mlx", Templates.mlxScript, true), // el último: es el marcador de «completa»
        ]
        for (name, content, exec) in files {
            let path = root + "/" + name
            do {
                try content.write(toFile: path, atomically: true, encoding: .utf8)
                if exec {
                    try FileManager.default.setAttributes(
                        [.posixPermissions: 0o755], ofItemAtPath: path)
                }
            } catch {
                return fail(4, "\(name): \(error.localizedDescription)")
            }
        }
        ok(4, ramTier == .reduced ? "variante 32 GB (contexto 32k)" : "")
        return true
    }

    private func step5Start() async -> Bool {
        begin(5, "cargando el modelo (~30 s)…")
        let r = await runCancellable(root + "/mlx", ["start"])
        guard r.code == 0 else { return fail(5, r.output) }
        begin(5, "petición de prueba…")
        var req = URLRequest(url: URL(string: "http://127.0.0.1:8080/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 120
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": "mlx-community/Qwen3.8-27B-4bit",
            "messages": [["role": "user", "content": "Di hola."]],
            "max_tokens": 16,
        ])
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                return fail(5, "La petición de prueba devolvió un error; mira el log.")
            }
        } catch {
            return fail(5, "La petición de prueba falló: \(error.localizedDescription)")
        }
        ok(5, "servidor funcionando")
        return true
    }

    // MARK: Progreso de la descarga

    private func repoCacheDir(_ repo: String) -> String {
        hfCache + "/models--" + repo.replacingOccurrences(of: "/", with: "--")
    }

    /// Total real por repo desde /tree (en /api/models los siblings van sin size —
    /// hallazgo 14); fallback a los tamaños medidos si la API no responde.
    private func fetchTotals() async -> [Int] {
        var out: [Int] = []
        for (repo, fallback) in Self.repos {
            let url = URL(string:
                "https://huggingface.co/api/models/\(repo)/tree/main?recursive=true")!
            if let (data, _) = try? await URLSession.shared.data(from: url),
               let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                let total = arr.reduce(0) { acc, f in
                    acc + ((f["lfs"] as? [String: Any])?["size"] as? Int
                           ?? f["size"] as? Int ?? 0)
                }
                out.append(total > 0 ? total : fallback)
            } else {
                out.append(fallback)
            }
        }
        return out
    }

    private func startProgressWatcher(totalBytes: Int) {
        progressTask?.cancel()
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                var done = 0
                for (repo, _) in Self.repos {
                    let dir = self.repoCacheDir(repo)
                    let du = await ServerModel.runCommand("/usr/bin/du", ["-sk", dir])
                    if du.code == 0,
                       let kb = Int(du.output.split(separator: "\t").first ?? "") {
                        done += kb * 1024
                    }
                }
                let f = totalBytes > 0 ? min(1.0, Double(done) / Double(totalBytes)) : 0
                self.downloadFraction = f
                self.downloadDetail = String(
                    format: "%.1f de %.1f GB (%.0f %%)",
                    Double(done) / 1e9, Double(totalBytes) / 1e9, f * 100)
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    // MARK: Proceso cancelable (el pipe se drena antes de esperar — mismo patrón
    // endurecido de ServerModel.runCommand, más el registro para cancel())

    private func runCancellable(
        _ path: String, _ args: [String], env: [String: String] = [:]
    ) async -> (code: Int32, output: String) {
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
            return (127, error.localizedDescription)
        }
        currentProcess = p
        // Solo anular si sigue siendo el nuestro: un run() viejo que despierta
        // tras cancelar no debe borrar el proceso de la generación nueva (H3).
        defer { if currentProcess === p { currentProcess = nil } }
        return await Task.detached {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        }.value
    }
}
