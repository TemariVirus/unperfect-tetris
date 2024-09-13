const std = @import("std");
const Allocator = std.mem.Allocator;
const SolutionList = std.ArrayList([]Placement);
const time = std.time;

const engine = @import("engine");
const GameState = Player.GameState;
const kicks = engine.kicks;
const Player = engine.Player(SevenBag);
const SevenBag = engine.bags.SevenBag;

const nterm = @import("nterm");
const Colors = nterm.Colors;
const View = nterm.View;

const root = @import("perfect-tetris");
const NN = root.NN;
const pc = root.pc;
const Placement = root.Placement;

const getNnOrDefault = @import("main.zig").getNnOrDefault;
const PeriodicTrigger = @import("PeriodicTrigger.zig");

const FRAMERATE = 60;
const FPS_TIMING_WINDOW = FRAMERATE * 2;
/// The maximum number of perfect clears to calculate in advance.
const MAX_PC_QUEUE = 128;

pub const DemoArgs = struct {
    help: bool = false,
    nn: ?[]const u8 = null,
    pps: u32 = 10,

    pub const wrap_len: u32 = 45;

    pub const shorthands = .{
        .h = "help",
        .n = "nn",
        .p = "pps",
    };

    pub const meta = .{
        .usage_summary = "demo [options]",
        .full_text = "Demostrates the perfect clear solver's speed with a tetris playing bot.",
        .option_docs = .{
            .help = "Print this help message.",
            .nn = "The path to the neural network to use for the bot. If not provided, a default built-in network will be used.",
            .pps = std.fmt.comptimePrint("The target pieces per second of the bot. (default: {})", .{(DemoArgs{}).pps}),
        },
    };
};

pub fn main(allocator: Allocator, args: DemoArgs) !void {
    const nn = try getNnOrDefault(allocator, args.nn);
    defer nn.deinit(allocator);

    // Add 2 to create a 1-wide empty boarder on the left and right.
    try nterm.init(
        allocator,
        std.io.getStdOut(),
        FRAMERATE * 2,
        Player.DISPLAY_W + 2,
        Player.DISPLAY_H,
        null,
        null,
    );
    defer nterm.deinit();

    const settings = engine.GameSettings{
        .g = 0,
        .display_stats = .{
            .pps,
            .app,
            .sent,
        },
        .target_mode = .none,
    };
    const player_view = View{
        .left = 1,
        .top = 0,
        .width = Player.DISPLAY_W,
        .height = Player.DISPLAY_H,
    };
    var player = Player.init(
        "PC Solver",
        SevenBag.init(0),
        kicks.srsPlus,
        settings,
        player_view,
        playSfxDummy,
    );

    var placement_i: usize = 0;
    var pc_queue = try SolutionList.initCapacity(allocator, MAX_PC_QUEUE);
    defer pc_queue.deinit();

    const pc_thread = try std.Thread.spawn(.{
        .allocator = allocator,
    }, pcThread, .{ allocator, nn, player.state, &pc_queue });
    pc_thread.detach();

    const fps_view = View{
        .left = 1,
        .top = 0,
        .width = 15,
        .height = 1,
    };

    var render_timer = PeriodicTrigger.init(time.ns_per_s / FRAMERATE, true);
    var place_timer = PeriodicTrigger.init(time.ns_per_s / args.pps, false);
    while (true) {
        var triggered = false;

        if (render_timer.trigger()) |dt| {
            triggered = true;
            player.tick(dt, 0, &.{});

            fps_view.printAt(0, 0, Colors.WHITE, null, "{d:.2}FPS", .{nterm.fps()});
            player.draw();
            nterm.render() catch |err| {
                // Trying to render after the terminal has been closed results
                // in an error, in which case stop the program gracefully.
                if (err == error.NotInitialized) {
                    return;
                }
                return err;
            };
        }
        while (place_timer.trigger()) |_| {
            triggered = true;
            placePcPiece(allocator, &player, &pc_queue, &placement_i);
        }

        if (!triggered) {
            time.sleep(1 * time.ns_per_ms);
        }
    }
}

fn placePcPiece(
    allocator: Allocator,
    game: *Player,
    queue: *SolutionList,
    placement_i: *usize,
) void {
    if (queue.items.len == 0) {
        return;
    }
    const placements = queue.items[0];

    const placement = placements[placement_i.*];
    if (placement.piece.kind != game.state.current.kind) {
        game.hold();
    }
    game.state.pos = placement.pos;
    game.state.current = placement.piece;
    game.hardDrop(0, &.{});
    placement_i.* += 1;

    // Start next perfect clear
    if (placement_i.* == placements.len) {
        allocator.free(queue.orderedRemove(0));
        placement_i.* = 0;
    }
}

fn pcThread(allocator: Allocator, nn: NN, state: GameState, queue: *SolutionList) !void {
    var game = state;

    while (true) {
        while (queue.items.len >= MAX_PC_QUEUE) {
            time.sleep(time.ns_per_ms);
        }

        // A 2- or 4-line PC is not always possible. 15 placements is enough
        // for a 6-line PC.
        const placements = try allocator.alloc(Placement, 15);
        const solution = try pc.findPc(SevenBag, allocator, game, nn, 0, placements);
        for (solution) |placement| {
            if (game.current.kind != placement.piece.kind) {
                game.hold();
            }
            game.current = placement.piece;
            game.pos = placement.pos;
            _ = game.lockCurrent(-1);
            game.nextPiece();
        }

        _ = allocator.resize(placements, solution.len);
        try queue.append(solution);
    }
}

/// Dummy function to satisfy the Player struct.
fn playSfxDummy(_: engine.player.Sfx) void {}
