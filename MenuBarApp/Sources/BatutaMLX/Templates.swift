// Plantillas de la instalación en Macs nuevos. Generadas desde los scripts
// validados de este proyecto; únicas divergencias (medidas en la auditoría):
//  - mlx: `python3` del sistema → `.venv/bin/python` (los Macs sin Command Line
//    Tools solo tienen un stub de python3 que dispara el diálogo de Apple).
//  - serve.sh: `--max-kv-size` parametrizado (__MAXKV__) para la variante de 32 GB.

enum Templates {
    static let serveSh = #"""
    #!/usr/bin/env bash
    # Arranca el servidor mlx-vlm con speculative decoding MTP (en primer plano).
    # Para uso diario normalmente querrás ./mlx en vez de esto.
    #
    #   ./serve.sh            -> con drafter MTP (configuración óptima medida)
    #   ./serve.sh --no-mtp   -> baseline sin drafter, para comparar
    #
    # Variables: HOST (default 127.0.0.1), PORT (8080), BLOCK (4), APC_ENABLED (1)
    set -euo pipefail
    cd "$(dirname "$0")"
    
    MODEL=mlx-community/Qwen3.8-27B-4bit
    DRAFT=mlx-community/Qwen3.8-27B-MTP-4bit
    HOST=${HOST:-127.0.0.1}
    PORT=${PORT:-8080}
    
    # Prefix caching (APC): evita re-prefill en conversaciones multi-turno.
    # Es justo la carencia que señala la tarjeta de referencia; en 0.6.14 ya existe.
    export APC_ENABLED=${APC_ENABLED:-1}
    
    # --max-tokens es solo el valor POR DEFECTO para clientes que no lo mandan (no un tope: si
    # la petición trae max_tokens, gana ella). No existe "sin límite": -1 y 0 cortan al instante.
    # 16384 tok ~= 12.000 palabras; deja 79k de los 95k de contexto libres para el prompt.
    ARGS=(--model "$MODEL" --host "$HOST" --port "$PORT" --max-tokens 16384 --max-kv-size __MAXKV__)
    
    # Razonamiento (thinking) por defecto. Batuta MLX lo inyecta como env al arrancar;
    # cada petición puede anularlo con "enable_thinking": true/false.
    if [[ "${THINKING:-1}" != "0" ]]; then
      ARGS+=(--enable-thinking)
    fi
    
    # Peticiones simultáneas (Batuta MLX lo inyecta como env al arrancar; vacío = sin límite).
    if [[ -n "${MAXSEQS:-}" ]]; then
      ARGS+=(--max-num-seqs "$MAXSEQS")
    fi
    
    if [[ "${1:-}" != "--no-mtp" ]]; then
      # block-size 4 medido como óptimo en M3 Max 30c (mejor que el 3 por defecto).
      ARGS+=(--draft-model "$DRAFT" --draft-kind mtp --draft-block-size "${BLOCK:-4}")
    fi
    
    exec .venv/bin/mlx_vlm.server "${ARGS[@]}"
    """#

    static let mlxScript = #"""
    #!/usr/bin/env bash
    # Control del servidor mlx-vlm (Qwen3.8-27B-4bit + drafter MTP).
    #
    #   ./mlx start        arranca en segundo plano (solo este Mac)
    #   ./mlx start --lan  arranca accesible desde la red local
    #   ./mlx stop         para el servidor y libera la memoria
    #   ./mlx restart      para y vuelve a arrancar
    #   ./mlx status       ¿está vivo? modelo cargado, memoria, dirección
    #   ./mlx logs         sigue el log en vivo (Ctrl-C para salir)
    #   ./mlx test         hace una pregunta de prueba y mide la velocidad
    #   ./mlx bench        benchmark completo
    
    set -uo pipefail
    cd "$(dirname "$0")"
    
    PORT=${PORT:-8080}
    LOG=server.log
    PIDFILE=.server.pid
    URL="http://127.0.0.1:$PORT"
    
    c_ok()   { printf "\033[32m%s\033[0m\n" "$*"; }
    c_err()  { printf "\033[31m%s\033[0m\n" "$*"; }
    c_dim()  { printf "\033[2m%s\033[0m\n" "$*"; }
    
    alive() { curl -s -m 2 "$URL/health" >/dev/null 2>&1; }
    
    lan_ip() { ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo "?"; }
    
    wait_ready() {
      # El modelo son 15,7 GB: la primera carga tarda ~25 s (más si no está en caché de disco).
      printf "cargando el modelo"
      for _ in $(seq 1 120); do
        if alive; then echo ""; return 0; fi
        if [[ -f $PIDFILE ]] && ! kill -0 "$(cat $PIDFILE)" 2>/dev/null; then
          echo ""; c_err "el servidor murió al arrancar. Últimas líneas:"; tail -20 "$LOG"; return 1
        fi
        printf "."; /bin/sleep 2
      done
      echo ""; c_err "timeout esperando al servidor"; tail -20 "$LOG"; return 1
    }
    
    cmd_start() {
      if alive; then c_ok "ya estaba arrancado en $URL"; cmd_status; return 0; fi
    
      local host=127.0.0.1 scope="solo este Mac (127.0.0.1)"
      if [[ "${1:-}" == "--lan" ]]; then
        host=0.0.0.0
        scope="RED LOCAL — http://$(lan_ip):$PORT  (sin contraseña: úsalo solo en redes de confianza)"
      fi
    
      HOST=$host PORT=$PORT nohup ./serve.sh > "$LOG" 2>&1 &
      echo $! > "$PIDFILE"
      wait_ready || return 1
      c_ok "servidor listo · $scope"
      cmd_status
    }
    
    cmd_stop() {
      if ! alive && [[ ! -f $PIDFILE ]]; then c_dim "no había nada corriendo"; return 0; fi
      pkill -f "mlx_vlm.server" 2>/dev/null
      for _ in $(seq 1 30); do alive || break; /bin/sleep 1; done
      rm -f "$PIDFILE"
      if alive; then c_err "no se pudo parar; prueba: pkill -9 -f mlx_vlm.server"; return 1; fi
      c_ok "parado (memoria liberada)"
    }
    
    cmd_status() {
      if ! alive; then c_err "● parado"; return 1; fi
      curl -s "$URL/health" | .venv/bin/python -c "
    import json, sys, subprocess
    d = json.load(sys.stdin)
    print('\033[32m● en marcha\033[0m  ->  http://127.0.0.1:$PORT/v1')
    print('  modelo      ', d['loaded_model'])
    print('  contexto    ', f\"{d['effective_context_limit']:,} tokens\")
    print('  prefix cache', 'sí' if d.get('apc_enabled') else 'no')
    out = subprocess.run(['pgrep','-f','mlx_vlm.server'], capture_output=True, text=True).stdout.split()
    if out:
        ps = subprocess.run(['ps','-o','rss=','-p',out[0]], capture_output=True, text=True).stdout.strip()
        if ps: print('  memoria     ', f'{int(ps)/1048576:.1f} GB')
    "
    }
    
    cmd_logs() { tail -f "$LOG"; }
    
    cmd_test() {
      alive || { c_err "el servidor está parado — arráncalo con ./mlx start"; return 1; }
      echo "Preguntando al modelo…"; echo ""
      curl -s "$URL/v1/chat/completions" -H 'Content-Type: application/json' -d '{
        "model": "mlx-community/Qwen3.8-27B-4bit",
        "messages": [{"role":"user","content":"Explica en dos frases qué es el speculative decoding."}],
        "max_tokens": 160, "temperature": 0.3
      }' | .venv/bin/python -c "
    import json, sys
    d = json.load(sys.stdin)
    print(d['choices'][0]['message']['content'].strip())
    t = d.get('timings') or {}
    print('')
    print('\033[2m%.1f tok/s decode · %.0f tok/s prompt eval\033[0m' % (
        t.get('predicted_per_second', 0), t.get('prompt_per_second', 0)))
    "
    }
    
    cmd_bench() {
      alive || { c_err "el servidor está parado — arráncalo con ./mlx start"; return 1; }
      .venv/bin/python bench.py "$@"
    }
    
    case "${1:-}" in
      start)   shift; cmd_start "$@" ;;
      stop)    cmd_stop ;;
      restart) cmd_stop; shift; cmd_start "$@" ;;
      status)  cmd_status ;;
      logs)    cmd_logs ;;
      test)    cmd_test ;;
      bench)   shift; cmd_bench "$@" ;;
      *)       sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//' ;;
    esac
    """#

    static let benchPy = #"""
    #!/usr/bin/env python3
    """Mide decode tok/s, prompt-eval tok/s y aceptación del drafter MTP.
    
    Usa el bloque `timings` (estilo llama.cpp) que devuelve el servidor mlx-vlm en
    /v1/chat/completions, así que las cifras son las del propio motor, no un
    cronómetro externo.
    """
    
    import argparse
    import json
    import statistics
    import time
    import urllib.request
    
    PROMPTS = [
        "Write a complete Python implementation of a red-black tree with insert, "
        "delete and search, plus docstrings and a small usage example.",
        "Explain step by step how HTTP/3 and QUIC differ from HTTP/2 over TCP, "
        "covering handshake, multiplexing, head-of-line blocking and congestion control.",
        "Write a Rust function that parses an INI file into a nested HashMap, with "
        "error handling, unit tests and comments explaining each branch.",
    ]
    
    
    def post(url: str, payload: dict, timeout: int = 900) -> dict:
        req = urllib.request.Request(
            url,
            data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json"},
        )
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read())
    
    
    def run_one(url: str, model: str, prompt: str, max_tokens: int) -> dict:
        body = {
            "model": model,
            "messages": [{"role": "user", "content": prompt}],
            "max_tokens": max_tokens,
            "temperature": 0.0,
            "stream": False,
        }
        t0 = time.perf_counter()
        resp = post(url, body)
        wall = time.perf_counter() - t0
        t = resp.get("timings") or {}
        usage = resp.get("usage") or {}
        n, acc = t.get("draft_n"), t.get("draft_n_accepted")
        return {
            "decode_tok_s": t.get("predicted_per_second"),
            "prefill_tok_s": t.get("prompt_per_second"),
            "prompt_n": t.get("prompt_n"),
            "predicted_n": t.get("predicted_n") or usage.get("completion_tokens"),
            "peak_memory_gb": t.get("peak_memory"),
            "draft_kind": t.get("draft_kind"),
            "draft_n": n,
            "draft_n_accepted": acc,
            "acceptance_pct": (100.0 * acc / n) if n else None,
            "wall_s": wall,
        }
    
    
    def main() -> None:
        p = argparse.ArgumentParser()
        p.add_argument("--url", default="http://127.0.0.1:8080/v1/chat/completions")
        p.add_argument("--model", default="mlx-community/Qwen3.8-27B-4bit")
        p.add_argument("--max-tokens", type=int, default=512)
        p.add_argument("--reps", type=int, default=3)
        p.add_argument("--label", default="mlx-vlm + MTP")
        p.add_argument("--out", default=None)
        a = p.parse_args()
    
        print(f"warmup…", flush=True)
        run_one(a.url, a.model, "Say hello in one short sentence.", 32)
    
        runs = []
        for i in range(a.reps):
            r = run_one(a.url, a.model, PROMPTS[i % len(PROMPTS)], a.max_tokens)
            runs.append(r)
            acc = f"{r['acceptance_pct']:.1f}%" if r["acceptance_pct"] is not None else "—"
            print(
                f"  run {i + 1}: decode {r['decode_tok_s']:.1f} tok/s · "
                f"prefill {r['prefill_tok_s']:.1f} tok/s · "
                f"aceptación {acc} · {r['predicted_n']} tok · {r['wall_s']:.1f}s",
                flush=True,
            )
    
        def med(k):
            vals = [r[k] for r in runs if r.get(k) is not None]
            return statistics.median(vals) if vals else None
    
        tot_n = sum(r["draft_n"] or 0 for r in runs)
        tot_a = sum(r["draft_n_accepted"] or 0 for r in runs)
        summary = {
            "label": a.label,
            "model": a.model,
            "max_tokens": a.max_tokens,
            "reps": a.reps,
            "decode_tok_s_median": med("decode_tok_s"),
            "prefill_tok_s_median": med("prefill_tok_s"),
            "acceptance_pct_overall": (100.0 * tot_a / tot_n) if tot_n else None,
            "peak_memory_gb": med("peak_memory_gb"),
            "draft_kind": runs[0].get("draft_kind"),
            "runs": runs,
        }
    
        print("\n" + "=" * 62)
        print(f"  {a.label}")
        print("=" * 62)
        print(f"  decode        {summary['decode_tok_s_median']:.1f} tok/s (mediana)")
        print(f"  prompt eval   {summary['prefill_tok_s_median']:.1f} tok/s (mediana)")
        if summary["acceptance_pct_overall"] is not None:
            print(
                f"  aceptación    {summary['acceptance_pct_overall']:.1f}% "
                f"({tot_a}/{tot_n} tokens borrador)"
            )
        print(f"  pico memoria  {summary['peak_memory_gb']:.2f} GB")
        print("=" * 62)
    
        if a.out:
            with open(a.out, "w") as f:
                json.dump(summary, f, indent=2)
            print(f"\nJSON -> {a.out}")
    
    
    if __name__ == "__main__":
        main()
    """#

}
