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
| **`Composition`** | work | The underlying written work. Core carries its title and the royalty rate it earns from recordings. |
| **`Recording`** | work | A master recording of a composition. It carries no name of its own — its display title is its composition's title, and version naming ("Radio Edit", "(Live)") is extension metadata. |
| **`Release`** | distribution | A distributable package (Album / EP / Single) assembled from recordings — a flat, ordered tracklist with per-track revenue splits. |
| **`Track`** | distribution | A recording placed on a release, created from the recording admin capability — its creation *is* the consent to a specific future release. |

Credits, artwork, language, advisory flags, master audio, and display grouping attach as extensions or dynamic fields rather than living in the core.

### Consent

A release's id is **derived from a digest of its exact economics**: the ordered
list of `(recording, split)` pairs plus a creator nonce, claimed as a derived
child of the canonical `ReleaseRegistry` shared by `musicos::release` package
initialization. A `Track` targets that derived id at creation, so creating one
consents to the release's precise membership, splits, and running order — and
nothing else. Nothing structural is chosen after consent except the release's
title; presentation is chosen by the release creator and is publicly
attributable rather than cryptographically committed.

`ReleaseRegistry` has one production instance per package publication. It is
shared, has no constructor, delete path, or mutable-UID accessor, and its
private UID is the only derivation parent accepted by `release::new`. Release
creation remains permissionless because the supplied `Track` values carry the
rightsholders' consent.

### Lifecycle

Core objects are **build-then-freeze**: created in an `Initialized` state, configured via their admin capability, then `publish()`ed — after which they are immutable. Creation and publication emit self-contained rich events with object/capability linkage, immutable fields, timestamps, and ordered release-track data.

### Ownership

Ownership is expressed through **share tokens** (via the [`share`](https://github.com/misofm/share) package): each composition and recording initializes a fixed-supply share currency, and the set of share holders *is* the set of rightsholders. There are no separate label / publisher / rightsholder fields — ownership is the revenue claim.

## Design principles

- **Core stores what a thing *is*; extensions describe it.** Constitutive state — identity declarations and everything the economics read — lives in the frozen core. Anything with more than one correct rendering is presentation and lives in the mutable extension layer. Core names exactly two things: the work (`Composition.title`) and the package (`Release.title`).
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

> **Unreleased changes:** this source places the canonical `ReleaseRegistry`
> directly in `musicos::release` and makes it the only production derivation
> parent for `release::new`. This is an upgrade-incompatible change that will
> ship as a fresh publication.

The current Testnet deployment is immutable: it was published and its
`UpgradeCap` destroyed atomically.

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
