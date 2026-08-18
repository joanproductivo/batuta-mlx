# Batuta MLX

**Un LLM local en la barra de menús del Mac.** Batuta MLX arranca, para y vigila un servidor
[mlx-vlm](https://github.com/Blaizzy/mlx-vlm) con `Qwen3.8-27B` y *speculative decoding*
MTP, y en un Mac nuevo **instala el stack entero ella sola** — sin Xcode, sin Homebrew,
sin Python previo y sin contraseña de administrador.

El servidor habla el protocolo de la API de OpenAI, así que cualquier app que permita
cambiar la URL base lo usa sin adaptaciones.

> *Llevar la batuta* es dirigir. La idea del proyecto es que la app acabe siendo la
> batuta de varios modelos locales, pudiendo cambiar de uno a otro desde el mismo panel.
> Hoy dirige uno solo; ver [Hacia dónde va](#hacia-dónde-va).

## Empezar

Descarga `BatutaMLX.zip` de la [última release](../../releases/latest), muévela a
`/Applications` **con el Finder antes de abrirla**, ábrela y pulsa «Instalar».

**Requisitos**: Apple Silicon, macOS 14+, **32 GB de RAM mínimo** (36+ recomendados),
25 GB de disco libres y conexión para descargar 16,3 GB de pesos. Detalles y solución
de problemas en [Instalar en otro Mac](#instalar-en-otro-mac-desde-la-app).

La app no está firmada con Developer ID (imposible sin cuenta de desarrollador de pago),
así que si la descargas con el navegador macOS la bloqueará la primera vez:
Ajustes → Privacidad y seguridad → «Abrir igualmente».

## Instalación manual (o para desarrollar)

```bash
uv venv --python 3.12 .venv
uv pip install --python .venv/bin/python "mlx-vlm==0.6.14"
```

Se instala una **versión publicada** de mlx-vlm, no el `main` de GitHub: así dos
instalaciones hechas en fechas distintas montan exactamente el mismo servidor. El
instalador de la app usa esa misma versión (constante `mlxVLMVersion` en
`SetupModel.swift`).

Pesos — hacen falta **los dos**, tienen papeles distintos:

```bash
.venv/bin/hf download mlx-community/Qwen3.8-27B-4bit      # 15 GB  · el modelo
.venv/bin/hf download mlx-community/Qwen3.8-27B-MTP-4bit  # 253 MB · el drafter MTP
```

- **`Qwen3.8-27B-4bit`** es el modelo de verdad: el que piensa y escribe. Sin él no hay nada.
- **`Qwen3.8-27B-MTP-4bit`** no es un modelo completo, sino la cabeza de *Multi-Token Prediction*
  extraída de ese mismo checkpoint. Propone varios tokens por adelantado que el modelo grande
  verifica de golpe; es de donde sale la aceleración (16,3 → 20-28 tok/s). Sólo ocupa 253 MB.

Si lo quitas, el servidor sigue funcionando igual de bien pero más lento: arranca con
`./serve.sh --no-mtp`. No merece la pena por 253 MB.

## Batuta MLX — app de barra de menús

Control del servidor desde la barra de estado de macOS: arrancar/parar, velocidad de la
última petición (decode/prefill/ttft), mini-gráfica de las últimas 32 peticiones,
indicador de «en uso», selector de ventana de contexto en caliente, y sección
«Conexión» con la dirección de la API (`http://127.0.0.1:8080/v1`) y el nombre del
modelo listos para copiar y pegar en cualquier cliente compatible con OpenAI.

Además:

- **Probar el modelo**: mini-chat plegable con streaming, para comprobar que todo
  funciona sin salir de la barra. Responde sin razonamiento (`enable_thinking: false`)
  y con tope de 1024 tokens; la conversación sobrevive a cerrar el panel.
- **Memoria del servidor**: los GB de RSS del proceso, en la cabecera, junto al contexto.
- **Ajustes**: abrir Batuta MLX al iniciar sesión (SMAppService), arrancar el servidor
  automáticamente al abrir la app (apagado por defecto), razonamiento (thinking) por
  defecto encendido/apagado, peticiones simultáneas, y «Ver log del servidor».

```bash
MenuBarApp/build-app.sh
```

Compila con Swift Package Manager (no requiere Xcode; bastan las Command Line Tools) y
lo instala en `~/Applications/Batuta MLX.app`.

| Icono | Estado |
|---|---|
| cerebro (contorno) | servidor parado |
| reloj de arena | arrancando o parando |
| cerebro relleno | en marcha, libre |
| rayo | generando (en uso) |
| interrogante | proceso vivo pero no responde |

Decisiones de diseño:

- **Salir de la app no para el servidor** — la app es un mando a distancia, no un
  supervisor. Para el servidor desde la propia app o con `./mlx stop`.
- El selector de contexto usa `PATCH /v1/settings` (cambio en caliente, sin recarga del
  modelo) y **reconcilia en cada sondeo**: si algo reinicia el servidor (p. ej.
  `./mlx restart` en Terminal, que vuelve a imponer el `--max-kv-size` de `serve.sh`),
  la app re-aplica tu elección en ≤6 s. Verificado de extremo a extremo.
- **Las ventanas ofrecidas dependen de la RAM del Mac**, porque la caché KV cuesta
  ~64 KB por token y la GPU solo puede tener «wired» unos 3/4 de la memoria:

  | RAM | Opciones |
  |---|---|
  | 32–36 GB | 32k · 65k · 95k · 131k |
  | 48 GB o más | + **262k** (el contexto nativo: ≈17 GB de KV + 16 GB de pesos) |

  El panel muestra el coste en GB de la opción elegida. Y como `PATCH /v1/settings`
  puede subir el límite hasta el nativo, 262k funciona sin reinstalar aunque el
  `serve.sh` generado por el instalador arrancara con menos.
- Un timeout del servidor **no** se interpreta como «parado»: solo conexión rechazada
  sin proceso `mlx_vlm.server` vivo habilita el botón Arrancar (evita el doble arranque,
  que cargaría 15,7 GB duplicados porque uvicorn carga el modelo antes de abrir el
  puerto).
- Si mueves la instalación de sitio, la app busca el script de control en la ruta
  guardada en `defaults read com.joanplanas.batuta mlxScriptPath`; actualízala con
  `defaults write`. Por defecto usa `~/MLXServer` (instalación desde la app) o
  `~/IA/MLX-VLM-IA` / `~/MLX-VLM-IA` si clonaste este repo a mano.

## Instalar en otro Mac (desde la app)

Batuta MLX lleva un instalador integrado: en un Mac sin nada, la propia app monta todo el
sistema (entorno Python con `uv`, mlx-vlm, los 16,3 GB de modelos y los scripts) en
`~/MLXServer`, sin Xcode, sin Command Line Tools y sin contraseña de administrador.

**Requisitos del Mac destino**: Apple Silicon, macOS 14+, **32 GB de RAM mínimo**
(36+ recomendados — con 32 GB se instala con contexto reducido a 32k; con menos se
bloquea con explicación: la GPU solo puede usar ~2/3 de la RAM y los pesos ya ocupan
16 GB), 25 GB de disco libres y conexión para la descarga.

Pasos:

1. Genera el paquete aquí: `MenuBarApp/build-app.sh` → `MenuBarApp/dist/BatutaMLX.zip`.
2. Cópialo al otro Mac **por USB o scp** (así macOS no lo pone en cuarentena y abre a
   la primera — verificado). Si va por AirDrop/navegador y macOS lo bloquea:
   Ajustes → Privacidad y seguridad → «Abrir igualmente», o
   `xattr -dr com.apple.quarantine <ruta>`.
3. Descomprime y **mueve Batuta MLX.app a /Applications o ~/Applications con el Finder
   ANTES de abrirla** (evita App Translocation y deja bien el ítem de inicio).
4. Ábrela → «Instalar» → espera la descarga (10–40 min) → icono cerebro en la barra.

La instalación es reanudable: si se corta, «Reintentar» continúa (la descarga retoma
por fichero completado; un shard de 5,3 GB a medias se repite). Instalación
desatendida: `open Batuta MLX.app --args -autoInstallOnLaunch YES`.

Desinstalar el sistema del otro Mac:

```bash
rm -rf ~/MLXServer ~/Applications/Batuta MLX.app /Applications/Batuta MLX.app \
  ~/.cache/huggingface/hub/models--mlx-community--Qwen3.8* \
  ~/.local/bin/uv ~/.local/bin/uvx ~/.local/bin/env ~/.config/uv ~/.local/share/uv
defaults delete com.joanplanas.batuta
```

(y quitar Batuta MLX de Ajustes → General → Ítems de inicio si se activó).

## Uso diario

Todo se maneja con el script `./mlx`:

| Comando | Qué hace |
|---|---|
| `./mlx start` | Arranca en segundo plano, accesible solo desde este Mac |
| `./mlx start --lan` | Arranca accesible desde la red local |
| `./mlx stop` | Para el servidor y libera los ~16 GB de memoria |
| `./mlx restart` | Reinicia |
| `./mlx status` | Estado, modelo cargado, contexto, memoria |
| `./mlx logs` | Sigue el log en vivo (Ctrl-C para salir) |
| `./mlx test` | Pregunta de prueba + velocidad medida |
| `./mlx bench` | Benchmark completo |

La primera carga tarda ~25 s (son 15,7 GB de pesos); los reinicios posteriores, ~8 s con el
fichero ya en caché de disco. Mientras está arrancado ocupa memoria de forma permanente, así que
conviene `./mlx stop` cuando no se use.

Por debajo, `./mlx` llama a [`serve.sh`](serve.sh), que equivale a:

```bash
APC_ENABLED=1 .venv/bin/mlx_vlm.server \
  --model mlx-community/Qwen3.8-27B-4bit \
  --draft-model mlx-community/Qwen3.8-27B-MTP-4bit \
  --draft-kind mtp --draft-block-size 4 \
  --host 127.0.0.1 --port 8080 \
  --max-tokens 16384 --enable-thinking --max-kv-size 95536
```

(más `--max-num-seqs N` si Batuta MLX inyecta `MAXSEQS` — el picker de «Peticiones
simultáneas» de sus Ajustes).

## Acceso desde otras aplicaciones

El servidor habla **el mismo protocolo que la API de OpenAI**, así que cualquier cliente que
permita cambiar la URL base funciona sin adaptaciones.

| | |
|---|---|
| URL base | `http://127.0.0.1:8080/v1` (o `http://<ip-del-mac>:8080/v1` desde la red local) |
| API key | Cualquier cosa no vacía — no hay autenticación |
| Nombre del modelo | `mlx-community/Qwen3.8-27B-4bit` |

### Endpoints disponibles

| Ruta | Protocolo |
|---|---|
| `/v1/chat/completions` | OpenAI — chat, con `stream: true` opcional |
| `/v1/responses` | OpenAI Responses API |
| `/v1/messages` | **Anthropic Messages API** (para SDKs de Anthropic) |
| `/v1/models` | Lista de modelos |
| `/health`, `/metrics` | Estado y métricas |
| `/v1/cache/stats`, `/v1/cache/reset` | Prefix cache |

### Python (SDK de OpenAI)

```python
from openai import OpenAI

client = OpenAI(base_url="http://127.0.0.1:8080/v1", api_key="no-hace-falta")

r = client.chat.completions.create(
    model="mlx-community/Qwen3.8-27B-4bit",
    messages=[{"role": "user", "content": "Hola"}],
    max_tokens=200,
)
print(r.choices[0].message.content)
```

### curl

```bash
curl http://127.0.0.1:8080/v1/chat/completions -H 'Content-Type: application/json' -d '{
  "model": "mlx-community/Qwen3.8-27B-4bit",
  "messages": [{"role": "user", "content": "Hola"}],
  "max_tokens": 200
}'
```

### Node / TypeScript

```ts
import OpenAI from "openai";
const client = new OpenAI({ baseURL: "http://127.0.0.1:8080/v1", apiKey: "x" });
```

### Imágenes

El modelo es multimodal. Se pasan como en OpenAI, con `image_url` y un data-URI en base64:

```json
{"role": "user", "content": [
  {"type": "text", "text": "¿Qué hay en la imagen?"},
  {"type": "image_url", "image_url": {"url": "data:image/jpeg;base64,..."}}
]}
```

### Ventana de contexto

El flag es **`--max-kv-size N`** (tokens), en los `ARGS` de [`serve.sh`](serve.sh):

```bash
ARGS=(--model "$MODEL" ... --max-kv-size 65536)
```

- Por defecto **no hay límite**: se usa el nativo del modelo, **262 144 tokens**.
- `--max-kv-size` sólo sirve para **bajarlo**, no para subirlo: el efectivo es
  `min(nativo, configurado)`. No se puede pasar de 262 144.
- Es un presupuesto **duro sobre prompt + generación**, y no trunca en silencio: si te pasas
  devuelve un error claro —
  `Request needs 9054 context tokens (54 prompt + 9000 max generation), but MAX_KV_SIZE is 8192.`
- Compruébalo en `./mlx status` o en `/health` → `effective_context_limit`.

No lo confundas con `--max-tokens`, que es sólo el tope de tokens **generados** por respuesta.

**Cuánta memoria cuesta.** Qwen3.8 es híbrido: de sus 64 capas sólo 16 son de atención completa
(las demás usan atención lineal, de estado fijo). Con `head_dim=256`, 4 cabezas KV y bf16 salen
~64 KB de caché KV por token:

| Contexto | KV cache aprox. | Total con el modelo (15,7 GB) |
|---:|---:|---:|
| 32 k | 2,1 GB | ~18 GB |
| 64 k | 4,3 GB | ~20 GB |
| 128 k | 8,6 GB | ~24 GB |
| 262 k (nativo) | 17,2 GB | ~33 GB ⚠️ al límite de los 36 GB |

En este Mac lo razonable es quedarse en **64 k–128 k**. Si necesitas más, `--kv-bits 4` cuantiza
la caché KV y la reduce ~4× (262 k pasarían de 17,2 a ~4,3 GB), a cambio de algo de calidad.

### Razonamiento (thinking)

Qwen3.8 es un modelo con razonamiento y este servidor arranca con él **activado por
defecto** (toggle en los Ajustes de Batuta MLX, o `THINKING=0 ./mlx start` desde
Terminal; como todo lo que va por entorno, se aplica al arrancar), así que las
peticiones que no digan nada razonan por defecto.
Cada petición puede desactivarlo con `"enable_thinking": false` — el mini-chat de
Batuta MLX lo hace — o controlarlo explícitamente:

```json
{"model": "...", "messages": [...], "enable_thinking": true, "thinking_budget": 2048}
```

**Cómo saber si lo está usando:** mira el campo `reasoning_content` de la respuesta.

| | `reasoning_content` |
|---|---|
| Razonamiento apagado | `null` |
| Razonamiento activo | contiene la cadena de pensamiento |

```bash
curl -s http://127.0.0.1:8080/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"model":"mlx-community/Qwen3.8-27B-4bit",
       "messages":[{"role":"user","content":"3 cajas de 4 manzanas, regalo 5. ¿Cuántas quedan?"}],
       "max_tokens":400,"enable_thinking":true}' \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['choices'][0]['message']['reasoning_content'])"
```

En streaming llega como `delta.reasoning_content` en vez de `delta.content`. El razonamiento
gasta tokens de generación: en la prueba de arriba, 155 tokens con razonamiento frente a 128 sin él.

Para dejarlo activado de forma permanente, añade `--enable-thinking` a los `ARGS` de
[`serve.sh`](serve.sh); cada petición podrá seguir desactivándolo con `"enable_thinking": false`.

### Acceso desde otro dispositivo

`./mlx start --lan` escucha en `0.0.0.0`, y el servicio queda en `http://<ip-del-mac>:8080/v1`.

> **El servidor no tiene autenticación**: cualquiera en la misma red Wi-Fi puede usar el modelo.
> Úsalo solo en redes de confianza. Para acceso remoto seguro, la alternativa es dejarlo en
> `127.0.0.1` y abrir un túnel SSH desde la máquina cliente:
> `ssh -N -L 8080:127.0.0.1:8080 usuario@<ip-del-mac>`, y apuntar la app a
> `http://127.0.0.1:8080/v1` en el cliente.

## Rendimiento medido

> Todas las cifras de abajo se midieron en un **MacBook Pro M3 Max de 30 núcleos GPU
> (≈300 GB/s) con 36 GB**, macOS 26.6. El *decode* de un modelo denso está limitado por
> ancho de banda, así que en Macs de 400+ GB/s (M3 Max de 40 núcleos, M4/M5 Max, Ultra)
> saldrán más altas y en un M-Pro más bajas. Estima con `256 GB/s ÷ tamaño_del_modelo_GB`.

El objetivo era reproducir una tarjeta de benchmark que anunciaba **36,4 tok/s de decode,
148 tok/s de prompt eval y 93 % de aceptación del drafter**.

| Métrica | Tarjeta | Medido aquí | |
|---|---:|---:|---|
| Prompt eval (prompts de 0,6–7,8 k tokens) | 148 tok/s | **143–147 tok/s** | ✅ |
| Aceptación del drafter (salida estructurada) | 93 % | **91,7 %** | ✅ |
| Decode, mejor caso (JSON/estructurado) | 36,4 tok/s | **28,5 tok/s** | ⚠️ 78 % |
| Decode, mediana de cargas mixtas | — | 20,0 tok/s | |
| Pico de memoria | — | 19,9 GB | |

### Barrido de `--draft-block-size` (decode tok/s, aceptación entre paréntesis)

| Configuración | JSON | Código | Chat | Mediana |
|---|---:|---:|---:|---:|
| sin MTP (baseline) | 15,9 | 16,4 | 16,2 | 16,3 |
| MTP block 3 *(default del drafter)* | 21,8 (95,7 %) | 15,0 (77,4 %) | 16,0 (73,7 %) | 16,1 |
| **MTP block 4** ← elegido | **27,0 (91,7 %)** | **20,0 (66,6 %)** | **17,8 (62,8 %)** | **20,0** |
| MTP block 5 | 25,6 (87,7 %) | 18,0 (53,7 %) | 17,9 (51,3 %) | 18,0 |
| MTP block 6 | 24,6 (84,1 %) | 17,0 (50,2 %) | 15,3 (42,2 %) | 17,0 |

El `block_size: 3` que trae el `config.json` del drafter **no es el óptimo aquí**: con block 3 el
MTP llega a rendir *por debajo* del baseline en código y chat. Con block 4 gana en todo.

### Prefix caching (APC) — mejora sobre la tarjeta

La tarjeta marca como pega *"no prefix cache, so multi-turn sessions re-pay prefill every turn"*.
En 0.6.14 ya existe y se activa con `APC_ENABLED=1`:

| Turno | prefill sin APC | prefill con APC | reutilizado |
|---|---:|---:|---:|
| 1 | 10 646 ms | 10 454 ms | 0 tok |
| 2 | 10 989 ms | **846 ms** | 1 585 tok |
| 3 | 11 639 ms | **784 ms** | 1 650 tok |
| 4 | 11 994 ms | **799 ms** | 1 711 tok |

**~13× menos latencia hasta el primer token** a partir del segundo turno.

## Por qué el decode se queda en 28,5 y no en 36,4

El decode de un modelo denso está limitado por ancho de banda de memoria: cada token exige leer
los 15,7 GB de pesos.

- Baseline medido sin MTP: **16,3 tok/s** → 16,3 × 15,7 GB ≈ **256 GB/s efectivos**, un 85 % del
  pico teórico de 300 GB/s. Es decir, ya se está exprimiendo el hardware.
- El MTP multiplica ×1,2–1,75 según lo predecible que sea la salida.
- Para 36,4 tok/s harían falta ~340–400 GB/s: un **M3 Max de 40 núcleos, un M4 Max o un Ultra**.
  Con el mismo factor MTP: 16,3 × (400/300) × 1,75 ≈ 38 tok/s.

Encaja con que el *prompt eval* sí coincida (148 tok/s): el prefill está limitado por cómputo,
no por ancho de banda, y ahí esta GPU sí llega.

## Vías descartadas

- **Cuantizaciones alternativas**: `OptiQ-4bit` (19,5 GB), `oQ4` (16,7 GB) y `nvfp4` (16,1 GB) son
  iguales o **más grandes** que el 4-bit afín actual → no hay decode más rápido por ahí.
- **PR [#1899](https://github.com/Blaizzy/mlx-vlm/pull/1899) "Add Qwen3.8-27B support"** (abierto):
  solo añade carga de pesos FP8/NVFP4 y tests. No toca la ruta de 4-bit afín; no aporta velocidad.
- **[MTPLX](https://github.com/youssofal/MTPLX)**: runtime alternativo, no mlx-vlm. Sus propias
  cifras (1,6× en M4 mini, 2,24× en M5 Max) están en el mismo rango que el ×1,75 obtenido aquí.

## Pendiente de upstream

- PR [#1915](https://github.com/Blaizzy/mlx-vlm/pull/1915) *"Page a hybrid's attention layers"*
  (abierto, tras `APC_COMPOSITE`): permitiría reanudar desde el último prefijo común cuando la
  conversación diverge, en vez de re-prefillear. Relevante porque Qwen3.8 es híbrido
  (atención lineal + full attention cada 4 capas).

## Hacia dónde va

El nombre no es casual: hoy Batuta MLX dirige un solo modelo, pero la arquitectura ya está
preparada para varios.

- `serve.sh` recibe el modelo y el drafter como variables, y `Templates.swift` genera
  ese script en la instalación → añadir un modelo es añadir una entrada, no reescribir
  la app.
- El servidor mlx-vlm ya expone `/v1/models` con todo lo que hay en la caché de Hugging
  Face y sabe cargar y descargar modelos en caliente (`POST /unload`).
- Lo que falta: un selector de modelo en el panel, descargar variantes desde el
  asistente (hoy instala un stack fijo y validado) y recordar los ajustes por modelo.

Otras cosas pendientes, con su porqué en el propio README: `--lan` sin autenticación,
notarización (imposible sin cuenta de desarrollador) y el PR de prefijos híbridos de
upstream.

## Créditos

Construido sobre [mlx-vlm](https://github.com/Blaizzy/mlx-vlm) de Prince Canuma y
[MLX](https://github.com/ml-explore/mlx) de Apple. Los pesos son de
[Qwen](https://huggingface.co/Qwen) (Apache 2.0), cuantizados por
[mlx-community](https://huggingface.co/mlx-community).

## Licencia

[MIT](LICENSE) — haz lo que quieras con el código: úsalo, modifícalo, distribúyelo,
véndelo o cierra tu fork. Lo único que pide es conservar el aviso de copyright.

Los pesos del modelo tienen su propia licencia (Apache 2.0, de Qwen) y no se
distribuyen aquí: la app los descarga de Hugging Face.
