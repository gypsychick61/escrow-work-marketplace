# Escrow Work Marketplace

An MCP server for the [Prometheus Protocol](https://prometheusprotocol.org) app store:
post a job, escrow the bounty on-chain, and let an agent claim it.

> **Status: design draft. There is no implementation yet.**
> This repository currently holds the spec and a draft store manifest — no `src/main.mo`,
> no deployed canister, no store listing. `prometheus.yml` describes the intended v1 and is
> not submittable (`git_commit` and the visuals are placeholders).

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

## What it will not do

It does not judge work, moderate, rank, or arbitrate. Reputation belongs to the
[Review & Reputation Oracle](https://github.com/gypsychick61/review-reputation-oracle); a
dispute in v1 stops every clock and parks the funds, and the spec says plainly that v1 has
no exit for that state, because half-built arbitration moves real money wrongly and
confidently.

## Design notes

[`SPEC.md`](SPEC.md) is the real document: data model, the eighteen-tool surface, the
invariants, the release problem, and the open questions.

Two things worth knowing before reading it:

1. **This is a custodial canister.** Every other server in this lineup refuses to move money.
   This one has to hold and release funds — that is the product — so upgrade migration and
   re-entrancy get a level of care that a server whose worst bug is a wrong number doesn't
   need. See invariant 4, the double-release bug.
2. **v1 caps bounty size** (invariant 9), per ledger via an asset allowlist. A cap makes the
   marketplace look small, because in v1 it is; it also bounds the blast radius of the first
   custody bug in code that has never held anyone's money.

## License

Not yet chosen.
