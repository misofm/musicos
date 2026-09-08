# Security Audit — `musicos` (protocol)

**Revision:** `4fed48b2b5632122fb677d742881259c65b1bc78` (git HEAD) ·
**Date:** 2026-08-23 · **Toolchain:** sui 1.77.2-51d177ad7d65

**Pinned dependencies** (`Move.toml`): `bps` `4ca1972a` · `miso_share`
`4999b7d6` (audited at exactly this rev; see `share/AUDIT.md`). Re-pinned from
`047d74d5` on 2026-08-23 per I2 — resolved.

Audit of the root package: `Composition`, `Recording`, `Release`, `Track`,
their admin capabilities, and the extension authorization contract that all
`musicos-extensions/*` packages build on. Verdict: **safe to publish — no
Critical/High/Medium findings.**

## What it does

- `composition::new<CompositionShare>` (`composition.move:134`) creates a
  composition with an immutable title and royalty rate, initializes its
  fixed-supply share token via `share::initialize`, and returns the object, a
  derived-address `CompositionAdminCap`, and the full 10¹³-unit supply.
- `recording::new<RecordingShare, CompositionShare>` (`recording.move:192`)
  mints a recording under a composition, initializes the recording's share
  token, and settles the composition's royalty rate as **cap-table ownership**:
  `rate.apply(10¹³)` shares are split off and `send_funds`ed to the
  composition's object address (`recording.move:238-242`); the remainder
  returns to the creator.
- `track::new` (`track.move:121`) is the recording admin's signed consent to
  inclusion in one specific future release (identified by digest-derived id)
  at one specific split.
- `release::new` (`release.move:221`) is permissionless assembly: it validates
  the tracklist (1–255 tracks, splits sum to exactly 10,000 bps), claims the
  release's derived id from the canonical singleton `ReleaseRegistry`
  (`init`, `release.move:205`), and returns object + `ReleaseAdminCap`.
  `publish` (`release.move:279`) verifies every track's target id against the
  claimed release id (`track::assign`, `track.move:170`).
- All four modules share one lifecycle: `key`-only, no `drop`, the only
  by-value consumer is `publish`, which shares the object. Create-and-publish
  is therefore atomic — no `Initialized` object can escape its transaction.
- Extension surface: `uid()` is public read; `uid_mut(cap)` is the one
  authority-bearing accessor on each object type.

Threat model: (a) a third party attaching/modifying/removing extension data on
someone else's object; (b) cap forgery, duplication, or cross-object
authorization; (c) consent bypass — a recording included in a release its
admin never agreed to, or at a different split; (d) value loss in the
composition-cut settlement; (e) griefing of the derived-address namespaces.

## Extension authorization model — the load-bearing check

**Can anyone touch someone else's object? No.** Every path to `&mut UID` is
cap-gated:

- `Release.uid_mut` / `publish` run `authorize` — cap carries `release_id`,
  compared by object ID (`release.move:303-305, 337-340`). `Party`-style
  ID-checked caps cannot cross objects.
- `Recording.uid_mut`/`publish` and `Composition.uid_mut`/`publish` check only
  the cap's phantom type (`recording.move:260-263, 306-311`;
  `composition.move:172-176, 217-222`) — the cap carries **no object ID**.
  This is sound only because share-type ↔ object uniqueness holds: a
  `Recording<RS, CS>` can be created at most once per `RS`, because
  `recording::new` consumes the unique `TreasuryCap<RS>` through
  `share::initialize` (`recording.move:221`), and `miso_share` proves one
  currency/one cap per share type (`share/AUDIT.md`, cap-uniqueness proof).
  One share type ⟹ one recording ⟹ one cap. Same for compositions. **This is
  the single most load-bearing imported invariant in the package** — see I2.

**Can an extension escalate past its own slice once handed `&mut UID`?**
Largely no, by Move construction privacy: `df::add`/`remove`/`borrow` require
a key *value*, and struct construction is module-private, so extension A
cannot construct extension B's key type unless B exports a constructor. The
residual powers of `&mut UID` are exactly (1) dynamic fields under keys the
caller can construct and (2) `derived_object::claim` on the object's
derivation namespace — see I1. Both are reachable only by whoever the cap
holder chooses to run, which is the documented, permanent trust assumption
(stated in every module header, e.g. `recording.move:40-46`).

## Findings

- **I1 (Informational, by design): `uid_mut` is permanent root, including the
  derived-address namespace.** Works in any lifecycle state, never expires,
  and covers `derived_object::claim` — so any extension the cap holder
  authorizes could squat derived addresses under the object's UID (e.g. claim
  the `(recording, Share, Currency)` royalty-pool key with a foreign object
  type, permanently blocking canonical pool creation and stranding funds
  addressed to it). Not cross-user: reaching `uid_mut` requires the object's
  own admin cap, whose holder is already documented as trusted root over all
  extension data forever (`recording.move:40-46`, `release.move:68-74`,
  `composition.move:31-37`). Integrators should treat cap-authorized code as
  fully trusted — which the vault-plugin architecture does (witness-gated,
  hot-potato cap lease; see `misofm/vault-plugins/*/AUDIT.md`).
  **Disposition (2026-08-24):** accepted-by-design — the cap holder is the
  documented permanent trusted root over the object and its derived-address
  namespace, and the vault-plugin architecture already treats cap-authorized
  code as fully trusted.
- **I2 (Informational, RESOLVED 2026-08-23): type-scoped caps inherit
  `miso_share`'s guarantees at a stale pin.** `Move.toml` previously pinned
  `miso_share` `047d74d5`, which predates the audited hardening rev `d67ff8c`
  (the `ETreasuryCapMismatch` cap binding). Per the share audit the hardening
  is defense-in-depth — cap uniqueness already makes the path unreachable — so
  the pin was sound, but a legacy-migrated share currency carrying
  `RegulatedState::Unknown` (concealing a `DenyCapV2`) would pass `initialize`
  at that rev. **Resolved 2026-08-23: re-pinned to `miso_share`
  `d67ff8cd377db2809fc97455e82e87ff1794073e`** (the exact audited hardening
  rev); `sui move build && sui move test` green (51/51) at the new pin. Same
  advisory in the misofm plugin audits is resolved by re-pinning `musicos` to the
  protocol rev carrying this change.
- **I3 (Informational): `release::new` is permissionless — consent is
  cryptographic, not access-controlled.** Verified non-abusable: the digest
  (`blake2b256` over BCS of recording ids, split values, nonce —
  `release.move:355-366`) commits to the exact ordered tracklist; a track can
  only be minted by the recording admin cap holder naming the derived target
  id (`track::new`, `track.move:121-133`); `publish` aborts unless every
  track's target matches the claimed id (`release.move:369-371`,
  `track.move:170-178`). Front-running the derived address requires the
  tracks themselves (unforgeable); deviating from the consented configuration
  changes the digest and aborts at publish; a mismatched assembly simply can
  never exist (key-only `Release`, `publish` its sole consumer).
  **Disposition (2026-08-24):** accepted-by-design — consent is cryptographic
  and verified non-abusable: the digest binds the exact ordered tracklist,
  tracks are cap-minted and unforgeable, and publish aborts on any deviation.
- **I4 (Informational): consent deliberately excludes presentation.** The
  digest binds `(recording, split)` pairs + nonce only; title, artwork,
  credits, and grouping are chosen by the release creator outside the
  commitment (`release.move:37-47`, `track.move:95-103`). Documented on both
  sides; flagged so signers know exactly what they consented to.
  **Disposition (2026-08-24):** accepted-by-design — presentation is
  deliberately outside the commitment and documented on both sides, so
  signers know exactly what they consented to.

No finding for: split arithmetic (u16 bps values ≤ 10,000 each, ≤ 255 tracks,
u64 fold — max 2.55 M, no overflow; sum-100% enforced at `release.move:233`),
the composition cut (`bps::apply` = widening `mul_div`, floor; `cut +
remainder == supply` exactly since `split` is total; 0% rate skips the split
by design, `recording.move:238-242`; 100% rate is a legitimate caller choice),
or event sufficiency.

## Edge cases (verified by reading + tests)

- **Double-publish** aborts `ENotInitializedState` on all three object types
  (match on state; `publish` consumes by value, so a second call is
  impossible anyway).
- **Duplicate recording in a tracklist** is permitted (splits still sum to
  100%); consented via the digest; harmless.
- **Zero-bps track** is permitted; routes nothing; consented.
- **Composition cut destination**: `send_funds` to the composition's *object
  address* accumulator (`recording.move:241`); withdraw-able only under the
  composition's `&mut UID` (`hikida::redeem_balance` /
  `withdraw_funds_from_object`), i.e. by the composition admin or their
  authorized plugins. Not stranded while the admin cap exists; cap loss is
  user error, not protocol trap.
- **Recording against an unpublished composition** is possible only
  intra-transaction by the composition's own creator (`recording.move:180-185`)
  — third parties only ever see `Published` shared compositions.
- **Registry singleton**: `ReleaseRegistry` has no production constructor, no
  delete path, no mutable UID accessor (`release.move:134-139, 205-214`) — the
  canonical derivation namespace cannot be replaced, deleted, or claimed from
  except via `new`. If it were lost, every consented track would strand —
  hence singleton-at-init.
- **Cap discoverability**: admin caps are derived objects of their parent
  (`claim` with a module-private-payload key), so exactly one cap per object;
  caps are `key + store` and freely transferable — delegation is intended.

## Verification

- **51/51 unit tests** (`sui move test`, sui 1.77.2): production-constructor
  tests run the real `composition::new`/`recording::new` flows with a genuine
  fixed-supply currency; digest matrix; track-consent negatives; publish-state
  negatives; post-publish immutability.
- Cross-read of consumers: `misofm/vault-plugins/{composition_routed_stake,
  composition_royalty_pool, recording_royalty_pool}` (audits + sources) and
  `musicos-extensions/release_credits`, `partyos-extensions/party_profile` —
  all consume the cap-gated `uid_mut` contract exactly as designed; none can
  forge `Track` consent or another extension's keys.

## Load-bearing assumptions

- `miso_share` cap/currency uniqueness per share type (audited at `d67ff8c`;
  pinned here at exactly `4999b7d6` — I2 resolved 2026-08-23). **Everything
  type-scoped rests on this.**
- Framework: `derived_object::claim` uniqueness; `transfer::share_object`
  finality; `send_funds`/`withdraw_funds_from_object` UID-gated accumulator
  semantics; BCS determinism for the digest. Framework rev per sibling
  lockfiles: `2a0becb2` (move-stdlib/sui-framework).
- `bps` (pinned `4ca1972a`, audited clean): `new` bounds to 10,000; `apply`
  floors via widening `mul_div`.
