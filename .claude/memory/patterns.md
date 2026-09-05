# sirocco — Code Patterns

## vtable interface

```zig
pub const Thing = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    pub const VTable = struct {
        doIt: *const fn (*anyopaque, arg: u32) anyerror!void,
    };
    pub fn doIt(self: Thing, arg: u32) !void {
        return self.vtable.doIt(self.ptr, arg);
    }
};
```

## Test with temporary directory

```zig
test "x" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(path);
}
```

## Error set per module

Define `pub const Error = error{ ... }` at module top; public functions return `Error!T` or a narrow union of it.
