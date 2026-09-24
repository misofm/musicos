#[test_only]
module musicos::test_helpers;

/// Phantom type for composition share tokens in tests.
public struct CompositionShare() has drop;
/// Phantom type for recording share tokens in tests.
public struct RecordingShare() has drop;

/// Creates a fake ID for testing by creating and immediately deleting a UID.
public fun fake_id(ctx: &mut TxContext): ID {
    let uid = object::new(ctx);
    let id = uid.to_inner();
    uid.delete();
    id
}
