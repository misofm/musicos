# musicos

[![License: Apache 2.0](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)

A permissionless music identity and release-consent protocol on Sui, written in Move.

Core defines compositions, recordings, releases, and tracks. Creating an identity requires no currency, treasury, share issuance, or tokenization. Ownership classes, composition commission rates, allocations, and royalty accounting belong in extensions.

## Data model

| Type | Core data |
|---|---|
| `Composition` | Identity and lifecycle |
| `Recording` | Identity, lifecycle, and immutable composition ID |
| `Release` | Identity, lifecycle, and ordered tracks |
| `Track` | Recording ID and release revenue split |
| `TrackConsent` | Authorized release ID and nested track; consumed during release creation |

Composition and recording types and their events have no ownership type parameters.
Anyone can create a recording referencing an existing composition. The reference establishes a relationship; it does not establish a license or impose a commission.

## Creation and authorization

```move
let (composition, composition_cap) = composition::new(ctx);
let (recording, recording_cap) = recording::new(&composition, ctx);

composition.publish(&composition_cap);
recording.publish(&recording_cap);

// The caller retains or transfers the returned admin capabilities.
```

Composition, recording, and release admin capabilities authorize one specific object.
Each module's `authorize` checks the capability's stored subject ID against the object.
Publication and mutable UID access enforce that check. Track consent also checks that the
recording capability belongs to the supplied recording.

The admin capability represents protocol administration, not fractional economic ownership.
Capabilities are transferable bearer objects: transferring one hands over administration.
Core has no recovery authority or forced revocation mechanism.

## Extensions

Extensions attach through `uid_mut(&admin_cap)`. The matching capability is required
both before and after publication. Read-only UID access supports extension queries.

Metadata, credits, artwork, audio, ownership classes, and economic agreements can live
outside core. A future ownership extension can obtain the authorized subject UID,
initialize shares, and allocate the composition's commission when establishing recording
ownership. MusicOS itself does not depend on a share implementation or enforce that setup.
Applications requiring economic terms must validate their recognized extension.

Extension modules control their own typed keys and APIs. Mutable UID access is a privileged
surface; extension immutability and authorization must be designed explicitly.

## Release consent

Release revenue splits remain part of core consent. A release's ID is derived from
the ordered `(recording_id, split)` pairs and creator nonce under the shared
`ReleaseRegistry`. Splits must total 10,000 basis points.

A recording admin calls `track::consent(&recording, &cap, release_id, split_bps)`.
It returns a store-only `TrackConsent`, which extensions can wrap for offers or
escrow. Its getters expose `release_id()` and read-only `track()` access.

`release::new` accepts `vector<TrackConsent>`, derives the release ID from the
nested tracks and nonce, and validates and consumes every consent. It stores only
`vector<Track>`; consent release IDs are discarded. Unwrapping is package-private,
and neither type has `copy`. There is no public constructor for a bare track.

```move
let consent = track::consent(&recording, &recording_cap, release_id, 10000);
let (release, release_cap) = release::new(&mut registry, vector[consent], nonce);
release.publish(&release_cap);
```

Consent binds membership, ordering, and release splits. Names, artwork, and other
extension data are outside that commitment. Publication emits the track events;
it does not repeat consent validation.

The registry is created once during package initialization. Release creation is
permissionless, but requires the recording-admin-authorized consents.

## Lifecycle and events

Core objects are key-only and must be published in their creating transaction.
Publication shares the object and freezes its embedded relationships. Authorized
extension access remains available afterward.

| Event | Data |
|---|---|
| `CompositionPublishedEvent` | Composition ID |
| `RecordingPublishedEvent` | Recording ID and composition ID |
| `ReleaseRegistryCreatedEvent` | Registry ID |
| `ReleaseTrackAssignedEvent` | Release ID, track position, recording ID, split BPS |
| `ReleasePublishedEvent` | Release ID and creator nonce |

Track events are emitted in tracklist order. Transaction metadata supplies sender and time.

## Move conventions

The package follows Sui's [Move best practices](https://docs.sui.io/develop/write-move/move-best-practices):
constructors return values, publication is separate, capabilities are object-bound,
consents are consumed by value, and tests live outside production sources.

Track and TrackConsent share a module to keep consent construction and unwrapping
encapsulated. The release registry is shared only by package initialization to
preserve its single namespace. Commit publication metadata when this source is deployed.

## Dependencies

The only explicit dependency is [bps](https://github.com/unconfirmedlabs/bps),
used for release track splits. Sui framework dependencies are pinned in `Move.lock`.

## Build and test

```sh
sui move build
sui move test
```

Tests cover production identity creation, object-specific authorization, extension access
after publication, lifecycle events, release derivation, consent, and split validation.

## License

[Apache 2.0](LICENSE) © Miso Labs, Inc.
