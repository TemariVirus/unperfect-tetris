const std = @import("std");
const Allocator = std.mem.Allocator;
const AtomicBool = std.atomic.Value(bool);
const fs = std.fs;
const json = std.json;
const Mutex = std.Thread.Mutex;
const os = std.os;
const SIG = os.linux.SIG;
const time = std.time;

const engine = @import("engine");
const GameState = engine.GameState(SevenBag);
const SevenBag = engine.bags.SevenBag;

const zmai = @import("zmai");
const neat = zmai.genetic.neat;
const Trainer = neat.Trainer;

const root = @import("root.zig");
const NN = root.NN;
const pc = root.pc;

const THREADS = std.Thread.getCpuCount() catch unreachable;
const SAVE_DIR = "pops/";
const GENERATIONS = 100;
const POPULATION_SIZE = 300;
const OPTIONS = Trainer.Options{
    .species_target = 12,
    .nn_options = .{
        .input_count = 5,
        .output_count = 1,
        .hidden_activation = .relu,
        .output_activation = .identity,
    },
};

var is_saving = AtomicBool.init(false);

const SaveJson = struct {
    seed: u64,
    trainer: Trainer.TrainerJson,
    fitnesses: []const ?f64,
};

pub fn main() !void {
    setupExitHandler();
    zmai.setRandomSeed(std.crypto.random.int(u64));
    std.debug.print("{}\n", .{THREADS});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var trainer, const fitnesses, var seed = try loadOrInit(
        allocator,
        SAVE_DIR ++ "current.json",
        POPULATION_SIZE,
        OPTIONS,
    );
    defer trainer.deinit();
    defer allocator.free(fitnesses);

    var fitnesses_lock = Mutex{};

    var threads: [THREADS]std.Thread = undefined;
    for (&threads) |*thread| {
        thread.* = try std.Thread.spawn(
            .{ .allocator = allocator },
            doWork,
            .{ &seed, &trainer, fitnesses, &fitnesses_lock },
        );
    }
    defer for (threads) |thread| {
        thread.join();
    };

    while (trainer.generation < GENERATIONS) {
        // Wait for all fitnesses to be calculated
        outer: while (true) {
            for (fitnesses) |fit| {
                if (std.math.isNan(fit orelse break)) {
                    break;
                }
            } else break :outer;

            // Save once every 500ms
            try save(allocator, SAVE_DIR ++ "current.json", seed, trainer, fitnesses);
            time.sleep(500 * time.ns_per_ms);
        }

        const path = try std.fmt.allocPrint(allocator, "{s}{}.json", .{ SAVE_DIR, trainer.generation });
        defer allocator.free(path);
        try save(allocator, path, seed, trainer, fitnesses);

        const final_fitnesses = try allocator.alloc(f64, fitnesses.len);
        defer allocator.free(final_fitnesses);
        for (0..fitnesses.len) |i| {
            final_fitnesses[i] = fitnesses[i] orelse unreachable;
        }

        seed = std.crypto.random.int(u64);
        if (trainer.generation != GENERATIONS - 1) {
            try trainer.nextGeneration(final_fitnesses);
        }
        printGenerationStats(trainer, final_fitnesses);

        fitnesses_lock.lock();
        @memset(fitnesses, null);
        fitnesses_lock.unlock();
    }
}

fn setupExitHandler() void {
    if (@import("builtin").os.tag == .windows) {
        const signal = struct {
            extern "c" fn signal(
                sig: c_int,
                func: *const fn (c_int, c_int) callconv(os.windows.WINAPI) void,
            ) callconv(.C) *anyopaque;
        }.signal;
        _ = signal(SIG.INT, handleExitWindows);
    } else {
        const action = os.linux.Sigaction{
            .handler = .{ .handler = handleExit },
            .mask = os.linux.empty_sigset,
            .flags = 0,
        };
        _ = os.linux.sigaction(SIG.INT, &action, null);
    }
}

fn handleExit(sig: c_int) callconv(.C) void {
    switch (sig) {
        SIG.INT => {
            // Wait for save to finish
            while (is_saving.raw) {}
            std.process.exit(0);
        },
        // This handler is only registered for SIG.INT
        else => unreachable,
    }
}

fn handleExitWindows(sig: c_int, _: c_int) callconv(.C) void {
    handleExit(sig);
}

fn loadOrInit(
    allocator: Allocator,
    path: []const u8,
    population_size: usize,
    options: Trainer.Options,
) !struct { Trainer, []?f64, u64 } {
    // Init if file does not exist
    fs.cwd().access(path, .{}) catch |e| if (e == fs.Dir.AccessError.FileNotFound) {
        var trainer = try Trainer.init(allocator, population_size, 1.0, options);
        errdefer trainer.deinit();
        const fitnesses = try allocator.alloc(?f64, population_size);
        @memset(fitnesses, null);
        return .{
            trainer,
            fitnesses,
            std.crypto.random.int(u64),
        };
    } else return e;

    const file = try fs.cwd().openFile(path, .{});
    defer file.close();

    var reader = json.reader(allocator, file.reader());
    defer reader.deinit();

    const parsed = try json.parseFromTokenSource(
        SaveJson,
        allocator,
        &reader,
        .{},
    );
    defer parsed.deinit();

    var trainer = try Trainer.from(allocator, parsed.value.trainer);
    trainer.options = options;
    errdefer trainer.deinit();

    const fitnesses = try allocator.alloc(?f64, trainer.population.len);
    @memcpy(fitnesses[0..parsed.value.fitnesses.len], parsed.value.fitnesses);
    @memset(fitnesses[parsed.value.fitnesses.len..], null);
    // Unset any NaNs from previous runs
    for (fitnesses) |*fit| {
        if (fit.* != null and std.math.isNan(fit.*)) {
            fit.* = null;
        }
    }

    return .{
        trainer,
        fitnesses,
        parsed.value.seed,
    };
}

fn save(
    allocator: Allocator,
    path: []const u8,
    seed: u64,
    trainer: Trainer,
    fitnesses: []const ?f64,
) !void {
    is_saving.store(true, .monotonic);
    defer is_saving.store(false, .monotonic);

    const trainer_json = try Trainer.TrainerJson.init(allocator, trainer);
    defer trainer_json.deinit(allocator);

    try fs.cwd().makePath(std.fs.path.dirname(path) orelse return error.InvalidPath);
    const file = try fs.cwd().createFile(path, .{});
    defer file.close();

    try json.stringify(SaveJson{
        .seed = seed,
        .trainer = trainer_json,
        .fitnesses = fitnesses,
    }, .{}, file.writer());
}

fn getFitness(allocator: Allocator, seed: u64, nn: NN) !f64 {
    const RUN_COUNT = 10;

    var rand = std.Random.DefaultPrng.init(seed);
    var timer = try time.Timer.start();
    for (0..RUN_COUNT) |_| {
        const gamestate = GameState.init(
            SevenBag.init(rand.next()),
            engine.kicks.srsPlus,
        );

        // Optimize for 4 line PCs (but not all states have a 4 line PC so
        // provide extra pieces for a 6 line PC)
        const solution = try pc.findPc(allocator, gamestate, nn, 4, 16);
        std.mem.doNotOptimizeAway(solution);
        allocator.free(solution);
    }

    // Return solutions/s as fitness
    const time_taken: f64 = @floatFromInt(timer.read());
    // Add 1ms to avoid division by zero
    return time.ns_per_s / (time_taken + time.ns_per_ms);
}

fn printGenerationStats(trainer: Trainer, fitnesses: []const f64) void {
    var avg_fitness: f64 = 0;
    for (fitnesses) |f| {
        avg_fitness += f;
    }
    avg_fitness /= @floatFromInt(fitnesses.len);

    std.debug.print("\nGen {}, Species: {}, Avg fit: {d:.4}, Max Fit: {d:.4}\n\n", .{
        trainer.generation,
        trainer.species.len,
        avg_fitness,
        std.mem.max(f64, fitnesses),
    });
}

fn doWork(
    seed: *const u64,
    trainer: *const Trainer,
    fitnesses: []?f64,
    fitnesses_lock: *Mutex,
) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    while (true) {
        const i = blk: {
            fitnesses_lock.lock();
            defer fitnesses_lock.unlock();

            for (fitnesses, 0..) |fit, i| {
                if (fit == null) {
                    // Reserve this index by setting it to NaN
                    fitnesses[i] = std.math.nan(f64);
                    break :blk i;
                }
            }
            break :blk trainer.population.len;
        };
        // Wait for work if all fitnesses have been calculated
        if (i == trainer.population.len) {
            time.sleep(time.ns_per_ms);
            continue;
        }

        // Update fitness of genome i
        var inputs_used: [OPTIONS.nn_options.input_count]bool = undefined;
        var nn = try neat.NN.init(
            allocator,
            trainer.population[i],
            OPTIONS.nn_options,
            &inputs_used,
        );
        defer nn.deinit(allocator);

        const fitness = try getFitness(allocator, seed.*, .{
            .inputs_used = inputs_used,
            .net = nn,
        });
        fitnesses[i] = fitness;
        std.debug.print("NN {}: {d:.4}\n", .{ i, fitness });
    }
}
