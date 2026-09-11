//! Burrito plugin: recreate the symlinks that `mix release` dereferenced and
//! Burrito's FOILZ archiver cannot carry.
//!
//! The manifest (`symlinks.zon`) is written next to this file by
//! `rel/symlinks.exs` and imported at wrapper build time.
//!
//! Burrito calls `burrito_plugin_entry` on EVERY launch, BEFORE the payload is
//! unpacked on first run (see burrito/src/wrapper.zig). That ordering is what
//! makes this work: we create (possibly dangling) links first, the archiver's
//! create_dirs tolerates already-existing directories, and the payload holds
//! no file at any link path (the release step removed the copies), so
//! unpacking never overwrites a link. Zig 0.16 std.Io API, as used by Burrito 1.6.
const std = @import("std");
const Io = std.Io;

const Link = struct { []const u8, []const u8 };

const manifest: []const Link = @import("symlinks.zon");

pub fn burrito_plugin_entry(install_dir: []const u8, program_manifest_json: []const u8) void {
    _ = program_manifest_json;

    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();

    apply(std.Options.debug_io, arena_state.allocator(), install_dir, manifest);
}

fn apply(io: Io, arena: std.mem.Allocator, install_dir: []const u8, links: []const Link) void {
    for (links) |l| {
        const link, const target = l;
        ensure_link(io, arena, install_dir, link, target) catch |err| {
            warn("symlinks: failed to create {s} -> {s}: {t}", .{ link, target, err });
        };
    }
}

fn ensure_link(io: Io, arena: std.mem.Allocator, install_dir: []const u8, link_rel: []const u8, target: []const u8) !void {
    const cwd = Io.Dir.cwd();
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
    var w = Io.File.stderr().writer(std.Options.debug_io, &buf);
    w.interface.print("[w] " ++ fmt ++ "\n", args) catch {};
    w.interface.flush() catch {};
}
