#[test_only]
module musicos::test_helpers;

use std::string::String;

/// Phantom type for composition share tokens in tests.
public struct CompositionShare() has drop;
/// Phantom type for recording share tokens in tests.
public struct RecordingShare() has drop;

/// Creates a string of the given length filled with 'A' characters.
public fun long_string(len: u64): String {
    let mut s = vector<u8>[];
    len.do!(|_| s.push_back(65));
    s.to_string()
}

/// Creates a fake ID for testing by creating and immediately deleting a UID.
public fun fake_id(ctx: &mut TxContext): ID {
    let uid = object::new(ctx);
    let id = uid.to_inner();
    uid.delete();
    id
}
