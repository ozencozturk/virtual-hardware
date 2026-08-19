//! A bounded queue of whole messages, oldest first, for devices that carry
//! framed data.
//!
//! A full queue drops the newest message and counts it, so an overloaded link
//! is visible rather than silent.

const std = @import("std");

/// A queue of at most `depth` messages, each at most `max_bytes` long.
pub fn Fifo(comptime depth: usize, comptime max_bytes: usize) type {
    return struct {
        const Self = @This();

        pub const DEPTH = depth;
        pub const MAX_BYTES = max_bytes;

        bytes: [depth * max_bytes]u8 = @splat(0),
        lengths: [depth]u32 = @splat(0),
        head: usize = 0,
        count: usize = 0,
        /// Messages refused because the queue was full or the message too long.
        dropped: u64 = 0,

        /// Queue a message; false when it did not fit and was dropped.
        pub fn push(self: *Self, msg: []const u8) bool {
            if (self.count == depth or msg.len > max_bytes) {
                self.dropped += 1;
                return false;
            }
            const slot = (self.head + self.count) % depth;
            @memcpy(self.bytes[slot * max_bytes ..][0..msg.len], msg);
            self.lengths[slot] = @intCast(msg.len);
            self.count += 1;
            return true;
        }

        /// The oldest message, or null when the queue is empty.
        pub fn peek(self: *const Self) ?[]const u8 {
            if (self.count == 0) return null;
            return self.bytes[self.head * max_bytes ..][0..self.lengths[self.head]];
        }

        /// Drop the oldest message.
        pub fn pop(self: *Self) void {
            if (self.count == 0) return;
            self.head = (self.head + 1) % depth;
            self.count -= 1;
        }

        /// Whether anything is queued.
        pub fn isEmpty(self: *const Self) bool {
            return self.count == 0;
        }
    };
}

// ---- tests ----------------------------------------------------------------

const testing = std.testing;
const Three = Fifo(3, 8);

test "fifo: messages come back in the order they went in" {
    var f = Three{};
    try testing.expect(f.isEmpty());
    try testing.expect(f.push("one"));
    try testing.expect(f.push("two"));
    try testing.expectEqualStrings("one", f.peek().?);
    f.pop();
    try testing.expectEqualStrings("two", f.peek().?);
    f.pop();
    try testing.expectEqual(@as(?[]const u8, null), f.peek());
}

test "fifo: a full queue drops the newest and counts it" {
    var f = Three{};
    for (0..3) |_| try testing.expect(f.push("x"));
    try testing.expect(!f.push("x"));
    try testing.expectEqual(@as(u64, 1), f.dropped);
    try testing.expectEqualStrings("x", f.peek().?);
}

test "fifo: a message longer than the queue carries is refused" {
    var f = Three{};
    try testing.expect(!f.push("far too long"));
    try testing.expectEqual(@as(u64, 1), f.dropped);
    try testing.expect(f.isEmpty());
}

test "fifo: slots are reused as the queue wraps" {
    var f = Three{};
    for (0..3) |_| try testing.expect(f.push("a"));
    f.pop();
    try testing.expect(f.push("b"));
    f.pop();
    f.pop();
    try testing.expectEqualStrings("b", f.peek().?);
}

test "fifo: popping an empty queue is not an error" {
    var f = Three{};
    f.pop();
    try testing.expect(f.isEmpty());
}
