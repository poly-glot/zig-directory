const std = @import("std");
const posix = std.posix;

/// Atomic flag indicating whether a shutdown has been requested.
var shutdown_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

/// Self-pipe used to wake epoll on shutdown signal.
/// Index 0 is the read end (registered with epoll), index 1 is the write end (written by signal handler).
var shutdown_pipe: [2]posix.fd_t = .{ -1, -1 };

/// Install signal handlers for SIGINT and SIGTERM that set the shutdown flag
/// and write a byte to the self-pipe to wake the epoll loop.
pub fn setupSignalHandlers() !void {
    // Create the self-pipe with CLOEXEC and NONBLOCK.
    shutdown_pipe = try posix.pipe2(.{
        .CLOEXEC = true,
        .NONBLOCK = true,
    });

    const sa = posix.Sigaction{
        .handler = .{ .handler = handleSignal },
        .mask = posix.sigemptyset(),
        .flags = std.os.linux.SA.RESTART,
    };

    posix.sigaction(posix.SIG.INT, &sa, null);
    posix.sigaction(posix.SIG.TERM, &sa, null);
}

/// Signal handler function. Must be async-signal-safe.
fn handleSignal(_: c_int) callconv(.c) void {
    shutdown_flag.store(true, .release);
    // Write a single byte to wake the epoll loop. Ignore errors (pipe full or closed).
    const write_fd = shutdown_pipe[1];
    if (write_fd != -1) {
        _ = posix.write(write_fd, &[_]u8{1}) catch {};
    }
}

/// Returns true if a shutdown has been requested via signal.
pub fn shutdownRequested() bool {
    return shutdown_flag.load(.acquire);
}

/// Returns the read end of the shutdown pipe for epoll registration.
pub fn getShutdownPipeFd() posix.fd_t {
    return shutdown_pipe[0];
}

/// Close the shutdown pipe file descriptors.
pub fn closeShutdownPipe() void {
    if (shutdown_pipe[0] != -1) {
        posix.close(shutdown_pipe[0]);
        shutdown_pipe[0] = -1;
    }
    if (shutdown_pipe[1] != -1) {
        posix.close(shutdown_pipe[1]);
        shutdown_pipe[1] = -1;
    }
}

test "shutdownRequested default is false" {
    try std.testing.expect(!shutdownRequested());
}
