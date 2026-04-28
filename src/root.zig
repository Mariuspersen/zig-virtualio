const std = @import("std");
const Io = std.Io;

pub fn helloWorld(writer: *Io.Writer) !void {
    try writer.print("Hello World\n", .{});
}

test "GreetTheWorld" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    const buf = try alloc.alloc(u8, 128);
    defer alloc.free(buf);
    var stdout = Io.File.stderr().writer(io, buf);
    try helloWorld(&stdout.interface);
}
