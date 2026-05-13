#!/usr/bin/env bash
# ============================================================================
#  PPREV Protocol — Reviewer Reproducibility Script
# ============================================================================
#  Regenerates the on-chain gas analysis tables published in the paper's
#  Section VII and verifies them against the committed baseline.
#
#  Output:
#    output/analysis_tables.md  --  human-readable tables (paper Tables I/II/III)
#    output/gas_raw.json        --  raw forge gas-report JSON (for diffing)
#
#  Exit codes:
#    0  All measurements within tolerance of baseline.
#    1  Numeric drift detected (exceeds baseline.json tolerance_pct).
#    2  forge test failed (compile/test error).
#    3  Missing dependency or parse error.
#
#  Usage (from PPREV Implementation/ root):
#    ./scripts/run_and_verify.sh
# ============================================================================

set -u
set -o pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
IMPL_ROOT="$( cd "${SCRIPT_DIR}/.." && pwd )"
OUT_DIR="${IMPL_ROOT}/output"
BASELINE="${SCRIPT_DIR}/baseline.json"
RAW_JSON="${OUT_DIR}/gas_raw.json"
TABLE_MD="${OUT_DIR}/analysis_tables.md"

FORGE=""
for cand in "${HOME}/.foundry/bin/forge" "$(command -v forge 2>/dev/null || true)"; do
    if [[ -x "${cand}" ]]; then FORGE="${cand}"; break; fi
done
if [[ -z "${FORGE}" ]]; then
    echo "error: forge not found (looked in ~/.foundry/bin/forge and \$PATH)" >&2
    exit 3
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "error: jq is required for JSON parsing. Install via 'brew install jq'." >&2
    exit 3
fi

if [[ ! -f "${BASELINE}" ]]; then
    echo "error: baseline file missing: ${BASELINE}" >&2
    exit 3
fi

mkdir -p "${OUT_DIR}"

# Portable thousands-separator (BSD printf doesn't honor "%'d" without locale)
fmt() { awk -v n="$1" 'BEGIN{
    s=sprintf("%d", n); neg=""
    if (substr(s,1,1)=="-") { neg="-"; s=substr(s,2) }
    out=""; len=length(s)
    for (i=1; i<=len; i++) {
        out = out substr(s, i, 1)
        if ((len-i) % 3 == 0 && i < len) out = out ","
    }
    print neg out
}'; }

echo "▸ Running forge test --gas-report (this takes ~10s)..."
cd "${IMPL_ROOT}"
if ! "${FORGE}" test --gas-report --json >"${RAW_JSON}" 2>"${OUT_DIR}/forge.stderr"; then
    echo "error: forge test failed. Stderr:" >&2
    cat "${OUT_DIR}/forge.stderr" >&2
    exit 2
fi

if ! jq empty "${RAW_JSON}" 2>/dev/null; then
    echo "error: forge output was not valid JSON. See ${RAW_JSON}" >&2
    exit 3
fi

extract_op_gas() {
    local op="$1" stat="$2"
    jq -r --arg op "${op}" --arg stat "${stat}" '
        .[]
        | select(.contract == "src/PPREVSingle.sol:PPREVSingle")
        | .functions
        | to_entries[]
        | select(.key | startswith($op + "("))
        | .value[$stat]
    ' "${RAW_JSON}"
}

extract_verifier_gas() {
    local contract="$1" fn="$2"
    jq -r --arg c "${contract}" --arg f "${fn}" '
        .[]
        | select(.contract == ("src/PPREVSingle.sol:" + $c))
        | .functions
        | to_entries[]
        | select(.key | startswith($f + "("))
        | .value.median
    ' "${RAW_JSON}"
}

extract_deployment() {
    local contract="$1" field="$2"
    jq -r --arg c "${contract}" --arg f "${field}" '
        .[]
        | select(.contract == ("src/PPREVSingle.sol:" + $c))
        | .deployment[$f]
    ' "${RAW_JSON}"
}

TOL_PCT=$(jq -r '.tolerance_pct' "${BASELINE}")

# Operations in protocol order: register → applyTx → engage → settle → expire → cancel
declare -a OPS
for op in register applyTx engage settle expire cancel; do
    stat=$(jq -r --arg op "${op}" '.operations[$op].stat' "${BASELINE}")
    base=$(jq -r --arg op "${op}" '.operations[$op].gas'  "${BASELINE}")
    meas=$(extract_op_gas "${op}" "${stat}")
    if [[ -z "${meas}" || "${meas}" == "null" ]]; then
        echo "error: could not extract gas for ${op} (stat=${stat})" >&2
        exit 3
    fi
    drift=$(awk -v b="${base}" -v m="${meas}" 'BEGIN{ if (b==0){print "inf"} else {printf "%.3f", (m-b)/b*100} }')
    OPS+=("${op}|${stat}|${base}|${meas}|${drift}")
done

# Verifier costs.
declare -a VERS
for entry in \
    "ECDSANotaryVerifier|verifySignature" \
    "MockNotaryVerifier|verifySignature"; do
    contract="${entry%|*}"; fn="${entry#*|}"
    base=$(jq -r --arg k "${contract}.${fn}" '.verifiers[$k].gas' "${BASELINE}")
    meas=$(extract_verifier_gas "${contract}" "${fn}")
    drift=$(awk -v b="${base}" -v m="${meas}" 'BEGIN{ if (b==0){print "inf"} else {printf "%.3f", (m-b)/b*100} }')
    VERS+=("${contract}.${fn}|${base}|${meas}|${drift}")
done

DEP_GAS_BASE=$(jq -r '.deployment.PPREVSingle.gas'   "${BASELINE}")
DEP_GAS_MEAS=$(extract_deployment PPREVSingle gas)
DEP_BYTES_BASE=$(jq -r '.deployment.PPREVSingle.bytes' "${BASELINE}")
DEP_BYTES_MEAS=$(extract_deployment PPREVSingle size)
DEP_DRIFT=$(awk -v b="${DEP_GAS_BASE}" -v m="${DEP_GAS_MEAS}" 'BEGIN{ printf "%.3f", (m-b)/b*100 }')

# Lifecycle total = register + applyTx + engage + settle (all four phases on-chain).
get_meas() { local op="$1"; for r in "${OPS[@]}"; do IFS='|' read -ra a <<<"${r}"; if [[ "${a[0]}" == "${op}" ]]; then echo "${a[3]}"; return; fi; done; }
LC_BASE=$(jq -r '.lifecycle_total_gas' "${BASELINE}")
LC_MEAS=$(( $(get_meas register) + $(get_meas applyTx) + $(get_meas engage) + $(get_meas settle) ))
LC_DRIFT=$(awk -v b="${LC_BASE}" -v m="${LC_MEAS}" 'BEGIN{ printf "%.3f", (m-b)/b*100 }')

TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
COMMIT=$(git -C "${IMPL_ROOT}" rev-parse --short HEAD 2>/dev/null || echo "no-git")

{
    echo "# PPREV Reproducibility Tables"
    echo ""
    echo "Generated: ${TIMESTAMP}  •  Commit: ${COMMIT}  •  Tolerance: ${TOL_PCT}%"
    echo ""
    echo "Reproduces the on-chain figures published in the paper's Section VII."
    echo "Run via \`./scripts/run_and_verify.sh\` from the implementation root."
    echo ""
    echo "## Table 1 — Deployment"
    echo ""
    echo "| Contract | Gas | Runtime bytes |"
    echo "|---|---:|---:|"
    echo "| PPREVSingle | $(fmt "${DEP_GAS_MEAS}") | $(fmt "${DEP_BYTES_MEAS}") |"
    echo ""
    echo "## Table 2 — Per-Operation On-Chain Gas (MockNotaryVerifier)"
    echo ""
    echo "| Operation | Stat | Measured gas |"
    echo "|---|:--:|---:|"
    for r in "${OPS[@]}"; do
        IFS='|' read -ra a <<<"${r}"
        echo "| ${a[0]} | ${a[1]} | $(fmt "${a[3]}") |"
    done
    echo ""
    echo "Lifecycle total (Register + Apply + Engage + Settle): **$(fmt "${LC_MEAS}") gas**"
    echo ""
    echo "## Table 3 — Verifier Cost per Verification Call"
    echo ""
    echo "| Verifier | Function | Gas |"
    echo "|---|---|---:|"
    for r in "${VERS[@]}"; do
        IFS='|' read -ra a <<<"${r}"
        ckey="${a[0]}"; cname="${ckey%.*}"; fname="${ckey#*.}"
        echo "| ${cname} | ${fname} | $(fmt "${a[2]}") |"
    done
    echo ""
    echo "## Table 4 — Drift vs Paper Baseline"
    echo ""
    echo "| Metric | Baseline | Measured | Drift % |"
    echo "|---|---:|---:|---:|"
    echo "| Deployment gas | $(fmt "${DEP_GAS_BASE}") | $(fmt "${DEP_GAS_MEAS}") | ${DEP_DRIFT}% |"
    echo "| Deployment bytes | $(fmt "${DEP_BYTES_BASE}") | $(fmt "${DEP_BYTES_MEAS}") | — |"
    for r in "${OPS[@]}"; do
        IFS='|' read -ra a <<<"${r}"
        echo "| ${a[0]} (${a[1]}) | $(fmt "${a[2]}") | $(fmt "${a[3]}") | ${a[4]}% |"
    done
    for r in "${VERS[@]}"; do
        IFS='|' read -ra a <<<"${r}"
        ckey="${a[0]}"
        echo "| ${ckey} | $(fmt "${a[1]}") | $(fmt "${a[2]}") | ${a[3]}% |"
    done
    echo "| Lifecycle total | $(fmt "${LC_BASE}") | $(fmt "${LC_MEAS}") | ${LC_DRIFT}% |"
    echo ""
} >"${TABLE_MD}"

FAIL=0
check_drift() {
    local name="$1" drift="$2"
    local abs
    abs=$(awk -v d="${drift}" 'BEGIN{ if (d<0) d=-d; printf "%.3f", d }')
    local over
    over=$(awk -v a="${abs}" -v t="${TOL_PCT}" 'BEGIN{ print (a>t) ? 1 : 0 }')
    if [[ "${over}" == "1" ]]; then
        echo "  ✗ ${name}: drift ${drift}% exceeds tolerance ${TOL_PCT}%"
        FAIL=1
    fi
}

echo ""
echo "▸ Drift check (tolerance ${TOL_PCT}%):"
check_drift "deployment" "${DEP_DRIFT}"
for r in "${OPS[@]}"; do
    IFS='|' read -ra a <<<"${r}"
    check_drift "${a[0]}" "${a[4]}"
done
for r in "${VERS[@]}"; do
    IFS='|' read -ra a <<<"${r}"
    check_drift "${a[0]}" "${a[3]}"
done
check_drift "lifecycle_total" "${LC_DRIFT}"

echo ""
if [[ "${FAIL}" == "1" ]]; then
    echo "✗ FAIL — drift exceeds tolerance. Inspect ${TABLE_MD} and update ${BASELINE} if intentional."
    exit 1
else
    echo "✓ PASS — all measurements within ${TOL_PCT}% of paper baseline."
    echo "  Tables written to: ${TABLE_MD}"
    exit 0
fi
