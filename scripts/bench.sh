#!/usr/bin/env bash
# Measure what the running plugin costs: the engine process(es) the bar started.
# Usage: scripts/bench.sh [seconds]   (default 30; `mise run bench -- 60`)
#
# Per engine process, over the window: CPU (% of one core and ms per snapshot),
# memory (PSS), threads, context switches per second and disk reads/writes.
# quickshell is shown for reference only: it is the whole shell, not just this plugin.
set -Eeuo pipefail

seconds="${1:-30}"
interval="${LLM_USAGE_INTERVAL:-2}"
ticks_per_s="$(getconf CLK_TCK)"

# utime+stime ticks, voluntary+involuntary context switches, read/write bytes.
sample() {
  local pid=$1 stat
  stat="$(<"/proc/$pid/stat")" || return 1
  stat="${stat##*) }"
  read -r -a f <<<"$stat"
  local cpu=$((f[11] + f[12]))
  local ctx
  ctx="$(awk '/ctxt_switches/ {n += $2} END {print n + 0}' "/proc/$pid/status")"
  local io
  io="$(awk '/^(read|write)_bytes/ {n[$1] = $2} END {print n["read_bytes:"] + 0, n["write_bytes:"] + 0}' "/proc/$pid/io" 2>/dev/null || echo "0 0")"
  echo "$cpu $ctx $io"
}

pss_mib() { awk '/^Pss:/ {printf "%.1f", $2 / 1024}' "/proc/$1/smaps_rollup" 2>/dev/null || echo "?"; }
threads() { awk '/^Threads:/ {print $2}' "/proc/$1/status"; }

mapfile -t engines < <(pgrep -x engine || true)
mapfile -t shells < <(pgrep -x quickshell || true)
if ((${#engines[@]} == 0)); then
  echo "bench: no running engine found. Is the plugin loaded in the bar?" >&2
  exit 1
fi

pids=("${engines[@]}" "${shells[@]}")
declare -A before after
for pid in "${pids[@]}"; do before[$pid]="$(sample "$pid")"; done
echo "Sampling ${#engines[@]} engine process(es) for ${seconds}s (snapshot every ${interval}s)..."
sleep "$seconds"
for pid in "${pids[@]}"; do after[$pid]="$(sample "$pid" || true)"; done

printf '\n%-12s %7s %9s %12s %9s %8s %9s %9s\n' process pid "cpu %" "ms/snapshot" "PSS MiB" threads "ctx/s" "io KiB/s"
total_cpu=0
for pid in "${pids[@]}"; do
  [[ -n ${after[$pid]} ]] || continue
  read -r c0 x0 r0 w0 <<<"${before[$pid]}"
  read -r c1 x1 r1 w1 <<<"${after[$pid]}"
  name="$(<"/proc/$pid/comm")"
  cpu_s="$(awk -v d=$((c1 - c0)) -v t="$ticks_per_s" 'BEGIN {printf "%.4f", d / t}')"
  awk -v n="$name" -v p="$pid" -v cpu="$cpu_s" -v s="$seconds" -v i="$interval" \
      -v pss="$(pss_mib "$pid")" -v th="$(threads "$pid")" \
      -v ctx=$((x1 - x0)) -v io=$((r1 - r0 + w1 - w0)) 'BEGIN {
        printf "%-12s %7d %9.2f %12.2f %9s %8s %9.0f %9.1f\n",
          n, p, 100 * cpu / s, 1000 * cpu / (s / i), pss, th, ctx / s, io / 1024 / s }'
  [[ $name == engine ]] && total_cpu="$(awk -v a="$total_cpu" -v b="$cpu_s" 'BEGIN {print a + b}')"
done
awk -v cpu="$total_cpu" -v s="$seconds" 'BEGIN {printf "\nEngine total: %.2f%% of one core (%.3f%% of this machine'"'"'s CPU)\n", 100 * cpu / s, 100 * cpu / s / '"$(nproc)"'}'
