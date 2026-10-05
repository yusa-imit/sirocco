//! Entry point of the differential suite (`zig build test`): one file per slot group.

test {
    _ = @import("fixtures.zig");
    _ = @import("harness.zig");
    _ = @import("slots.zig");
    _ = @import("time.zig");
    _ = @import("dir.zig");
    _ = @import("concurrency.zig");
    _ = @import("cancel.zig");
    _ = @import("group.zig");
    _ = @import("scene.zig");
    _ = @import("futex.zig");
    _ = @import("futex_model.zig");
    _ = @import("futex_sync.zig");
}
