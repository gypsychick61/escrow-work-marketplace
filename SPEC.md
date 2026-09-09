# Escrow Work Marketplace — MCP Server Spec

Status: **design draft, nothing built.** The sole top pick on the Prometheus App Store
opportunity map (business operations), confirmed still open by live registry queries on
September 2 and September 9, 2026. This document is the pre-work: data model, tool surface,
invariants, and the decisions that have to be made before `src/main.mo` exists.

## Decided

**2026-09-09 — v1 ships with a per-bounty size cap** (open question 4, resolved). Roblynn's
call. The cap is a design decision in the type, not a config knob, and it is enforced as
**invariant 9**. Proposed figure: **100 ckUSDC**, and because `Asset` admits any ICRC
ledger the cap has to be expressed per ledger rather than as one number — see invariant 9
for the allowlist that falls out of it, which v1 needed anyway. Changing the figure later
is one constant; removing the cap after launch is an upgrade that changes what is
acceptable on live escrows, so the number wants to be roughly right now.

---

## Why this exists

**Press** (`io.github.jneums.press`, Atlas Labs, Silver) proved the pattern on this store:
curators post briefs with escrowed ICP bounties, agents research and write articles against
them, and payment releases when the curator approves. It works, and it is the store's only
labor market.

It is also only about articles.

The pattern generalizes to anything an agent can deliver and a human can check — code
review, bookkeeping cleanup, data labeling, design, transcription, research, QA passes. The
escrow, the brief, the deadline, and the release-on-approval are identical in every one of
those. Only the deliverable changes, and the deliverable is the one part the canister should
never have opinions about.

So: **Press's machinery, with the article-shaped assumptions removed.**

The reason to build it on-chain is not ideology. A freelance escrow is exactly the thing
neither party trusts the other to hold, and every off-chain marketplace solves that by
being a company you have to trust instead. Here the escrow is a canister whose rules are
readable and whose balances are auditable by both sides, and the buyer's money is provably
present before the worker starts — which is the single most common way freelance work goes
wrong.

---

## The one that breaks the house pattern

Every server in this lineup so far has refused to move money. Dispatch Scheduler quotes a
price and hands settlement to Invoice Desk. Subscription Auditor is read-only by design and
returns the `icrc2_approve` call rather than making it. The Bookkeeping Ledger spec is
blunt about it: *"a ledger that can also spend is a ledger nobody should trust to describe
its own spending."*

**This server has to hold and release funds. That is the product.** An escrow that only
describes an escrow is not an escrow.

That makes it the first custodial canister here, and it deserves a different level of care
than a server where the worst bug is a wrong number:

- **A state-migration bug on upgrade loses other people's money**, not just data. Stable
  state, no orphaned balances, and an upgrade checklist that reconciles held balances
  against open bounties before and after.
- **Re-entrancy is a real exploit here, not a theoretical one.** Motoko interleaves at every
  `await`. A release that awaits the ledger while still in `#submitted` can be released
  twice. See invariant 4 — this is the bug that would actually cost someone money.
- **v1 caps bounty size** (see open question 4). A cap is an admission that the code is new,
  and it is a cheaper admission than the alternative.

None of that is a reason not to build it. It is a reason the build is slower than
Subscription Auditor was, and the spec says so up front so that is not a surprise in week
two.

---

## What it will not do

**It does not judge work.** The canister never sees the deliverable and could not evaluate
it if it did. It holds a hash and a pointer, timestamps them, and enforces a clock. Quality
is the buyer's call, and where the buyer will not make one, the clock decides — not the
canister's opinion of the work.

**It does not moderate, curate, or rank.** No featured listings, no takedowns, no quality
score of its own. Reputation is the Review & Reputation Oracle's job and it already
shipped; this server feeds it rather than growing a second one.

**It does not arbitrate in v1.** A dispute parks the funds and stops the clock. It does not
resolve them. Half-built arbitration is worse than none, because a bad arbiter with real
authority moves money wrongly and confidently — see open question 1, where this is named as
the boundary rather than quietly deferred.

**It does not escrow anything but ICRC-1/2 tokens.** No fiat, no off-chain payment
confirmation, no "mark as paid" flag. If the money is not on the ledger the canister can
read, this server has no opinion about whether it exists.

**It never lets the buyer edit the brief after work starts.** Moving goalposts is the
defining pathology of freelance marketplaces, and it is cheap to make structurally
impossible. See invariant 2.

---

## Data model

Motoko sketch following the `subscription-auditor` idiom: `Map` from `mo:map`, timestamps as
nanoseconds, dates where they are genuinely dates as days since the Unix epoch in UTC, money
as minor units, per-principal partitioning where the data is private.

Note the deliberate difference from the other servers: bounties are **not** private to one
principal. An open bounty is a public listing — that is the point of a marketplace — and the
partitioning here is per-role, not per-principal. See [Privacy model](#privacy-model).

```motoko
type Asset = {
  ledger : Text;             // ICRC ledger canister id
  symbol : Text;             // "ckUSDC", "ICP" — display only, ledger id is truth
  decimals : Nat8;
};

type Assignment = {
  #firstClaim;               // any worker may claim; first one wins
  #buyerSelects;             // workers bid; buyer picks
};

type State = {
  #draft;                    // created, not funded. No money, no visibility
  #open;                     // funded and listed. Accepting claims or bids
  #assigned;                 // a worker holds it; delivery clock running
  #submitted;                // deliverable in; review clock running
  #releasing;                // INTERMEDIATE — see invariant 4. Never persists across a call
  #released;                 // paid out. Terminal
  #refunding;                // INTERMEDIATE
  #refunded;                 // returned to buyer. Terminal
  #disputed;                 // clocks stopped, funds parked. Not terminal, but v1 has no exit
};

type Deliverable = {
  hash : Blob;               // sha256 of the content. The canister never sees the content
  pointer : Text;            // URL, canister id, IPFS cid — where it actually lives
  kind : Text;               // "text/markdown", "application/pdf", freeform
  note : ?Text;              // worker's cover note
  at : Int;                  // ns, when it was submitted
};

type Bounty = {
  id : Nat;
  buyer : Principal;
  title : Text;
  brief : Text;                    // what is wanted
  acceptance : Text;               // what counts as done. FROZEN at funding — invariant 2
  briefHash : Blob;                // sha256(brief ++ acceptance), set at funding
  skills : [Text];                 // "code-review", "bookkeeping" — for discovery
  asset : Asset;
  amountMinor : Nat;               // the bounty, in the asset's minor units
  subaccount : Blob;               // 32 bytes, derived from id. Invariant 3
  assignment : Assignment;
  state : State;
  worker : ?Principal;
  deliveryDeadline : ?Int;         // ns. Set when assigned
  reviewWindowNs : Nat;            // how long the buyer has after submission
  reviewDeadline : ?Int;           // ns. Set when submitted
  revisionsUsed : Nat;
  revisionsAllowed : Nat;          // bounded. Invariant 6
  deliverable : ?Deliverable;      // latest submission
  history : [Event];               // append-only
  createdAt : Int;
  fundedAt : ?Int;
};

type Bid = {
  bounty : Nat;
  worker : Principal;
  note : Text;
  at : Int;
};

type Event = { at : Int; actor_ : Principal; event : Text; detail : ?Text };

let bounties : Map.Map<Nat, Bounty> = Map.new();
let bountyIdsByBuyer : Map.Map<Principal, [Nat]> = Map.new();
let bountyIdsByWorker : Map.Map<Principal, [Nat]> = Map.new();
let openBountyIds : Map.Map<Nat, ()> = Map.new();      // the listing index
let bidsByBounty : Map.Map<Nat, [Bid]> = Map.new();
var nextBountyId : Nat = 1;
```

### Invariants

Enforced in the canister, not suggested.

1. **Money is real before work starts.** A bounty leaves `#draft` only after the canister
   has pulled the funds via `icrc2_transfer_from` **and** confirmed receipt with
   `icrc1_balance_of` on the bounty's own subaccount. No worker ever sees a listing backed
   by an intention.

2. **The brief freezes at funding.** `brief` and `acceptance` are editable in `#draft` and
   never again; `briefHash` is set at the funding transition and returned in every read.
   A buyer who wants different work cancels and posts a new bounty. This is the structural
   fix for moving goalposts, and it costs one hash.

3. **Every bounty's funds live in its own subaccount**, derived deterministically as
   `bounty_id` big-endian in the low 8 bytes of a 32-byte blob. Anyone can compute it and
   check the balance against the listed amount without trusting this server's own reporting.
   Funds are never commingled in the canister's default account.

4. **No ledger call happens from a state that a second caller could act on.** Before any
   `await` on a transfer the bounty moves to `#releasing` or `#refunding`, which every entry
   point rejects. On failure it moves back with the error recorded in `history`. **This is
   the double-release bug**, it is the one that loses money, and it is why those two
   intermediate states exist in the type rather than being implied.

5. **Silence has a defined consequence, and it is never "the money stays here."** Every
   clock resolves: a review window that expires releases to the worker, a delivery deadline
   that expires lets the buyer reclaim. Funds are never stranded by inaction alone — only by
   an explicit `#disputed`.

6. **Revisions are bounded and declared up front.** `revisionsAllowed` is set at creation
   and visible before a worker claims. Unlimited revision requests are how a buyer extracts
   free work while technically never rejecting anything.

7. **Entries in `history` are append-only and every state transition writes one**, with the
   principal that caused it. A marketplace where either side can dispute what happened needs
   the record to be the canister's, not either party's.

8. **A worker cannot claim their own bounty.** `worker != buyer`, checked. Self-dealing to
   farm reputation is the first thing anyone tries.

9. **No bounty exceeds its asset's cap, and no bounty uses an asset without one.**
   `create_bounty` rejects an `amountMinor` over the cap, and `fund_bounty` re-checks at the
   funding transition rather than trusting the draft. The cap lives in a small allowlist of
   `ledger -> capMinor` — ckUSDC (`xevnm-gaaaa-aaaar-qafnq-cai`) at 100_000_000 minor units
   (100 ckUSDC, 6 decimals) to start. **This makes the allowlist load-bearing twice over:**
   a cap keyed by ledger means an unknown ledger has no cap and is therefore refused, which
   also closes the hole where `Asset.ledger` is free text and a buyer could point a bounty
   at a hostile ledger canister of their own. v1 needed that check regardless; the cap is
   what forces it to exist now.

   The cost is real and worth naming: a 100 ckUSDC ceiling makes the marketplace look like
   it is for small jobs, because in v1 it is. That is the admission being bought, and it
   buys a bounded blast radius on the first custody bug in a codebase that has never held
   anyone's money.

---

## The release problem

This is the part worth getting right, because it is the entire trust model.

If the buyer alone decides when to release, the buyer can take the deliverable and simply
never approve — the deliverable is already in their hands, since the canister only holds a
pointer. If the worker alone decides, the escrow is decorative. Every real escrow resolves
this with a clock, an arbiter, or both.

**v1 uses the clock, and names the arbiter as v2.**

```
                 fund_bounty                 claim / select
     #draft ──────────────────► #open ──────────────────────► #assigned
        │                          │                              │
        │ cancel                   │ cancel (unclaimed)           │ submit_work
        ▼                          ▼                              ▼
    (deleted)                  #refunded ◄──── reclaim ────── #submitted
                                   ▲          (delivery              │
                                   │           deadline)             │
                                   │                                 │
                        request_changes ──► #assigned                │
                              (bounded, invariant 6)                 │
                                                                     │
              approve_work ─────────────────────────────────────► #released
              review window expires ───────────────────────────► #released
              dispute (either side, before release) ──────────► #disputed
```

Three properties that follow, stated plainly because they are the product:

- **Ghosting costs the buyer the bounty.** If the buyer neither approves nor requests
  changes nor disputes within `reviewWindowNs`, the funds release to the worker. The
  default window is 7 days, set per bounty at creation, minimum 24 hours. A buyer who
  wants to keep the money has to say something.
- **Vanishing costs the worker the job, not the buyer the money.** A missed delivery
  deadline lets the buyer reclaim and be refunded in full.
- **Either side can stop the clock, and neither can restart it alone.** `dispute` freezes
  everything. In v1 that is a dead end by design — funds park until arbitration ships. That
  is an honest v1 answer; "we resolve it somehow" is not.

Auto-release needs something to fire it. Both, deliberately: a periodic `Timer` sweep, **and**
a public `settle_due` tool anyone may call to settle any bounty whose clock has expired. A
timer that fails silently after an upgrade is a fund-locking bug, and the public poke means
a stranger — or the worker — can always force the resolution the rules already guarantee.

---

## Tools

Eighteen tools, `verb_noun` naming, all free in v1 (see [Metering](#metering)).

### Posting and funding — buyer

| Tool | What it does |
|------|--------------|
| `create_bounty` | Title, brief, acceptance criteria, skills, asset, amount, assignment mode, review window, revisions allowed. Lands in `#draft` — nothing is public and no money has moved |
| `update_bounty` | Edit a `#draft`. Refuses on anything funded, pointing at invariant 2 and the frozen `briefHash` |
| `fund_bounty` | Pulls the escrow via `icrc2_transfer_from` into the bounty's subaccount, confirms receipt, publishes the listing. Returns the exact `icrc2_approve` call to make first if the allowance is short |
| `cancel_bounty` | `#draft` deletes; `#open` and unclaimed refunds in full. Refuses once a worker is assigned — that is `dispute`, not cancellation |

### Discovery — anyone

| Tool | What it does |
|------|--------------|
| `search_bounties` | Open bounties by skill, asset, amount range, assignment mode. The listing an agent shops |
| `get_bounty` | One bounty in full: brief, acceptance, `briefHash`, state, clocks, deliverable pointer if submitted, and the full `history` |
| `get_escrow_proof` | The bounty's subaccount, the ledger, and the live `icrc1_balance_of` for it — so either side can verify the money without trusting this canister's own summary |

### Claiming and delivering — worker

| Tool | What it does |
|------|--------------|
| `claim_bounty` | `#firstClaim` only. Assigns and starts the delivery clock. Refuses the buyer (invariant 8) |
| `submit_bid` | `#buyerSelects` only. A note, no price negotiation in v1 — the amount is the amount |
| `list_bids` | Bids on a bounty. Buyer sees all; a worker sees their own |
| `select_worker` | Buyer picks a bidder. Assigns and starts the delivery clock |
| `submit_work` | Content hash, pointer, kind, optional note. Starts the review clock. Allowed in `#assigned` only |
| `withdraw_claim` | A worker who cannot finish releases the bounty back to `#open` before the deadline. Costs them nothing and costs the buyer nothing — far better than a silent no-show |

### Settling

| Tool | What it does |
|------|--------------|
| `approve_work` | Buyer accepts. Releases escrow to the worker and closes the bounty |
| `request_changes` | Buyer rejects with a reason, returning to `#assigned` with a new deadline. Bounded by `revisionsAllowed`; the reason is required and goes in `history` |
| `reclaim_bounty` | Buyer reclaims after a missed delivery deadline. Refunds in full |
| `settle_due` | Public. Settles any bounty whose clock has expired, per the rules above. Callable by anyone, including a stranger |
| `dispute_bounty` | Either party, before release. Stops every clock, parks the funds, records the reason. v1 has no exit and the tool description says so |
| `my_work` | The caller's bounties on both sides, with what is waiting on them — the "what do I owe anyone" sweep, in the shape of Subscription Auditor's `audit` |

### The three that carry the design

**`create_bounty`**

```jsonc
{
  "title": "Reconcile Q3 books against the ckUSDC ledger",
  "brief": "Books are in Bookkeeping Ledger, 140 entries Jul-Sep...",
  "acceptance": "Trial balance balances, 6900 Uncategorized is zero, reconcile returns a zero difference on account 1000. Deliverable is the entry list you posted plus a one-page note on what was wrong.",
  "skills": ["bookkeeping", "icrc"],
  "asset": { "ledger": "xevnm-gaaaa-aaaar-qafnq-cai", "symbol": "ckUSDC", "decimals": 6 },
  "amount_minor": 15000000,          // 15 ckUSDC
  "assignment": "first_claim",
  "delivery_days": 5,
  "review_window_hours": 168,        // 7 days, the default
  "revisions_allowed": 2
}
```

Acceptance criteria are a separate required field rather than a paragraph inside `brief`,
because they are the thing that freezes and the thing a dispute is read against. Making the
buyer write them as their own field is most of the value.

**`fund_bounty`**

```jsonc
{ "bounty": 17 }
```

Returns either the funded listing, or — when the allowance is short — the exact call the
buyer's wallet needs to make, in the shape Subscription Auditor returns revocations:

```jsonc
{
  "funded": false,
  "reason": "allowance_insufficient",
  "have_minor": 0, "need_minor": 15000000,
  "do_this": {
    "canister": "xevnm-gaaaa-aaaar-qafnq-cai",
    "method": "icrc2_approve",
    "arg": { "spender": { "owner": "<this canister>" }, "amount": 15000000 }
  }
}
```

**`get_escrow_proof`**

```jsonc
{ "bounty": 17 }
```

Returns the derived subaccount, the ledger, the live on-chain balance, and the amount the
bounty claims to hold — the same self-checking move the Bookkeeping Ledger spec makes with
`reconcile`, applied to custody. If those two numbers ever disagree, both parties find out
from the server itself rather than from a surprise.

---

## Composition with what's already shipped

| Server | Relationship |
|--------|--------------|
| **Press** `ezirm-3yaaa-aaaai-q4r5a-cai` | The precedent. Press stays the specialist for articles — it knows what a good one looks like and this server deliberately does not. Not a competitor unless it wants to be |
| **Review & Reputation Oracle** `gnoi7-taaaa-aaaah-quxiq-cai` | The pairing the map calls out. A released bounty is exactly the "verified transaction" a review should hang off. v1 returns the `submit_review` call to both parties on release; binding it harder needs cross-canister trust that neither server has yet |
| **Invoice Desk** `kx2vm-6qaaa-aaaao-qqbca-cai` | A released bounty is an invoice-shaped event for the worker's records. One hop away, not wired |
| **Bookkeeping Ledger** (spec'd, unbuilt) | Both sides of a release are ledger entries — expense for the buyer, revenue for the worker. The `ref` type in that spec already has a slot for this |
| **Agent Identity & Delegation Registry** (opening #10) | The unbuilt server this one most wants. "This agent may take jobs up to X" is the missing safety rail on autonomous claiming |

---

## Privacy model

Different from every other server here, and worth being explicit because the difference is
the point.

**Bounties are public.** An open listing is readable by anyone — that is what makes it a
marketplace. `brief`, `acceptance`, `amount`, `skills`, the buyer's principal, and the whole
`history` are public from the funding transition onward. A `#draft` is private to its buyer.

**The deliverable is not stored here, and its pointer is public.** The canister holds a hash
and a URL. If the work itself is sensitive, the pointer must go somewhere access-controlled
— and v1 has nothing to offer there, which is a real gap and the reason **Document & File
Storage** (opening #12) keeps coming up. Say this in the README in the same blunt terms
Subscription Auditor uses about card numbers: *do not put the deliverable itself behind a
public URL if it is confidential, and know that the fact of the job is public either way.*

**Bids are semi-private:** the buyer sees all bids on their bounty, a worker sees only their
own. Public bids turn into a race to the bottom and let anyone read a worker's pipeline.

Tool calls still require `x-api-key`, and writes are still authorized against the calling
principal — public to read is not public to write.

---

## Metering

Free for v1, `payment: null`, matching Subscription Auditor and the Bookkeeping Ledger spec.

The obvious revenue model is a basis-point fee on release, and this is the first server in
the lineup where that fee would be *natural* rather than bolted on — the canister is already
in the payment path, so taking 100bps costs the user nothing extra in friction. That is
precisely why it should wait: a marketplace with no listings and a fee is a worse product
than a marketplace with no listings, and the fee is trivial to add once there is volume to
take it from. See open question 5.

---

## Open questions

**1. Arbitration — named as the v2 boundary, not deferred silently.**
v1 parks disputed funds forever, which is honest but not good. The three options: a buyer-
chosen arbiter named at creation (simple, but the buyer picks the judge); a registry of
arbiters with reputation from the Review & Reputation Oracle (right shape, real work); or
staked voting (over-engineered for the volume this will see for a year). I lean toward the
second, built only after v1 has enough real bounties to show what actually gets disputed —
guessing at the dispute taxonomy before seeing one is how you build the wrong court.

**2. Worker stake against spam claims.**
`#firstClaim` is exploitable: a worker claims everything, delivers nothing, and burns every
buyer's delivery window. Mitigations: an optional stake the worker forfeits on a missed
deadline; a cap on concurrent claims per principal; or reputation-gating claims once the
Oracle integration is real. **The cheapest one that works in v1 is the concurrent-claim
cap** — no new money movement, no new state, and it blunts the attack to a nuisance. Stake
is the better long answer and needs its own escrow path.

**3. Milestones.** One bounty, one deliverable, one release in v1. Real work of any size
wants staged payment. This is a genuine feature, not a tweak — it turns `Bounty` into a
parent with children and every clock becomes per-milestone. Deliberately out of v1 so v1
ships.

**4. Bounty size cap. — RESOLVED 2026-09-09: yes, a cap.** Roblynn's call; see
[Decided](#decided) and **invariant 9**, which is where it is now enforced. Proposed at 100
ckUSDC, expressed per ledger via the asset allowlist. The number itself is still open to
adjustment before the build starts — it is one constant — but the *presence* of a cap in v1
is settled and the type is written around it.

**5. Fee timing.** Free at launch per Metering above. The thing to decide before launch, not
after, is whether the *plumbing* for a fee goes in v1 unused — adding a fee later to a
canister that never had one means an upgrade that changes payout math on live escrows.
Cheaper to build the 0% path now and change one number later.

**6. Cross-canister reputation.** Returning the `submit_review` call to both parties is the
v1 answer and it is weak — nothing stops a party from not calling it, so reputation
accumulates only from the conscientious. Making the release itself write the review needs
the Oracle to trust this canister as an attestor, which is a conversation with Atlas Labs
and a change on their side, not something this spec can decide unilaterally.
