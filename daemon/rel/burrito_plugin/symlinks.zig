const std = @import("std");

const io = std.Options.debug_io;

const Link = struct { []const u8, []const u8 };

const manifest: []const Link = @import("symlinks.zon");

pub fn burrito_plugin_entry(install_dir: []const u8, program_manifest_json: []const u8) void {
    _ = program_manifest_json;

    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    for (manifest) |l| {
        const link, const target = l;
        ensure_link(arena, install_dir, link, target) catch |err| {
            warn("symlinks: failed to create {s} -> {s}: {t}", .{ link, target, err });
        };
    }
}

fn ensure_link(arena: std.mem.Allocator, install_dir: []const u8, link_rel: []const u8, target: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    const link_path = try std.fs.path.join(arena, &.{ install_dir, link_rel });

    if (std.fs.path.dirname(link_path)) |parent| try cwd.createDirPath(io, parent);

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (cwd.readLink(io, link_path, &buf)) |n| {
        if (std.mem.eql(u8, buf[0..n], target)) return;
    } else |err| switch (err) {
        error.FileNotFound, error.NotLink => {},
        else => return err,
    }

    try cwd.symLinkAtomic(io, target, link_path, .{});
    std.log.debug("symlinks: {s} -> {s}", .{ link_path, target });
}

fn warn(comptime fmt: []const u8, args: anytype) void {
    var buf: [128]u8 = undefined;
    var w = std.Io.File.stderr().writer(io, &buf);
    w.interface.print("[w] " ++ fmt ++ "\n", args) catch {};
    w.interface.flush() catch {};
}
