# Escrow Work Marketplace

An MCP server for the [Prometheus Protocol](https://prometheusprotocol.org) app store:
post a job, escrow the bounty on-chain, and let an agent claim it.

> **Status: built and locally verified. Not yet deployed to mainnet.**
> `src/main.mo` implements the full v1 surface — nineteen tools — and
> `scripts/local-verify.sh` runs it end to end against a real ICRC-1/2 ledger.
> What is left before a store listing: icon and banner assets, and the
> `git_commit` in `prometheus.yml`.

## The idea

[Press](https://prometheusprotocol.org) proved on this store that agents will do paid work:
a curator escrows a bounty, an agent writes the article, approval releases the money. That
machinery is not really about articles. Code review, bookkeeping cleanup, data labeling,
transcription, QA — the escrow, the brief, the deadline, and the release-on-approval are
identical, and only the deliverable changes.

The deliverable is also the one thing a canister should never have opinions about, so this
one doesn't. It holds a content hash and a pointer, timestamps them, and enforces a clock.

What it does instead is remove the two ways freelance work actually goes wrong:

- **The money is provably present before the worker starts** — pulled via `icrc2_transfer_from`
  into a subaccount derived deterministically from the bounty id, so either party can check
  the ledger directly rather than trusting this server's own reporting.
- **The acceptance criteria freeze the moment it's funded** — hashed and returned in every
  read, so the goalposts cannot move after someone has begun.

Silence always resolves: an unanswered submission releases to the worker, a missed delivery
deadline refunds the buyer, and a public `settle_due` lets anyone force the outcome the
rules already guarantee.

## The money, exactly

Funding pulls the bounty **plus one ledger fee** into escrow, so the worker is paid the
round number on the listing rather than that number minus whatever the ledger charged on
the way out. A 15 ckUSDC bounty on a ledger charging 0.01 costs the buyer 15.02 in
allowance, holds 15.01 in escrow, and pays the worker exactly 15.00.

Every bounty's funds live in **its own subaccount** — the bounty id big-endian in the low
8 bytes of a 32-byte blob. The derivation is trivial on purpose: compute it yourself, call
`icrc1_balance_of`, and check the money without this server in the loop. `get_escrow_proof`
does the same call for you and tells you when the two numbers disagree.

**v1 caps a bounty at 100 ckUSDC**, per ledger via an allowlist. An unlisted ledger has no
cap and is therefore refused — which is also what stops a bounty pointing escrow at a
hostile ledger canister. The cap makes the marketplace look small, because in v1 it is; it
also bounds what the first custody bug can cost.

## What it will not do

**It does not judge work.** The canister never sees the deliverable. Quality is the buyer's
call, and where the buyer will not make one, the clock decides.

**It does not moderate, curate, or rank.** Reputation belongs to the
[Review & Reputation Oracle](https://github.com/gypsychick61/review-reputation-oracle);
this server returns the `submit_review` call on release rather than growing a score of its
own.

**It does not arbitrate in v1.** A dispute stops every clock and parks the funds, and there
is no exit from that state, because half-built arbitration moves real money wrongly and
confidently. Disputing is a last resort, not a negotiating move.

**It does not escrow anything but allowlisted ICRC-1/2 tokens.** No fiat, no "mark as paid".

## Privacy — read this before posting a job

**Bounties are public.** From the moment one is funded, the brief, the acceptance criteria,
the amount, the buyer's principal, and the entire history are readable by anyone. That is
what makes it a marketplace. Only an unfunded draft is private, and only to its buyer.

**The deliverable is not stored here, and its pointer is public.** This canister holds a
hash and a URL. So, bluntly: do not put a confidential deliverable behind a public URL, and
know that the *fact* of the job is public either way. v1 has nothing better to offer —
access-controlled delivery wants a document-storage server that does not exist yet.

**Bids are semi-private:** the buyer sees every bid, a worker sees only their own.

## Tools

Nineteen, all free in v1.

| | |
|---|---|
| **Buyer** | `create_bounty` `update_bounty` `fund_bounty` `cancel_bounty` |
| **Anyone** | `search_bounties` `get_bounty` `get_escrow_proof` |
| **Worker** | `claim_bounty` `submit_bid` `list_bids` `select_worker` `submit_work` `withdraw_claim` |
| **Settling** | `approve_work` `request_changes` `reclaim_bounty` `settle_due` `dispute_bounty` `my_work` |

## Verifying it

```sh
dfx start --clean --background
./scripts/local-verify.sh
```

The script deploys a throwaway ICRC-1/2 ledger, funds a real escrow, runs a job through to
payment, and checks every number against the ledger rather than against what the canister
says about itself. It covers funding, the frozen brief, self-claim refusal, payout exactness,
double-release refusal, the cap, the allowlist, and the concurrent-claim cap.

The clock-expiry paths need one extra step, because a local replica cannot be moved days
ahead of the host clock without breaking ingress expiry: set `nanosPerHour` to
`1_000_000_000` and `nanosPerDay` to `2_000_000_000` in `src/main.mo`, redeploy, and the
same code settles in seconds. Verified that way — a ghosted review releases to the worker,
a vanished worker refunds the buyer — then both constants restored.

## Design notes

[`SPEC.md`](SPEC.md) is the real document: data model, tool surface, the invariants, the
release problem, and the open questions. Two things worth knowing:

1. **This is a custodial canister.** Every other server in this lineup refuses to move
   money. This one has to hold and release funds — that is the product — so re-entrancy and
   upgrade migration get a level of care a server whose worst bug is a wrong number does not
   need. See invariant 4, the double-release bug: every ledger call is made from an
   intermediate state that all other entry points reject.
2. **v1 caps bounty size** (invariant 9). A cap is an admission that the code is new, and it
   is a cheaper admission than the alternative.

Decisions taken at build time, against the spec's open questions: the cap stays at 100
ckUSDC (q4); `#firstClaim` spam is blunted by a three-job concurrent-claim cap (q2); and the
fee path is built at 0% now rather than added later to a canister holding live escrows (q5).

## License

Not yet chosen.
