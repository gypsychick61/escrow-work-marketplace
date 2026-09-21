import Map "mo:map/Map";
import { thash; phash; nhash } "mo:map/Map";
import Result "mo:base/Result";
import Blob "mo:base/Blob";
import Principal "mo:base/Principal";
import Text "mo:base/Text";
import Char "mo:base/Char";
import Nat8 "mo:base/Nat8";
import Nat32 "mo:base/Nat32";
import Nat64 "mo:base/Nat64";
import Array "mo:base/Array";
import Buffer "mo:base/Buffer";
import Float "mo:base/Float";
import Int "mo:base/Int";
import Nat "mo:base/Nat";
import Time "mo:base/Time";
import Timer "mo:base/Timer";
import Error "mo:base/Error";
import Sha256 "mo:sha2/Sha256";
import Json "mo:json";
import HttpTypes "mo:http-types";

import Mcp "mo:mcp-motoko-sdk/mcp/Mcp";
import McpTypes "mo:mcp-motoko-sdk/mcp/Types";
import AuthTypes "mo:mcp-motoko-sdk/auth/Types";
import ApiKey "mo:mcp-motoko-sdk/auth/ApiKey";
import AuthState "mo:mcp-motoko-sdk/auth/State";
import AuthCleanup "mo:mcp-motoko-sdk/auth/Cleanup";
import HttpHandler "mo:mcp-motoko-sdk/mcp/HttpHandler";
import SrvTypes "mo:mcp-motoko-sdk/server/Types";
import Cleanup "mo:mcp-motoko-sdk/mcp/Cleanup";
import State "mo:mcp-motoko-sdk/mcp/State";
import HttpAssets "mo:mcp-motoko-sdk/mcp/HttpAssets";
import Beacon "mo:mcp-motoko-sdk/mcp/Beacon";

shared ({ caller = deployer }) persistent actor class McpServer() = self {

  // --- ESCROW DATA MODEL ---
  //
  // A bounty is a brief, a frozen set of acceptance criteria, money that is
  // provably present, and a clock. This canister holds the money and enforces
  // the clock. It never sees the deliverable and has no opinion about whether
  // the work is good — that is the buyer's call, and where the buyer will not
  // make one, the clock decides.
  //
  // The thing that makes this server different from every other one in this
  // lineup: it is custodial. Funds pulled from a buyer sit in a subaccount
  // derived from the bounty id until they are released to a worker or refunded.
  // Two consequences run through the whole file:
  //
  //   1. Every ledger call is made from an intermediate state (#releasing,
  //      #refunding) that every entry point rejects, because Motoko interleaves
  //      at every await and a release awaited from #submitted can be released
  //      twice. That is the bug that loses other people's money.
  //
  //   2. State migration on upgrade is a money problem, not a data problem.
  //      Balances are never derived — they are read live off the ledger by
  //      get_escrow_proof, so the canister's own bookkeeping can be checked
  //      against the ledger rather than believed.

  type Asset = {
    ledger : Text; // ICRC ledger canister id — the truth
    symbol : Text; // display only
    decimals : Nat8;
  };

  type Assignment = {
    #firstClaim; // any worker may claim; first one wins
    #buyerSelects; // workers bid; buyer picks
  };

  type State = {
    #draft; // created, not funded. No money, no visibility
    #open; // funded and listed. Accepting claims or bids
    #assigned; // a worker holds it; delivery clock running
    #submitted; // deliverable in; review clock running
    #releasing; // INTERMEDIATE — a ledger call is in flight. Never persists
    #refunding; // INTERMEDIATE — ditto
    #released; // paid out. Terminal
    #refunded; // returned to buyer. Terminal
    #disputed; // clocks stopped, funds parked. v1 has no exit
  };

  type Deliverable = {
    hash : Text; // sha256 hex of the content. The canister never sees the content
    pointer : Text; // URL, canister id, IPFS cid — where it actually lives
    kind : Text; // "text/markdown", "application/pdf", freeform
    note : ?Text; // worker's cover note
    at : Int; // ns
  };

  type Event = { at : Int; actor_ : Principal; event : Text; detail : ?Text };

  type Bounty = {
    id : Nat;
    buyer : Principal;
    title : Text;
    brief : Text; // what is wanted
    acceptance : Text; // what counts as done. FROZEN at funding — invariant 2
    briefHash : ?Text; // hash of brief ++ acceptance, set at funding
    skills : [Text];
    asset : Asset;
    amountMinor : Nat; // the bounty itself, in minor units
    ledgerFeeMinor : Nat; // the ledger's fee, observed at funding
    escrowedMinor : Nat; // what the subaccount should hold: amount + one outbound fee
    subaccount : Blob; // 32 bytes, derived from id — invariant 3
    assignment : Assignment;
    state : State;
    worker : ?Principal;
    deliveryDays : Nat;
    deliveryDeadline : ?Int; // ns. Set when assigned
    reviewWindowNs : Nat;
    reviewDeadline : ?Int; // ns. Set when submitted
    revisionsUsed : Nat;
    revisionsAllowed : Nat; // bounded — invariant 6
    deliverable : ?Deliverable;
    history : [Event]; // append-only — invariant 7
    createdAt : Int;
    fundedAt : ?Int;
    settledAt : ?Int;
    disputeReason : ?Text;
  };

  type Bid = { bounty : Nat; worker : Principal; note : Text; at : Int };

  var nextBountyId : Nat = 1;
  let bounties : Map.Map<Nat, Bounty> = Map.new();
  let bountyIdsByBuyer : Map.Map<Principal, [Nat]> = Map.new();
  let bountyIdsByWorker : Map.Map<Principal, [Nat]> = Map.new();
  let openBountyIds : Map.Map<Nat, ()> = Map.new(); // the listing index
  let bidsByBounty : Map.Map<Nat, [Bid]> = Map.new();

  // --- THE ASSET ALLOWLIST ---
  //
  // Load-bearing twice over (invariant 9). It is where the per-bounty cap
  // lives, and because Asset.ledger is free text, a ledger with no entry has
  // no cap and is therefore refused — which is also what stops a buyer
  // pointing a bounty at a hostile ledger canister of their own.
  //
  // v1 caps ckUSDC at 100 (6 decimals). The cap makes this marketplace look
  // like it is for small jobs, because in v1 it is; what it buys is a bounded
  // blast radius on the first custody bug in code that has never held anyone's
  // money. Raising it later is one number.

  type AllowedAsset = { symbol : Text; decimals : Nat8; capMinor : Nat };

  let allowedAssets : Map.Map<Text, AllowedAsset> = Map.new();

  transient let ckusdcLedger : Text = "xevnm-gaaaa-aaaar-qafnq-cai";

  if (Map.size(allowedAssets) == 0) {
    Map.set(allowedAssets, thash, ckusdcLedger, { symbol = "ckUSDC"; decimals = 6 : Nat8; capMinor = 100_000_000 });
  };

  // --- FEE PLUMBING ---
  //
  // Zero at launch, and deliberately present anyway. Adding a fee later to a
  // canister that never had one means an upgrade that changes payout math on
  // escrows that are already live and already promised a number to both
  // parties. Building the 0% path now makes that later change one constant
  // instead of a migration.
  transient let feeBps : Nat = 0;

  func marketplaceFee(amountMinor : Nat) : Nat { amountMinor * feeBps / 10_000 };

  // --- CLOCK BOUNDS ---
  transient let nanosPerHour : Nat = 3_600_000_000_000;
  transient let nanosPerDay : Nat = 86_400_000_000_000;
  transient let minReviewWindowNs : Nat = 24 * nanosPerHour; // invariant 5 needs a floor
  transient let defaultReviewWindowNs : Nat = 168 * nanosPerHour; // 7 days
  transient let maxReviewWindowNs : Nat = 30 * nanosPerDay;
  transient let maxDeliveryDays : Nat = 90;
  transient let maxRevisionsAllowed : Nat = 10;

  // Open question 2, v1 answer: a worker may hold three live jobs at once.
  // #firstClaim is otherwise free to abuse — claim everything, deliver
  // nothing, and burn every buyer's delivery window. A concurrent cap needs no
  // new money movement and blunts that to a nuisance; stake is the better long
  // answer and needs its own escrow path.
  transient let maxConcurrentClaims : Nat = 3;

  // --- MCP SERVER PLUMBING ---

  var stable_http_assets : HttpAssets.StableEntries = [];
  transient let http_assets = HttpAssets.init(stable_http_assets);

  let appContext : McpTypes.AppContext = State.init([]);
  let authContext : AuthTypes.AuthContext = AuthState.initApiKey(deployer);

  Cleanup.startCleanupTimer<system>(appContext);
  AuthCleanup.startCleanupTimer<system>(authContext);

  transient let beaconContext : Beacon.BeaconContext = Beacon.init(
    Principal.fromText("m63pw-fqaaa-aaaai-q33pa-cai"),
    ?(15 * 60),
  );
  Beacon.startTimer<system>(beaconContext);

  // --- ICRC-1/2 LEDGER INTERFACE ---

  type Account = { owner : Principal; subaccount : ?Blob };

  type TransferFromArgs = {
    spender_subaccount : ?Blob;
    from : Account;
    to : Account;
    amount : Nat;
    fee : ?Nat;
    memo : ?Blob;
    created_at_time : ?Nat64;
  };

  type TransferFromError = {
    #BadFee : { expected_fee : Nat };
    #BadBurn : { min_burn_amount : Nat };
    #InsufficientFunds : { balance : Nat };
    #InsufficientAllowance : { allowance : Nat };
    #TooOld;
    #CreatedInFuture : { ledger_time : Nat64 };
    #Duplicate : { duplicate_of : Nat };
    #TemporarilyUnavailable;
    #GenericError : { error_code : Nat; message : Text };
  };

  type TransferFromResult = { #Ok : Nat; #Err : TransferFromError };

  type TransferArg = {
    from_subaccount : ?Blob;
    to : Account;
    amount : Nat;
    fee : ?Nat;
    memo : ?Blob;
    created_at_time : ?Nat64;
  };

  type TransferError = {
    #BadFee : { expected_fee : Nat };
    #BadBurn : { min_burn_amount : Nat };
    #InsufficientFunds : { balance : Nat };
    #TooOld;
    #CreatedInFuture : { ledger_time : Nat64 };
    #Duplicate : { duplicate_of : Nat };
    #TemporarilyUnavailable;
    #GenericError : { error_code : Nat; message : Text };
  };

  type TransferResult = { #Ok : Nat; #Err : TransferError };

  type AllowanceArgs = { account : Account; spender : Account };
  type Allowance = { allowance : Nat; expires_at : ?Nat64 };

  func ledgerOf(id : Text) : actor {
    icrc1_balance_of : (Account) -> async Nat;
    icrc1_fee : () -> async Nat;
    icrc1_transfer : (TransferArg) -> async TransferResult;
    icrc2_allowance : (AllowanceArgs) -> async Allowance;
    icrc2_transfer_from : (TransferFromArgs) -> async TransferFromResult;
  } {
    actor (id);
  };

  func transferFromErrText(e : TransferFromError) : Text {
    switch (e) {
      case (#BadFee(d)) "ledger rejected the fee; it expects " # Nat.toText(d.expected_fee);
      case (#BadBurn(d)) "burn below the minimum of " # Nat.toText(d.min_burn_amount);
      case (#InsufficientFunds(d)) "your balance is " # Nat.toText(d.balance) # " minor units, which is not enough";
      case (#InsufficientAllowance(d)) "your allowance to this canister is " # Nat.toText(d.allowance) # " minor units, which is not enough";
      case (#TooOld) "the transfer was too old by the time it reached the ledger; try again";
      case (#CreatedInFuture(_)) "the ledger thinks this transfer is from the future; try again";
      case (#Duplicate(d)) "the ledger saw this as a duplicate of transaction " # Nat.toText(d.duplicate_of);
      case (#TemporarilyUnavailable) "the ledger is temporarily unavailable; try again";
      case (#GenericError(d)) "ledger error " # Nat.toText(d.error_code) # ": " # d.message;
    };
  };

  func transferErrText(e : TransferError) : Text {
    switch (e) {
      case (#BadFee(d)) "ledger rejected the fee; it expects " # Nat.toText(d.expected_fee);
      case (#BadBurn(d)) "burn below the minimum of " # Nat.toText(d.min_burn_amount);
      case (#InsufficientFunds(d)) "the escrow subaccount holds only " # Nat.toText(d.balance) # " minor units";
      case (#TooOld) "the transfer was too old by the time it reached the ledger; try again";
      case (#CreatedInFuture(_)) "the ledger thinks this transfer is from the future; try again";
      case (#Duplicate(d)) "the ledger saw this as a duplicate of transaction " # Nat.toText(d.duplicate_of);
      case (#TemporarilyUnavailable) "the ledger is temporarily unavailable; try again";
      case (#GenericError(d)) "ledger error " # Nat.toText(d.error_code) # ": " # d.message;
    };
  };

  // --- SUBACCOUNT DERIVATION — INVARIANT 3 ---
  //
  // Every bounty's funds live in its own subaccount: the id big-endian in the
  // low 8 bytes of a 32-byte blob. The derivation is public and trivial on
  // purpose — either party can compute it, ask the ledger for the balance, and
  // check the money without trusting a word this canister says about it.

  func subaccountFor(id : Nat) : Blob {
    let bytes = Array.init<Nat8>(32, 0);
    var v : Nat = id;
    var i : Nat = 32;
    while (i > 24 and v > 0) {
      i -= 1;
      bytes[i] := Nat8.fromNat(v % 256);
      v /= 256;
    };
    Blob.fromArray(Array.freeze(bytes));
  };

  func toHex(b : Blob) : Text {
    let digits = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f"];
    var out = "";
    for (byte in b.vals()) {
      let n = Nat8.toNat(byte);
      out #= digits[n / 16] # digits[n % 16];
    };
    out;
  };

  func escrowAccount(id : Nat) : Account {
    { owner = Principal.fromActor(self); subaccount = ?subaccountFor(id) };
  };

  // --- ARGUMENT PARSING ---
  //
  // Agents stringify numbers more often than you would like, so every numeric
  // reader accepts a JSON number or a numeric string.

  func optText(args : McpTypes.JsonValue, field : Text) : ?Text {
    switch (Result.toOption(Json.getAsText(args, field))) {
      case (?t) { let v = Text.trim(t, #char ' '); if (v == "") null else ?v };
      case (null) null;
    };
  };

  func floatFromText(t : Text) : ?Float {
    var whole : Float = 0.0;
    var frac : Float = 0.0;
    var scale : Float = 1.0;
    var seenDot = false;
    var seenDigit = false;
    for (c in t.chars()) {
      if (c == '.') {
        if (seenDot) return null;
        seenDot := true;
      } else if (Char.isDigit(c)) {
        seenDigit := true;
        let d = Float.fromInt(Nat32.toNat(Char.toNat32(c) - 48));
        if (seenDot) { scale *= 10.0; frac += d / scale } else {
          whole := whole * 10.0 + d;
        };
      } else if (c == ',' or c == '_') {
        // tolerated thousands separators
      } else return null;
    };
    if (not seenDigit) return null;
    ?(whole + frac);
  };

  func optFloat(args : McpTypes.JsonValue, field : Text) : ?Float {
    switch (Result.toOption(Json.getAsFloat(args, field))) {
      case (?f) ?f;
      case (null) {
        switch (Result.toOption(Json.getAsText(args, field))) {
          case (?t) floatFromText(Text.trim(t, #char ' '));
          case (null) null;
        };
      };
    };
  };

  func optNat(args : McpTypes.JsonValue, field : Text) : ?Nat {
    switch (optFloat(args, field)) {
      case (?f) { if (f < 0.0) null else ?Int.abs(Float.toInt(f + 0.5)) };
      case (null) null;
    };
  };

  func lower(t : Text) : Text {
    Text.map(
      t,
      func(c : Char) : Char {
        let n = Char.toNat32(c);
        if (n >= 65 and n <= 90) Char.fromNat32(n + 32) else c;
      },
    );
  };

  func splitParts(t : Text, sep : Char) : [Text] {
    let out = Buffer.Buffer<Text>(4);
    var cur = "";
    for (c in t.chars()) {
      if (c == sep) {
        let v = Text.trim(cur, #char ' ');
        if (v != "") out.add(v);
        cur := "";
      } else cur #= Char.toText(c);
    };
    let v = Text.trim(cur, #char ' ');
    if (v != "") out.add(v);
    Buffer.toArray(out);
  };

  // Skills arrive as a JSON array or as "code-review, icrc". Both are common.
  func optTextList(args : McpTypes.JsonValue, field : Text) : [Text] {
    switch (Json.get(args, field)) {
      case (?#array(items)) {
        let out = Buffer.Buffer<Text>(items.size());
        for (item in items.vals()) {
          switch (item) {
            case (#string(s)) {
              let v = Text.trim(s, #char ' ');
              if (v != "") out.add(lower(v));
            };
            case (_) {};
          };
        };
        Buffer.toArray(out);
      };
      case (?#string(s)) Array.map<Text, Text>(splitParts(s, ','), lower);
      case (_) [];
    };
  };

  // Principal.fromText traps on malformed input rather than returning an
  // option, and a trap here would take down the whole call, so the shape is
  // checked before it is handed over.
  func parsePrincipal(t : Text) : ?Principal {
    let trimmed = Text.trim(t, #char ' ');
    let n = trimmed.size();
    if (n < 5 or n > 63) return null;
    for (c in trimmed.chars()) {
      let ok = (Char.isLowercase(c) and Char.isAlphabetic(c)) or Char.isDigit(c) or c == '-';
      if (not ok) return null;
    };
    let p = Principal.fromText(trimmed);
    if (Principal.isAnonymous(p)) return null;
    ?p;
  };

  func parseAssignment(t : Text) : ?Assignment {
    switch (lower(t)) {
      case ("first_claim") ?#firstClaim;
      case ("firstclaim") ?#firstClaim;
      case ("first-claim") ?#firstClaim;
      case ("buyer_selects") ?#buyerSelects;
      case ("buyerselects") ?#buyerSelects;
      case ("buyer-selects") ?#buyerSelects;
      case (_) null;
    };
  };

  // --- RESULTS ---

  func errorResult(msg : Text) : McpTypes.CallToolResult {
    { content = [#text({ text = msg })]; isError = true; structuredContent = null };
  };

  func okResult(payload : Json.Json) : McpTypes.CallToolResult {
    {
      content = [#text({ text = Json.stringify(payload, null) })];
      isError = false;
      structuredContent = ?payload;
    };
  };

  func optJsonText(t : ?Text) : Json.Json {
    switch (t) { case (?v) Json.str(v); case (null) Json.nullable() };
  };

  func optJsonInt(v : ?Int) : Json.Json {
    switch (v) { case (?x) Json.int(x); case (null) Json.nullable() };
  };

  func schemaProp(name : Text, jsonType : Text, description : Text) : (Text, Json.Json) {
    (name, Json.obj([("type", Json.str(jsonType)), ("description", Json.str(description))]));
  };

  func objSchema(props : [(Text, Json.Json)], required : [Text]) : Json.Json {
    Json.obj([
      ("type", Json.str("object")),
      ("properties", Json.obj(props)),
      ("required", Json.arr(Array.map<Text, Json.Json>(required, Json.str))),
    ]);
  };

  // --- FORMATTING ---

  func now() : Int { Time.now() };

  func sha256Hex(t : Text) : Text {
    toHex(Sha256.fromBlob(#sha256, Text.encodeUtf8(t)));
  };

  func stateText(s : State) : Text {
    switch (s) {
      case (#draft) "draft";
      case (#open) "open";
      case (#assigned) "assigned";
      case (#submitted) "submitted";
      case (#releasing) "releasing";
      case (#refunding) "refunding";
      case (#released) "released";
      case (#refunded) "refunded";
      case (#disputed) "disputed";
    };
  };

  func assignmentText(a : Assignment) : Text {
    switch (a) { case (#firstClaim) "first_claim"; case (#buyerSelects) "buyer_selects" };
  };

  func pow10(n : Nat) : Nat {
    var out : Nat = 1;
    var i : Nat = 0;
    while (i < n) { out *= 10; i += 1 };
    out;
  };

  func padLeft(t : Text, width : Nat) : Text {
    var out = t;
    while (out.size() < width) { out := "0" # out };
    out;
  };

  // Minor units -> "15.00 ckUSDC". Integer math only; a float here would round
  // someone's money.
  func fmtMoney(minor : Nat, asset : Asset) : Text {
    let scale = pow10(Nat8.toNat(asset.decimals));
    let whole = minor / scale;
    let frac = minor % scale;
    if (Nat8.toNat(asset.decimals) == 0) return Nat.toText(whole) # " " # asset.symbol;
    Nat.toText(whole) # "." # padLeft(Nat.toText(frac), Nat8.toNat(asset.decimals)) # " " # asset.symbol;
  };

  func fmtDuration(ns : Int) : Text {
    if (ns <= 0) return "now";
    let hours = ns / Int.abs(nanosPerHour);
    if (hours < 1) return "under an hour";
    if (hours < 48) return Int.toText(hours) # (if (hours == 1) " hour" else " hours");
    Int.toText(hours / 24) # " days";
  };

  func remainingText(deadline : ?Int, nowNs : Int) : Text {
    switch (deadline) {
      case (?d) { if (d <= nowNs) "expired" else fmtDuration(d - nowNs) };
      case (null) "n/a";
    };
  };

  // --- STORAGE HELPERS ---

  func idsFor(m : Map.Map<Principal, [Nat]>, p : Principal) : [Nat] {
    switch (Map.get(m, phash, p)) { case (?ids) ids; case (null) [] };
  };

  func addId(m : Map.Map<Principal, [Nat]>, p : Principal, id : Nat) {
    let existing = idsFor(m, p);
    for (x in existing.vals()) { if (x == id) return };
    Map.set(m, phash, p, Array.append(existing, [id]));
  };

  func putBounty(b : Bounty) {
    Map.set(bounties, nhash, b.id, b);
    // The listing index holds exactly the bounties a worker may act on.
    switch (b.state) {
      case (#open) Map.set(openBountyIds, nhash, b.id, ());
      case (_) Map.delete(openBountyIds, nhash, b.id);
    };
  };

  func withEvent(b : Bounty, who : Principal, event : Text, detail : ?Text) : Bounty {
    {
      b with history = Array.append(b.history, [{ at = now(); actor_ = who; event; detail }])
    };
  };

  func getBounty(id : Nat) : ?Bounty { Map.get(bounties, nhash, id) };

  func bountiesOf(m : Map.Map<Principal, [Nat]>, p : Principal) : [Bounty] {
    let out = Buffer.Buffer<Bounty>(8);
    for (id in idsFor(m, p).vals()) {
      switch (getBounty(id)) { case (?b) out.add(b); case (null) {} };
    };
    Buffer.toArray(out);
  };

  // Invariant 4's guard, in one place. A bounty mid-ledger-call is untouchable
  // by anyone, including the principal who started the call.
  func isSettling(b : Bounty) : Bool {
    b.state == #releasing or b.state == #refunding;
  };

  func settlingError(b : Bounty) : Text {
    "Bounty " # Nat.toText(b.id) # " has a ledger transfer in flight (" # stateText(b.state) # "). Nothing can touch it until that call returns — try again in a moment.";
  };

  func isLiveClaim(b : Bounty) : Bool {
    b.state == #assigned or b.state == #submitted;
  };

  func liveClaimCount(p : Principal) : Nat {
    var n : Nat = 0;
    for (b in bountiesOf(bountyIdsByWorker, p).vals()) {
      if (isLiveClaim(b)) {
        switch (b.worker) { case (?w) { if (w == p) n += 1 }; case (null) {} };
      };
    };
    n;
  };

  func bidsFor(id : Nat) : [Bid] {
    switch (Map.get(bidsByBounty, nhash, id)) { case (?bs) bs; case (null) [] };
  };

  // --- SERIALIZATION ---

  func eventToJson(e : Event) : Json.Json {
    Json.obj([
      ("at", Json.int(e.at)),
      ("by", Json.str(Principal.toText(e.actor_))),
      ("event", Json.str(e.event)),
      ("detail", optJsonText(e.detail)),
    ]);
  };

  func assetToJson(a : Asset) : Json.Json {
    Json.obj([
      ("ledger", Json.str(a.ledger)),
      ("symbol", Json.str(a.symbol)),
      ("decimals", Json.int(Nat8.toNat(a.decimals))),
    ]);
  };

  func deliverableToJson(d : Deliverable) : Json.Json {
    Json.obj([
      ("hash", Json.str(d.hash)),
      ("pointer", Json.str(d.pointer)),
      ("kind", Json.str(d.kind)),
      ("note", optJsonText(d.note)),
      ("submitted_at", Json.int(d.at)),
    ]);
  };

  func bidToJson(b : Bid) : Json.Json {
    Json.obj([
      ("bounty", Json.int(b.bounty)),
      ("worker", Json.str(Principal.toText(b.worker))),
      ("note", Json.str(b.note)),
      ("at", Json.int(b.at)),
    ]);
  };

  // `full` adds the history and the deliverable pointer. A #draft is private to
  // its buyer; everything from funding onward is public, because a listing
  // nobody can read is not a marketplace. See the privacy model in SPEC.md.
  func bountyToJson(b : Bounty, full : Bool) : Json.Json {
    let nowNs = now();
    let base : [(Text, Json.Json)] = [
      ("id", Json.int(b.id)),
      ("title", Json.str(b.title)),
      ("state", Json.str(stateText(b.state))),
      ("buyer", Json.str(Principal.toText(b.buyer))),
      ("worker", switch (b.worker) { case (?w) Json.str(Principal.toText(w)); case (null) Json.nullable() }),
      ("brief", Json.str(b.brief)),
      ("acceptance", Json.str(b.acceptance)),
      ("brief_hash", optJsonText(b.briefHash)),
      ("skills", Json.arr(Array.map<Text, Json.Json>(b.skills, Json.str))),
      ("asset", assetToJson(b.asset)),
      ("amount_minor", Json.int(b.amountMinor)),
      ("amount", Json.str(fmtMoney(b.amountMinor, b.asset))),
      ("assignment", Json.str(assignmentText(b.assignment))),
      ("delivery_days", Json.int(b.deliveryDays)),
      ("delivery_deadline", optJsonInt(b.deliveryDeadline)),
      ("delivery_remaining", Json.str(remainingText(b.deliveryDeadline, nowNs))),
      ("review_window_hours", Json.int(b.reviewWindowNs / nanosPerHour)),
      ("review_deadline", optJsonInt(b.reviewDeadline)),
      ("review_remaining", Json.str(remainingText(b.reviewDeadline, nowNs))),
      ("revisions_used", Json.int(b.revisionsUsed)),
      ("revisions_allowed", Json.int(b.revisionsAllowed)),
      ("created_at", Json.int(b.createdAt)),
      ("funded_at", optJsonInt(b.fundedAt)),
      ("settled_at", optJsonInt(b.settledAt)),
      ("escrow_subaccount", Json.str(toHex(b.subaccount))),
      ("escrowed_minor", Json.int(b.escrowedMinor)),
      ("dispute_reason", optJsonText(b.disputeReason)),
    ];
    if (not full) return Json.obj(base);
    Json.obj(
      Array.append(
        base,
        [
          ("deliverable", switch (b.deliverable) { case (?d) deliverableToJson(d); case (null) Json.nullable() }),
          ("history", Json.arr(Array.map<Event, Json.Json>(b.history, eventToJson))),
        ],
      )
    );
  };

  func bountyResponse(b : Bounty, message : Text) : Json.Json {
    Json.obj([("message", Json.str(message)), ("bounty", bountyToJson(b, false))]);
  };

  // --- AUTH ---

  type ToolCb = (Result.Result<McpTypes.CallToolResult, McpTypes.HandlerError>) -> ();

  func callerPrincipal(auth : ?AuthTypes.AuthInfo) : ?Principal {
    switch (auth) { case (?a) ?a.principal; case (null) null };
  };

  func requireAuth(auth : ?AuthTypes.AuthInfo, cb : ToolCb) : ?Principal {
    switch (callerPrincipal(auth)) {
      case (?p) ?p;
      case (null) {
        cb(#ok(errorResult("Authentication required: call this tool with a valid x-api-key.")));
        null;
      };
    };
  };

  // Reading a bounty is public; writing to one is not. Every write resolves the
  // bounty through one of these two.
  func requireBuyer(b : Bounty, p : Principal, cb : ToolCb) : Bool {
    if (b.buyer != p) {
      cb(#ok(errorResult("Only the buyer who posted bounty " # Nat.toText(b.id) # " can do that.")));
      return false;
    };
    true;
  };

  func requireWorker(b : Bounty, p : Principal, cb : ToolCb) : Bool {
    switch (b.worker) {
      case (?w) {
        if (w == p) return true;
        cb(#ok(errorResult("Only the assigned worker on bounty " # Nat.toText(b.id) # " can do that.")));
        false;
      };
      case (null) {
        cb(#ok(errorResult("Bounty " # Nat.toText(b.id) # " has no assigned worker.")));
        false;
      };
    };
  };

  func resolveBounty(args : McpTypes.JsonValue, cb : ToolCb) : ?Bounty {
    switch (optNat(args, "bounty")) {
      case (null) {
        cb(#ok(errorResult("Which bounty? Pass 'bounty' as its numeric id.")));
        null;
      };
      case (?id) {
        switch (getBounty(id)) {
          case (?b) ?b;
          case (null) {
            cb(#ok(errorResult("No bounty " # Nat.toText(id) # ".")));
            null;
          };
        };
      };
    };
  };

  // --- CUSTODY ---
  //
  // Everything below moves real money. Three rules hold throughout:
  //
  //   Before any await on a ledger call, the bounty is written to an
  //   intermediate state that every entry point rejects (isSettling). On
  //   success it advances to a terminal state; on failure it goes back where it
  //   was with the ledger's own error in history. Motoko interleaves at every
  //   await, and without this a release awaited from #submitted can be entered
  //   a second time and paid twice.
  //
  //   The bounty is re-read from the map after every await. The value captured
  //   before the await is stale by definition.
  //
  //   Nothing here derives a balance. get_escrow_proof asks the ledger.

  // Funding pulls amount + one outbound fee, so the worker is paid the round
  // number the listing advertises rather than the number minus whatever the
  // ledger charged on the way out. The buyer pays both fees, which is right:
  // posting a job is the buyer's action.
  transient let fundLocks : Map.Map<Nat, Bool> = Map.new();

  func lockFunding(id : Nat) : Bool {
    switch (Map.get(fundLocks, nhash, id)) {
      case (?true) false;
      case (_) { Map.set(fundLocks, nhash, id, true); true };
    };
  };

  func unlockFunding(id : Nat) { Map.delete(fundLocks, nhash, id) };

  // Pays out of a bounty's own subaccount. `amount` is what the recipient
  // receives; the ledger fee comes out of the escrow on top of it, which is
  // exactly what the extra fee pulled at funding is for.
  func payOut(b : Bounty, to : Account, amount : Nat) : async Result.Result<Nat, Text> {
    try {
      let res = await ledgerOf(b.asset.ledger).icrc1_transfer({
        from_subaccount = ?b.subaccount;
        to = to;
        amount = amount;
        fee = ?b.ledgerFeeMinor;
        memo = null;
        created_at_time = null;
      });
      switch (res) {
        case (#Ok(block)) #ok(block);
        case (#Err(e)) #err(transferErrText(e));
      };
    } catch (e) {
      #err("the ledger call failed: " # Error.message(e));
    };
  };

  // Release to the worker. Entered from #submitted only — by the buyer
  // approving, or by a clock that ran out on them.
  func releaseToWorker(id : Nat, who : Principal, why : Text) : async Result.Result<Bounty, Text> {
    let b = switch (getBounty(id)) {
      case (?b) b;
      case (null) return #err("No bounty " # Nat.toText(id) # ".");
    };
    if (b.state != #submitted) return #err("Bounty " # Nat.toText(id) # " is " # stateText(b.state) # ", not awaiting review.");
    let worker = switch (b.worker) {
      case (?w) w;
      case (null) return #err("Bounty " # Nat.toText(id) # " has no worker to pay.");
    };

    let fee = marketplaceFee(b.amountMinor);
    let workerGets : Nat = b.amountMinor - fee;

    // The guard. From here to the end of this function nothing else may act.
    putBounty(withEvent({ b with state = #releasing }, who, "Releasing escrow to worker.", ?why));

    switch (await payOut(b, { owner = worker; subaccount = null }, workerGets)) {
      case (#err(msg)) {
        let cur = switch (getBounty(id)) { case (?x) x; case (null) b };
        putBounty(withEvent({ cur with state = #submitted }, who, "Release failed; bounty returned to review.", ?msg));
        #err("Could not release the escrow: " # msg);
      };
      case (#ok(block)) {
        let cur = switch (getBounty(id)) { case (?x) x; case (null) b };
        let done = withEvent(
          { cur with state = #released; settledAt = ?now() },
          who,
          "Escrow released to worker: " # fmtMoney(workerGets, b.asset) # ".",
          ?(why # " (ledger block " # Nat.toText(block) # ")"),
        );
        putBounty(done);
        #ok(done);
      };
    };
  };

  // Refund the buyer. Entered from #open (cancelled before anyone claimed) or
  // #assigned (the worker missed the delivery deadline).
  func refundBuyer(id : Nat, who : Principal, why : Text) : async Result.Result<Bounty, Text> {
    let b = switch (getBounty(id)) {
      case (?b) b;
      case (null) return #err("No bounty " # Nat.toText(id) # ".");
    };
    if (b.state != #open and b.state != #assigned) {
      return #err("Bounty " # Nat.toText(id) # " is " # stateText(b.state) # " and cannot be refunded from there.");
    };

    putBounty(withEvent({ b with state = #refunding }, who, "Refunding escrow to buyer.", ?why));

    switch (await payOut(b, { owner = b.buyer; subaccount = null }, b.amountMinor)) {
      case (#err(msg)) {
        let cur = switch (getBounty(id)) { case (?x) x; case (null) b };
        putBounty(withEvent({ cur with state = b.state }, who, "Refund failed; bounty restored.", ?msg));
        #err("Could not refund the escrow: " # msg);
      };
      case (#ok(block)) {
        let cur = switch (getBounty(id)) { case (?x) x; case (null) b };
        let done = withEvent(
          { cur with state = #refunded; settledAt = ?now(); worker = null },
          who,
          "Escrow refunded to buyer: " # fmtMoney(b.amountMinor, b.asset) # ".",
          ?(why # " (ledger block " # Nat.toText(block) # ")"),
        );
        putBounty(done);
        #ok(done);
      };
    };
  };

  // --- CLOCKS — INVARIANT 5 ---
  //
  // Silence always resolves, and never in favour of the canister keeping the
  // money. An unanswered submission pays the worker; a missed delivery refunds
  // the buyer. Both a timer and a public settle_due drive this, deliberately:
  // a timer that dies quietly after an upgrade is a fund-locking bug, so a
  // stranger has to be able to force the outcome the rules already guarantee.

  type Due = { #releaseToWorker; #refundBuyer; #notDue : Text };

  func dueOutcome(b : Bounty, nowNs : Int) : Due {
    switch (b.state) {
      case (#submitted) {
        switch (b.reviewDeadline) {
          case (?d) { if (nowNs >= d) #releaseToWorker else #notDue("the buyer's review window has " # fmtDuration(d - nowNs) # " left") };
          case (null) #notDue("no review deadline is set");
        };
      };
      case (#assigned) {
        switch (b.deliveryDeadline) {
          case (?d) { if (nowNs >= d) #refundBuyer else #notDue("the worker has " # fmtDuration(d - nowNs) # " left to deliver") };
          case (null) #notDue("no delivery deadline is set");
        };
      };
      case (#disputed) #notDue("it is disputed — clocks are stopped and v1 has no exit from that state");
      case (s) #notDue("it is " # stateText(s));
    };
  };

  func settleOne(id : Nat, who : Principal) : async Result.Result<Bounty, Text> {
    let b = switch (getBounty(id)) {
      case (?b) b;
      case (null) return #err("No bounty " # Nat.toText(id) # ".");
    };
    if (isSettling(b)) return #err(settlingError(b));
    switch (dueOutcome(b, now())) {
      case (#releaseToWorker) await releaseToWorker(id, who, "Review window expired with no response from the buyer.");
      case (#refundBuyer) await refundBuyer(id, who, "Delivery deadline passed with no submission.");
      case (#notDue(reason)) #err("Bounty " # Nat.toText(id) # " is not due: " # reason # ".");
    };
  };

  func sweepDue() : async () {
    let self_ = Principal.fromActor(self);
    var id = nextBountyId;
    while (id > 1) {
      id -= 1;
      switch (getBounty(id)) {
        case (?b) {
          if (not isSettling(b)) {
            switch (dueOutcome(b, now())) {
              case (#notDue(_)) {};
              case (_) { ignore await settleOne(id, self_) };
            };
          };
        };
        case (null) {};
      };
    };
  };

  ignore Timer.recurringTimer<system>(#seconds 900, sweepDue);

  // --- TOOL SURFACE ---

  transient let bountyResultSchema : Json.Json = objSchema(
    [
      schemaProp("message", "string", "Confirmation message."),
      ("bounty", Json.obj([("type", Json.str("object"))])),
    ],
    ["message"],
  );

  transient let tools : [McpTypes.Tool] = [
    {
      name = "create_bounty";
      title = ?"Create Bounty";
      description = ?"Draft a job: what you want, what counts as done, how much it pays, and how long each side has. Acceptance criteria are their own required field because they freeze the moment the bounty is funded and are what any dispute is read against — write them as something checkable, not as a restatement of the brief. Nothing is public and no money moves until you call fund_bounty. v1 caps a bounty at 100 ckUSDC.";
      payment = null;
      inputSchema = objSchema(
        [
          schemaProp("title", "string", "Short name for the job, e.g. 'Reconcile Q3 books against the ckUSDC ledger'."),
          schemaProp("brief", "string", "What is wanted: context, where the inputs live, what the worker needs to know."),
          schemaProp("acceptance", "string", "What counts as done, in checkable terms. Frozen at funding and never editable afterward."),
          schemaProp("skills", "string", "Comma-separated or an array, e.g. 'bookkeeping, icrc'. This is what workers search on."),
          schemaProp("amount", "number", "The bounty in whole tokens, e.g. 15 or 15.5. Or pass amount_minor instead."),
          schemaProp("amount_minor", "number", "The bounty in the ledger's minor units, if you would rather be exact."),
          schemaProp("ledger", "string", "ICRC ledger canister id. Defaults to ckUSDC. Only allowlisted ledgers are accepted."),
          schemaProp("assignment", "string", "first_claim (default — any worker may take it, first one wins) or buyer_selects (workers bid, you pick)."),
          schemaProp("delivery_days", "number", "How many days the worker gets once assigned. Default 7, max 90."),
          schemaProp("review_window_hours", "number", "How long you get to review after submission. Default 168 (7 days), minimum 24. If you say nothing in this window the escrow releases to the worker."),
          schemaProp("revisions_allowed", "number", "How many rounds of changes you may request. Default 1, max 10. Visible to workers before they claim."),
        ],
        ["title", "brief", "acceptance"],
      );
      outputSchema = ?bountyResultSchema;
    },
    {
      name = "update_bounty";
      title = ?"Update Bounty";
      description = ?"Edit a draft bounty. Works only while the bounty is unfunded: once money is in escrow the brief and the acceptance criteria are frozen and hashed, and the only way to want different work is to cancel and post a new bounty. That is deliberate — moving the goalposts after someone has started is the defining failure of freelance work, and it costs one hash to make impossible.";
      payment = null;
      inputSchema = objSchema(
        [
          schemaProp("bounty", "number", "The bounty id."),
          schemaProp("title", "string", "New title."),
          schemaProp("brief", "string", "New brief."),
          schemaProp("acceptance", "string", "New acceptance criteria."),
          schemaProp("skills", "string", "Replace the skills list."),
          schemaProp("amount", "number", "New amount in whole tokens."),
          schemaProp("amount_minor", "number", "New amount in minor units."),
          schemaProp("assignment", "string", "first_claim or buyer_selects."),
          schemaProp("delivery_days", "number", "New delivery window in days."),
          schemaProp("review_window_hours", "number", "New review window in hours."),
          schemaProp("revisions_allowed", "number", "New revision allowance."),
        ],
        ["bounty"],
      );
      outputSchema = ?bountyResultSchema;
    },
    {
      name = "fund_bounty";
      title = ?"Fund Bounty";
      description = ?"Move the money into escrow and publish the listing. This pulls the bounty plus one ledger fee from your account via icrc2_transfer_from into a subaccount derived from the bounty id, confirms the balance actually landed, freezes the brief, and lists the job. Approve this canister as spender on the ledger first — if the allowance is short this returns the exact icrc2_approve call to make.";
      payment = null;
      inputSchema = objSchema([schemaProp("bounty", "number", "The bounty id to fund.")], ["bounty"]);
      outputSchema = null;
    },
    {
      name = "cancel_bounty";
      title = ?"Cancel Bounty";
      description = ?"Withdraw a bounty. A draft is deleted outright. A funded bounty nobody has claimed is refunded to you in full, less the ledger's own fees. Once a worker is assigned this refuses: at that point someone is doing the work you asked for, and the way out is request_changes, letting the delivery clock run, or dispute_bounty.";
      payment = null;
      inputSchema = objSchema([schemaProp("bounty", "number", "The bounty id to cancel.")], ["bounty"]);
      outputSchema = null;
    },
    {
      name = "search_bounties";
      title = ?"Search Bounties";
      description = ?"The listing a worker shops: open bounties that are funded and waiting for someone to take them. Filter by skill, ledger, amount range, or assignment mode. Every result is backed by money already sitting in escrow — this marketplace has no listings backed by an intention.";
      payment = null;
      inputSchema = objSchema(
        [
          schemaProp("skill", "string", "Match one skill tag, e.g. 'code-review'."),
          schemaProp("ledger", "string", "Only bounties paid in this ledger's token."),
          schemaProp("min_amount", "number", "Minimum bounty in whole tokens."),
          schemaProp("max_amount", "number", "Maximum bounty in whole tokens."),
          schemaProp("assignment", "string", "first_claim or buyer_selects."),
          schemaProp("limit", "number", "Max rows, default 50."),
        ],
        [],
      );
      outputSchema = null;
    },
    {
      name = "get_bounty";
      title = ?"Get Bounty";
      description = ?"One bounty in full: brief, the frozen acceptance criteria and their hash, state, both clocks and what is left on them, the deliverable pointer once work is submitted, and the complete history of who did what and when. Drafts are visible only to the buyer who owns them; everything from funding onward is public.";
      payment = null;
      inputSchema = objSchema([schemaProp("bounty", "number", "The bounty id.")], ["bounty"]);
      outputSchema = null;
    },
    {
      name = "get_escrow_proof";
      title = ?"Get Escrow Proof";
      description = ?"Check the money yourself. Returns the bounty's escrow subaccount, the ledger it lives on, what this canister believes it holds, and the live icrc1_balance_of for that exact account — so either party can compare the two numbers, or skip this tool entirely and ask the ledger directly. If they ever disagree you hear it from the server rather than from a surprise.";
      payment = null;
      inputSchema = objSchema([schemaProp("bounty", "number", "The bounty id.")], ["bounty"]);
      outputSchema = null;
    },
    {
      name = "claim_bounty";
      title = ?"Claim Bounty";
      description = ?"Take a first_claim bounty and start the delivery clock. First worker wins. You cannot claim your own bounty, and you may hold at most three live jobs at once — a cap that exists because claiming everything and delivering nothing would otherwise burn every buyer's delivery window for free.";
      payment = null;
      inputSchema = objSchema([schemaProp("bounty", "number", "The bounty id to claim.")], ["bounty"]);
      outputSchema = null;
    },
    {
      name = "submit_bid";
      title = ?"Submit Bid";
      description = ?"Bid on a buyer_selects bounty with a note saying why you are the one to do it. There is no price negotiation in v1 — the amount on the listing is the amount. Your bid is visible to the buyer and to you, and to nobody else: public bids turn into a race to the bottom and let anyone read a worker's pipeline.";
      payment = null;
      inputSchema = objSchema(
        [
          schemaProp("bounty", "number", "The bounty id."),
          schemaProp("note", "string", "Your pitch: relevant experience, how you would approach it, when you would deliver."),
        ],
        ["bounty", "note"],
      );
      outputSchema = null;
    },
    {
      name = "list_bids";
      title = ?"List Bids";
      description = ?"Bids on a bounty. The buyer sees every bid; a worker sees only their own.";
      payment = null;
      inputSchema = objSchema([schemaProp("bounty", "number", "The bounty id.")], ["bounty"]);
      outputSchema = null;
    },
    {
      name = "select_worker";
      title = ?"Select Worker";
      description = ?"Pick a bidder for a buyer_selects bounty. Assigns them and starts the delivery clock.";
      payment = null;
      inputSchema = objSchema(
        [
          schemaProp("bounty", "number", "The bounty id."),
          schemaProp("worker", "string", "The principal of the bidder you are choosing."),
        ],
        ["bounty", "worker"],
      );
      outputSchema = null;
    },
    {
      name = "submit_work";
      title = ?"Submit Work";
      description = ?"Deliver: a content hash, a pointer to where the work actually lives, and an optional cover note. This canister never sees the deliverable and could not judge it if it did — it timestamps the hash and starts the buyer's review clock. Do not put a confidential deliverable behind a public URL; the pointer is public, and so is the fact of the job.";
      payment = null;
      inputSchema = objSchema(
        [
          schemaProp("bounty", "number", "The bounty id."),
          schemaProp("hash", "string", "sha256 of the delivered content, hex. Proves later that what you handed over is what they are reviewing."),
          schemaProp("pointer", "string", "Where the work lives: a URL, a canister id, an IPFS cid."),
          schemaProp("kind", "string", "Content type, e.g. 'text/markdown' or 'application/pdf'. Freeform."),
          schemaProp("note", "string", "Optional cover note for the buyer."),
        ],
        ["bounty", "hash", "pointer"],
      );
      outputSchema = null;
    },
    {
      name = "withdraw_claim";
      title = ?"Withdraw Claim";
      description = ?"Give a bounty back before the delivery deadline if you cannot finish it. It returns to open for someone else and costs nobody anything, which is the point — a clean withdrawal is far better for everyone than a silent no-show that burns the buyer's whole delivery window.";
      payment = null;
      inputSchema = objSchema(
        [
          schemaProp("bounty", "number", "The bounty id."),
          schemaProp("reason", "string", "Optional note for the record."),
        ],
        ["bounty"],
      );
      outputSchema = null;
    },
    {
      name = "approve_work";
      title = ?"Approve Work";
      description = ?"Accept the delivered work and release the escrow to the worker. This is final and immediate: the money leaves the bounty's subaccount for the worker's account in the same call. Returns the submit_review call for the Review & Reputation Oracle, which is where reputation for this job belongs — this server does not grow a score of its own.";
      payment = null;
      inputSchema = objSchema(
        [
          schemaProp("bounty", "number", "The bounty id."),
          schemaProp("note", "string", "Optional note to the worker, recorded in the history."),
        ],
        ["bounty"],
      );
      outputSchema = null;
    },
    {
      name = "request_changes";
      title = ?"Request Changes";
      description = ?"Send work back with a required reason, returning the bounty to the worker with a fresh delivery clock. Bounded by the revision allowance you set at creation and visible to the worker before they claimed, because unlimited revision requests are how free rework gets extracted while technically never rejecting anything. The reason goes in the permanent history.";
      payment = null;
      inputSchema = objSchema(
        [
          schemaProp("bounty", "number", "The bounty id."),
          schemaProp("reason", "string", "What specifically is not yet meeting the acceptance criteria. Required."),
          schemaProp("extra_days", "number", "Days the worker gets for the revision. Defaults to the original delivery window."),
        ],
        ["bounty", "reason"],
      );
      outputSchema = null;
    },
    {
      name = "reclaim_bounty";
      title = ?"Reclaim Bounty";
      description = ?"Take your money back after a worker has missed the delivery deadline. Refunds the full bounty to you. Only works once the deadline has actually passed — until then the job is theirs.";
      payment = null;
      inputSchema = objSchema([schemaProp("bounty", "number", "The bounty id.")], ["bounty"]);
      outputSchema = null;
    },
    {
      name = "settle_due";
      title = ?"Settle Due Bounties";
      description = ?"Force the outcome the rules already guarantee on any bounty whose clock has run out: an unanswered submission releases to the worker, a missed delivery refunds the buyer. Anyone may call this on any bounty, including a complete stranger — a timer also does it every fifteen minutes, and a timer that fails quietly after an upgrade would otherwise leave funds stuck. Pass a bounty id, or call it bare to settle everything that is due.";
      payment = null;
      inputSchema = objSchema([schemaProp("bounty", "number", "Optional: one bounty id. Omit to settle every due bounty.")], []);
      outputSchema = null;
    },
    {
      name = "dispute_bounty";
      title = ?"Dispute Bounty";
      description = ?"Stop every clock and park the funds. Either party may do this before release. Be warned, in plain terms: v1 has no way out of a dispute. There is no arbiter, the money stays in the bounty's subaccount, and it stays there until an arbitration path ships. That is an honest limit rather than a half-built court moving real money confidently in the wrong direction — but it means disputing is a last resort, not a negotiating move.";
      payment = null;
      inputSchema = objSchema(
        [
          schemaProp("bounty", "number", "The bounty id."),
          schemaProp("reason", "string", "What went wrong. Required, and permanent."),
        ],
        ["bounty", "reason"],
      );
      outputSchema = null;
    },
    {
      name = "my_work";
      title = ?"My Work";
      description = ?"Everything you are on either side of, and what is waiting on you: bounties you posted, bounties you are working, which clocks are running, and which ones need an action from you right now. The 'what do I owe anyone' sweep.";
      payment = null;
      inputSchema = objSchema(
        [
          schemaProp("role", "string", "buyer, worker, or both (default)."),
          schemaProp("include_settled", "string", "Pass 'true' to include released, refunded, and cancelled bounties. Default false."),
        ],
        [],
      );
      outputSchema = null;
    },
  ];

  // --- TOOL IMPLEMENTATIONS ---

  transient let reviewOracle : Text = "gnoi7-taaaa-aaaah-quxiq-cai";

  // Reputation is the Review & Reputation Oracle's job, and it already shipped.
  // Returning the call is a weak binding — nothing makes either party make it —
  // but making the release itself write a review needs that canister to trust
  // this one as an attestor, which is a conversation, not a line of code.
  func reviewHint(b : Bounty, subject : Principal) : Json.Json {
    Json.obj([
      ("canister", Json.str(reviewOracle)),
      ("tool", Json.str("submit_review")),
      ("subject", Json.str(Principal.toText(subject))),
      ("context", Json.str("Escrow Work Marketplace bounty " # Nat.toText(b.id) # ": " # b.title)),
    ]);
  };

  func allowedAssetFor(ledger : Text) : ?AllowedAsset {
    Map.get(allowedAssets, thash, ledger);
  };

  func allowlistText() : Text {
    var out = "";
    for ((id, a) in Map.entries(allowedAssets)) {
      let cap = fmtMoney(a.capMinor, { ledger = id; symbol = a.symbol; decimals = a.decimals });
      out #= (if (out == "") "" else "; ") # a.symbol # " (" # id # ", cap " # cap # ")";
    };
    out;
  };

  func createBountyTool(args : McpTypes.JsonValue, auth : ?AuthTypes.AuthInfo, cb : ToolCb) : async () {
    let ?caller = requireAuth(auth, cb) else return;

    let ?title = optText(args, "title") else return cb(#ok(errorResult("A bounty needs a 'title'.")));
    let ?brief = optText(args, "brief") else return cb(#ok(errorResult("A bounty needs a 'brief' saying what is wanted.")));
    let ?acceptance = optText(args, "acceptance") else return cb(#ok(errorResult("A bounty needs 'acceptance' criteria: what counts as done, in terms someone can check. This is the field that freezes at funding and the one a dispute is read against, so it is required rather than optional.")));

    let ledger = switch (optText(args, "ledger")) { case (?l) l; case (null) ckusdcLedger };
    let ?allowed = allowedAssetFor(ledger) else return cb(#ok(errorResult("Ledger " # ledger # " is not on the allowlist, so this canister will not hold funds denominated in it. Allowed: " # allowlistText() # ". An unknown ledger has no size cap and no vetting, and pointing escrow at an arbitrary canister is how a marketplace gets drained.")));

    let asset : Asset = { ledger = ledger; symbol = allowed.symbol; decimals = allowed.decimals };
    let scale = pow10(Nat8.toNat(allowed.decimals));

    let amountMinor = switch (optNat(args, "amount_minor")) {
      case (?m) m;
      case (null) {
        switch (optFloat(args, "amount")) {
          case (?a) { if (a <= 0.0) 0 else Int.abs(Float.toInt(a * Float.fromInt(scale) + 0.5)) };
          case (null) 0;
        };
      };
    };
    if (amountMinor == 0) return cb(#ok(errorResult("A bounty needs an 'amount' greater than zero — in whole tokens, or 'amount_minor' in the ledger's minor units.")));
    if (amountMinor > allowed.capMinor) {
      return cb(#ok(errorResult("That is " # fmtMoney(amountMinor, asset) # ", over the v1 cap of " # fmtMoney(allowed.capMinor, asset) # " per bounty. The cap is deliberate: this is the first canister in this lineup that holds anyone's money, and a ceiling bounds what a custody bug can cost while the code is new.")));
    };

    let assignment = switch (optText(args, "assignment")) {
      case (?a) {
        switch (parseAssignment(a)) {
          case (?x) x;
          case (null) return cb(#ok(errorResult("'assignment' must be first_claim or buyer_selects.")));
        };
      };
      case (null) #firstClaim;
    };

    let deliveryDays = switch (optNat(args, "delivery_days")) { case (?d) d; case (null) 7 };
    if (deliveryDays == 0 or deliveryDays > maxDeliveryDays) {
      return cb(#ok(errorResult("'delivery_days' must be between 1 and " # Nat.toText(maxDeliveryDays) # ".")));
    };

    let reviewWindowNs = switch (optNat(args, "review_window_hours")) {
      case (?h) h * nanosPerHour;
      case (null) defaultReviewWindowNs;
    };
    if (reviewWindowNs < minReviewWindowNs) {
      return cb(#ok(errorResult("'review_window_hours' must be at least 24. The window is what a worker is trusting when they start: too short and an honest buyer misses it, and the escrow releases on a technicality.")));
    };
    if (reviewWindowNs > maxReviewWindowNs) {
      return cb(#ok(errorResult("'review_window_hours' cannot exceed 720 (30 days). A longer window is a worker waiting a month to find out whether they were paid.")));
    };

    let revisionsAllowed = switch (optNat(args, "revisions_allowed")) { case (?r) r; case (null) 1 };
    if (revisionsAllowed > maxRevisionsAllowed) {
      return cb(#ok(errorResult("'revisions_allowed' cannot exceed " # Nat.toText(maxRevisionsAllowed) # ".")));
    };

    let id = nextBountyId;
    nextBountyId += 1;

    let b : Bounty = {
      id = id;
      buyer = caller;
      title = title;
      brief = brief;
      acceptance = acceptance;
      briefHash = null;
      skills = optTextList(args, "skills");
      asset = asset;
      amountMinor = amountMinor;
      ledgerFeeMinor = 0;
      escrowedMinor = 0;
      subaccount = subaccountFor(id);
      assignment = assignment;
      state = #draft;
      worker = null;
      deliveryDays = deliveryDays;
      deliveryDeadline = null;
      reviewWindowNs = reviewWindowNs;
      reviewDeadline = null;
      revisionsUsed = 0;
      revisionsAllowed = revisionsAllowed;
      deliverable = null;
      history = [];
      createdAt = now();
      fundedAt = null;
      settledAt = null;
      disputeReason = null;
    };
    let withHistory = withEvent(b, caller, "Bounty drafted.", ?(fmtMoney(amountMinor, asset) # ", " # assignmentText(assignment)));
    putBounty(withHistory);
    addId(bountyIdsByBuyer, caller, id);

    cb(#ok(okResult(Json.obj([
      ("message", Json.str("Bounty " # Nat.toText(id) # " drafted for " # fmtMoney(amountMinor, asset) # ". It is private and unlisted until you call fund_bounty — no money has moved, and until it does, no worker sees it.")),
      ("bounty", bountyToJson(withHistory, false)),
      ("next_step", Json.str("fund_bounty with bounty=" # Nat.toText(id) # ". You will need an ICRC-2 allowance to this canister covering the bounty plus two ledger fees.")),
    ]))));
  };

  func updateBountyTool(args : McpTypes.JsonValue, auth : ?AuthTypes.AuthInfo, cb : ToolCb) : async () {
    let ?caller = requireAuth(auth, cb) else return;
    let ?b = resolveBounty(args, cb) else return;
    if (not requireBuyer(b, caller, cb)) return;
    if (b.state != #draft) {
      return cb(#ok(errorResult("Bounty " # Nat.toText(b.id) # " is " # stateText(b.state) # " and can no longer be edited. The brief and acceptance criteria froze when the escrow was funded — hash " # (switch (b.briefHash) { case (?h) h; case (null) "n/a" }) # " — and they stay frozen so the work someone agreed to do cannot change underneath them. If you want different work, cancel and post a new bounty.")));
    };

    let scale = pow10(Nat8.toNat(b.asset.decimals));
    let newAmount = switch (optNat(args, "amount_minor")) {
      case (?m) m;
      case (null) {
        switch (optFloat(args, "amount")) {
          case (?a) { if (a <= 0.0) b.amountMinor else Int.abs(Float.toInt(a * Float.fromInt(scale) + 0.5)) };
          case (null) b.amountMinor;
        };
      };
    };
    let ?allowed = allowedAssetFor(b.asset.ledger) else return cb(#ok(errorResult("Ledger " # b.asset.ledger # " is no longer allowlisted.")));
    if (newAmount > allowed.capMinor) {
      return cb(#ok(errorResult("That is over the v1 cap of " # fmtMoney(allowed.capMinor, b.asset) # " per bounty.")));
    };

    let deliveryDays = switch (optNat(args, "delivery_days")) { case (?d) d; case (null) b.deliveryDays };
    if (deliveryDays == 0 or deliveryDays > maxDeliveryDays) {
      return cb(#ok(errorResult("'delivery_days' must be between 1 and " # Nat.toText(maxDeliveryDays) # ".")));
    };
    let reviewWindowNs = switch (optNat(args, "review_window_hours")) { case (?h) h * nanosPerHour; case (null) b.reviewWindowNs };
    if (reviewWindowNs < minReviewWindowNs or reviewWindowNs > maxReviewWindowNs) {
      return cb(#ok(errorResult("'review_window_hours' must be between 24 and 720.")));
    };
    let revisionsAllowed = switch (optNat(args, "revisions_allowed")) { case (?r) r; case (null) b.revisionsAllowed };
    if (revisionsAllowed > maxRevisionsAllowed) {
      return cb(#ok(errorResult("'revisions_allowed' cannot exceed " # Nat.toText(maxRevisionsAllowed) # ".")));
    };
    let assignment = switch (optText(args, "assignment")) {
      case (?a) {
        switch (parseAssignment(a)) {
          case (?x) x;
          case (null) return cb(#ok(errorResult("'assignment' must be first_claim or buyer_selects.")));
        };
      };
      case (null) b.assignment;
    };

    let skills = switch (Json.get(args, "skills")) { case (null) b.skills; case (_) optTextList(args, "skills") };

    let updated = withEvent(
      {
        b with
        title = switch (optText(args, "title")) { case (?t) t; case (null) b.title };
        brief = switch (optText(args, "brief")) { case (?t) t; case (null) b.brief };
        acceptance = switch (optText(args, "acceptance")) { case (?t) t; case (null) b.acceptance };
        skills = skills;
        amountMinor = newAmount;
        assignment = assignment;
        deliveryDays = deliveryDays;
        reviewWindowNs = reviewWindowNs;
        revisionsAllowed = revisionsAllowed;
      },
      caller,
      "Draft updated.",
      null,
    );
    putBounty(updated);
    cb(#ok(okResult(bountyResponse(updated, "Bounty " # Nat.toText(b.id) # " updated. Still a draft, still private, still unfunded."))));
  };

  func fundBountyTool(args : McpTypes.JsonValue, auth : ?AuthTypes.AuthInfo, cb : ToolCb) : async () {
    let ?caller = requireAuth(auth, cb) else return;
    let ?b0 = resolveBounty(args, cb) else return;
    if (not requireBuyer(b0, caller, cb)) return;
    if (b0.state != #draft) {
      return cb(#ok(errorResult("Bounty " # Nat.toText(b0.id) # " is already " # stateText(b0.state) # ".")));
    };

    // Invariant 9, re-checked at the transition rather than trusted from the draft.
    let ?allowed = allowedAssetFor(b0.asset.ledger) else return cb(#ok(errorResult("Ledger " # b0.asset.ledger # " is not allowlisted; this bounty cannot be funded.")));
    if (b0.amountMinor > allowed.capMinor) {
      return cb(#ok(errorResult("Bounty " # Nat.toText(b0.id) # " is over the current cap of " # fmtMoney(allowed.capMinor, b0.asset) # " and cannot be funded.")));
    };

    if (not lockFunding(b0.id)) {
      return cb(#ok(errorResult("Bounty " # Nat.toText(b0.id) # " already has a funding call in flight. Wait for it to finish rather than pulling twice.")));
    };

    let ledger = ledgerOf(b0.asset.ledger);
    let self_ = Principal.fromActor(self);

    let fee = try { await ledger.icrc1_fee() } catch (e) {
      unlockFunding(b0.id);
      return cb(#ok(errorResult("Could not read the ledger's fee: " # Error.message(e))));
    };

    // What the escrow must hold: the bounty, plus the fee its eventual payout
    // will cost. The worker is then paid the round number on the listing.
    let escrowNeeds : Nat = b0.amountMinor + fee;
    // What the buyer must have approved: that, plus the fee on this pull.
    let allowanceNeeds : Nat = escrowNeeds + fee;

    let allowance = try {
      await ledger.icrc2_allowance({
        account = { owner = caller; subaccount = null };
        spender = { owner = self_; subaccount = null };
      });
    } catch (e) {
      unlockFunding(b0.id);
      return cb(#ok(errorResult("Could not read your allowance: " # Error.message(e))));
    };

    if (allowance.allowance < allowanceNeeds) {
      unlockFunding(b0.id);
      return cb(#ok(okResult(Json.obj([
        ("funded", Json.bool(false)),
        ("reason", Json.str("allowance_insufficient")),
        ("have_minor", Json.int(allowance.allowance)),
        ("need_minor", Json.int(allowanceNeeds)),
        ("message", Json.str("Your ICRC-2 allowance to this canister is " # fmtMoney(allowance.allowance, b0.asset) # "; funding bounty " # Nat.toText(b0.id) # " needs " # fmtMoney(allowanceNeeds, b0.asset) # " — the bounty, plus the ledger fee on the way in and the one on the way out. Make the approve call below from your own wallet, then call fund_bounty again.")),
        ("do_this", Json.obj([
          ("canister", Json.str(b0.asset.ledger)),
          ("method", Json.str("icrc2_approve")),
          ("arg", Json.obj([
            ("spender", Json.obj([("owner", Json.str(Principal.toText(self_))), ("subaccount", Json.nullable())])),
            ("amount", Json.int(allowanceNeeds)),
          ])),
        ])),
      ]))));
    };

    let pulled = try {
      await ledger.icrc2_transfer_from({
        spender_subaccount = null;
        from = { owner = caller; subaccount = null };
        to = escrowAccount(b0.id);
        amount = escrowNeeds;
        fee = ?fee;
        memo = null;
        created_at_time = null;
      });
    } catch (e) {
      unlockFunding(b0.id);
      return cb(#ok(errorResult("The escrow transfer failed: " # Error.message(e) # ". Nothing moved.")));
    };

    switch (pulled) {
      case (#Err(e)) {
        unlockFunding(b0.id);
        return cb(#ok(errorResult("The ledger refused the escrow transfer: " # transferFromErrText(e) # ". Nothing moved and the bounty is still a draft.")));
      };
      case (#Ok(_)) {};
    };

    // Invariant 1: confirm the money actually arrived before anything is
    // listed. A worker never sees a bounty backed by an intention.
    let balance = try { await ledger.icrc1_balance_of(escrowAccount(b0.id)) } catch (e) {
      unlockFunding(b0.id);
      return cb(#ok(errorResult("The transfer was accepted but the balance check failed: " # Error.message(e) # ". Call get_escrow_proof before funding again — the money may already be in escrow.")));
    };

    if (balance < escrowNeeds) {
      unlockFunding(b0.id);
      let cur = switch (getBounty(b0.id)) { case (?x) x; case (null) b0 };
      putBounty(withEvent(cur, caller, "Funding aborted: escrow balance short after transfer.", ?(Nat.toText(balance) # " < " # Nat.toText(escrowNeeds))));
      return cb(#ok(errorResult("The ledger accepted the transfer but the escrow subaccount holds " # fmtMoney(balance, b0.asset) # ", less than the " # fmtMoney(escrowNeeds, b0.asset) # " this bounty needs. The bounty has not been listed. Check get_escrow_proof.")));
    };

    let cur = switch (getBounty(b0.id)) { case (?x) x; case (null) b0 };
    let funded = withEvent(
      {
        cur with
        state = #open;
        briefHash = ?sha256Hex(cur.brief # "\n---\n" # cur.acceptance);
        fundedAt = ?now();
        ledgerFeeMinor = fee;
        escrowedMinor = escrowNeeds;
      },
      caller,
      "Escrow funded and bounty listed.",
      ?(fmtMoney(escrowNeeds, b0.asset) # " held in subaccount " # toHex(b0.subaccount)),
    );
    putBounty(funded);
    unlockFunding(b0.id);

    cb(#ok(okResult(Json.obj([
      ("funded", Json.bool(true)),
      ("message", Json.str("Bounty " # Nat.toText(b0.id) # " is funded and live. " # fmtMoney(escrowNeeds, b0.asset) # " is held in its own subaccount, the brief and acceptance criteria are frozen, and workers can find it with search_bounties.")),
      ("bounty", bountyToJson(funded, false)),
      ("escrow", Json.obj([
        ("ledger", Json.str(b0.asset.ledger)),
        ("owner", Json.str(Principal.toText(self_))),
        ("subaccount", Json.str(toHex(b0.subaccount))),
        ("balance_minor", Json.int(balance)),
        ("verify_with", Json.str("icrc1_balance_of on " # b0.asset.ledger # " — you do not have to take this server's word for it")),
      ])),
    ]))));
  };

  func cancelBountyTool(args : McpTypes.JsonValue, auth : ?AuthTypes.AuthInfo, cb : ToolCb) : async () {
    let ?caller = requireAuth(auth, cb) else return;
    let ?b = resolveBounty(args, cb) else return;
    if (not requireBuyer(b, caller, cb)) return;
    if (isSettling(b)) return cb(#ok(errorResult(settlingError(b))));

    switch (b.state) {
      case (#draft) {
        Map.delete(bounties, nhash, b.id);
        Map.delete(openBountyIds, nhash, b.id);
        Map.set(bountyIdsByBuyer, phash, caller, Array.filter<Nat>(idsFor(bountyIdsByBuyer, caller), func(x) { x != b.id }));
        cb(#ok(okResult(Json.obj([("message", Json.str("Draft bounty " # Nat.toText(b.id) # " deleted. No money had moved."))]))));
      };
      case (#open) {
        switch (await refundBuyer(b.id, caller, "Buyer cancelled an unclaimed bounty.")) {
          case (#ok(done)) cb(#ok(okResult(bountyResponse(done, "Bounty " # Nat.toText(b.id) # " cancelled and " # fmtMoney(b.amountMinor, b.asset) # " refunded to you. The ledger's fees are gone — that is what posting and withdrawing cost."))));
          case (#err(msg)) cb(#ok(errorResult(msg)));
        };
      };
      case (#assigned or #submitted) {
        cb(#ok(errorResult("Bounty " # Nat.toText(b.id) # " has a worker on it, so it cannot simply be cancelled — someone is doing the work you asked for. Your options are request_changes if the delivery is not right, letting the delivery clock run out and then reclaim_bounty, or dispute_bounty if something has actually gone wrong.")));
      };
      case (s) cb(#ok(errorResult("Bounty " # Nat.toText(b.id) # " is " # stateText(s) # " and cannot be cancelled.")));
    };
  };

  func searchBountiesTool(args : McpTypes.JsonValue, _auth : ?AuthTypes.AuthInfo, cb : ToolCb) : async () {
    let skill = switch (optText(args, "skill")) { case (?s) ?lower(s); case (null) null };
    let ledgerFilter = optText(args, "ledger");
    let assignmentFilter = switch (optText(args, "assignment")) { case (?a) parseAssignment(a); case (null) null };
    let limit = switch (optNat(args, "limit")) { case (?l) l; case (null) 50 };

    let out = Buffer.Buffer<Json.Json>(16);
    var scanned : Nat = 0;
    for ((id, _) in Map.entries(openBountyIds)) {
      switch (getBounty(id)) {
        case (?b) {
          if (b.state == #open) {
            let scale = Float.fromInt(pow10(Nat8.toNat(b.asset.decimals)));
            let amountMajor = Float.fromInt(b.amountMinor) / scale;
            var keep = true;
            switch (skill) {
              case (?s) {
                var found = false;
                for (tag in b.skills.vals()) { if (tag == s) found := true };
                if (not found) keep := false;
              };
              case (null) {};
            };
            switch (ledgerFilter) { case (?l) { if (b.asset.ledger != l) keep := false }; case (null) {} };
            switch (assignmentFilter) { case (?a) { if (b.assignment != a) keep := false }; case (null) {} };
            switch (optFloat(args, "min_amount")) { case (?m) { if (amountMajor < m) keep := false }; case (null) {} };
            switch (optFloat(args, "max_amount")) { case (?m) { if (amountMajor > m) keep := false }; case (null) {} };
            if (keep and out.size() < limit) {
              out.add(bountyToJson(b, false));
              scanned += 1;
            };
          };
        };
        case (null) {};
      };
    };

    cb(#ok(okResult(Json.obj([
      ("count", Json.int(out.size())),
      ("bounties", Json.arr(Buffer.toArray(out))),
      ("note", Json.str("Every bounty listed here is funded — the money is already in a subaccount you can check with get_escrow_proof before you start work.")),
    ]))));
  };

  func getBountyTool(args : McpTypes.JsonValue, auth : ?AuthTypes.AuthInfo, cb : ToolCb) : async () {
    let ?caller = requireAuth(auth, cb) else return;
    let ?b = resolveBounty(args, cb) else return;
    if (b.state == #draft and b.buyer != caller) {
      return cb(#ok(errorResult("Bounty " # Nat.toText(b.id) # " is an unfunded draft and is private to the buyer who wrote it.")));
    };
    cb(#ok(okResult(Json.obj([
      ("bounty", bountyToJson(b, true)),
      ("bids", Json.int(bidsFor(b.id).size())),
    ]))));
  };

  func getEscrowProofTool(args : McpTypes.JsonValue, auth : ?AuthTypes.AuthInfo, cb : ToolCb) : async () {
    let ?_caller = requireAuth(auth, cb) else return;
    let ?b = resolveBounty(args, cb) else return;
    let self_ = Principal.fromActor(self);

    let balance = try { await ledgerOf(b.asset.ledger).icrc1_balance_of(escrowAccount(b.id)) } catch (e) {
      return cb(#ok(errorResult("Could not read the ledger: " # Error.message(e))));
    };

    let agrees = balance >= b.escrowedMinor;
    cb(#ok(okResult(Json.obj([
      ("bounty", Json.int(b.id)),
      ("state", Json.str(stateText(b.state))),
      ("ledger", Json.str(b.asset.ledger)),
      ("account", Json.obj([
        ("owner", Json.str(Principal.toText(self_))),
        ("subaccount_hex", Json.str(toHex(b.subaccount))),
      ])),
      ("claimed_minor", Json.int(b.escrowedMinor)),
      ("claimed", Json.str(fmtMoney(b.escrowedMinor, b.asset))),
      ("on_chain_minor", Json.int(balance)),
      ("on_chain", Json.str(fmtMoney(balance, b.asset))),
      ("payout_to_worker_minor", Json.int(b.amountMinor - marketplaceFee(b.amountMinor))),
      ("marketplace_fee_minor", Json.int(marketplaceFee(b.amountMinor))),
      ("agrees", Json.bool(agrees)),
      ("message", Json.str(
        if (agrees) "The ledger confirms the escrow. The subaccount holds " # fmtMoney(balance, b.asset) # " against a claimed " # fmtMoney(b.escrowedMinor, b.asset) # "."
        else "MISMATCH: this canister claims " # fmtMoney(b.escrowedMinor, b.asset) # " but the ledger reports " # fmtMoney(balance, b.asset) # " in the escrow subaccount. Do not start work on this bounty; something is wrong and both parties should see this before anyone relies on it."
      )),
      ("verify_yourself", Json.str("Call icrc1_balance_of on " # b.asset.ledger # " with owner=" # Principal.toText(self_) # " and subaccount=" # toHex(b.subaccount) # ". The subaccount is just the bounty id big-endian in the low 8 bytes of 32, so you can derive it without this server.")),
    ]))));
  };

  func assignTo(b : Bounty, worker : Principal, who : Principal, why : Text) : Bounty {
    let deadline = now() + b.deliveryDays * Int.abs(nanosPerDay);
    let assigned = withEvent(
      { b with state = #assigned; worker = ?worker; deliveryDeadline = ?deadline },
      who,
      why,
      ?("delivery due in " # Nat.toText(b.deliveryDays) # " days"),
    );
    putBounty(assigned);
    addId(bountyIdsByWorker, worker, b.id);
    assigned;
  };

  func claimBountyTool(args : McpTypes.JsonValue, auth : ?AuthTypes.AuthInfo, cb : ToolCb) : async () {
    let ?caller = requireAuth(auth, cb) else return;
    let ?b = resolveBounty(args, cb) else return;
    if (isSettling(b)) return cb(#ok(errorResult(settlingError(b))));
    if (b.state != #open) return cb(#ok(errorResult("Bounty " # Nat.toText(b.id) # " is " # stateText(b.state) # ", not open for claiming.")));
    if (b.assignment != #firstClaim) {
      return cb(#ok(errorResult("Bounty " # Nat.toText(b.id) # " is buyer_selects: submit_bid instead, and the buyer picks.")));
    };
    // Invariant 8. Self-dealing to farm a reputation is the first thing anyone tries.
    if (b.buyer == caller) return cb(#ok(errorResult("You cannot claim your own bounty.")));

    let held = liveClaimCount(caller);
    if (held >= maxConcurrentClaims) {
      return cb(#ok(errorResult("You are already holding " # Nat.toText(held) # " live jobs, which is the limit. Finish one, or withdraw_claim on one you cannot finish, then claim this. The cap exists because claiming everything and delivering nothing would otherwise cost nothing and burn every buyer's delivery window.")));
    };

    let assigned = assignTo(b, caller, caller, "Worker claimed the bounty.");
    cb(#ok(okResult(Json.obj([
      ("message", Json.str("Bounty " # Nat.toText(b.id) # " is yours. You have " # Nat.toText(b.deliveryDays) # " days to submit_work. The acceptance criteria are frozen at hash " # (switch (b.briefHash) { case (?h) h; case (null) "n/a" }) # " and cannot change underneath you.")),
      ("bounty", bountyToJson(assigned, true)),
      ("verify_the_money", Json.str("get_escrow_proof with bounty=" # Nat.toText(b.id) # " before you start.")),
    ]))));
  };

  func submitBidTool(args : McpTypes.JsonValue, auth : ?AuthTypes.AuthInfo, cb : ToolCb) : async () {
    let ?caller = requireAuth(auth, cb) else return;
    let ?b = resolveBounty(args, cb) else return;
    let ?note = optText(args, "note") else return cb(#ok(errorResult("A bid needs a 'note' — the buyer is choosing between people, not between empty bids.")));
    if (b.state != #open) return cb(#ok(errorResult("Bounty " # Nat.toText(b.id) # " is " # stateText(b.state) # ", not open for bids.")));
    if (b.assignment != #buyerSelects) {
      return cb(#ok(errorResult("Bounty " # Nat.toText(b.id) # " is first_claim: call claim_bounty and it is yours, no bidding.")));
    };
    if (b.buyer == caller) return cb(#ok(errorResult("You cannot bid on your own bounty.")));

    let existing = bidsFor(b.id);
    let kept = Array.filter<Bid>(existing, func(x) { x.worker != caller });
    let bid : Bid = { bounty = b.id; worker = caller; note = note; at = now() };
    Map.set(bidsByBounty, nhash, b.id, Array.append(kept, [bid]));
    putBounty(withEvent(b, caller, "Bid submitted.", null));

    cb(#ok(okResult(Json.obj([
      ("message", Json.str(if (kept.size() < existing.size()) "Bid on bounty " # Nat.toText(b.id) # " replaced." else "Bid submitted on bounty " # Nat.toText(b.id) # ". Only the buyer can see it.")),
      ("bid", bidToJson(bid)),
    ]))));
  };

  func listBidsTool(args : McpTypes.JsonValue, auth : ?AuthTypes.AuthInfo, cb : ToolCb) : async () {
    let ?caller = requireAuth(auth, cb) else return;
    let ?b = resolveBounty(args, cb) else return;
    let all = bidsFor(b.id);
    let visible = if (b.buyer == caller) all else Array.filter<Bid>(all, func(x) { x.worker == caller });
    cb(#ok(okResult(Json.obj([
      ("bounty", Json.int(b.id)),
      ("count", Json.int(visible.size())),
      ("bids", Json.arr(Array.map<Bid, Json.Json>(visible, bidToJson))),
      ("note", Json.str(if (b.buyer == caller) "Every bid on your bounty." else "Your own bids. Other workers' bids are not public — a visible bid list is a race to the bottom and a view of someone's pipeline.")),
    ]))));
  };

  func selectWorkerTool(args : McpTypes.JsonValue, auth : ?AuthTypes.AuthInfo, cb : ToolCb) : async () {
    let ?caller = requireAuth(auth, cb) else return;
    let ?b = resolveBounty(args, cb) else return;
    if (not requireBuyer(b, caller, cb)) return;
    if (isSettling(b)) return cb(#ok(errorResult(settlingError(b))));
    if (b.state != #open) return cb(#ok(errorResult("Bounty " # Nat.toText(b.id) # " is " # stateText(b.state) # ", not open.")));
    if (b.assignment != #buyerSelects) return cb(#ok(errorResult("Bounty " # Nat.toText(b.id) # " is first_claim; workers take it themselves.")));

    let ?workerText = optText(args, "worker") else return cb(#ok(errorResult("Which worker? Pass 'worker' as a principal.")));
    let ?worker = parsePrincipal(workerText) else return cb(#ok(errorResult("'" # workerText # "' is not a valid principal.")));
    if (worker == caller) return cb(#ok(errorResult("You cannot assign a bounty to yourself.")));

    var hasBid = false;
    for (x in bidsFor(b.id).vals()) { if (x.worker == worker) hasBid := true };
    if (not hasBid) return cb(#ok(errorResult("That principal has not bid on bounty " # Nat.toText(b.id) # ". You can only select from the bids you have.")));

    let held = liveClaimCount(worker);
    if (held >= maxConcurrentClaims) {
      return cb(#ok(errorResult("That worker is already holding " # Nat.toText(held) # " live jobs, which is the limit. Pick another bidder or wait for them to finish one.")));
    };

    let assigned = assignTo(b, worker, caller, "Buyer selected a worker from the bids.");
    cb(#ok(okResult(bountyResponse(assigned, "Bounty " # Nat.toText(b.id) # " assigned to " # Principal.toText(worker) # ". They have " # Nat.toText(b.deliveryDays) # " days to deliver."))));
  };

  func submitWorkTool(args : McpTypes.JsonValue, auth : ?AuthTypes.AuthInfo, cb : ToolCb) : async () {
    let ?caller = requireAuth(auth, cb) else return;
    let ?b = resolveBounty(args, cb) else return;
    if (isSettling(b)) return cb(#ok(errorResult(settlingError(b))));
    if (not requireWorker(b, caller, cb)) return;
    if (b.state != #assigned) return cb(#ok(errorResult("Bounty " # Nat.toText(b.id) # " is " # stateText(b.state) # ", not awaiting delivery.")));

    let ?hash = optText(args, "hash") else return cb(#ok(errorResult("Pass the 'hash' of what you delivered — sha256 hex. It is what proves later that the thing under review is the thing you handed over.")));
    let ?pointer = optText(args, "pointer") else return cb(#ok(errorResult("Pass a 'pointer' to where the work actually lives. This canister stores the pointer, never the content.")));
    let kind = switch (optText(args, "kind")) { case (?k) k; case (null) "application/octet-stream" };

    let d : Deliverable = { hash = hash; pointer = pointer; kind = kind; note = optText(args, "note"); at = now() };
    let reviewDeadline = now() + b.reviewWindowNs;
    let submitted = withEvent(
      { b with state = #submitted; deliverable = ?d; reviewDeadline = ?reviewDeadline },
      caller,
      "Work submitted.",
      ?("hash " # hash),
    );
    putBounty(submitted);

    cb(#ok(okResult(Json.obj([
      ("message", Json.str("Delivered. The buyer has " # fmtDuration(b.reviewWindowNs) # " to approve or request changes. If they say nothing at all in that window, the escrow releases to you — silence is not a way to keep the money.")),
      ("bounty", bountyToJson(submitted, false)),
      ("review_deadline", Json.int(reviewDeadline)),
    ]))));
  };

  func withdrawClaimTool(args : McpTypes.JsonValue, auth : ?AuthTypes.AuthInfo, cb : ToolCb) : async () {
    let ?caller = requireAuth(auth, cb) else return;
    let ?b = resolveBounty(args, cb) else return;
    if (isSettling(b)) return cb(#ok(errorResult(settlingError(b))));
    if (not requireWorker(b, caller, cb)) return;
    if (b.state != #assigned) return cb(#ok(errorResult("Bounty " # Nat.toText(b.id) # " is " # stateText(b.state) # "; only an assigned, undelivered bounty can be handed back.")));

    let released = withEvent(
      { b with state = #open; worker = null; deliveryDeadline = null },
      caller,
      "Worker withdrew; bounty returned to open.",
      optText(args, "reason"),
    );
    putBounty(released);
    Map.set(bountyIdsByWorker, phash, caller, Array.filter<Nat>(idsFor(bountyIdsByWorker, caller), func(x) { x != b.id }));

    cb(#ok(okResult(bountyResponse(released, "Bounty " # Nat.toText(b.id) # " is open again. Nothing is held against you — withdrawing cleanly is better for everyone than a silent no-show."))));
  };

  func approveWorkTool(args : McpTypes.JsonValue, auth : ?AuthTypes.AuthInfo, cb : ToolCb) : async () {
    let ?caller = requireAuth(auth, cb) else return;
    let ?b = resolveBounty(args, cb) else return;
    if (not requireBuyer(b, caller, cb)) return;
    if (isSettling(b)) return cb(#ok(errorResult(settlingError(b))));
    if (b.state != #submitted) return cb(#ok(errorResult("Bounty " # Nat.toText(b.id) # " is " # stateText(b.state) # ", with nothing submitted to approve.")));

    let worker = switch (b.worker) { case (?w) w; case (null) return cb(#ok(errorResult("No worker on that bounty."))) };
    let why = switch (optText(args, "note")) { case (?n) "Buyer approved: " # n; case (null) "Buyer approved the work." };

    switch (await releaseToWorker(b.id, caller, why)) {
      case (#err(msg)) cb(#ok(errorResult(msg)));
      case (#ok(done)) {
        cb(#ok(okResult(Json.obj([
          ("message", Json.str("Approved. " # fmtMoney(b.amountMinor - marketplaceFee(b.amountMinor), b.asset) # " released to " # Principal.toText(worker) # ".")),
          ("bounty", bountyToJson(done, false)),
          ("leave_a_review", reviewHint(b, worker)),
        ]))));
      };
    };
  };

  func requestChangesTool(args : McpTypes.JsonValue, auth : ?AuthTypes.AuthInfo, cb : ToolCb) : async () {
    let ?caller = requireAuth(auth, cb) else return;
    let ?b = resolveBounty(args, cb) else return;
    if (not requireBuyer(b, caller, cb)) return;
    if (isSettling(b)) return cb(#ok(errorResult(settlingError(b))));
    if (b.state != #submitted) return cb(#ok(errorResult("Bounty " # Nat.toText(b.id) # " is " # stateText(b.state) # ", with nothing submitted to send back.")));

    let ?reason = optText(args, "reason") else return cb(#ok(errorResult("A revision request needs a 'reason' saying what does not yet meet the acceptance criteria. It is required, it is permanent, and it is the only thing that makes a revision request different from stalling.")));

    if (b.revisionsUsed >= b.revisionsAllowed) {
      return cb(#ok(errorResult("You have used all " # Nat.toText(b.revisionsAllowed) # " revisions you declared on bounty " # Nat.toText(b.id) # ". The remaining choices are approve_work, or dispute_bounty if the delivery genuinely does not meet the frozen acceptance criteria. The bound is the deal the worker accepted when they claimed it.")));
    };

    let extraDays = switch (optNat(args, "extra_days")) { case (?d) d; case (null) b.deliveryDays };
    if (extraDays == 0 or extraDays > maxDeliveryDays) {
      return cb(#ok(errorResult("'extra_days' must be between 1 and " # Nat.toText(maxDeliveryDays) # ".")));
    };
    let deadline = now() + extraDays * Int.abs(nanosPerDay);

    let back = withEvent(
      {
        b with
        state = #assigned;
        revisionsUsed = b.revisionsUsed + 1;
        deliveryDeadline = ?deadline;
        reviewDeadline = null;
      },
      caller,
      "Changes requested (revision " # Nat.toText(b.revisionsUsed + 1) # " of " # Nat.toText(b.revisionsAllowed) # ").",
      ?reason,
    );
    putBounty(back);

    cb(#ok(okResult(bountyResponse(back, "Sent back to the worker with " # Nat.toText(extraDays) # " days to revise. That is revision " # Nat.toText(b.revisionsUsed + 1) # " of " # Nat.toText(b.revisionsAllowed) # "."))));
  };

  func reclaimBountyTool(args : McpTypes.JsonValue, auth : ?AuthTypes.AuthInfo, cb : ToolCb) : async () {
    let ?caller = requireAuth(auth, cb) else return;
    let ?b = resolveBounty(args, cb) else return;
    if (not requireBuyer(b, caller, cb)) return;
    if (isSettling(b)) return cb(#ok(errorResult(settlingError(b))));
    if (b.state != #assigned) return cb(#ok(errorResult("Bounty " # Nat.toText(b.id) # " is " # stateText(b.state) # ". Reclaiming is for a worker who took the job and then missed the deadline.")));

    switch (b.deliveryDeadline) {
      case (?d) {
        if (now() < d) {
          return cb(#ok(errorResult("The worker still has " # fmtDuration(d - now()) # " to deliver on bounty " # Nat.toText(b.id) # ". Until the deadline passes, the job is theirs.")));
        };
      };
      case (null) return cb(#ok(errorResult("Bounty " # Nat.toText(b.id) # " has no delivery deadline set.")));
    };

    switch (await refundBuyer(b.id, caller, "Delivery deadline passed; buyer reclaimed the escrow.")) {
      case (#ok(done)) cb(#ok(okResult(bountyResponse(done, "Reclaimed. " # fmtMoney(b.amountMinor, b.asset) # " is back in your account."))));
      case (#err(msg)) cb(#ok(errorResult(msg)));
    };
  };

  func settleDueTool(args : McpTypes.JsonValue, auth : ?AuthTypes.AuthInfo, cb : ToolCb) : async () {
    let ?caller = requireAuth(auth, cb) else return;

    switch (optNat(args, "bounty")) {
      case (?id) {
        switch (await settleOne(id, caller)) {
          case (#ok(done)) cb(#ok(okResult(bountyResponse(done, "Settled bounty " # Nat.toText(id) # ": it is now " # stateText(done.state) # "."))));
          case (#err(msg)) cb(#ok(errorResult(msg)));
        };
      };
      case (null) {
        let settled = Buffer.Buffer<Json.Json>(4);
        var id = nextBountyId;
        while (id > 1) {
          id -= 1;
          switch (getBounty(id)) {
            case (?b) {
              if (not isSettling(b)) {
                switch (dueOutcome(b, now())) {
                  case (#notDue(_)) {};
                  case (_) {
                    switch (await settleOne(id, caller)) {
                      case (#ok(done)) settled.add(Json.obj([("bounty", Json.int(id)), ("state", Json.str(stateText(done.state)))]));
                      case (#err(msg)) settled.add(Json.obj([("bounty", Json.int(id)), ("error", Json.str(msg))]));
                    };
                  };
                };
              };
            };
            case (null) {};
          };
        };
        cb(#ok(okResult(Json.obj([
          ("count", Json.int(settled.size())),
          ("settled", Json.arr(Buffer.toArray(settled))),
          ("message", Json.str(if (settled.size() == 0) "Nothing was due. Every clock still has time on it." else Nat.toText(settled.size()) # " bounty/bounties settled.")),
        ]))));
      };
    };
  };

  func disputeBountyTool(args : McpTypes.JsonValue, auth : ?AuthTypes.AuthInfo, cb : ToolCb) : async () {
    let ?caller = requireAuth(auth, cb) else return;
    let ?b = resolveBounty(args, cb) else return;
    if (isSettling(b)) return cb(#ok(errorResult(settlingError(b))));
    let ?reason = optText(args, "reason") else return cb(#ok(errorResult("A dispute needs a 'reason'. It is permanent and it is all anyone will have to go on later.")));

    let isParty = b.buyer == caller or (switch (b.worker) { case (?w) w == caller; case (null) false });
    if (not isParty) return cb(#ok(errorResult("Only the buyer or the assigned worker can dispute bounty " # Nat.toText(b.id) # ".")));
    if (b.state != #assigned and b.state != #submitted) {
      return cb(#ok(errorResult("Bounty " # Nat.toText(b.id) # " is " # stateText(b.state) # " and there is nothing to dispute.")));
    };

    let disputed = withEvent(
      { b with state = #disputed; disputeReason = ?reason; deliveryDeadline = null; reviewDeadline = null },
      caller,
      "Disputed; all clocks stopped and funds parked.",
      ?reason,
    );
    putBounty(disputed);

    cb(#ok(okResult(Json.obj([
      ("message", Json.str("Bounty " # Nat.toText(b.id) # " is disputed. Every clock is stopped and " # fmtMoney(b.escrowedMinor, b.asset) # " stays in its subaccount. Read this plainly: v1 has no way out of this state. There is no arbiter, no vote, and no timer that will resolve it — the money sits there until an arbitration path ships. That is the honest limit of this version, and it is why disputing is a last resort rather than a negotiating move.")),
      ("bounty", bountyToJson(disputed, true)),
    ]))));
  };

  func myWorkTool(args : McpTypes.JsonValue, auth : ?AuthTypes.AuthInfo, cb : ToolCb) : async () {
    let ?caller = requireAuth(auth, cb) else return;
    let role = switch (optText(args, "role")) { case (?r) lower(r); case (null) "both" };
    let includeSettled = switch (optText(args, "include_settled")) { case (?t) lower(t) == "true"; case (null) false };
    let nowNs = now();

    func live(b : Bounty) : Bool {
      if (includeSettled) return true;
      b.state != #released and b.state != #refunded;
    };

    func waitingOnBuyer(b : Bounty) : ?Text {
      switch (b.state) {
        case (#draft) ?("unfunded draft — call fund_bounty or it will never be seen");
        case (#submitted) ?("work submitted; you have " # remainingText(b.reviewDeadline, nowNs) # " to approve or request changes, after which it releases to the worker");
        case (#assigned) {
          switch (b.deliveryDeadline) {
            case (?d) { if (nowNs >= d) ?"delivery deadline passed — reclaim_bounty to get your money back" else null };
            case (null) null;
          };
        };
        case (#open) { if (b.assignment == #buyerSelects and bidsFor(b.id).size() > 0) ?(Nat.toText(bidsFor(b.id).size()) # " bid(s) waiting on your pick") else null };
        case (#disputed) ?"disputed and parked; v1 has no resolution path";
        case (_) null;
      };
    };

    func waitingOnWorker(b : Bounty) : ?Text {
      switch (b.state) {
        case (#assigned) ?("deliver within " # remainingText(b.deliveryDeadline, nowNs) # " or the buyer can reclaim");
        case (#submitted) ?("submitted; buyer has " # remainingText(b.reviewDeadline, nowNs) # " before it releases to you");
        case (#disputed) ?"disputed and parked; v1 has no resolution path";
        case (_) null;
      };
    };

    let buying = Buffer.Buffer<Json.Json>(8);
    let working = Buffer.Buffer<Json.Json>(8);
    var actionsNeeded : Nat = 0;

    if (role == "both" or role == "buyer") {
      for (b in bountiesOf(bountyIdsByBuyer, caller).vals()) {
        if (live(b)) {
          let action = waitingOnBuyer(b);
          if (action != null) actionsNeeded += 1;
          buying.add(Json.obj([
            ("bounty", bountyToJson(b, false)),
            ("waiting_on_you", optJsonText(action)),
          ]));
        };
      };
    };

    if (role == "both" or role == "worker") {
      for (b in bountiesOf(bountyIdsByWorker, caller).vals()) {
        let mine = switch (b.worker) { case (?w) w == caller; case (null) false };
        if (mine and live(b)) {
          let action = waitingOnWorker(b);
          if (action != null) actionsNeeded += 1;
          working.add(Json.obj([
            ("bounty", bountyToJson(b, false)),
            ("waiting_on_you", optJsonText(action)),
          ]));
        };
      };
    };

    cb(#ok(okResult(Json.obj([
      ("as_buyer", Json.arr(Buffer.toArray(buying))),
      ("as_worker", Json.arr(Buffer.toArray(working))),
      ("actions_needed", Json.int(actionsNeeded)),
      ("message", Json.str(
        if (actionsNeeded == 0) "Nothing is waiting on you."
        else Nat.toText(actionsNeeded) # " item(s) need something from you. Each one says what, under waiting_on_you."
      )),
    ]))));
  };

  // --- SERVER ---

  transient let mcpConfig : McpTypes.McpConfig = {
    self = Principal.fromActor(self);
    allowanceUrl = null;
    serverInfo = {
      name = "escrow-work-marketplace";
      title = "Escrow Work Marketplace";
      version = "0.1.0";
    };
    resources = [];
    resourceReader = func(uri) { Map.get(appContext.resourceContents, thash, uri) };
    tools = tools;
    toolImplementations = [
      ("create_bounty", createBountyTool),
      ("update_bounty", updateBountyTool),
      ("fund_bounty", fundBountyTool),
      ("cancel_bounty", cancelBountyTool),
      ("search_bounties", searchBountiesTool),
      ("get_bounty", getBountyTool),
      ("get_escrow_proof", getEscrowProofTool),
      ("claim_bounty", claimBountyTool),
      ("submit_bid", submitBidTool),
      ("list_bids", listBidsTool),
      ("select_worker", selectWorkerTool),
      ("submit_work", submitWorkTool),
      ("withdraw_claim", withdrawClaimTool),
      ("approve_work", approveWorkTool),
      ("request_changes", requestChangesTool),
      ("reclaim_bounty", reclaimBountyTool),
      ("settle_due", settleDueTool),
      ("dispute_bounty", disputeBountyTool),
      ("my_work", myWorkTool),
    ];
    beacon = ?beaconContext;
  };

  transient let mcpServer = Mcp.createServer(mcpConfig);

  private func _create_http_context() : HttpHandler.Context {
    return {
      self = Principal.fromActor(self);
      active_streams = appContext.activeStreams;
      mcp_server = mcpServer;
      streaming_callback = http_request_streaming_callback;
      auth = ?authContext;
      http_asset_cache = ?http_assets.cache;
      mcp_path = ?"/mcp";
    };
  };

  public query func http_request(req : SrvTypes.HttpRequest) : async SrvTypes.HttpResponse {
    let ctx : HttpHandler.Context = _create_http_context();
    switch (HttpHandler.http_request(ctx, req)) {
      case (?mcpResponse) { mcpResponse };
      case (null) {
        if (req.url == "/") {
          {
            status_code = 204;
            headers = [];
            body = Blob.fromArray([]);
            upgrade = ?true;
            streaming_strategy = null;
          };
        } else {
          {
            status_code = 404;
            headers = [];
            body = Blob.fromArray([]);
            upgrade = null;
            streaming_strategy = null;
          };
        };
      };
    };
  };

  public shared func http_request_update(req : SrvTypes.HttpRequest) : async SrvTypes.HttpResponse {
    let ctx : HttpHandler.Context = _create_http_context();
    switch (await HttpHandler.http_request_update(ctx, req)) {
      case (?res) { res };
      case (null) {
        if (req.url == "/") {
          {
            status_code = 200;
            headers = [("Content-Type", "text/html")];
            body = Text.encodeUtf8("<h1>Escrow Work Marketplace MCP Server</h1><p>Post a job, escrow the bounty on-chain, and let an agent claim it. Funds sit in a subaccount derived from the bounty id that either party can check against the ledger directly; the acceptance criteria freeze the moment the money lands; and every clock resolves, so an unanswered submission pays the worker and a missed deadline refunds the buyer. The canister never sees the deliverable and never judges it. MCP endpoint at <code>/mcp</code>. Authenticate with an <code>x-api-key</code> header.</p>");
            upgrade = null;
            streaming_strategy = null;
          };
        } else {
          {
            status_code = 404;
            headers = [];
            body = Blob.fromArray([]);
            upgrade = null;
            streaming_strategy = null;
          };
        };
      };
    };
  };

  public query func http_request_streaming_callback(token : HttpTypes.StreamingToken) : async ?HttpTypes.StreamingCallbackResponse {
    let ctx : HttpHandler.Context = _create_http_context();
    return HttpHandler.http_request_streaming_callback(ctx, token);
  };

  system func preupgrade() {
    stable_http_assets := HttpAssets.preupgrade(http_assets);
  };

  system func postupgrade() {
    HttpAssets.postupgrade(http_assets);
  };

  /// Mint a stable API key bound to the caller's principal.
  /// The raw key is returned once and never stored in plaintext.
  public shared (msg) func create_my_api_key(name : Text, scopes : [Text]) : async Text {
    return await ApiKey.create_my_api_key(authContext, msg.caller, name, scopes);
  };

  /// Add a ledger to the escrow allowlist with its own per-bounty cap.
  /// Deployer only, and deliberately not an MCP tool: the allowlist is what
  /// stops a bounty pointing at a hostile ledger, so it is not something a
  /// caller with an API key gets to edit. Its first use is local testing
  /// against a throwaway ICRC ledger.
  public shared (msg) func admin_allow_asset(ledger : Text, symbol : Text, decimals : Nat8, capMinor : Nat) : async Text {
    if (msg.caller != deployer) throw Error.reject("Only the deployer can change the asset allowlist.");
    Map.set(allowedAssets, thash, ledger, { symbol = symbol; decimals = decimals; capMinor = capMinor });
    "Allowlisted " # symbol # " (" # ledger # ") with a per-bounty cap of " # Nat.toText(capMinor) # " minor units.";
  };

  /// The allowlist as it stands, for anyone checking what this canister will hold.
  public query func allowed_assets() : async [(Text, AllowedAsset)] {
    Map.toArray(allowedAssets);
  };
};
