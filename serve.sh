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
ARGS=(--model "$MODEL" --host "$HOST" --port "$PORT" --max-tokens 16384 --max-kv-size 95536)

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
