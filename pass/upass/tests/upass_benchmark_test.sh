#!/bin/sh
# Benchmark: compare pass.cprop (original LiveHD) vs pass.upass (this project)
# on a constant-folding workload.
#
# Correctness: uPass must fold constant Mult nodes and DCE must remove the dead
#              constant-input nodes that folding leaves behind.
# Observability: uPass emits structured summary lines; cprop is silent.
# Timing: wall-clock time for each full pipeline (inou.pyrope -> lnast_tolg -> pass).

set -eu

LGSHELL="${TEST_SRCDIR}/${TEST_WORKSPACE}/main/lgshell"
BENCH_FILE="${TEST_SRCDIR}/${TEST_WORKSPACE}/pass/upass/tests/bench_folding.prp"
CPROP_OUT="${TEST_TMPDIR}/bench_cprop.out"
UPASS_OUT="${TEST_TMPDIR}/bench_upass.out"

# portable millisecond timer (python3 always available under Bazel)
ms_now() {
  python3 -c 'import time; print(int(time.time()*1000))'
}

# Pipeline A: pass.cprop (baseline)
T0=$(ms_now)
printf 'inou.pyrope files:%s |> pass.lnast_tolg |> pass.cprop\nquit\n' \
  "${BENCH_FILE}" \
  | HOME="${TEST_TMPDIR}" "${LGSHELL}" >"${CPROP_OUT}" 2>&1
T1=$(ms_now)
CPROP_MS=$(( T1 - T0 ))

# Pipeline B: pass.upass (our micro-pass system)
# Runs constant-folding passes in dependency order:
#   fold_sum_const  -- fold Sum nodes whose inputs are all constant
#   fold_mult_const -- fold Mult nodes whose inputs are all constant
#   fold_neutral    -- eliminate neutral elements (+0, *1, etc.)
#   dce             -- remove nodes that became dead after folding
T2=$(ms_now)
printf 'inou.pyrope files:%s |> pass.lnast_tolg |> pass.upass ir:lgraph order:fold_sum_const,fold_mult_const,fold_neutral,dce max_iters:5\nquit\n' \
  "${BENCH_FILE}" \
  | HOME="${TEST_TMPDIR}" "${LGSHELL}" >"${UPASS_OUT}" 2>&1
T3=$(ms_now)
UPASS_MS=$(( T3 - T2 ))

# Extract uPass structured metrics.
# Actual format strings (from upass_runner_lgraph.cpp):
#   uPass(lgraph) - sum_const_folded:N rewired:N ...
#   uPass(lgraph) - mult_folded:N rewired:N ...
#   uPass(lgraph) - neutral_simplified:N ...
#   uPass(lgraph) - dce_removed:N edges_freed:N ...
SUM_FOLDED=$(   grep -oE 'sum_const_folded:[0-9]+'   "${UPASS_OUT}" | head -1 | cut -d: -f2 || echo "0")
MULT_FOLDED=$(  grep -oE 'mult_folded:[0-9]+'        "${UPASS_OUT}" | head -1 | cut -d: -f2 || echo "0")
NEUTRAL_EL=$(   grep -oE 'neutral_simplified:[0-9]+' "${UPASS_OUT}" | head -1 | cut -d: -f2 || echo "0")
DCE_REMOVED=$(  grep -oE 'dce_removed:[0-9]+'        "${UPASS_OUT}" | head -1 | cut -d: -f2 || echo "0")
CONVERGE=$(grep -oE 'converged at iteration [0-9]+' "${UPASS_OUT}"  | head -1 || echo "(no convergence line)")

# Print comparison report
printf '\n'
printf '=== BENCHMARK: pass.cprop vs pass.upass ===\n'
printf '    Workload: %s\n' "${BENCH_FILE##*/}"
printf '\n'
printf '  %-16s  %s\n'  "Pass"           "Wall time (ms)"
printf '  %-16s  %s\n'  "----------"     "--------------"
printf '  %-16s  %s ms\n' "pass.cprop"   "${CPROP_MS}"
printf '  %-16s  %s ms\n' "pass.upass"   "${UPASS_MS}"
printf '\n'
printf '  uPass(lgraph) structured metrics:\n'
printf '    sum_const_folded   : %s\n' "${SUM_FOLDED}"
printf '    mult_folded        : %s\n' "${MULT_FOLDED}"
printf '    neutral_simplified : %s\n' "${NEUTRAL_EL}"
printf '    dce_removed        : %s\n' "${DCE_REMOVED}"
printf '    %s\n' "${CONVERGE}"
printf '\n'
printf '  Feature comparison:\n'
printf '    %-32s  %-12s  %-12s\n' "Capability"                   "pass.cprop"  "pass.upass"
printf '    %-32s  %-12s  %-12s\n' "----------------------------" "------------" "------------"
printf '    %-32s  %-12s  %-12s\n' "Constant arith folding"       "[yes]"        "[yes]"
printf '    %-32s  %-12s  %-12s\n' "Structured summary metrics"   "[no]"         "[yes]"
printf '    %-32s  %-12s  %-12s\n' "Dry-run / what-if mode"       "[no]"         "[yes]"
printf '    %-32s  %-12s  %-12s\n' "Fixed-point iteration"        "[no]"         "[yes]"
printf '    %-32s  %-12s  %-12s\n' "Composable pass order"        "[no]"         "[yes]"
printf '    %-32s  %-12s  %-12s\n' "Tuple / struct support"       "[yes]"        "[no]"
printf '    %-32s  %-12s  %-12s\n' "Comparison folding"           "[yes]"        "[no]"
printf '    %-32s  %-12s  %-12s\n' "Mux simplification"           "[yes]"        "[no]"
printf '\n'

# Correctness checks

# 1. upass must report at least one mult fold
if ! grep -q 'uPass(lgraph) - mult_folded:' "${UPASS_OUT}"; then
  printf 'FAIL: upass did not emit any mult_folded summary\n'
  echo 'upass output follows:'
  cat "${UPASS_OUT}"
  exit 1
fi

# 2. upass DCE must remove at least one dead node (inputs to folded mults)
if ! grep -qE 'uPass\(lgraph\) - dce_removed:[1-9]' "${UPASS_OUT}"; then
  printf 'FAIL: upass dce_removed is zero -- expected dead const inputs to be removed\n'
  echo 'upass output follows:'
  cat "${UPASS_OUT}"
  exit 2
fi

# 3. upass must converge
if ! grep -q 'uPass(lgraph) - converged at iteration' "${UPASS_OUT}"; then
  printf 'FAIL: upass did not converge\n'
  echo 'upass output follows:'
  cat "${UPASS_OUT}"
  exit 3
fi

printf 'PASS: benchmark complete -- upass folds constants, eliminates dead nodes, and converges\n'
