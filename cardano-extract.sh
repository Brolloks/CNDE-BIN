#!/usr/bin/env bash
# =============================================================================
# cardano-extract.sh — Extract Cardano skey/vkey from a seed phrase
# =============================================================================
# Usage:
#   chmod +x cardano-extract.sh
#   ./cardano-extract.sh [--env /path/to/cardano-extract.env]
#
# Default env file: ./cardano-extract.env (same directory as script)
#
# IMPORTANT: Run this on an offline / air-gapped machine only.
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# ─── Colour helpers ───────────────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
die()     { error "$*"; cleanup; exit 1; }

# ─── Cleanup — securely wipe entire temp directory on exit ───────────────────
TEMP_DIR=""  # set after env load

cleanup() {
    if [[ -n "${TEMP_DIR}" && -d "${TEMP_DIR}" ]]; then
        warn "Securely deleting all temporary key material in ${TEMP_DIR} ..."
        find "${TEMP_DIR}" -type f | while read -r f; do
            "${SHRED_BIN:-shred}" ${SHRED_OPTS:--u -z -n 3} "${f}" 2>/dev/null \
                && info "  Shredded: ${f}" \
                || { warn "  shred failed for ${f} — falling back to rm"; rm -f "${f}"; }
        done
        rm -rf "${TEMP_DIR}"
        success "Temp directory removed."
    fi
    rm -f /tmp/cardano_extract_err
}

# Always run cleanup on any exit — success, failure or Ctrl+C
trap cleanup EXIT

# ─── Parse arguments ──────────────────────────────────────────────────────────
ENV_FILE="$(dirname "$0")/cardano-extract.env"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --env|-e)
            ENV_FILE="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: $0 [--env /path/to/cardano-extract.env]"
            exit 0
            ;;
        *)
            die "Unknown argument: $1. Use --help for usage."
            ;;
    esac
done

# ─── Load env file ────────────────────────────────────────────────────────────
if [[ ! -f "${ENV_FILE}" ]]; then
    die "Env file not found: ${ENV_FILE}"
fi

# Warn if env file is world/group readable
ENV_PERMS=$(stat -c "%a" "${ENV_FILE}")
if [[ "${ENV_PERMS}" != "600" && "${ENV_PERMS}" != "400" ]]; then
    warn "Env file permissions are ${ENV_PERMS}. Recommended: 600"
    warn "Run: chmod 600 \"${ENV_FILE}\""
    read -rp "Continue anyway? (y/N): " CONT
    [[ "${CONT,,}" == "y" ]] || { echo "Aborted."; exit 1; }
fi

# shellcheck source=/dev/null
source "${ENV_FILE}"

# ─── Validate required variables ──────────────────────────────────────────────
check_var() {
    local var_name="$1"
    local var_val="${!var_name}"
    if [[ -z "${var_val}" ]]; then
        die "Required variable ${var_name} is not set in ${ENV_FILE}"
    fi
}

for VAR in SEED_PHRASE ACCOUNT_INDEX ADDRESS_INDEX WALLET_TYPE NETWORK \
           VERIFY_ADDRESS OUTPUT_DIR CARDANO_ADDRESS_BIN CARDANO_CLI_BIN \
           SHRED_BIN TEMP_DIR; do
    check_var "${VAR}"
done

# Validate ACCOUNT_INDEX
if ! [[ "${ACCOUNT_INDEX}" =~ ^[0-9]+$ ]]; then
    die "ACCOUNT_INDEX must be a non-negative integer. Got: ${ACCOUNT_INDEX}"
fi

# Validate ADDRESS_INDEX
if ! [[ "${ADDRESS_INDEX}" =~ ^[0-9]+$ ]]; then
    die "ADDRESS_INDEX must be a non-negative integer. Got: ${ADDRESS_INDEX}"
fi

# Validate WALLET_TYPE
if [[ "${WALLET_TYPE}" != "Shelley" && "${WALLET_TYPE}" != "Byron" ]]; then
    die "WALLET_TYPE must be 'Shelley' or 'Byron'. Got: ${WALLET_TYPE}"
fi

# Validate NETWORK
if [[ "${NETWORK}" != "mainnet" && "${NETWORK}" != "testnet" ]]; then
    die "NETWORK must be 'mainnet' or 'testnet'. Got: ${NETWORK}"
fi

# Validate VERIFY_ADDRESS is not the placeholder
if [[ "${VERIFY_ADDRESS}" == *"PASTE_A_KNOWN"* ]]; then
    die "VERIFY_ADDRESS is still the placeholder. Set it to a real address from your wallet."
fi

# ─── Detect address type from VERIFY_ADDRESS prefix ──────────────────────────
# Base address    (payment + stake): addr1q...  / addr_test1q...
# Enterprise addr (payment only):    addr1v...  / addr_test1v...
if [[ "${VERIFY_ADDRESS}" == addr1q* || "${VERIFY_ADDRESS}" == addr_test1q* ]]; then
    ADDRESS_TYPE="base"
elif [[ "${VERIFY_ADDRESS}" == addr1v* || "${VERIFY_ADDRESS}" == addr_test1v* ]]; then
    ADDRESS_TYPE="enterprise"
else
    ADDRESS_TYPE="base"
    warn "Could not auto-detect address type from prefix — defaulting to base address."
    warn "If verification fails, check your VERIFY_ADDRESS is a valid mainnet/testnet address."
fi

info "Detected address type: ${ADDRESS_TYPE}"

# ─── Banner ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}============================================================${RESET}"
echo -e "${BOLD}  Cardano Key Extractor — Offline Use Only${RESET}"
echo -e "${BOLD}============================================================${RESET}"
echo ""
warn "Ensure this machine is OFFLINE before proceeding."
warn "Your seed phrase will be held in memory during this script."
echo ""
echo -e "  ${BOLD}Wallet type:${RESET}    ${WALLET_TYPE}"
echo -e "  ${BOLD}Network:${RESET}        ${NETWORK}"
echo -e "  ${BOLD}Account index:${RESET}  ${ACCOUNT_INDEX}  (UI Account $((ACCOUNT_INDEX + 1)))"
echo -e "  ${BOLD}Address index:${RESET}  ${ADDRESS_INDEX}"
echo -e "  ${BOLD}Address type:${RESET}   ${ADDRESS_TYPE}"
echo -e "  ${BOLD}Output dir:${RESET}     ${OUTPUT_DIR}"
echo -e "  ${BOLD}Verify address:${RESET} ${VERIFY_ADDRESS}"
echo ""

read -rp "Confirm settings look correct and proceed? (y/N): " CONFIRM
[[ "${CONFIRM,,}" == "y" ]] || { echo "Aborted by user."; exit 0; }

# ─── Check binaries ───────────────────────────────────────────────────────────
echo ""
info "Checking binaries..."

if [[ ! -x "${CARDANO_ADDRESS_BIN}" ]]; then
    die "cardano-address not found or not executable: ${CARDANO_ADDRESS_BIN}"
fi
success "cardano-address: ${CARDANO_ADDRESS_BIN} ($(${CARDANO_ADDRESS_BIN} version 2>/dev/null | head -1 || echo 'version unknown'))"

if [[ ! -x "${CARDANO_CLI_BIN}" ]]; then
    die "cardano-cli not found or not executable: ${CARDANO_CLI_BIN}"
fi
success "cardano-cli:     ${CARDANO_CLI_BIN} ($(${CARDANO_CLI_BIN} version 2>/dev/null | head -1 || echo 'version unknown'))"

if [[ ! -x "${SHRED_BIN}" ]]; then
    die "shred not found: ${SHRED_BIN}. Install: sudo apt install coreutils"
fi
success "shred:           ${SHRED_BIN}"

# ─── Validate seed phrase word count ──────────────────────────────────────────
WORD_COUNT=$(echo "${SEED_PHRASE}" | wc -w)
if [[ "${WORD_COUNT}" -ne 24 && "${WORD_COUNT}" -ne 15 ]]; then
    die "Seed phrase must be 15 or 24 words. Got ${WORD_COUNT} words."
fi
info "Seed phrase word count: ${WORD_COUNT} words ✓"

# ─── Create directories ───────────────────────────────────────────────────────
mkdir -p "${TEMP_DIR}"
chmod 700 "${TEMP_DIR}"
info "Temp directory created: ${TEMP_DIR}"

mkdir -p "${OUTPUT_DIR}"
chmod 700 "${OUTPUT_DIR}"
info "Output directory: ${OUTPUT_DIR}"

# ─── File paths ───────────────────────────────────────────────────────────────
ROOT_PRV="${TEMP_DIR}/root.prv"
ACCT_PRV="${TEMP_DIR}/acct.prv"
PAYMENT_PRV="${TEMP_DIR}/payment.prv"
PAYMENT_PUB="${TEMP_DIR}/payment.pub"
STAKE_PRV="${TEMP_DIR}/stake.prv"

OUT_SKEY="${OUTPUT_DIR}/payment_account${ACCOUNT_INDEX}.skey"
OUT_VKEY="${OUTPUT_DIR}/payment_account${ACCOUNT_INDEX}.vkey"

# ─── Step 1: Root key from seed phrase ────────────────────────────────────────
echo ""
info "Step 1/6 — Deriving root key from seed phrase..."

if ! echo "${SEED_PHRASE}" \
    | "${CARDANO_ADDRESS_BIN}" key from-recovery-phrase "${WALLET_TYPE}" \
    > "${ROOT_PRV}" 2>/tmp/cardano_extract_err; then
    ERR=$(cat /tmp/cardano_extract_err)
    rm -f /tmp/cardano_extract_err
    die "Failed to derive root key. Error: ${ERR}"
fi
rm -f /tmp/cardano_extract_err

if [[ ! -s "${ROOT_PRV}" ]]; then
    die "Root key file is empty. Check your seed phrase."
fi
chmod 600 "${ROOT_PRV}"
success "Root key derived."

# ─── Step 2: Account key derivation ───────────────────────────────────────────
info "Step 2/6 — Deriving account key (index ${ACCOUNT_INDEX})..."

if [[ "${WALLET_TYPE}" == "Shelley" ]]; then
    ACCT_PATH="1852H/1815H/${ACCOUNT_INDEX}H"
else
    ACCT_PATH="44H/1815H/${ACCOUNT_INDEX}H"
fi

info "  Derivation path: m/${ACCT_PATH}"

if ! "${CARDANO_ADDRESS_BIN}" key child "${ACCT_PATH}" \
    < "${ROOT_PRV}" > "${ACCT_PRV}" 2>/tmp/cardano_extract_err; then
    ERR=$(cat /tmp/cardano_extract_err)
    rm -f /tmp/cardano_extract_err
    die "Failed to derive account key. Error: ${ERR}"
fi
rm -f /tmp/cardano_extract_err
chmod 600 "${ACCT_PRV}"
success "Account key derived (path: m/${ACCT_PATH})."

# Shred root key immediately — no longer needed
"${SHRED_BIN}" ${SHRED_OPTS} "${ROOT_PRV}" 2>/dev/null || rm -f "${ROOT_PRV}"
info "Root key securely deleted."

# ─── Step 3: Payment key derivation ───────────────────────────────────────────
info "Step 3/6 — Deriving payment key (role 0, address ${ADDRESS_INDEX})..."

if ! "${CARDANO_ADDRESS_BIN}" key child "0/${ADDRESS_INDEX}" \
    < "${ACCT_PRV}" > "${PAYMENT_PRV}" 2>/tmp/cardano_extract_err; then
    ERR=$(cat /tmp/cardano_extract_err)
    rm -f /tmp/cardano_extract_err
    die "Failed to derive payment key. Error: ${ERR}"
fi
rm -f /tmp/cardano_extract_err
chmod 600 "${PAYMENT_PRV}"

if ! "${CARDANO_ADDRESS_BIN}" key public --with-chain-code \
    < "${PAYMENT_PRV}" > "${PAYMENT_PUB}" 2>/tmp/cardano_extract_err; then
    ERR=$(cat /tmp/cardano_extract_err)
    rm -f /tmp/cardano_extract_err
    die "Failed to derive payment public key. Error: ${ERR}"
fi
rm -f /tmp/cardano_extract_err
chmod 600 "${PAYMENT_PUB}"
success "Payment key pair derived."

# ─── Step 4: Stake key derivation (required for base address verification) ────
# acct.prv is kept alive until BOTH payment and stake keys are derived.
# It is shredded at the end of this step only.
if [[ "${ADDRESS_TYPE}" == "base" ]]; then
    info "Step 4/6 — Deriving stake key (role 2, index 0) for base address..."

    if ! "${CARDANO_ADDRESS_BIN}" key child "2/0" \
        < "${ACCT_PRV}" > "${STAKE_PRV}" 2>/tmp/cardano_extract_err; then
        ERR=$(cat /tmp/cardano_extract_err)
        rm -f /tmp/cardano_extract_err
        die "Failed to derive stake key. Error: ${ERR}"
    fi
    rm -f /tmp/cardano_extract_err
    chmod 600 "${STAKE_PRV}"
    success "Stake key derived."
else
    info "Step 4/6 — Skipping stake key (enterprise address — no stake credential needed)."
fi

# Shred account key now that both payment and stake keys are derived
"${SHRED_BIN}" ${SHRED_OPTS} "${ACCT_PRV}" 2>/dev/null || rm -f "${ACCT_PRV}"
info "Account key securely deleted."

# ─── Step 5: Verify derived address matches expected address ──────────────────
info "Step 5/6 — Verifying derived address matches expected address..."

if [[ "${ADDRESS_TYPE}" == "base" ]]; then
    # Build full base address using the pattern from the official cardano-addresses README:
    #
    #   cat addr.prv \
    #     | cardano-address key public --with-chain-code \
    #     | cardano-address address payment --network-tag mainnet \
    #     | cardano-address address delegation $(cat stake.prv | cardano-address key public --with-chain-code)
    #
    # The stake public key is derived INLINE as the argument to address delegation.
    # The payment address flows through stdin.
    # This avoids the broken pipe that occurs when passing a pre-saved pub key file.

    STAKE_PUB_INLINE=$("${CARDANO_ADDRESS_BIN}" key public --with-chain-code < "${STAKE_PRV}" 2>/tmp/cardano_extract_err)
    if [[ -z "${STAKE_PUB_INLINE}" ]]; then
        ERR=$(cat /tmp/cardano_extract_err 2>/dev/null)
        rm -f /tmp/cardano_extract_err
        die "Failed to derive stake public key inline. Error: ${ERR}"
    fi
    rm -f /tmp/cardano_extract_err

    DERIVED_ADDRESS=$(
        "${CARDANO_ADDRESS_BIN}" key public --with-chain-code \
            < "${PAYMENT_PRV}" \
        | "${CARDANO_ADDRESS_BIN}" address payment \
            --network-tag "${NETWORK}" \
        | "${CARDANO_ADDRESS_BIN}" address delegation \
            "${STAKE_PUB_INLINE}" \
        2>/tmp/cardano_extract_err || true
    )

else
    # Enterprise address: payment credential only (no stake)
    DERIVED_ADDRESS=$(
        "${CARDANO_ADDRESS_BIN}" address payment \
            --network-tag "${NETWORK}" \
            < "${PAYMENT_PUB}" \
        2>/tmp/cardano_extract_err || true
    )
fi

if [[ -z "${DERIVED_ADDRESS}" ]]; then
    ERR=$(cat /tmp/cardano_extract_err 2>/dev/null)
    rm -f /tmp/cardano_extract_err
    die "Failed to derive address for verification. Error: ${ERR}"
fi
rm -f /tmp/cardano_extract_err

echo ""
echo -e "  ${BOLD}Derived address:${RESET}  ${DERIVED_ADDRESS}"
echo -e "  ${BOLD}Expected address:${RESET} ${VERIFY_ADDRESS}"
echo ""

if [[ "${DERIVED_ADDRESS}" != "${VERIFY_ADDRESS}" ]]; then
    error "ADDRESS MISMATCH!"
    error "The derived address does NOT match your expected address."
    error ""
    error "Possible causes:"
    error "  - Wrong ACCOUNT_INDEX (try 0, 1, 2, 3...)"
    error "  - Wrong ADDRESS_INDEX (try 0, 1, 2...)"
    error "  - Wrong WALLET_TYPE (Shelley vs Byron)"
    error "  - Wrong NETWORK (mainnet vs testnet)"
    error "  - Incorrect VERIFY_ADDRESS pasted"
    error "  - Address type mismatch (base vs enterprise)"
    error ""
    error "All temporary files will be securely deleted. Aborting."
    exit 1
fi

success "Address verified! ✓ The derived key matches your wallet."

# ─── Step 6: Convert to cardano-cli skey/vkey format ─────────────────────────
info "Step 6/6 — Converting to cardano-cli skey/vkey format..."

if ! "${CARDANO_CLI_BIN}" key convert-cardano-address-key \
    --shelley-payment-key \
    --signing-key-file "${PAYMENT_PRV}" \
    --out-file "${OUT_SKEY}" 2>/tmp/cardano_extract_err; then
    ERR=$(cat /tmp/cardano_extract_err)
    rm -f /tmp/cardano_extract_err
    die "Failed to convert to skey. Error: ${ERR}"
fi
rm -f /tmp/cardano_extract_err
chmod 600 "${OUT_SKEY}"
success "skey written: ${OUT_SKEY}"

if ! "${CARDANO_CLI_BIN}" key verification-key \
    --signing-key-file "${OUT_SKEY}" \
    --verification-key-file "${OUT_VKEY}" 2>/tmp/cardano_extract_err; then
    ERR=$(cat /tmp/cardano_extract_err)
    rm -f /tmp/cardano_extract_err
    die "Failed to generate vkey. Error: ${ERR}"
fi
rm -f /tmp/cardano_extract_err
chmod 600 "${OUT_VKEY}"
success "vkey written: ${OUT_VKEY}"

# ─── Done ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}============================================================${RESET}"
echo -e "${BOLD}${GREEN}  SUCCESS — Key extraction complete${RESET}"
echo -e "${BOLD}${GREEN}============================================================${RESET}"
echo ""
echo -e "  ${BOLD}Signing key (skey):${RESET}       ${OUT_SKEY}"
echo -e "  ${BOLD}Verification key (vkey):${RESET}  ${OUT_VKEY}"
echo ""
warn "Reminder: Your skey is your private key. Keep it secure."
warn "Delete the skey from this machine once transferred to"
warn "cold storage or wherever you need it."
warn ""
warn "To securely delete after use:"
warn "  shred -u -z -n 3 \"${OUT_SKEY}\""
echo ""
info "Cleaning up remaining temp files via EXIT trap..."
