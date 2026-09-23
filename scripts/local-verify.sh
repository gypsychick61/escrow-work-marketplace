#!/usr/bin/env bash
# Local end-to-end verification against a real ICRC-1/2 ledger.
#
# This is a custodial canister, so "it compiles" is not verification. This
# script stands up a throwaway ledger, funds a real escrow, runs a job through
# to payment, and then checks the numbers against the ledger rather than
# against what the canister says about itself.
#
# Usage:  ./scripts/local-verify.sh
# Needs:  dfx, python3, curl, and local-ledger/ic-icrc1-ledger.wasm.gz
#         (copy it from any ICP release, or from a sibling project).
#
# The clock-expiry paths — an unanswered review releasing to the worker, a
# missed delivery refunding the buyer — are not exercised here, because their
# deadlines are days long and a local replica cannot be moved days ahead of the
# host clock without breaking ingress-message expiry. Those live in
# ./scripts/verify-expiry.sh, which compresses the clock instead of the wait and
# restores src/main.mo when it is done. Run both; neither alone is the whole story.

set -euo pipefail
cd "$(dirname "$0")/.."

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
ok()  { printf '  ok   %s\n' "$*"; }
bad() { printf '  FAIL %s\n' "$*"; exit 1; }

dfx identity new escrow-worker --storage-mode plaintext 2>/dev/null || true

BUYER=$(dfx identity get-principal --identity default)
WORKER=$(dfx identity get-principal --identity escrow-worker)
MINTER=$(dfx identity get-principal --identity ledger-minter 2>/dev/null || echo "$BUYER")

say "Deploying a throwaway ICRC-1/2 ledger"
dfx deploy test_ledger --argument "(variant { Init = record {
  token_symbol = \"TESTUSD\"; token_name = \"Test USD\";
  minting_account = record { owner = principal \"$MINTER\" };
  transfer_fee = 10_000; decimals = opt (6 : nat8); metadata = vec {};
  initial_balances = vec { record { record { owner = principal \"$BUYER\" }; 1_000_000_000 : nat } };
  feature_flags = opt record { icrc2 = true };
  archive_options = record {
    num_blocks_to_archive = 1000 : nat64; trigger_threshold = 2000 : nat64;
    controller_id = principal \"$MINTER\";
  };
} })" >/dev/null

say "Deploying the marketplace"
dfx deploy escrow_work_marketplace >/dev/null
ESCROW=$(dfx canister id escrow_work_marketplace)
LEDGER=$(dfx canister id test_ledger)

# The allowlist is deployer-only and not an MCP tool, so a local ledger has to
# be added deliberately — which is the point of it existing.
dfx canister call escrow_work_marketplace admin_allow_asset \
  "(\"$LEDGER\", \"TESTUSD\", 6:nat8, 100_000_000:nat)" >/dev/null

BUYER_KEY=$(dfx canister call escrow_work_marketplace create_my_api_key '("buyer", vec {})' --identity default | sed -n 's/.*"\(.*\)".*/\1/p')
WORKER_KEY=$(dfx canister call escrow_work_marketplace create_my_api_key '("worker", vec {})' --identity escrow-worker | sed -n 's/.*"\(.*\)".*/\1/p')

mcp() { # mcp <key> <tool> <json>
  curl -s -X POST "http://127.0.0.1:4943/mcp?canisterId=$ESCROW" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -H "x-api-key: $1" \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"$2\",\"arguments\":${3:-\{\}}}}"
}
field() { python3 -c "import sys,json;d=json.load(sys.stdin)['result'];print(json.dumps(d.get('structuredContent') or d['content'][0]['text']))" ; }
balance() { dfx canister call test_ledger icrc1_balance_of "(record { owner = principal \"$1\" })" | tr -dc '0-9'; }

say "1. A bounty is drafted, and it is private until it is funded"
ID=$(mcp "$BUYER_KEY" create_bounty "{\"title\":\"Reconcile Q3 books\",\"brief\":\"140 entries, find what is miscoded.\",\"acceptance\":\"Trial balance balances; 6900 Uncategorized is zero.\",\"skills\":\"bookkeeping\",\"amount\":15,\"ledger\":\"$LEDGER\",\"delivery_days\":5,\"review_window_hours\":24,\"revisions_allowed\":1}" \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['result']['structuredContent']['bounty']['id'])")
ok "bounty $ID drafted"

say "2. Funding refuses without an allowance, and says exactly what to approve"
NEED=$(mcp "$BUYER_KEY" fund_bounty "{\"bounty\":$ID}" | python3 -c "import sys,json;print(json.load(sys.stdin)['result']['structuredContent']['need_minor'])")
[ "$NEED" = "15020000" ] || bad "expected to need 15.02 (bounty + two ledger fees), got $NEED"
ok "asked for 15.020000 — the bounty plus the fee in and the fee out"

say "3. Funded: the money is in the bounty's own subaccount"
dfx canister call test_ledger icrc2_approve "(record { spender = record { owner = principal \"$ESCROW\" }; amount = 100_000_000 : nat })" --identity default >/dev/null
mcp "$BUYER_KEY" fund_bounty "{\"bounty\":$ID}" >/dev/null
SUB=$(printf '%064x' "$ID" | sed 's/../\\&/g')
HELD=$(dfx canister call test_ledger icrc1_balance_of "(record { owner = principal \"$ESCROW\"; subaccount = opt blob \"$(echo $SUB | sed 's/\\\\/\\/g')\" })" | tr -dc '0-9')
[ "$HELD" = "15010000" ] || bad "escrow subaccount holds $HELD, expected 15010000"
ok "the ledger — not this canister — confirms 15.010000 in subaccount $ID"

say "4. The brief is frozen (invariant 2) and self-claiming is refused (invariant 8)"
mcp "$BUYER_KEY" update_bounty "{\"bounty\":$ID,\"acceptance\":\"something else\"}" | grep -q "no longer be edited" || bad "a funded brief was editable"
ok "editing a funded brief is refused"
mcp "$BUYER_KEY" claim_bounty "{\"bounty\":$ID}" | grep -q "cannot claim your own" || bad "buyer claimed their own bounty"
ok "the buyer cannot claim their own bounty"

say "5. A worker finds it, claims it, and delivers"
mcp "$WORKER_KEY" search_bounties '{"skill":"bookkeeping"}' | grep -q "Reconcile Q3" || bad "funded bounty not in the listing"
mcp "$WORKER_KEY" claim_bounty "{\"bounty\":$ID}" >/dev/null
mcp "$WORKER_KEY" submit_work "{\"bounty\":$ID,\"hash\":\"ab12\",\"pointer\":\"https://example.com/q3.md\",\"kind\":\"text/markdown\"}" >/dev/null
ok "claimed and submitted"

say "6. Approval pays the worker the round number on the listing"
BEFORE=$(balance "$WORKER")
mcp "$BUYER_KEY" approve_work "{\"bounty\":$ID,\"note\":\"Clean work.\"}" >/dev/null
AFTER=$(balance "$WORKER")
[ $((AFTER - BEFORE)) = "15000000" ] || bad "worker received $((AFTER - BEFORE)), expected 15000000"
ok "worker received exactly 15.000000 — the outbound fee came from the extra pulled at funding"

say "7. A released bounty cannot be released again (invariant 4)"
mcp "$BUYER_KEY" approve_work "{\"bounty\":$ID}" | grep -q "released" || bad "double approval was not refused"
ok "second approval refused"

say "8. The cap and the allowlist both hold (invariant 9)"
mcp "$BUYER_KEY" create_bounty "{\"title\":\"Too big\",\"brief\":\"b\",\"acceptance\":\"a\",\"amount\":150,\"ledger\":\"$LEDGER\"}" | grep -q "over the v1 cap" || bad "the cap did not hold"
ok "150 TESTUSD refused against a 100 cap"
mcp "$BUYER_KEY" create_bounty '{"title":"Hostile","brief":"b","acceptance":"a","amount":5,"ledger":"aaaaa-aa"}' | grep -q "not on the allowlist" || bad "an unknown ledger was accepted"
ok "an unknown ledger is refused, which is what closes the hostile-ledger hole"

say "9. Concurrent claims are capped at three"
for i in 1 2 3 4; do
  N=$(mcp "$BUYER_KEY" create_bounty "{\"title\":\"Job $i\",\"brief\":\"b\",\"acceptance\":\"a\",\"amount\":5,\"ledger\":\"$LEDGER\",\"delivery_days\":3}" | python3 -c "import sys,json;print(json.load(sys.stdin)['result']['structuredContent']['bounty']['id'])")
  mcp "$BUYER_KEY" fund_bounty "{\"bounty\":$N}" >/dev/null
  RESULT=$(mcp "$WORKER_KEY" claim_bounty "{\"bounty\":$N}")
  if [ "$i" -le 3 ]; then
    echo "$RESULT" | grep -q "is yours" || bad "claim $i was refused"
  else
    echo "$RESULT" | grep -q "which is the limit" || bad "the fourth claim was allowed"
    ok "the fourth concurrent claim is refused"
  fi
done

say "All checks passed."
