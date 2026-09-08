/// Structural stress test: proves every bound (255 tracks, 300-byte title,
/// exact-100% splits) is achievable simultaneously and that the resulting
/// release still publishes. The only thing under test is whether construction
/// and `publish` abort at these bounds — there is no cross-transaction
/// re-fetch or sender-dependent behavior to assert on the shared object
/// afterward, so this stays a single `tx_context::dummy()` transaction rather
/// than a `test_scenario`.
#[test_only]
module musicos::kitchen_sink_tests;

use musicos::release;
use musicos::test_helpers;
use musicos::track;
use std::unit_test::destroy;

// === Tests ===

// A recording kitchen-sink test used to exercise its naming fields at max
// bounds; recordings now carry no configurable embedded fields (naming lives
// in the metadata extension), so only the release retains structural bounds.

/// Kitchen sink test: creates a release with the structural fields at maximum
/// bounds.
/// - 255 tracks (MAX_TRACKS) in one flat tracklist
/// - Track splits sum to exactly 10000 BPS (55 x 40 + 200 x 39 = 10000)
/// - Title at 300 bytes (MAX_TITLE_LENGTH)
/// - Successfully publishes
#[test]
fun test_release_kitchen_sink() {
    let ctx = &mut tx_context::dummy();

    // Split math: 55 x 40 BPS + 200 x 39 BPS = 2200 + 7800 = 10000 BPS (100%)
    // Tracks are created with a dummy release_id; release::new_for_testing patches them.
    let dummy_release_id = test_helpers::fake_id(ctx);
    let tracks = vector::tabulate!(255, |index| track::new_for_testing(
        test_helpers::fake_id(ctx),
        test_helpers::fake_id(ctx),
        dummy_release_id,
        if (index < 55) 40 else 39,
    ));

    // Create release with max title.
    // new_for_testing patches all tracks to point to the real release ID.
    let (rel, rel_cap) = release::new_for_testing(
        test_helpers::long_string(300), // MAX_TITLE_LENGTH
        tracks,
        ctx,
    );

    // Publish - proves all max bounds are achievable together
    let clock = sui::clock::create_for_testing(ctx);
    rel.publish(&rel_cap, &clock);

    // Cleanup
    clock.destroy_for_testing();
    destroy(rel_cap);
}
