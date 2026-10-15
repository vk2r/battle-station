#!/usr/bin/env bash
# Free the GPU memory held by local LLM runtimes. Models are unloaded through
# each runtime's own API where it has one, so its service keeps running and
# loads them again on the next request:
#   llama.cpp router  POST /models/unload for every loaded model
#   Ollama            keep_alive 0 for every model in memory
#   LM Studio         lms unload --all (its daemon keeps running)
# A llama-server without the router, and vLLM, cannot unload a model: the user
# systemd unit that owns the process is stopped instead (whatever its name),
# which ends its workers (KillMode=control-group). Nothing outside the user's
# own units is touched, and nothing runs as root.
set -u

api() { curl -fsS --max-time 5 "$@"; }

# The user systemd unit a process belongs to, e.g. llama-router.service.
user_unit() {
  sed -n 's#^0::/user.slice/user-[0-9]*\.slice/user@[0-9]*\.service/\(.*/\)\{0,1\}\([^/]*\.service\)$#\2#p' "/proc/$1/cgroup" 2>/dev/null
}

stop_units_of() {
  local pid unit
  for pid in "$@"; do
    unit="$(user_unit "$pid")"
    [[ -n $unit ]] && systemctl --user stop "$unit" 2>/dev/null
  done
}

freed=0

# llama.cpp: the router lists its models; a plain llama-server has no /models
# states, so its unit is stopped.
if pids=$(pgrep -u "$UID" -x llama-server); then
  listing=$(api http://127.0.0.1:8080/models 2>/dev/null)
  if jq -e '.data[0].status' >/dev/null 2>&1 <<<"$listing"; then
    models=$(jq -r '.data[] | select(.status.value | IN("loaded", "loading", "sleeping")) | .id' <<<"$listing")
    while IFS= read -r model; do
      [[ -n $model ]] || continue
      api -X POST -H 'Content-Type: application/json' \
        -d "$(jq -cn --arg model "$model" '{model: $model}')" \
        http://127.0.0.1:8080/models/unload >/dev/null && freed=1
    done <<<"$models"
  else
    # Not a router: LM Studio's and Ollama's engines share the name, leave them alone.
    for pid in $pids; do
      grep -qE 'ollama|lm-studio|\.lmstudio' "/proc/$pid/cmdline" 2>/dev/null && continue
      stop_units_of "$pid" && freed=1
    done
  fi
fi

# Ollama (user or system service alike): drop every resident model right away.
if pgrep -x ollama >/dev/null; then
  while IFS= read -r model; do
    [[ -n $model ]] || continue
    api -X POST -d "$(jq -cn --arg model "$model" '{model: $model, keep_alive: 0}')" \
      http://127.0.0.1:11434/api/generate >/dev/null && freed=1
  done < <(api http://127.0.0.1:11434/api/ps 2>/dev/null | jq -r '.models[]?.name' 2>/dev/null)
fi

# vLLM keeps its model for the life of the server.
if pids=$(pgrep -u "$UID" -f 'vllm(\s+serve|\.entrypoints)'); then
  stop_units_of $pids && freed=1
fi

# LM Studio: unload all models, keep the daemon.
lms_bin="$(command -v lms || echo "$HOME/.lmstudio/bin/lms")"
if [[ -x $lms_bin ]] && pgrep -f "lm-studio --run-as-service|\.lmstudio/extensions" >/dev/null; then
  "$lms_bin" unload --all >/dev/null 2>&1 && freed=1
fi

if ((freed)); then
  notify-send -a "Engines" "GPU memory freed" "Local LLM models were unloaded." 2>/dev/null || true
else
  notify-send -a "Engines" "Nothing to free" "No local LLM model was holding GPU memory." 2>/dev/null || true
fi
