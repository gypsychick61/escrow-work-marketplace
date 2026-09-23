#!/usr/bin/env bash
# Clock-expiry verification — the half local-verify.sh cannot reach.
#
# "Silence always resolves" is the load-bearing promise of this canister, and it
# is the one behaviour a normal test run never exercises: the deadlines are days
# long, and a local replica cannot be moved days ahead of the host clock without
# breaking ingress-message expiry. So this script compresses the clock instead of
# the wait — an hour becomes a second, a day becomes two — by patching the two
# constants in src/main.mo, redeploying, and letting the same code settle in real
# time. src/main.mo is restored on exit, including on failure or Ctrl-C.
#
# It runs two passes, because the timer and settle_due cannot be tested in the
# same build: with a fast timer, the timer wins every race and no settle_due
# assertion means anything.
#
#   pass 1 — timer left at 900s so it never fires: settle_due, reclaim_bounty,
#            and the two states that must NOT settle (not yet due, disputed).
#   pass 2 — timer at 3s: nobody calls anything, and the escrow still resolves.
#
# Usage:  ./scripts/verify-expiry.sh      (needs a running replica: dfx start)
# Runtime: about four minutes, most of it two builds and ~60s of real waiting.

set -euo pipefail
cd "$(dirname "$0")/.."
export DFX_WARNING=-mainnet_plaintext_identity

SRC=src/main.mo
BACKUP="$(mktemp -t escrow-main-mo)"
cp "$SRC" "$BACKUP"
# Restore the source AND rebuild from it. Without the rebuild this script leaves a
# compressed-clock wasm in .dfx/local — which is the file prometheus.yml's wasm_path
# points at. A canister where an hour is a second must never outlive this script.
restore() {
  cp "$BACKUP" "$SRC"; rm -f "$BACKUP"
  printf '\n  ..   restoring src/main.mo and rebuilding at real clock speed\n'
  dfx build escrow_work_marketplace >/dev/null 2>&1 \
    || printf '  WARN rebuild failed — .dfx/local still holds a COMPRESSED-CLOCK wasm; run: dfx build\n'
}
trap restore EXIT

say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '  ok   %s\n' "$*"; }
bad()  { printf '  FAIL %s\n' "$*"; exit 1; }
note() { printf '       %s\n' "$*"; }

dfx identity new escrow-worker   --storage-mode plaintext 2>/dev/null || true
dfx identity new escrow-stranger --storage-mode plaintext 2>/dev/null || true

BUYER=$(dfx identity get-principal --identity default)
WORKER=$(dfx identity get-principal --identity escrow-worker)
MINTER=$(dfx identity get-principal --identity ledger-minter 2>/dev/null || echo "$BUYER")

# compress <timer-seconds> — patch the clock constants and the sweep interval.
compress() {
  cp "$BACKUP" "$SRC"
  perl -pi -e "s/(nanosPerHour : Nat = )3_600_000_000_000/\${1}1_000_000_000/;
               s/(nanosPerDay : Nat = )86_400_000_000_000/\${1}2_000_000_000/;
               s/#seconds 900/#seconds $1/" "$SRC"
  grep -q 'nanosPerHour : Nat = 1_000_000_000'  "$SRC" || bad "could not compress nanosPerHour — has the constant been renamed?"
  grep -q 'nanosPerDay : Nat = 2_000_000_000'   "$SRC" || bad "could not compress nanosPerDay — has the constant been renamed?"
  grep -q "#seconds $1"                         "$SRC" || bad "could not retime the sweep timer"
}

# setup — fresh ledger, fresh canister, allowlist, three API keys.
setup() {
  dfx deploy test_ledger --mode reinstall --yes --argument "(variant { Init = record {
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
  dfx deploy escrow_work_marketplace --mode reinstall --yes >/dev/null

  ESCROW=$(dfx canister id escrow_work_marketplace)
  LEDGER=$(dfx canister id test_ledger)

  dfx canister call escrow_work_marketplace admin_allow_asset \
    "(\"$LEDGER\", \"TESTUSD\", 6:nat8, 100_000_000:nat)" >/dev/null

  BUYER_KEY=$(dfx    canister call escrow_work_marketplace create_my_api_key '("buyer", vec {})'    --identity default         | sed -n 's/.*"\(.*\)".*/\1/p')
  WORKER_KEY=$(dfx   canister call escrow_work_marketplace create_my_api_key '("worker", vec {})'   --identity escrow-worker   | sed -n 's/.*"\(.*\)".*/\1/p')
  STRANGER_KEY=$(dfx canister call escrow_work_marketplace create_my_api_key '("stranger", vec {})' --identity escrow-stranger | sed -n 's/.*"\(.*\)".*/\1/p')

  # One allowance, large enough for every bounty this script funds.
  dfx canister call test_ledger icrc2_approve \
    "(record { spender = record { owner = principal \"$ESCROW\" }; amount = 500_000_000 : nat })" \
    --identity default >/dev/null
}

mcp() { # mcp <key> <tool> <json>
  curl -s -X POST "http://127.0.0.1:4943/mcp?canisterId=$ESCROW" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -H "x-api-key: $1" \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"$2\",\"arguments\":${3:-\{\}}}}"
}

balance() { dfx canister call test_ledger icrc1_balance_of "(record { owner = principal \"$1\" })" | tr -dc '0-9'; }

held() { # held <bounty-id> — what the ledger says is in that bounty's subaccount
  local sub
  sub=$(printf '%064x' "$1" | sed 's/../\\&/g')
  dfx canister call test_ledger icrc1_balance_of \
    "(record { owner = principal \"$ESCROW\"; subaccount = opt blob \"$(echo $sub | sed 's/\\\\/\\/g')\" })" | tr -dc '0-9'
}

state() { # state <key> <bounty-id>
  mcp "$1" get_bounty "{\"bounty\":$2}" \
    | python3 -c "import sys,json;d=json.load(sys.stdin)['result']['structuredContent'];print(d['bounty']['state'])"
}

new_bounty() { # new_bounty <delivery-days> <review-hours> — drafts and funds, echoes the id
  local id
  id=$(mcp "$BUYER_KEY" create_bounty "{\"title\":\"Clock test\",\"brief\":\"b\",\"acceptance\":\"a\",\"skills\":\"testing\",\"amount\":15,\"ledger\":\"$LEDGER\",\"delivery_days\":$1,\"review_window_hours\":$2,\"revisions_allowed\":1}" \
    | python3 -c "import sys,json;print(json.load(sys.stdin)['result']['structuredContent']['bounty']['id'])")
  mcp "$BUYER_KEY" fund_bounty "{\"bounty\":$id}" >/dev/null
  echo "$id"
}

# ---------------------------------------------------------------- pass 1

say "PASS 1 — compressed clocks, sweep timer parked at 900s"
compress 900
setup
note "1 hour = 1s, 1 day = 2s; the review-window floor of 24h is now 24s"

say "1. A submission that is still inside its review window will not settle"
A=$(new_bounty 5 24)
mcp "$WORKER_KEY" claim_bounty "{\"bounty\":$A}" >/dev/null
mcp "$WORKER_KEY" submit_work "{\"bounty\":$A,\"hash\":\"ab12\",\"pointer\":\"https://example.com/a.md\",\"kind\":\"text/markdown\"}" >/dev/null
OUT=$(mcp "$STRANGER_KEY" settle_due "{\"bounty\":$A}")
echo "$OUT" | grep -q "review window has" || bad "settle_due did not refuse a live review window: $OUT"
[ "$(held "$A")" = "15010000" ] || bad "an unsettled bounty's escrow moved"
ok "refused, with the time remaining — and the escrow is untouched"

say "2. Silence from the buyer pays the worker, and a stranger can force it"
BEFORE=$(balance "$WORKER")
sleep 26
OUT=$(mcp "$STRANGER_KEY" settle_due "{\"bounty\":$A}")
echo "$OUT" | grep -q "released" || bad "settle_due did not release after the window expired: $OUT"
AFTER=$(balance "$WORKER")
[ $((AFTER - BEFORE)) = "15000000" ] || bad "worker received $((AFTER - BEFORE)), expected 15000000"
[ "$(held "$A")" = "0" ] || bad "bounty $A still holds $(held "$A") after release"
ok "worker paid exactly 15.000000 by a principal who is neither party"
note "the subaccount is empty afterwards — the canister keeps nothing"

say "3. A worker who never delivers refunds the buyer"
B=$(new_bounty 1 24)
mcp "$WORKER_KEY" claim_bounty "{\"bounty\":$B}" >/dev/null
BEFORE=$(balance "$BUYER")
sleep 4
OUT=$(mcp "$STRANGER_KEY" settle_due "{\"bounty\":$B}")
echo "$OUT" | grep -q "refunded" || bad "settle_due did not refund a missed delivery: $OUT"
AFTER=$(balance "$BUYER")
[ $((AFTER - BEFORE)) = "15000000" ] || bad "buyer got back $((AFTER - BEFORE)), expected 15000000"
[ "$(held "$B")" = "0" ] || bad "bounty $B still holds $(held "$B") after refund"
ok "buyer refunded exactly 15.000000"

say "4. reclaim_bounty is refused before the deadline and works after it"
C=$(new_bounty 1 24)
mcp "$WORKER_KEY" claim_bounty "{\"bounty\":$C}" >/dev/null
mcp "$BUYER_KEY" reclaim_bounty "{\"bounty\":$C}" | grep -q "the job is theirs" || bad "the buyer reclaimed a job that was still live"
ok "an early reclaim is refused — the job is still the worker's"
BEFORE=$(balance "$BUYER")
sleep 4
mcp "$BUYER_KEY" reclaim_bounty "{\"bounty\":$C}" | grep -q "back in your account" || bad "reclaim failed after the deadline passed"
AFTER=$(balance "$BUYER")
[ $((AFTER - BEFORE)) = "15000000" ] || bad "reclaim returned $((AFTER - BEFORE)), expected 15000000"
ok "after the deadline the buyer gets the full 15.000000 back"

say "5. A dispute stops the clock — an expired disputed bounty does NOT settle"
D=$(new_bounty 1 24)
mcp "$WORKER_KEY" claim_bounty "{\"bounty\":$D}" >/dev/null
mcp "$BUYER_KEY" dispute_bounty "{\"bounty\":$D,\"reason\":\"Work never started.\"}" >/dev/null
sleep 4
OUT=$(mcp "$STRANGER_KEY" settle_due "{\"bounty\":$D}")
echo "$OUT" | grep -q "clocks are stopped" || bad "a disputed bounty was settled by settle_due: $OUT"
[ "$(held "$D")" = "15010000" ] || bad "disputed bounty $D holds $(held "$D"), expected the escrow to be parked intact"
ok "settle_due refuses it and the money stays parked in the subaccount"

say "6. A bare settle_due sweep settles what is due and leaves the rest alone"
E=$(new_bounty 5 24)
mcp "$WORKER_KEY" claim_bounty "{\"bounty\":$E}" >/dev/null
mcp "$WORKER_KEY" submit_work "{\"bounty\":$E,\"hash\":\"cd34\",\"pointer\":\"https://example.com/e.md\",\"kind\":\"text/markdown\"}" >/dev/null
F=$(new_bounty 5 24)
sleep 26
COUNT=$(mcp "$STRANGER_KEY" settle_due '{}' | python3 -c "import sys,json;print(json.load(sys.stdin)['result']['structuredContent']['count'])")
[ "$COUNT" = "1" ] || bad "the bare sweep settled $COUNT bounties, expected exactly 1"
[ "$(state "$WORKER_KEY" "$E")" = "released" ] || bad "the due bounty was not released by the sweep"
[ "$(state "$BUYER_KEY" "$F")" = "open" ]      || bad "the sweep touched an open, unclaimed bounty"
[ "$(held "$D")" = "15010000" ] || bad "the sweep moved money on the disputed bounty"
ok "one settled, the open bounty and the disputed one left exactly where they were"

# ---------------------------------------------------------------- pass 2

say "PASS 2 — same clocks, sweep timer at 3s, and nobody calls anything"
compress 3
setup

say "7. The timer alone resolves an unanswered submission"
G=$(new_bounty 5 24)
mcp "$WORKER_KEY" claim_bounty "{\"bounty\":$G}" >/dev/null
mcp "$WORKER_KEY" submit_work "{\"bounty\":$G,\"hash\":\"ef56\",\"pointer\":\"https://example.com/g.md\",\"kind\":\"text/markdown\"}" >/dev/null
BEFORE=$(balance "$WORKER")
note "waiting out a 24s review window with no settle_due call at all"
SETTLED=no
for _ in $(seq 1 20); do
  sleep 3
  if [ "$(state "$WORKER_KEY" "$G")" = "released" ]; then SETTLED=yes; break; fi
done
[ "$SETTLED" = "yes" ] || bad "the recurring timer never settled bounty $G"
AFTER=$(balance "$WORKER")
[ $((AFTER - BEFORE)) = "15000000" ] || bad "timer paid $((AFTER - BEFORE)), expected 15000000"
[ "$(held "$G")" = "0" ] || bad "bounty $G still holds $(held "$G") after the timer released it"
ok "the timer released 15.000000 to the worker with no caller involved"

say "All clock-expiry checks passed."
note "src/main.mo is restored; redeploy before using this replica for anything else."
