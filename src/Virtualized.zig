//Copied from std.Io.Threaded
const Virtualized = @This();

const builtin = @import("builtin");
const native_os = builtin.os.tag;
const is_windows = native_os == .windows;
const is_darwin = native_os.isDarwin();
const is_debug = builtin.mode == .Debug;

const std = @import("std");
const Io = std.Io;
const net = std.Io.net;
const File = std.Io.File;
const Dir = std.Io.Dir;
const HostName = net.HostName;
const IpAddress = net.IpAddress;
const process = std.process;
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;
const assert = std.debug.assert;
const posix = std.posix;
const windows = std.os.windows;
const ws2_32 = windows.ws2_32;

const FilesHashMap = std.StringHashMap(std.ArrayList(u8));
const DirsHashMap = std.StringHashMap(Dir);
const HandlesToFilesMap = std.AutoHashMap(Io.File.Handle, []const u8);
const HandleMap = std.StringHashMap(Io.File.Handle);

const CAPACITY_BUFFER_SIZE = 256;

allocator: Allocator,
files: FilesHashMap,
dirs: DirsHashMap,
handles: HandlesToFilesMap,
reverse: HandleMap,
count: i32,
stderr_mode: Io.Terminal.Mode,
stderr_buf: []u8,
backing_io: Io,

fn newHandle(v: *Virtualized) File.Handle {
    v.count += 1;
    const casted: usize = @intCast(v.count);
    return @ptrFromInt(casted);
}

fn createFile(v: *Virtualized) File {
    return .{
        .flags = .{ .nonblocking = false },
        .handle = v.getHandle(),
    };
}

fn createFilesEntry(v: *Virtualized) File {
    const f = v.createFile();
    try v.files.put(
        v.createFile(),
        Io.Writer.Allocating.init(v.allocator),
    );
    return f;
}

pub fn init(gpa: Allocator, backing_io: Io) !Virtualized {
    return .{
        .allocator = gpa,
        .backing_io = backing_io,
        .files = .init(gpa),
        .dirs = .init(gpa),
        .handles = .init(gpa),
        .reverse = .init(gpa),
        .count = 2,
        .stderr_mode = .no_color,
        .stderr_buf = try gpa.alloc(u8, 1024),
    };
}

pub fn deinit(v: *Virtualized) void {
    var it = v.files.valueIterator();
    while (it.next()) |writer| {
        writer.deinit(v.allocator);
    }
    v.dirs.deinit();
    v.files.deinit();
    v.handles.deinit();
    v.reverse.deinit();
    v.allocator.free(v.stderr_buf);
}

pub fn io(v: *Virtualized) Io {
    return .{
        .userdata = v,
        .vtable = &.{
            .crashHandler = noCrashHandler,

            .async = noAsync,
            .concurrent = virtConcurrent,
            .await = virtAwait,
            .cancel = virtCancel,

            .groupAsync = noGroupAsync,
            .groupConcurrent = virtGroupConcurrent,
            .groupAwait = virtGroupAwait,
            .groupCancel = virtGroupCancel,

            .recancel = virtRecancel,
            .swapCancelProtection = virtSwapCancelProtection,
            .checkCancel = virtCheckCancel,

            .futexWait = noFutexWait,
            .futexWaitUncancelable = noFutexWaitUncancelable,
            .futexWake = noFutexWake,

            .operate = virtOperate,
            .batchAwaitAsync = virtBatchAwaitAsync,
            .batchAwaitConcurrent = virtBatchAwaitConcurrent,
            .batchCancel = virtBatchCancel,

            .dirCreateDir = virtDirCreateDir,
            .dirCreateDirPath = virtDirCreateDirPath,
            .dirCreateDirPathOpen = virtDirCreateDirPathOpen,
            .dirOpenDir = virtDirOpenDir,
            .dirStat = virtDirStat,
            .dirStatFile = virtDirStatFile,
            .dirAccess = virtDirAccess,
            .dirCreateFile = virtDirCreateFile,
            .dirCreateFileAtomic = virtDirCreateFileAtomic,
            .dirOpenFile = virtDirOpenFile,
            .dirClose = virtDirClose,
            .dirRead = noDirRead,
            .dirRealPath = virtDirRealPath,
            .dirRealPathFile = virtDirRealPathFile,
            .dirDeleteFile = virtDirDeleteFile,
            .dirDeleteDir = virtDirDeleteDir,
            .dirRename = virtDirRename,
            .dirRenamePreserve = virtDirRenamePreserve,
            .dirSymLink = virtDirSymLink,
            .dirReadLink = virtDirReadLink,
            .dirSetOwner = virtDirSetOwner,
            .dirSetFileOwner = virtDirSetFileOwner,
            .dirSetPermissions = virtDirSetPermissions,
            .dirSetFilePermissions = virtDirSetFilePermissions,
            .dirSetTimestamps = noDirSetTimestamps,
            .dirHardLink = virtDirHardLink,

            .fileStat = virtFileStat,
            .fileLength = virtFileLength,
            .fileClose = virtFileClose,
            .fileWritePositional = virtFileWritePositional,
            .fileWriteFileStreaming = virtFileWriteFileStreaming,
            .fileWriteFilePositional = virtFileWriteFilePositional,
            .fileReadPositional = virtFileReadPositional,
            .fileSeekBy = virtFileSeekBy,
            .fileSeekTo = virtFileSeekTo,
            .fileSync = virtFileSync,
            .fileIsTty = virtFileIsTty,
            .fileEnableAnsiEscapeCodes = virtFileEnableAnsiEscapeCodes,
            .fileSupportsAnsiEscapeCodes = virtFileSupportsAnsiEscapeCodes,
            .fileSetLength = virtFileSetLength,
            .fileSetOwner = virtFileSetOwner,
            .fileSetPermissions = virtFileSetPermissions,
            .fileSetTimestamps = noFileSetTimestamps,
            .fileLock = virtFileLock,
            .fileTryLock = virtFileTryLock,
            .fileUnlock = virtFileUnlock,
            .fileDowngradeLock = virtFileDowngradeLock,
            .fileRealPath = virtFileRealPath,
            .fileHardLink = virtFileHardLink,

            .fileMemoryMapCreate = virtFileMemoryMapCreate,
            .fileMemoryMapDestroy = virtFileMemoryMapDestroy,
            .fileMemoryMapSetLength = virtFileMemoryMapSetLength,
            .fileMemoryMapRead = virtFileMemoryMapRead,
            .fileMemoryMapWrite = virtFileMemoryMapWrite,

            .processExecutableOpen = virtProcessExecutableOpen,
            .processExecutablePath = virtProcessExecutablePath,
            .lockStderr = virtLockStderr,
            .tryLockStderr = noTryLockStderr,
            .unlockStderr = virtUnlockStderr,
            .processCurrentPath = virtProcessCurrentPath,
            .processSetCurrentDir = virtProcessSetCurrentDir,
            .processSetCurrentPath = virtProcessSetCurrentPath,
            .processReplace = virtProcessReplace,
            .processReplacePath = virtProcessReplacePath,
            .processSpawn = virtProcessSpawn,
            .processSpawnPath = virtProcessSpawnPath,
            .childWait = virtChildWait,
            .childKill = virtChildKill,

            .progressParentFile = virtProgressParentFile,

            .random = noRandom,
            .randomSecure = virtRandomSecure,

            .now = noNow,
            .clockResolution = virtClockResolution,
            .sleep = noSleep,

            .netListenIp = virtNetListenIp,
            .netAccept = virtNetAccept,
            .netBindIp = virtNetBindIp,
            .netConnectIp = virtNetConnectIp,
            .netListenUnix = virtNetListenUnix,
            .netConnectUnix = virtNetConnectUnix,
            .netSocketCreatePair = virtNetSocketCreatePair,
            .netSend = virtNetSend,
            .netRead = virtNetRead,
            .netWrite = virtNetWrite,
            .netWriteFile = virtNetWriteFile,
            .netClose = virtNetClose,
            .netShutdown = virtNetShutdown,
            .netInterfaceNameResolve = virtNetInterfaceNameResolve,
            .netInterfaceName = virtNetInterfaceName,
            .netLookup = virtNetLookup,
        },
    };
}

pub fn noCrashHandler(userdata: ?*anyopaque) void {
    _ = userdata;
}

pub fn noAsync(
    userdata: ?*anyopaque,
    result: []u8,
    result_alignment: std.mem.Alignment,
    context: []const u8,
    context_alignment: std.mem.Alignment,
    start: *const fn (context: *const anyopaque, result: *anyopaque) void,
) ?*Io.AnyFuture {
    _ = userdata;
    _ = result_alignment;
    _ = context_alignment;
    start(context.ptr, result.ptr);
    return null;
}

pub fn virtConcurrent(
    userdata: ?*anyopaque,
    result_len: usize,
    result_alignment: std.mem.Alignment,
    context: []const u8,
    context_alignment: std.mem.Alignment,
    start: *const fn (context: *const anyopaque, result: *anyopaque) void,
) Io.ConcurrentError!*Io.AnyFuture {
    _ = userdata;
    _ = result_len;
    _ = result_alignment;
    _ = context;
    _ = context_alignment;
    _ = start;
    return error.ConcurrencyUnavailable;
}

pub fn virtAwait(
    userdata: ?*anyopaque,
    any_future: *Io.AnyFuture,
    result: []u8,
    result_alignment: std.mem.Alignment,
) void {
    _ = userdata;
    _ = any_future;
    _ = result;
    _ = result_alignment;
    unreachable;
}

pub fn virtCancel(
    userdata: ?*anyopaque,
    any_future: *Io.AnyFuture,
    result: []u8,
    result_alignment: std.mem.Alignment,
) void {
    _ = userdata;
    _ = any_future;
    _ = result;
    _ = result_alignment;
    unreachable;
}

pub fn noGroupAsync(
    userdata: ?*anyopaque,
    group: *Io.Group,
    context: []const u8,
    context_alignment: std.mem.Alignment,
    start: *const fn (context: *const anyopaque) void,
) void {
    _ = userdata;
    _ = group;
    _ = context_alignment;
    start(context.ptr);
}

pub fn virtGroupConcurrent(
    userdata: ?*anyopaque,
    group: *Io.Group,
    context: []const u8,
    context_alignment: std.mem.Alignment,
    start: *const fn (context: *const anyopaque) void,
) Io.ConcurrentError!void {
    _ = userdata;
    _ = group;
    _ = context;
    _ = context_alignment;
    _ = start;
    return error.ConcurrencyUnavailable;
}

pub fn virtGroupAwait(userdata: ?*anyopaque, group: *Io.Group, token: *anyopaque) Io.Cancelable!void {
    _ = userdata;
    _ = group;
    _ = token;
    unreachable;
}

pub fn virtGroupCancel(userdata: ?*anyopaque, group: *Io.Group, token: *anyopaque) void {
    _ = userdata;
    _ = group;
    _ = token;
    unreachable;
}

pub fn virtRecancel(userdata: ?*anyopaque) void {
    _ = userdata;
    unreachable;
}

pub fn virtSwapCancelProtection(userdata: ?*anyopaque, new: Io.CancelProtection) Io.CancelProtection {
    _ = userdata;
    _ = new;
    unreachable;
}

pub fn virtCheckCancel(userdata: ?*anyopaque) Io.Cancelable!void {
    _ = userdata;
    unreachable;
}

pub fn noFutexWait(userdata: ?*anyopaque, ptr: *const u32, expected: u32, timeout: Io.Timeout) Io.Cancelable!void {
    _ = userdata;
    std.debug.assert(ptr.* == expected or timeout != .none);
}

pub fn noFutexWaitUncancelable(userdata: ?*anyopaque, ptr: *const u32, expected: u32) void {
    _ = userdata;
    std.debug.assert(ptr.* == expected);
}

pub fn noFutexWake(userdata: ?*anyopaque, ptr: *const u32, max_waiters: u32) void {
    _ = userdata;
    _ = ptr;
    _ = max_waiters;
    // no-op
}

pub fn virtOperate(userdata: ?*anyopaque, operation: Io.Operation) Io.Cancelable!Io.Operation.Result {
    _ = userdata;
    return switch (operation) {
        .file_read_streaming => .{ .file_read_streaming = error.InputOutput },
        .file_write_streaming => .{ .file_write_streaming = error.InputOutput },
        .device_io_control => unreachable,
        .net_receive => .{ .net_receive = .{ error.NetworkDown, 0 } },
    };
}

pub fn virtBatchAwaitAsync(userdata: ?*anyopaque, b: *Io.Batch) Io.Cancelable!void {
    _ = userdata;
    _ = b;
    unreachable;
}

pub fn virtBatchAwaitConcurrent(userdata: ?*anyopaque, b: *Io.Batch, timeout: Io.Timeout) Io.Batch.AwaitConcurrentError!void {
    _ = userdata;
    _ = b;
    _ = timeout;
    unreachable;
}

pub fn virtBatchCancel(userdata: ?*anyopaque, b: *Io.Batch) void {
    _ = userdata;
    _ = b;
    unreachable;
}

pub fn virtDirCreateDir(userdata: ?*anyopaque, dir: Dir, sub_path: []const u8, permissions: Dir.Permissions) Dir.CreateDirError!void {
    _ = userdata;
    _ = dir;
    _ = sub_path;
    _ = permissions;
    return error.NoSpaceLeft;
}

pub fn virtDirCreateDirPath(userdata: ?*anyopaque, dir: Dir, sub_path: []const u8, permissions: Dir.Permissions) Dir.CreateDirPathError!Dir.CreatePathStatus {
    _ = userdata;
    _ = dir;
    _ = sub_path;
    _ = permissions;
    return error.NoSpaceLeft;
}

pub fn virtDirCreateDirPathOpen(userdata: ?*anyopaque, dir: Dir, sub_path: []const u8, permissions: Dir.Permissions, options: Dir.OpenOptions) Dir.CreateDirPathOpenError!Dir {
    _ = userdata;
    _ = dir;
    _ = sub_path;
    _ = permissions;
    _ = options;
    return error.NoSpaceLeft;
}

pub fn virtDirOpenDir(userdata: ?*anyopaque, dir: Dir, sub_path: []const u8, options: Dir.OpenOptions) Dir.OpenError!Dir {
    _ = userdata;
    _ = dir;
    _ = sub_path;
    _ = options;
    return error.FileNotFound;
}

pub fn virtDirStat(userdata: ?*anyopaque, dir: Dir) Dir.StatError!Dir.Stat {
    _ = userdata;
    _ = dir;
    return error.Streaming;
}

pub fn virtDirStatFile(userdata: ?*anyopaque, dir: Dir, sub_path: []const u8, options: Dir.StatFileOptions) Dir.StatFileError!File.Stat {
    _ = userdata;
    _ = dir;
    _ = sub_path;
    _ = options;
    return error.FileNotFound;
}

pub fn virtDirAccess(userdata: ?*anyopaque, dir: Dir, sub_path: []const u8, options: Dir.AccessOptions) Dir.AccessError!void {
    _ = userdata;
    _ = dir;
    _ = sub_path;
    _ = options;
    return error.FileNotFound;
}

pub fn virtDirCreateFile(userdata: ?*anyopaque, dir: Dir, sub_path: []const u8, options: File.CreateFlags) File.OpenError!File {
    const v: *Virtualized = @ptrCast(@alignCast(userdata));
    // TODO: Figure out the best way of checking this
    const handle = v.newHandle();
    v.files.put(
        sub_path,
        std.ArrayList(u8).initCapacity(v.allocator, CAPACITY_BUFFER_SIZE) catch return error.NoSpaceLeft,
    ) catch return error.NoSpaceLeft;
    //UUHH This should not fail :))))
    const hashed_sub_path = v.files.getKey(sub_path) orelse unreachable;
    v.handles.put(handle, hashed_sub_path) catch return error.NoSpaceLeft;
    v.reverse.put(hashed_sub_path, handle) catch return error.NoSpaceLeft;

    const flags = File.OpenFlags{ .lock_nonblocking = options.lock_nonblocking };

    return virtDirOpenFile(userdata, dir, sub_path, flags);
}

pub fn virtDirCreateFileAtomic(userdata: ?*anyopaque, dir: Dir, sub_path: []const u8, options: Dir.CreateFileAtomicOptions) Dir.CreateFileAtomicError!File.Atomic {
    _ = userdata;
    _ = dir;
    _ = sub_path;
    _ = options;
    return error.NoSpaceLeft;
}

pub fn virtDirOpenFile(userdata: ?*anyopaque, dir: Dir, sub_path: []const u8, flags: File.OpenFlags) File.OpenError!File {
    // TODO: Figure out the best way of checking this
    _ = dir;
    const v: *Virtualized = @ptrCast(@alignCast(userdata));
    //File doesn't exist
    const hashed_sub_path = v.files.getKey(sub_path) orelse return error.FileNotFound;

    //File exists and file already has a handle
    if (v.reverse.get(sub_path)) |handle| {
        return .{
            .handle = handle,
            .flags = .{ .nonblocking = flags.lock_nonblocking },
        };
    }

    //File exists but doesnt have a handle
    const handle = v.newHandle();
    v.handles.put(handle, hashed_sub_path) catch return error.NoSpaceLeft;
    return .{
        .handle = v.newHandle(),
        .flags = .{ .nonblocking = flags.lock_nonblocking },
    };
}

pub fn virtDirClose(userdata: ?*anyopaque, dirs: []const Dir) void {
    _ = userdata;
    _ = dirs;
    unreachable;
}

pub fn noDirRead(userdata: ?*anyopaque, dir_reader: *Dir.Reader, buffer: []Dir.Entry) Dir.Reader.Error!usize {
    _ = userdata;
    _ = dir_reader;
    _ = buffer;
    return 0;
}

pub fn virtDirRealPath(userdata: ?*anyopaque, dir: Dir, out_buffer: []u8) Dir.RealPathError!usize {
    _ = userdata;
    _ = dir;
    _ = out_buffer;
    return error.FileNotFound;
}

pub fn virtDirRealPathFile(userdata: ?*anyopaque, dir: Dir, path_name: []const u8, out_buffer: []u8) Dir.RealPathFileError!usize {
    _ = userdata;
    _ = dir;
    _ = path_name;
    _ = out_buffer;
    return error.FileNotFound;
}

pub fn virtDirDeleteFile(userdata: ?*anyopaque, dir: Dir, sub_path: []const u8) Dir.DeleteFileError!void {
    _ = userdata;
    _ = dir;
    _ = sub_path;
    return error.FileNotFound;
}

pub fn virtDirDeleteDir(userdata: ?*anyopaque, dir: Dir, sub_path: []const u8) Dir.DeleteDirError!void {
    _ = userdata;
    _ = dir;
    _ = sub_path;
    return error.FileNotFound;
}

pub fn virtDirRename(userdata: ?*anyopaque, old_dir: Dir, old_sub_path: []const u8, new_dir: Dir, new_sub_path: []const u8) Dir.RenameError!void {
    _ = userdata;
    _ = old_dir;
    _ = old_sub_path;
    _ = new_dir;
    _ = new_sub_path;
    return error.FileNotFound;
}

pub fn virtDirRenamePreserve(userdata: ?*anyopaque, old_dir: Dir, old_sub_path: []const u8, new_dir: Dir, new_sub_path: []const u8) Dir.RenamePreserveError!void {
    _ = userdata;
    _ = old_dir;
    _ = old_sub_path;
    _ = new_dir;
    _ = new_sub_path;
    return error.FileNotFound;
}

pub fn virtDirSymLink(userdata: ?*anyopaque, dir: Dir, target_path: []const u8, sym_link_path: []const u8, flags: Dir.SymLinkFlags) Dir.SymLinkError!void {
    _ = userdata;
    _ = dir;
    _ = target_path;
    _ = sym_link_path;
    _ = flags;
    return error.FileNotFound;
}

pub fn virtDirReadLink(userdata: ?*anyopaque, dir: Dir, sub_path: []const u8, buffer: []u8) Dir.ReadLinkError!usize {
    _ = userdata;
    _ = dir;
    _ = sub_path;
    _ = buffer;
    return error.FileNotFound;
}

pub fn virtDirSetOwner(userdata: ?*anyopaque, dir: Dir, owner: ?File.Uid, group: ?File.Gid) Dir.SetOwnerError!void {
    _ = userdata;
    _ = dir;
    _ = owner;
    _ = group;
    return error.FileNotFound;
}

pub fn virtDirSetFileOwner(userdata: ?*anyopaque, dir: std.Io.Dir, sub_path: []const u8, owner: ?File.Uid, group: ?File.Gid, options: Dir.SetFileOwnerOptions) Dir.SetFileOwnerError!void {
    _ = userdata;
    _ = dir;
    _ = sub_path;
    _ = owner;
    _ = group;
    _ = options;
    return error.FileNotFound;
}

pub fn virtDirSetPermissions(userdata: ?*anyopaque, dir: Dir, permissions: Dir.Permissions) Dir.SetPermissionsError!void {
    _ = userdata;
    _ = dir;
    _ = permissions;
    return error.FileNotFound;
}

pub fn virtDirSetFilePermissions(userdata: ?*anyopaque, dir: Dir, sub_path: []const u8, permissions: File.Permissions, options: Dir.SetFilePermissionsOptions) Dir.SetFilePermissionsError!void {
    _ = userdata;
    _ = dir;
    _ = sub_path;
    _ = permissions;
    _ = options;
    return error.FileNotFound;
}

pub fn noDirSetTimestamps(userdata: ?*anyopaque, dir: Dir, sub_path: []const u8, options: Dir.SetTimestampsOptions) Dir.SetTimestampsError!void {
    _ = userdata;
    _ = dir;
    _ = sub_path;
    _ = options;
    // no-op
}

pub fn virtDirHardLink(userdata: ?*anyopaque, old_dir: Dir, old_sub_path: []const u8, new_dir: Dir, new_sub_path: []const u8, options: Dir.HardLinkOptions) Dir.HardLinkError!void {
    _ = userdata;
    _ = old_dir;
    _ = old_sub_path;
    _ = new_dir;
    _ = new_sub_path;
    _ = options;
    return error.FileNotFound;
}

pub fn virtFileStat(userdata: ?*anyopaque, file: File) File.StatError!File.Stat {
    _ = userdata;
    _ = file;
    return error.Streaming;
}

pub fn virtFileLength(userdata: ?*anyopaque, file: File) File.LengthError!u64 {
    _ = userdata;
    _ = file;
    return error.Streaming;
}

pub fn virtFileClose(userdata: ?*anyopaque, files: []const File) void {
    const v: *Virtualized = @ptrCast(@alignCast(userdata));
    for(files) |file| {
        _ = v.handles.remove(file.handle);
    }
}

pub fn virtFileWritePositional(userdata: ?*anyopaque, file: File, header: []const u8, data: []const []const u8, splat: usize, offset: u64) File.WritePositionalError!usize {
    const v: *Virtualized = @ptrCast(@alignCast(userdata));
    _ = offset;

    const filename = v.handles.get(file.handle) orelse return error.BrokenPipe;
    const array_buf = v.files.getPtr(filename) orelse return error.BrokenPipe;

    const before_size = array_buf.items.len;

    array_buf.appendSlice(v.allocator, header) catch return error.NoSpaceLeft;
    for (data) |slice| {
        array_buf.appendSlice(v.allocator, slice) catch return error.NoSpaceLeft;
    }
    for (0..splat) |_| {
        array_buf.appendSlice(v.allocator, data[data.len - 1]) catch return error.NoSpaceLeft;
    }
        
    const after_size = array_buf.items.len;
    
    return after_size - before_size;
}

pub fn virtFileWriteFileStreaming(userdata: ?*anyopaque, file: File, header: []const u8, file_reader: *Io.File.Reader, limit: Io.Limit) File.Writer.WriteFileError!usize {
    _ = userdata;
    _ = header;
    _ = file;
    _ = file_reader;
    _ = limit;
    return File.Writer.WriteFileError.PermissionDenied;
}

pub fn virtFileWriteFilePositional(userdata: ?*anyopaque, file: File, header: []const u8, file_reader: *Io.File.Reader, limit: Io.Limit, offset: u64) File.WriteFilePositionalError!usize {
    _ = userdata;
    _ = file;
    _ = header;
    _ = file_reader;
    _ = limit;
    _ = offset;
    return File.WriteFilePositionalError.PermissionDenied;
}

pub fn virtFileReadPositional(userdata: ?*anyopaque, file: File, data: []const []u8, offset: u64) File.ReadPositionalError!usize {
    _ = userdata;
    _ = file;
    _ = offset;
    for (data) |item| {
        if (item.len > 0) return error.InputOutput;
    }
    return 0;
}

pub fn virtFileSeekBy(userdata: ?*anyopaque, file: File, relative_offset: i64) File.SeekError!void {
    _ = userdata;
    _ = file;
    _ = relative_offset;
    return error.Unseekable;
}

pub fn virtFileSeekTo(userdata: ?*anyopaque, file: File, absolute_offset: u64) File.SeekError!void {
    _ = userdata;
    _ = file;
    _ = absolute_offset;
    return error.Unseekable;
}

pub fn virtFileSync(userdata: ?*anyopaque, file: File) File.SyncError!void {
    _ = userdata;
    _ = file;
    return error.NoSpaceLeft;
}

pub fn virtFileIsTty(userdata: ?*anyopaque, file: File) Io.Cancelable!bool {
    _ = userdata;
    _ = file;
    unreachable;
}

pub fn virtFileEnableAnsiEscapeCodes(userdata: ?*anyopaque, file: File) File.EnableAnsiEscapeCodesError!void {
    _ = userdata;
    _ = file;
    unreachable;
}

pub fn virtFileSupportsAnsiEscapeCodes(userdata: ?*anyopaque, file: File) Io.Cancelable!bool {
    _ = userdata;
    _ = file;
    unreachable;
}

pub fn virtFileSetLength(userdata: ?*anyopaque, file: File, length: u64) File.SetLengthError!void {
    _ = userdata;
    _ = file;
    _ = length;
    return error.NonResizable;
}

pub fn virtFileSetOwner(userdata: ?*anyopaque, file: File, owner: ?File.Uid, group: ?File.Gid) File.SetOwnerError!void {
    _ = userdata;
    _ = file;
    _ = owner;
    _ = group;
    return error.FileNotFound;
}

pub fn virtFileSetPermissions(userdata: ?*anyopaque, file: File, permissions: File.Permissions) File.SetPermissionsError!void {
    _ = userdata;
    _ = file;
    _ = permissions;
    return error.FileNotFound;
}

pub fn noFileSetTimestamps(userdata: ?*anyopaque, file: File, options: File.SetTimestampsOptions) File.SetTimestampsError!void {
    _ = userdata;
    _ = file;
    _ = options;
    // no-op
}

pub fn virtFileLock(userdata: ?*anyopaque, file: File, lock: File.Lock) File.LockError!void {
    _ = userdata;
    _ = file;
    _ = lock;
    return error.FileLocksUnsupported;
}

pub fn virtFileTryLock(userdata: ?*anyopaque, file: File, lock: File.Lock) File.LockError!bool {
    _ = userdata;
    _ = file;
    _ = lock;
    return error.FileLocksUnsupported;
}

pub fn virtFileUnlock(userdata: ?*anyopaque, file: File) void {
    _ = userdata;
    _ = file;
    unreachable;
}

pub fn virtFileDowngradeLock(userdata: ?*anyopaque, file: File) File.DowngradeLockError!void {
    _ = userdata;
    _ = file;
    // no-op
}

pub fn virtFileRealPath(userdata: ?*anyopaque, file: File, out_buffer: []u8) File.RealPathError!usize {
    _ = userdata;
    _ = file;
    _ = out_buffer;
    return error.FileNotFound;
}

pub fn virtFileHardLink(userdata: ?*anyopaque, file: File, new_dir: Dir, new_sub_path: []const u8, options: File.HardLinkOptions) File.HardLinkError!void {
    _ = userdata;
    _ = file;
    _ = new_dir;
    _ = new_sub_path;
    _ = options;
    return error.FileNotFound;
}

pub fn virtFileMemoryMapCreate(userdata: ?*anyopaque, file: File, options: File.MemoryMap.CreateOptions) File.MemoryMap.CreateError!File.MemoryMap {
    _ = userdata;
    _ = file;
    _ = options;
    return error.AccessDenied;
}

pub fn virtFileMemoryMapDestroy(userdata: ?*anyopaque, mm: *File.MemoryMap) void {
    _ = userdata;
    _ = mm;
    unreachable;
}

pub fn virtFileMemoryMapSetLength(userdata: ?*anyopaque, mm: *File.MemoryMap, new_len: usize) File.MemoryMap.SetLengthError!void {
    _ = userdata;
    _ = mm;
    _ = new_len;
    unreachable;
}

pub fn virtFileMemoryMapRead(userdata: ?*anyopaque, mm: *File.MemoryMap) File.ReadPositionalError!void {
    _ = userdata;
    _ = mm;
    unreachable;
}

pub fn virtFileMemoryMapWrite(userdata: ?*anyopaque, mm: *File.MemoryMap) File.WritePositionalError!void {
    _ = userdata;
    _ = mm;
    unreachable;
}

pub fn virtProcessExecutableOpen(userdata: ?*anyopaque, flags: File.OpenFlags) std.process.OpenExecutableError!File {
    _ = userdata;
    _ = flags;
    return error.FileNotFound;
}

pub fn virtProcessExecutablePath(userdata: ?*anyopaque, buffer: []u8) std.process.ExecutablePathError!usize {
    _ = userdata;
    _ = buffer;
    return error.FileNotFound;
}

pub fn virtLockStderr(userdata: ?*anyopaque, terminal_mode: ?Io.Terminal.Mode) Io.Cancelable!Io.LockedStderr {
    const v: *Virtualized = @ptrCast(@alignCast(userdata));
    return v.backing_io.lockStderr(v.stderr_buf, terminal_mode);
}

pub fn noTryLockStderr(userdata: ?*anyopaque, terminal_mode: ?Io.Terminal.Mode) Io.Cancelable!?Io.LockedStderr {
    _ = userdata;
    _ = terminal_mode;
    return null;
}

pub fn virtUnlockStderr(userdata: ?*anyopaque) void {
    _ = userdata;
    unreachable;
}

pub fn virtProcessCurrentPath(userdata: ?*anyopaque, buffer: []u8) std.process.CurrentPathError!usize {
    _ = userdata;
    _ = buffer;
    return error.CurrentDirUnlinked;
}

pub fn virtProcessSetCurrentDir(userdata: ?*anyopaque, dir: Dir) std.process.SetCurrentDirError!void {
    _ = userdata;
    _ = dir;
    return error.FileNotFound;
}

pub fn virtProcessSetCurrentPath(userdata: ?*anyopaque, path: []const u8) std.process.SetCurrentPathError!void {
    _ = userdata;
    _ = path;
    return error.FileNotFound;
}

pub fn virtProcessReplace(userdata: ?*anyopaque, options: std.process.ReplaceOptions) std.process.ReplaceError {
    _ = userdata;
    _ = options;
    return error.OperationUnsupported;
}

pub fn virtProcessReplacePath(userdata: ?*anyopaque, dir: Dir, options: std.process.ReplaceOptions) std.process.ReplaceError {
    _ = userdata;
    _ = dir;
    _ = options;
    return error.OperationUnsupported;
}

pub fn virtProcessSpawn(userdata: ?*anyopaque, options: std.process.SpawnOptions) std.process.SpawnError!std.process.Child {
    _ = userdata;
    _ = options;
    return error.OperationUnsupported;
}

pub fn virtProcessSpawnPath(userdata: ?*anyopaque, dir: Dir, options: std.process.SpawnOptions) std.process.SpawnError!std.process.Child {
    _ = userdata;
    _ = dir;
    _ = options;
    return error.OperationUnsupported;
}

pub fn virtChildWait(userdata: ?*anyopaque, child: *std.process.Child) std.process.Child.WaitError!std.process.Child.Term {
    _ = userdata;
    _ = child;
    unreachable;
}

pub fn virtChildKill(userdata: ?*anyopaque, child: *std.process.Child) void {
    _ = userdata;
    _ = child;
    unreachable;
}

pub fn virtProgressParentFile(userdata: ?*anyopaque) std.Progress.ParentFileError!File {
    _ = userdata;
    return error.UnsupportedOperation;
}

pub fn noRandom(userdata: ?*anyopaque, buffer: []u8) void {
    _ = userdata;
    @memset(buffer, 0);
}

pub fn virtRandomSecure(userdata: ?*anyopaque, buffer: []u8) Io.RandomSecureError!void {
    _ = userdata;
    _ = buffer;
    return error.EntropyUnavailable;
}

pub fn noNow(userdata: ?*anyopaque, clock: Io.Clock) Io.Timestamp {
    _ = userdata;
    _ = clock;
    return .zero;
}

pub fn virtClockResolution(userdata: ?*anyopaque, clock: Io.Clock) Io.Clock.ResolutionError!Io.Duration {
    _ = userdata;
    _ = clock;
    return error.ClockUnavailable;
}

pub fn noSleep(userdata: ?*anyopaque, clock: Io.Timeout) Io.Cancelable!void {
    _ = userdata;
    _ = clock;
}

pub fn virtNetListenIp(userdata: ?*anyopaque, address: *const net.IpAddress, options: net.IpAddress.ListenOptions) net.IpAddress.ListenError!net.Socket {
    _ = userdata;
    _ = address;
    _ = options;
    return error.NetworkDown;
}

pub fn virtNetAccept(userdata: ?*anyopaque, listen_fd: net.Socket.Handle, options: net.Server.AcceptOptions) net.Server.AcceptError!net.Socket {
    _ = userdata;
    _ = listen_fd;
    _ = options;
    return error.NetworkDown;
}

pub fn virtNetBindIp(userdata: ?*anyopaque, address: *const net.IpAddress, options: net.IpAddress.BindOptions) net.IpAddress.BindError!net.Socket {
    _ = userdata;
    _ = address;
    _ = options;
    return error.NetworkDown;
}

pub fn virtNetConnectIp(userdata: ?*anyopaque, address: *const net.IpAddress, options: net.IpAddress.ConnectOptions) net.IpAddress.ConnectError!net.Socket {
    _ = userdata;
    _ = address;
    _ = options;
    return error.NetworkDown;
}

pub fn virtNetListenUnix(userdata: ?*anyopaque, address: *const net.UnixAddress, options: net.UnixAddress.ListenOptions) net.UnixAddress.ListenError!net.Socket.Handle {
    _ = userdata;
    _ = address;
    _ = options;
    return error.NetworkDown;
}

pub fn virtNetConnectUnix(userdata: ?*anyopaque, address: *const net.UnixAddress) net.UnixAddress.ConnectError!net.Socket.Handle {
    _ = userdata;
    _ = address;
    return error.NetworkDown;
}

pub fn virtNetSocketCreatePair(userdata: ?*anyopaque, options: net.Socket.CreatePairOptions) net.Socket.CreatePairError![2]net.Socket {
    _ = userdata;
    _ = options;
    return error.OperationUnsupported;
}

pub fn virtNetSend(userdata: ?*anyopaque, handle: net.Socket.Handle, messages: []net.OutgoingMessage, flags: net.SendFlags) struct { ?net.Socket.SendError, usize } {
    _ = userdata;
    _ = handle;
    _ = messages;
    _ = flags;
    return .{ error.NetworkDown, 0 };
}

pub fn virtNetRead(userdata: ?*anyopaque, src: net.Socket.Handle, data: [][]u8) net.Stream.Reader.Error!usize {
    _ = userdata;
    _ = src;
    _ = data;
    return error.NetworkDown;
}

pub fn virtNetWrite(userdata: ?*anyopaque, dest: net.Socket.Handle, header: []const u8, data: []const []const u8, splat: usize) net.Stream.Writer.Error!usize {
    _ = userdata;
    _ = dest;
    _ = header;
    _ = data;
    _ = splat;
    return error.NetworkDown;
}

pub fn virtNetWriteFile(userdata: ?*anyopaque, handle: net.Socket.Handle, header: []const u8, file_reader: *Io.File.Reader, limit: Io.Limit) net.Stream.Writer.WriteFileError!usize {
    _ = userdata;
    _ = handle;
    _ = header;
    _ = file_reader;
    _ = limit;
    return error.NetworkDown;
}

pub fn virtNetClose(userdata: ?*anyopaque, handle: []const net.Socket.Handle) void {
    _ = userdata;
    _ = handle;
    unreachable;
}

pub fn virtNetShutdown(userdata: ?*anyopaque, handle: net.Socket.Handle, how: net.ShutdownHow) net.ShutdownError!void {
    _ = userdata;
    _ = handle;
    _ = how;
    return error.NetworkDown;
}

pub fn virtNetInterfaceNameResolve(userdata: ?*anyopaque, name: *const net.Interface.Name) net.Interface.Name.ResolveError!net.Interface {
    _ = userdata;
    _ = name;
    return error.InterfaceNotFound;
}

pub fn virtNetInterfaceName(userdata: ?*anyopaque, interface: net.Interface) net.Interface.NameError!net.Interface.Name {
    _ = userdata;
    _ = interface;
    unreachable;
}

pub fn virtNetLookup(userdata: ?*anyopaque, host_name: net.HostName, resolved: *Io.Queue(net.HostName.LookupResult), options: net.HostName.LookupOptions) net.HostName.LookupError!void {
    _ = userdata;
    _ = host_name;
    _ = resolved;
    _ = options;
    return error.NetworkDown;
}
