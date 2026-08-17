# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Idioma: el usuario trabaja en español. README, comentarios de código y mensajes de UI
están en español; mantén esa convención.

## Qué es esto

Dos piezas acopladas:

1. **El stack de servidor**: `mlx-vlm` 0.6.14 sirviendo `Qwen3.8-27B-4bit` con
   speculative decoding MTP en Apple Silicon. Se controla con dos scripts de shell
   (`serve.sh` lanza el servidor, `mlx` lo gestiona) y se mide con `bench.py`.
2. **Batuta MLX** (`MenuBarApp/`): app SwiftUI de barra de menús que controla ese servidor
   por HTTP y, en un Mac nuevo, **instala todo el stack ella misma**.

No es un repositorio git. `.venv/` es el entorno del servidor (no se versiona ni se
toca a mano); `mlx-vlm` 0.6.14 no está en PyPI y se instala desde el `main` de GitHub.

## Comandos

```bash
./mlx start          # arranca el servidor en background (127.0.0.1:8080)
./mlx stop           # para y libera ~16 GB
./mlx status         # estado, modelo, contexto, memoria
./mlx logs           # tail -f de server.log
./mlx test           # una petición de prueba + velocidad
./mlx bench          # benchmark completo (bench.py)
```

```bash
MenuBarApp/build-app.sh   # compila, firma ad-hoc, instala en ~/Applications y empaqueta dist/BatutaMLX.zip
cd MenuBarApp && swift build   # solo compilar (sin instalar)
```

No hay Xcode en esta máquina, solo Command Line Tools: **`xcodebuild` no existe**, se
compila con SwiftPM. No hay suite de tests; la verificación es funcional (arrancar el
servidor, `./mlx test`, comprobar `/metrics`).

**Trampa del build**: `.build/release` es un symlink y SwiftPM puede reutilizar un
binario rancio tras editar Swift. Si un cambio no aparece en la app, `rm -rf
MenuBarApp/.build` y reconstruye; verifica con
`LC_ALL=C grep -ac "<string nuevo>" ~/Applications/Batuta MLX.app/Contents/MacOS/Batuta`
(`strings` no encuentra literales con acentos).

## Arquitectura de Batuta MLX

`MenuBarExtra` estilo `.window`, `LSUIElement` (sin Dock). Tres modelos `@Observable
@MainActor` creados en `BatutaMLXApp.swift` y pasados al panel:

- **`ServerModel`** — sondea `GET /metrics` (3 s con el panel cerrado, 1 s abierto) y
  deriva de ahí TODO: velocidad de la última petición, gráfica de las últimas 32,
  `in_flight` (el indicador de «en uso»), modelo y contexto. Arranca/para delegando en
  el script `mlx` vía `Process` (una sola fuente de verdad; la app no duplica lógica
  de shell).
- **`ChatModel`** — mini-chat de prueba con streaming SSE.
- **`SetupModel` / `SetupView`** — el asistente de instalación de 6 pasos.

`PanelView` decide: si `model.installed` muestra el panel normal, si no, `SetupView`.

### Invariantes que NO deben romperse

Nacieron de auditorías adversariales; cada uno tiene un incidente concreto detrás.

- **Un timeout nunca significa «parado».** Solo conexión rechazada (`URLError
  .cannotConnectToHost`) **y** ausencia de proceso `mlx_vlm.server` habilitan el botón
  Arrancar. Motivo: uvicorn carga los 15,7 GB **antes** de abrir el puerto, así que un
  segundo arranque durante la carga duplica el modelo en memoria.
- **Nunca escribir `state` tras un `await` sin re-comprobar la transición.** Un sondeo
  suspendido que despierta con datos viejos puede pisar `.starting` y reabrir el doble
  arranque. El guard es el flag `appDrivenTransition`.
- **`@State` de los modelos sin valor por defecto** en `BatutaMLXApp`: un inicializador
  ahí correría antes del `init()` y crearía un `ServerModel` huérfano cuyo `pollLoop`
  se auto-retiene (zombi sondeando + doble auto-arranque).
- **`SetupModel.cancel()` invalida por token de generación** (`generation`), no solo
  interrumpiendo el proceso: cancelar durante un `await` sin proceso (consulta de
  tamaños, petición de prueba) dejaría la secuencia avanzar sola.
- **Drenar el pipe antes de `waitUntilExit`** en cualquier `Process`; al revés se
  interbloquea si el hijo llena el búfer.

### Resolución de la instalación (4 niveles, en `ServerModel.resolveInstallation`)

`installRootOverride` (solo pruebas, no persiste) → clave `mlxScriptPath` de
UserDefaults → rutas legacy `~/IA/MLX-VLM-IA/mlx` y `~/MLX-VLM-IA/mlx` (**migra** escribiendo
la clave) → `~/MLXServer` si está completa → si nada, asistente. «Completa» exige
`mlx` + `serve.sh` + `.venv/bin/mlx_vlm.server`, y el asistente escribe `mlx` el último
para que sea el marcador de cierre.

### El instalador

Bootstrap pensado para un Mac **sin** Command Line Tools: `uv` standalone
(`UV_INSTALL_DIR` + `UV_NO_MODIFY_PATH=1`), CPython gestionado por uv
(`UV_PYTHON_PREFERENCE=only-managed` — el `/usr/bin/python3` de macOS es un stub que
dispara el diálogo de Apple), y mlx-vlm desde tarball de GitHub (sin git).

`Templates.swift` contiene `serve.sh`, `mlx` y `bench.py` como literales, generados
desde los ficheros reales. **Si editas los scripts del proyecto, regenera las
plantillas**; sus únicas divergencias permitidas son `python3` → `.venv/bin/python`
(2 usos en `mlx`) y `--max-kv-size __MAXKV__` en `serve.sh`.

## Conocimiento del stack (medido, no supuesto)

- **Techo de esta máquina** (M3 Max 30 núcleos GPU, ~300 GB/s): decode 16,3 tok/s sin
  MTP ≈ 85 % del ancho de banda teórico; 20–28 tok/s con MTP; prefill ~146 tok/s. Las
  cifras de benchmarks en Macs de 400+ GB/s no son reproducibles aquí. Estima con
  `256 GB/s ÷ tamaño_del_modelo_GB`.
- **Degradación por throttling**: en sesiones largas de tests seguidos el decode cae a
  ~10 tok/s y el prefill con él (el prefill, limitado por cómputo, es el termómetro
  limpio). Se recupera en minutos. No confundir con estado acumulado del servidor.
- **`--draft-block-size 4`** es el óptimo medido; el `3` que trae la config del drafter
  rinde por debajo del baseline en código y chat, y `5`/`6` **sobredraftean** con la
  cabeza MTP stock: los tokens aceptados por prompt no crecen (≈845) mientras los
  drafteados sí (aceptación 39 % → 31 % → 25 %, decode 21,7 → 18,6 → 14,2 tok/s;
  BLOCK=6 cae por debajo del serial). Más profundidad solo pagaría con una cabeza de
  mayor aceptación, no como knob.
- **`--max-kv-size N`** solo baja el contexto (nativo 262 144) y es un presupuesto duro
  sobre `prompt + max_tokens`: si te pasas, rechaza con error, no trunca. Es
  ajustable **en caliente** con `PATCH /v1/settings {"max_kv_size": N}`.
- **`--max-tokens`** es el valor por defecto para clientes que no lo mandan, **no un
  tope**. No existe «sin límite»: `-1` y `0` cortan la generación al instante.
- **`--max-num-seqs`** (peticiones simultáneas) NO es knob en caliente: va por env
  `MLX_VLM_MAX_NUM_SEQS`; Batuta MLX lo inyecta como `MAXSEQS` al arrancar.
- **KV cache**: ~64 KB/token (solo 16 de las 64 capas son de atención completa; el
  resto son lineales con estado fijo). 262 k ≈ 17 GB.
- **`/metrics`** expone `latest`, `summary.in_flight` y `recent` — la API recorta
  `recent` a **32** entradas aunque el búfer interno guarde 100.

## Distribución de la app

Sin Developer ID (0 identidades en esta máquina) la notarización es imposible y `spctl`
siempre dirá `rejected`. Pero **sin quarantine la app arranca sin problema**: copiar el
zip por USB o scp funciona a la primera; por AirDrop/navegador hace falta «Abrir
igualmente» o `xattr -dr com.apple.quarantine`. En el Mac destino, mover la app a
`/Applications` **antes** de abrirla (App Translocation rompería el ítem de inicio).

## Metodología

Los cambios delicados de este proyecto se hacen con la skill `ciclo-plan`
(medir → plan → auditoría adversarial → verificar hallazgos → implementar →
verificadores paralelos → endurecer). Los planes viven en `~/.claude/plans/`
(`mlx-menubar-app.md`, `mlxbar-instalador.md`) y documentan qué se descartó y por qué.
Regla que ha pagado en este proyecto: **los hallazgos de una auditoría también se
verifican** — varios «graves» resultaron refutables con una medición.
