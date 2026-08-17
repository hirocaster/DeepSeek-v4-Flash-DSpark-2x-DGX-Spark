#!/usr/bin/env bash
# hotfix-dsv4-mq-spin-51950.sh — Bound the shm_broadcast SpinCondition busy-loop
#
# Backport of upstream vLLM PR #51950 ("Expose MessageQueue busy-loop duration
# as VLLM_MQ_SPIN_SECONDS") applied to the Anemll dspark-vllm-gx10 0.1.1 image
# (vLLM 0.25.2.dev0+g752a3a504.d20260714). Upstream PR currently closed pending
# re-validation; this is the same change carried as a recipe hotfix until it
# lands in a base image and can be dropped wholesale.
#
# WHAT IT FIXES: SpinCondition readers in shm_broadcast.py busy-loop
# (`sched_yield`) for `busy_loop_s` seconds after the last message before
# falling back to blocking on the zmq notify socket. The 1-second default is
# hardcoded at both call sites. During decode, messages arrive every few ms, so
# readers never reach the idle path — the hybrid wait degenerates into a
# permanent spin that pins 3-4 performance cores at 100% doing no useful work.
# On GB10 (CPU + GPU share a package) this becomes the dominant heat source:
# measured on 2x GX10 TP=2 (this recipe's stack) it drove vLLM CPU to 333% and
# the SoC hot-spot sensor past 90°C while the GPU stayed ~20°C cooler.
#
# THIS BACKPORT makes the window configurable via VLLM_MQ_SPIN_SECONDS and DOES
# NOT change the default (1s = historical always-spin behavior). The GB10
# recipe then sets VLLM_MQ_SPIN_SECONDS=0.002 in .env.dspark, which was measured
# to drop vLLM CPU 333% -> 89% and SoC by ~11°C with throughput and first-token
# latency flat. Because the default is preserved, non-GB10 hosts are unaffected
# unless they opt in (and the 1s default keeps the idle-wakeup path untouched).
#
# The patch rewrites the `busy_loop_s` default expression in SpinCondition and
# adds `import os` (absent in the 0.25.1-lineage file). It also registers the
# key in vllm/envs.py (best-effort, NON-fatal) so the process does not log
# "Unknown vLLM environment variable detected: VLLM_MQ_SPIN_SECONDS" on boot.
# The functional read in shm_broadcast.py does not depend on that registration.
#
# Usage:
#   docker cp hotfix-dsv4-mq-spin-51950.sh <container>:/tmp/ && \
#   docker exec <container> bash /tmp/hotfix-dsv4-mq-spin-51950.sh
#   # then stop + start the server yourself (this script never restarts it)
#
# Apply on BOTH nodes (each node runs its own container). Idempotent.
# The compose entrypoint runs this before `exec vllm serve`; a failure here
# stops the container loudly instead of silently starting an unpatched vLLM.
#
# Validation (run from the HOST, not in the container):
#   bash hotfix-dsv4-mq-spin-51950.sh --before   # pre-restart SoC/CPU snapshot
#   ... apply + restart yourself, replay typical load ...
#   bash hotfix-dsv4-mq-spin-51950.sh --after    # post-restart SoC/CPU snapshot
set -euo pipefail

VLLM_ROOT="${VLLM_ROOT:-/usr/local/lib/python3.12/dist-packages/vllm}"
CONTAINER="${CONTAINER:-deepseek-v4-flash-vllm-dspark-1}"
RESULTS_DIR="${RESULTS_DIR:-$(cd "$(dirname "$0")" && pwd)/../results}"
BASELINE_FILE="$RESULTS_DIR/hotfix-51950-thermal-baseline.txt"
AFTER_FILE="$RESULTS_DIR/hotfix-51950-thermal-after.txt"

ACTION="${1:-patch}"

# VLLM_ROOT is only needed for patch / --status (which run inside the container
# via docker exec). The host-side --before/--after capture modes only need the
# docker/thermal tooling, so skip the check there.
if [ "$ACTION" != "--before" ] && [ "$ACTION" != "--baseline" ] \
   && [ "$ACTION" != "--after" ] && [ "$ACTION" != "--verify" ]; then
  if [ ! -d "$VLLM_ROOT" ]; then
    echo "ERROR: vLLM not found at $VLLM_ROOT" >&2
    exit 1
  fi
fi

# ---- validation helpers (host side) -----------------------------------------
capture_thermal_snapshot() {
  local tag="$1" outfile="$2"
  {
    echo "=== thermal snapshot ($tag) $(date -Is) ==="
    echo "-- SoC thermal zones (host: /sys/class/thermal) --"
    for z in /sys/class/thermal/thermal_zone*; do
      [ -r "$z/temp" ] || continue
      local path
      path=$(cat "$z/device/firmware_node/path" 2>/dev/null || true)
      printf '  %-8s %-28s %3d C\n' "${z##*/}" "${path:-unknown}" \
        "$(( $(cat "$z/temp") / 1000 ))"
    done
    echo "-- vLLM cgroup CPU over 6s --"
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER"; then
      local s1 s2 pct
      s1=$(docker exec "$CONTAINER" sh -c 'cat /sys/fs/cgroup/cpu.stat 2>/dev/null' \
        | awk '/^usage_usec /{print $2}')
      sleep 6
      s2=$(docker exec "$CONTAINER" sh -c 'cat /sys/fs/cgroup/cpu.stat 2>/dev/null' \
        | awk '/^usage_usec /{print $2}')
      if [ -n "$s1" ] && [ -n "$s2" ]; then
        # usage_usec delta / 6s = sum of core utilization; 333 means ~3.3 cores.
        pct=$(awk -v a="$s1" -v b="$s2" 'BEGIN { printf "%.1f", (b-a)/1e6/6*100 }')
        printf '  %s%% (sum over cores: 333 = ~3.33 cores spinning)\n' "$pct"
      else
        echo "  (cgroup cpu.stat unavailable inside container)"
      fi
    else
      echo "  (container $CONTAINER is not running)"
    fi
  } > "$outfile"
  echo "[OK] $tag snapshot -> $outfile"
}

if [ "$ACTION" = "--before" ] || [ "$ACTION" = "--baseline" ]; then
  mkdir -p "$RESULTS_DIR"
  capture_thermal_snapshot "BEFORE (pre-restart)" "$BASELINE_FILE"
  echo ""
  echo "Next: apply the patch, restart the server yourself, then run:"
  echo "  bash $(basename "$0") --after"
  exit 0
fi

if [ "$ACTION" = "--after" ] || [ "$ACTION" = "--verify" ]; then
  if [ ! -f "$BASELINE_FILE" ]; then
    echo "ERROR: no baseline at $BASELINE_FILE — run --before first" >&2
    exit 1
  fi
  mkdir -p "$RESULTS_DIR"
  capture_thermal_snapshot "AFTER (post-restart)" "$AFTER_FILE"
  echo ""
  echo "=== SoC / CPU diff (BEFORE -> AFTER) ==="
  python3 - "$BASELINE_FILE" "$AFTER_FILE" <<'PY'
import sys


def grab(f: str) -> dict[str, int | float | str]:
    out: dict[str, str] = {}
    try:
        for line in open(f):
            line = line.rstrip("\n")
            if line.startswith("  ") and " C " in line:
                # "  thermal_zone4 \\_TZ_.TSOC     96 C"
                parts = line.split()
                if len(parts) >= 4:
                    out[parts[1]] = parts[-2]
            if line.startswith("  ") and "% (sum over cores" in line:
                val = line.split()[0]
                out["vllm_cpu_sum"] = val
    except FileNotFoundError:
        pass
    return out


B, A = grab(sys.argv[1]), grab(sys.argv[2])
for zone, b in B.items():
    a = A.get(zone)
    if a is not None and b != a:
        print(f"  {zone:28} {b:>6} C -> {a:>6} C")
for key in ("vllm_cpu_sum",):
    if key in B and key in A and B[key] != A[key]:
        print(f"  {key:28} {B[key]:>6}% -> {A[key]:>6}%")
PY
  echo ""
  echo "Expected #51950 effect on an idle/low-load window: vLLM CPU collapses"
  echo "(333% -> ~89% under active load) and TS1P/TS0P/TSOC drop by 10-20 C."
  exit 0
fi

if [ "$ACTION" = "--status" ]; then
  python3 - "$VLLM_ROOT" <<'PY'
import sys
from pathlib import Path

root = Path(sys.argv[1])
shm = root / "distributed/device_communicators/shm_broadcast.py"
envs = root / "envs.py"
MARK = "# [hotfix-dsv4-mq-spin-51950]"

if shm.is_file() and MARK in shm.read_text():
    st = "APPLIED"
else:
    st = "NOT APPLIED"
print(f"shm_broadcast busy_loop_s env read : {st}")

if envs.is_file() and "VLLM_MQ_SPIN_SECONDS" in envs.read_text():
    et = "APPLIED"
elif envs.is_file():
    et = "NOT APPLIED"
else:
    et = "envs.py missing"
print(f"envs.py VLLM_MQ_SPIN_SECONDS reg    : {et}")
PY
  exit 0
fi

if [ "$ACTION" != "patch" ]; then
  echo "Usage: $0 [patch|--status|--verify|--before|--after]" >&2
  exit 2
fi

# ---- patch (default action) -------------------------------------------------
echo "=== Hotfix: bound SpinCondition busy-loop via VLLM_MQ_SPIN_SECONDS (upstream #51950 backport) ==="
echo "vLLM root: $VLLM_ROOT  image: 0.25.2.dev0+g752a3a504.d20260714"

python3 - "$VLLM_ROOT" <<'PY'
import sys
from pathlib import Path

root = Path(sys.argv[1])
MARK = "# [hotfix-dsv4-mq-spin-51950]"

# Required: spin window becomes env-configurable (default 1s preserved).
shm = root / "distributed/device_communicators/shm_broadcast.py"
if not shm.is_file():
    print(f"[ERR] shm_broadcast.py not found: {shm}", file=sys.stderr)
    sys.exit(1)

text = shm.read_text()
if MARK in text:
    print("[skip] shm_broadcast.py (already applied)")
else:
    import_old = "import functools\nimport pickle\n"
    import_new = "import os\nimport functools\nimport pickle\n"
    busy_old = "busy_loop_s: float = 1,"
    busy_new = (
        'busy_loop_s: float = float(os.getenv("VLLM_MQ_SPIN_SECONDS", "1")), '
        + MARK
    )
    errors = []
    if text.count(import_old) != 1:
        errors.append(f"import anchor not found (count={text.count(import_old)})")
    if text.count(busy_old) != 1:
        errors.append(f"busy_loop_s anchor not found (count={text.count(busy_old)})")
    if errors:
        print("[ERR] shm_broadcast.py anchors do not match this image:", file=sys.stderr)
        for e in errors:
            print(f"  {e}", file=sys.stderr)
        sys.exit(1)
    text = text.replace(import_old, import_new).replace(busy_old, busy_new)
    shm.write_text(text)
    print("[OK]   shm_broadcast.py busy_loop_s -> os.getenv(VLLM_MQ_SPIN_SECONDS, 1s) + import os")

# Best-effort (non-fatal): register the key so the boot does not warn
# "Unknown vLLM environment variable detected: VLLM_MQ_SPIN_SECONDS".
envs = root / "envs.py"
if envs.is_file():
    et = envs.read_text()
    if "VLLM_MQ_SPIN_SECONDS" in et:
        print("[skip] envs.py registration (already present)")
    else:
        old = '''    "VLLM_MQ_MAX_CHUNK_BYTES_MB": lambda: int(
        os.getenv("VLLM_MQ_MAX_CHUNK_BYTES_MB", "16")
    ),'''
        new = old + '''
    # [hotfix-dsv4-mq-spin-51950] bound SpinCondition busy-loop window.
    "VLLM_MQ_SPIN_SECONDS": lambda: float(
        os.getenv("VLLM_MQ_SPIN_SECONDS", "1")
    ),'''
        if et.count(old) == 1:
            envs.write_text(et.replace(old, new))
            print("[OK]   envs.py VLLM_MQ_SPIN_SECONDS registered")
        else:
            print("[WARN] envs.py anchor did not match on this image; the boot"
                  " may log a benign 'Unknown vLLM environment variable' warning"
                  " (functional read in shm_broadcast.py is unaffected).")
else:
    print("[WARN] vllm/envs.py not found; skipping registration (benign boot warning possible).")

print("")
print("=== Verification ===")
PY

bash "$0" --status

echo ""
echo "Stop + start the vLLM process (or the container) to take effect."
echo "Set VLLM_MQ_SPIN_SECONDS=0.002 in .env.dspark on GB10 to opt into the"
echo "measured 333%->89% CPU / -11 C SoC result (default 1s = stock behavior)."
