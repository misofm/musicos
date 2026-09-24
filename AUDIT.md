# Security Audit — `musicos` (protocol)

**Revision:** `4fed48b2b5632122fb677d742881259c65b1bc78` (git HEAD) ·
**Date:** 2026-08-23 · **Toolchain:** sui 1.77.2-51d177ad7d65

**Pinned dependencies** (`Move.toml`): `bps` `4ca1972a` · `share`
`4999b7d6` (audited at exactly this rev; see `share/AUDIT.md`). Re-pinned from
`047d74d5` on 2026-08-23 per I2 — resolved.

> **Current pins (2026-09-15):** `share` is now `780bf701` (share#2:
> `assert_valid_share_type` replaced by `is_share`; `initialize` checks and
> abort codes unchanged; independent regression review in share#2). Reviewed in
> the pre-launch audit, misofm/audit#1. This document records the 2026-08-23
> audit at the revisions above.

> **Design change (2026-09-23, unreleased):** `Recording` is now
> `Recording<RS>` — the `CompositionShare` phantom is dropped from the object
> and from `RecordingPublishedEvent`, whose `composition_id` payload field is
> the composition link (`recording::new` still takes `&Composition<CS>` and
> sets it; callers pairing a recording with a composition compare
> `composition_id()` with the composition's object ID). The
> uniqueness claim under "Extension authorization model" below, "a
> `Recording<RS, CS>` can be created at most once per `RS`", now reads
> `Recording<RS>`; its argument is unchanged, since it rests on
> `TreasuryCap<RS>` consumption alone. This supersedes the prior dispositions
> to keep the `CompositionShare` event dimension — recorded outside this
> repository, in the broader workspace's
> `audits/v1-event-final-20260916/REPORT.md:9` and
> `audits/engineering-skills-20260916/REVIEW.md:369` — with `composition_id`
> in the payload as the replacement. Otherwise this document still records
> the 2026-08-23 audit, and its line references are to that revision.

> **Design change (2026-09-23, unreleased, continued):** three further
> changes in the same unreleased source.
> (1) *Event slimming.* `CompositionPublishedEvent<CS>` now carries exactly
> `composition_id`, `royalty_rate_bps`, `published_at_ms`;
> `RecordingPublishedEvent<RS>` exactly `recording_id`, `composition_id`,
> `composition_royalty_rate_bps`, `published_at_ms`. The rule: a field stays
> only if an indexer reading musicos events alone would otherwise need an
> object lookup for it and it matters to the business. Dropped as derivable
> or constant: `clock_id` (always `0x6`), `shared_after` (always true),
> `created_by` (the envelope sender), `*_admin_cap_id`/`created_admin_cap_id`
> (derived addresses of the object id under `*AdminCapKey`),
> `share_currency_id`/`consumed_treasury_cap_id` (duplicated by
> `share::ShareInitializedEvent<S>` in the same transaction),
> `share_supply_before/after`, `shares_before_grant`,
> `composition_shares_granted`, `shares_returned`, `share_decimals`,
> `share_supply_fixed_after`, `composition_funds_sent` (all fixed by
> `share::initialize` — zero before, 100M·10⁶ after, 6 decimals, supply fixed —
> or arithmetic on the rate and that supply), and `title_bytes` (see 3).
> `ReleasePublishedEvent` is unchanged.
> (2) *`Initialized` slimming.* The `Initialized` variants existed only to
> carry creation facts to `publish` for those fields. `CompositionState::
> Initialized` is now fieldless (`publish` reads the embedded
> `royalty_rate`); `RecordingState::Initialized { composition_royalty_rate_bps
> }` carries only the rate `new` applied, since `publish` does not receive the
> composition. The economics of `recording::new` are unchanged
> (`share::initialize`, `rate.apply(supply)` split, `send_funds` to the
> composition address only when non-zero, remainder returned); `publish`
> still takes the cap (authorization by type) and the clock.
> (3) *Title removal.* `Composition` no longer has a `title` field;
> `composition::new` takes `(royalty_rate_bps, share_currency,
> share_treasury_cap, ctx)`; `title()`, `EEmptyString`,
> `EMaxTitleLengthExceeded` and `MAX_TITLE_LENGTH` are gone from
> `composition`. Titles have more than one correct rendering and are never
> read by the economics, so by the package's own rule they are presentation
> and belong in a metadata extension (none existed at this date; see
> Verification's cross-read). `release::title` is unchanged.
> This supersedes the prior rich-event dispositions recorded in the broader
> workspace (`audits/v1-event-final-20260916/REPORT.md` and
> `audits/engineering-skills-20260916/REVIEW.md`), and the "immutable title"
> wording under "What it does" below, which describes the audited revision.
> Finding I4's "title" refers to the release title and still holds. Test
> count at this change: 50 (title-validation tests removed; the composition
> cut remains asserted through the creator's returned balance for 0%, 15% and
> 100% rates).

> **Design change (2026-09-23, unreleased, continued): release title and
> release events.** The same three rules now reach `release`.
> (1) *Title removal.* `Release` no longer has a `title` field;
> `release::new` takes `(&mut ReleaseRegistry, tracks, nonce)`; `title()`,
> `EEmptyString`, `EMaxTitleLengthExceeded` and `MAX_TITLE_LENGTH` are gone
> from `release`. Beyond the presentation argument in (3) above, the release
> title was the one embedded field outside the release digest: no track
> signer ever consented to it, it was chosen unilaterally by the release
> creator, and what buyers rely on is the fixed tracklist, splits and id.
> Core now embeds nothing outside the digest; release titles belong in the
> `release_metadata` extension, as composition titles belong in
> `composition_metadata`. This supersedes "`release::title` is unchanged"
> in the note above, the "one embedded name" wording it left in
> `release.move`, and the reading of Finding I4 — whose "title" is now
> extension metadata like the artwork, credits and grouping it lists; I4
> itself (consent excludes presentation) still holds and is now enforced by
> the type, since core has no presentation field left to choose after consent.
> (2) *Event slimming.* `ReleasePublishedEvent` now carries exactly
> `release_id`, `published_at_ms`, `nonce`, `track_allocations` (unchanged
> 66-byte `TrackAllocation` entries in tracklist order, duplicates and zero
> splits retained). Dropped as derivable or constant under the same rule:
> `clock_id` (always `0x6`), `shared_after` (always true),
> `release_admin_cap_id` (derived address of `release_id` under
> `ReleaseAdminCapKey`), `title_bytes` (see 1), `assigned_track_count`
> (`track_allocations.length()`), `registry_id` (one canonical registry per
> deployment, announced by `ReleaseRegistryCreatedEvent` in the publish
> transaction), and `release_digest` (`blake2b256(bcs(recording_ids) ||
> bcs(splits as u64) || bcs(nonce))` over the allocation and nonce carried in
> the same event, of which `release_id` is the derived address under
> `ReleaseKey`). `ReleaseRegistryCreatedEvent` now carries exactly
> `registry_id`; `created_by` (envelope sender) and `shared_after` (always
> true) are dropped. The rich per-track allocation stays: the tracklist's
> recording ids, composition ids and splits are the release's economics and
> membership and are reachable from no other event.
> (3) *`Initialized` slimming.* `ReleaseState::Initialized { nonce }` carries
> only the creator's nonce, which `publish` emits and cannot otherwise reach
> (it is a digest input, not an embedded field); `registry_id` and
> `release_digest` existed there only to feed the dropped event fields. The
> digest, id derivation, split validation, track bounds and `track::assign`
> verification in `new`/`publish` are unchanged. Test count at this change:
> 48 (`new_title_too_long_aborts` and `new_empty_title_aborts` removed;
> event assertions converted to the slimmed payloads, with the e2e flow now
> re-deriving `release_id` from the event's allocation and nonce alone).

> **Design change (2026-09-24, unreleased): no track limit.** `release::new`
> no longer caps the tracklist at 255 tracks; `MAX_TRACKS` and
> `EMaxTracksExceeded` (31) are gone. The limit was arbitrary: no index or
> count in core or its extensions is narrower than `u64`. The effective
> ceiling is now Sui's own object-size, event-size and gas limits. Because an
> `Initialized` release cannot outlive its creating transaction, an oversized
> release aborts that transaction as a whole; no track is consumed and no
> consent is stranded beyond the existing "release that never publishes"
> class. The "1–255 tracks" and "≤ 255 tracks" statements below describe the
> audited revision; the split-arithmetic finding still holds, since splits
> must sum to exactly 10,000 bps regardless of track count. Test count at
> this change: 47 (`new_exceeds_max_tracks_aborts` removed; the 255-track
> stress tests remain as large-tracklist coverage).

> **Design change (2026-09-24, unreleased, continued): per-track events and
> non-copyable states.** (1) `TrackAllocation` and
> `ReleasePublishedEvent.track_allocations` are gone. `publish` now emits one
> `ReleaseTrackAssignedEvent { release_id, position, recording_id, split_bps }`
> per track, in tracklist order, as `track::assign` verifies it, then
> `ReleasePublishedEvent { release_id, published_at_ms, nonce }`. The track's
> `composition_id` is no longer emitted: it is the `composition_id` of the
> recording's own `RecordingPublishedEvent`, reachable by joining on
> `recording_id` (the e2e test performs that join). The digest remains
> reconstructible from the track events in position order and the nonce.
> Sui's per-transaction event-count limit now bounds tracks per release,
> alongside the object-size and gas limits noted above. This supersedes the
> "rich per-track allocation stays" wording in the release-events note above.
> (2) `CompositionState`, `RecordingState`, `ReleaseState` and `TrackState`
> no longer have `copy`; state is matched by reference and the few scalar
> payloads read from it (royalty rate, nonce, target release id) are copied
> explicitly. No behavior changes; `drop` and `store` remain, since the state
> is an object field that is overwritten on transition. Test count unchanged
> at 47.

> **Design change (2026-09-24, unreleased, continued): `Track` drops
> `composition_id`.** `Track` is now `{ state, recording_id, split_bps }`;
> `track::composition_id()` is gone and `track::new` reads only the
> recording's id. Revenue already routed to `recording_id` alone, and every
> known consumer of the field (the release revenue distributor and
> `release_cover_art`) only echoed it into events. The recording's immutable
> `composition_id`, set from a real `&Composition` in `recording::new`, is now
> the single source of truth for a track's composition. Lost: answering "is
> composition X on this release?" on-chain from a `&Release` alone, without
> the recordings; no consumer does this. Test count unchanged at 47.

> **Design change (2026-09-24, unreleased, continued): final minimalism
> pass.** (1) `RecordingPublishedEvent<RS>` now carries exactly
> `recording_id`, `composition_id`, `published_at_ms`;
> `composition_royalty_rate_bps` is dropped as derivable by joining
> `composition_id` to the composition's `CompositionPublishedEvent`, whose
> rate is immutable and is always emitted in or before the recording's
> transaction. `RecordingState::Initialized` is therefore fieldless, like
> `CompositionState::Initialized`; the economics of `recording::new` are
> unchanged. (2) `release::release_registry_id` (with the
> `ReleaseRegistry.id` alias) is removed as a wrapper of `object::id`, and
> `release::release_admin_cap_release_id` (with the `ReleaseAdminCap.release_id`
> alias) as an accessor with no consumer; `authorize` remains the way to
> check a cap against a release. (3) `release::new` inlines its digest-input
> helper. No authorization, digest or settlement behavior changes. Test
> count at this change: 42 (five tests subsumed by others removed).

> **Design change (2026-09-24, unreleased, continued): no publish
> timestamp.** `Published` is now a unit variant of `CompositionState`,
> `RecordingState` and `ReleaseState` (BCS: the single tag byte `0x01`);
> `published_at_ms` is gone from `CompositionPublishedEvent`,
> `RecordingPublishedEvent` and `ReleasePublishedEvent`; and the three
> `publish` functions no longer take `&Clock`. Create-and-publish is atomic
> and every transaction in a consensus commit reads the same `Clock` value,
> which is the timestamp of the event's transaction envelope, so the stored
> and emitted value duplicated the envelope and no on-chain code read it.
> The events now carry exactly: `CompositionPublishedEvent<CS>`
> `composition_id`, `royalty_rate_bps`; `RecordingPublishedEvent<RS>`
> `recording_id`, `composition_id`; `ReleasePublishedEvent` `release_id`,
> `nonce`. This supersedes "`publish` still takes the cap ... and the clock"
> above. No authorization, digest or settlement behavior changes. Test count
> unchanged at 42 (the state-layout test now asserts the bare variant tag).

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
  `share::initialize` (`recording.move:221`), and `share` proves one
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
  `share`'s guarantees at a stale pin.** `Move.toml` previously pinned
  `share` `047d74d5`, which predates the audited hardening rev `d67ff8c`
  (the `ETreasuryCapMismatch` cap binding). Per the share audit the hardening
  is defense-in-depth — cap uniqueness already makes the path unreachable — so
  the pin was sound, but a legacy-migrated share currency carrying
  `RegulatedState::Unknown` (concealing a `DenyCapV2`) would pass `initialize`
  at that rev. **Resolved 2026-08-23: re-pinned to `share`
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

- `share` cap/currency uniqueness per share type (audited at `d67ff8c`;
  pinned here at exactly `4999b7d6` — I2 resolved 2026-08-23). **Everything
  type-scoped rests on this.**
- Framework: `derived_object::claim` uniqueness; `transfer::share_object`
  finality; `send_funds`/`withdraw_funds_from_object` UID-gated accumulator
  semantics; BCS determinism for the digest. Framework rev per sibling
  lockfiles: `2a0becb2` (move-stdlib/sui-framework).
- `bps` (pinned `4ca1972a`, audited clean): `new` bounds to 10,000; `apply`
  floors via widening `mul_div`.
