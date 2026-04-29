const std = @import("std");
const Io = std.Io;

const Virtualized = @import("Virtualized.zig");

test "Test Init" {
    const alloc = std.testing.allocator;
    const backing_io = std.testing.io;

    const buf = try alloc.alloc(u8, 1024);
    defer alloc.free(buf);
    
    var virtual = try Virtualized.init(alloc, backing_io);
    defer virtual.deinit();

    const io = virtual.io();
    var locked = try io.lockStderr(buf, null);
    try locked.file_writer.interface.print("Hello from Test Init", .{});
}

test "Reading File and Writing to File" {
    const alloc = std.testing.allocator;
    const backing_io = std.testing.io;

    var virtual = try Virtualized.init(alloc, backing_io);
    defer virtual.deinit();

    const buf = try alloc.alloc(u8, 1024);
    defer alloc.free(buf);

    const io = virtual.io();
    var cwd = Io.Dir.cwd();
    const f = try cwd.createFile(io, "file.txt", .{});
    defer f.close(io);
    
    var f_writer = f.writer(io, buf);
    const writer = &f_writer.interface;

    try writer.print("Hello File!", .{});
    try writer.flush();
}