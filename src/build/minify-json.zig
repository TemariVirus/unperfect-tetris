const std = @import("std");
const json = std.json;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.next().?; // Executable path
    const path = args.next() orelse return error.MissingJsonPath;
    const output_path = args.next() orelse return error.MissingOutputPath;

    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    var reader = json.reader(allocator, file.reader());
    defer reader.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const value = try json.Value.jsonParse(
        arena.allocator(),
        &reader,
        .{ .max_value_len = 1_000_000 },
    );

    const output_file = try std.fs.cwd().createFile(output_path, .{});
    defer output_file.close();
    var writer = json.writeStream(
        output_file.writer(),
        .{ .whitespace = .minified },
    );
    try value.jsonStringify(&writer);
}
