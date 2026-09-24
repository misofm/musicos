# musicos

[![License: Apache 2.0](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)
[![Move](https://img.shields.io/badge/Move-2024-black.svg)](https://docs.sui.io/concepts/sui-move-concepts)

> A permissionless music protocol on [Sui](https://sui.io), written in Move.

musicos models the core objects of recorded music — **compositions**, **recordings**, and **releases** — as on-chain objects whose ownership is expressed through per-object share tokens. Anyone can register a work; no gatekeeper, allowlist, or central registry of artists.

This repo is the core protocol package. First-party **extensions** (credits, cover art, genre, royalty pools, revenue distribution, attribution) live in [`musicos-extensions`](https://github.com/misofm/musicos-extensions) — standalone packages that attach to core objects via cap-gated `&mut UID` access, without modifying or re-publishing the core. The TypeScript SDK (`@misofm/protocol`) lives in [`misofm/sdks`](https://github.com/misofm/sdks), generated from this package's Move source.

## Data model

The protocol separates the *work* layer from the *distribution* layer:

| Object | Layer | What it is |
|--------|-------|------------|
| **`Composition`** | work | The underlying written work. Core carries only the royalty rate it earns from recordings; its title is extension metadata. |
| **`Recording`** | work | A master recording of a composition. It carries no name of its own — display titles (its own and its composition's) and version naming ("Radio Edit", "(Live)") are extension metadata. |
| **`Release`** | distribution | A distributable package (Album / EP / Single) assembled from recordings — a flat, ordered tracklist with per-track revenue splits. It carries no title: release titles are extension metadata (`release_metadata`). |
| **`Track`** | distribution | A recording placed on a release, created from the recording admin capability — its creation *is* the consent to a specific future release. |

Credits, artwork, language, advisory flags, master audio, and display grouping attach as extensions or dynamic fields rather than living in the core.

### Consent

A release's id is **derived from a digest of its exact economics**: the ordered
list of `(recording, split)` pairs plus a creator nonce, claimed as a derived
child of the canonical `ReleaseRegistry` shared by `musicos::release` package
initialization. A `Track` targets that derived id at creation, so creating one
consents to the release's precise membership, splits, and running order — and
nothing else. Core embeds nothing outside the digest, so nothing is chosen
after consent; everything else about a release (title, artwork, credits,
grouping) is presentation in the extension layer, chosen by the release
creator and publicly attributable rather than cryptographically committed.

`ReleaseRegistry` has one production instance per package publication. It is
shared, has no constructor, delete path, or mutable-UID accessor, and its
private UID is the only derivation parent accepted by `release::new`. Release
creation remains permissionless because the supplied `Track` values carry the
rightsholders' consent.

### Lifecycle

Core objects are **build-then-freeze**: created in an `Initialized` state, configured via their admin capability, then `publish()`ed — after which they are immutable. Because the objects are key-only and cannot escape the creating transaction, only the final `Published` transition emits a lifecycle event.

Published events are as small as possible while still communicating the business action: each carries what an indexer needs to understand what happened without object lookups, and object identities are typed `ID`. `CompositionPublishedEvent` carries the composition id and its royalty rate; `RecordingPublishedEvent` carries the recording id and its composition id; the royalty rate applied at creation is the immutable rate of that composition's `CompositionPublishedEvent`. Publishing a release emits one `ReleaseTrackAssignedEvent` per track, in tracklist order, carrying the release id, the track's zero-based position, its recording id and its `u16` split BPS; duplicate recordings and zero splits keep their positions, so indexers need no object reads to reconstruct the allocation. A track's composition is not repeated: it is the `composition_id` of that recording's `RecordingPublishedEvent`. `ReleasePublishedEvent` follows, carrying the release id and the creator's nonce. `ReleaseRegistryCreatedEvent`, emitted once at package publication, carries only the registry id. Everything else is derivable — the share type from the event's type argument, the sender and publish time from the transaction envelope (so `publish` takes no `Clock`), the share currency and treasury cap ids from `share::ShareInitializedEvent` in the same transaction, admin cap ids as derived addresses of the object id, share amounts from the fixed supply and the composition's rate, the track count from the number of track events, the registry id from the package's `ReleaseRegistryCreatedEvent`, and the release digest (and from it the release id, as a derived address) by hashing the track events' recordings and splits with the nonce.

### Ownership

Ownership is expressed through **share tokens** (via the [`share`](https://github.com/misofm/share) package): each composition and recording initializes a fixed-supply share currency, and the set of share holders *is* the set of rightsholders. There are no separate label / publisher / rightsholder fields — ownership is the revenue claim.

## Design principles

- **Core stores what a thing *is*; extensions describe it.** Constitutive state — identity declarations and everything the economics read — lives in the frozen core. Anything with more than one correct rendering is presentation and lives in the mutable extension layer. Core names nothing: compositions, recordings and releases all carry no title — a title has translations, alternate titles and corrections, so it is presentation, and the economics never read one. A release title is additionally outside the release digest, so no track signer consents to it; what buyers rely on is the fixed tracklist, splits and id.
- **The digest binds what signers agree to; publish freezes what the creator declared; extensions carry what anyone might rephrase.**
- **Create-and-publish is atomic by construction.** Core objects are `key`-only with no `drop`: an `Initialized` object cannot outlive its creating transaction.
- **Classifications are attestations, not core fields.** Subjective labels (e.g. genre) live in an attestation layer.
- **Permissionless and territory-agnostic** — the territory is the internet.
- **V1 has no derivative-work edges** — remix/sample/cover relationships are out of scope for now.

## Modules

```
composition   recording   release   track
```

## Dependencies

| Dependency | Source | Purpose |
|------------|--------|---------|
| `bps`   | `unconfirmedlabs/bps` | Basis-point math |
| `share` | [`misofm/share`](https://github.com/misofm/share) | Fixed-supply share/ownership currency |

## Build & test

```sh
sui move build
sui move test
```

## Deployment

> **Unreleased changes:** this source drops the `CompositionShare` type
> parameter from `Recording` (now `Recording<RecordingShare>`) and from
> `RecordingPublishedEvent`; the composition link is carried by the
> `composition_id` field alone. It also slims `CompositionPublishedEvent` to
> identity and rate, `RecordingPublishedEvent` to identity and composition id
> (the rate is the composition event's), and `ReleasePublishedEvent` to
> identity and nonce, with the tracklist moved to one
> `ReleaseTrackAssignedEvent` per track (see Lifecycle), drops the publish
> timestamp from the `Published` states and the `Clock` parameter from every
> `publish` (the publish time is the event's transaction timestamp), drops
> `composition_id` from `Track` (reach it through the recording), removes
> the 255-track limit, reduces the `Initialized` state variants to what `publish` needs,
> removes the composition and release `title` fields (`composition::new`
> and `release::new` no longer take a title; `composition::title()` and
> `release::title()` are gone), and removes `release::release_registry_id`
> (use `object::id`) and `release::release_admin_cap_release_id` (unused;
> `release::authorize` checks a cap against a release). These are upgrade-incompatible changes that
> will require a fresh publication, superseding the Mainnet and Testnet packages
> currently recorded in `Published.toml`.

The current Mainnet and Testnet deployments are immutable: each was published
and its `UpgradeCap` destroyed atomically.

[`Published.toml`](./Published.toml) records this package's publish metadata
and is what dependent Move packages build against; treat it as the canonical
source for this package's ids on every network. Dependency package ids come
from each dependency's own `Published.toml` at the revision pinned in
`Move.toml`. Object ids such as the shared `ReleaseRegistry` are deliberately
not listed here until the production deployment has stabilized.

## Contributing

Issues and pull requests are welcome. By contributing you agree that your contributions are licensed under the project's Apache 2.0 license.

## License

[Apache 2.0](LICENSE) © Miso Labs, Inc.
