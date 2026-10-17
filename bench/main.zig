const std = @import("std");
const seed = @import("workloads/seed.zig");
const create_link = @import("workloads/create_link.zig");
const bulk_import = @import("workloads/bulk_import.zig");
const get_link = @import("workloads/get_link.zig");
const browse = @import("workloads/browse.zig");
const search = @import("workloads/search.zig");
const mixed = @import("workloads/mixed.zig");
const cold = @import("workloads/cold.zig");
const common = @import("common.zig");

pub fn main(init: std.process.Init) !void {
    const env = common.Env{
        .io = init.io,
        .allocator = init.gpa,
        .environ = init.environ_map,
        .hostname = init.environ_map.get("HOSTNAME") orelse "unknown",
    };

    var args = init.minimal.args.iterate();
    _ = args.skip();

    const sub = args.next() orelse {
        printHelp();
        return;
    };
    if (std.mem.eql(u8, sub, "--help") or std.mem.eql(u8, sub, "-h")) {
        printHelp();
        return;
    }
    if (std.mem.eql(u8, sub, "seed")) return seed.run(env, &args);
    if (std.mem.eql(u8, sub, "create_link")) return create_link.run(env, &args);
    if (std.mem.eql(u8, sub, "bulk_import")) return bulk_import.run(env, &args);
    if (std.mem.eql(u8, sub, "get_link")) return get_link.run(env, &args);
    if (std.mem.eql(u8, sub, "browse")) return browse.run(env, &args);
    if (std.mem.eql(u8, sub, "search")) return search.run(env, &args);
    if (std.mem.eql(u8, sub, "mixed")) return mixed.run(env, &args);
    if (std.mem.eql(u8, sub, "cold")) return cold.run(env, &args);

    std.debug.print("Unknown subcommand: {s}\n\n", .{sub});
    printHelp();
    return error.UnknownSubcommand;
}

fn printHelp() void {
    const help =
        \\bench - dmozdb benchmark harness
        \\
        \\Usage:
        \\  bench seed         [opts]
        \\  bench create_link  [opts]
        \\  bench bulk_import  [--count N] [--batch-size M]    Stream items via op=24
        \\  bench get_link     [opts]
        \\  bench browse       --kind {path|children|subtree-links} [opts]
        \\  bench search       --target {links|categories} [opts]
        \\  bench mixed        --read-pct PCT [opts]
        \\  bench cold         --kind {cache|boot} --server-cmd CMD [opts]
        \\
        \\Common options:
        \\  --profile {1cpu2gb|2cpu4gb|unconstrained}    Tag the JSON record (does NOT enforce)
        \\  --output PATH        Append JSON Lines records to PATH (default: stdout)
        \\  --workers W          Concurrent client connections (default: 4)
        \\  --ops-per-worker N   Ops per worker (default: 10000)
        \\  --warmup-ops N       Discard first N ops from percentile recording (default: 1000)
        \\  --connect-host HOST  (default: 127.0.0.1)
        \\  --port P             (default: 8080)
        \\  --rss-sample-ms MS   (default: 200, 0 to disable)
        \\  --git-rev REV        Override auto-detected git rev
        \\
        \\See bench/README.md for matrix-runner examples.
        \\
    ;
    std.debug.print("{s}", .{help});
}
