//! Phase 10 final differential structural fuzz-style regression and
//! deterministic cancellation *inside* a large binary list.
//!
//! This is a reproducible randomized oracle test, not a claim that a
//! coverage-guided fuzzing campaign has been completed.
const std = @import("std");
const internal = @import("zply_internals");
const boundary = internal.binary_boundary;
const Layout = internal.layout.ElementLayout;
const Property = internal.property.Property;
const Element = internal.element.Element;
const Header = internal.header.Header;
const Pool = internal.batch_storage.Pool;

const properties = [_]Property{
    Property.scalar("time", .f32),
    Property.list("indices", .u16, .u32),
    Property.list("labels", .u8, .u8),
    Property.scalar("stamp", .f64),
};
const limits: boundary.Limits = .{ .max_record_bytes = 256, .max_list_items_per_record = 32 };

fn compile(props: []const Property) ![]Layout {
    const elements = [_]Element{.{ .name = "entry", .count = 1, .properties = props }};
    const header: Header = .{
        .encoding = .binary_little_endian,
        .version = .{ .major = 1, .minor = 0 },
        .elements = &elements,
    };
    return internal.layout.compileSchema(std.testing.allocator, &header);
}

fn freeLayouts(layouts: []Layout) void {
    for (layouts) |l| std.testing.allocator.free(l.properties);
    std.testing.allocator.free(layouts);
}

const Oracle = union(enum) {
    complete: struct { byte_length: usize, items: usize, counts: [4]usize },
    incomplete: boundary.Incomplete,
    rejected: boundary.ScanError,
};

/// Deliberately independent from the compiled operations, list-count
/// decoder, and boundary scanner. The four-property schema is hard-coded.
/// In particular, this oracle does not call `scanRecord` or decodeListCount.
fn reference(bytes: []const u8, endian: std.builtin.Endian) Oracle {
    if (bytes.len < 4) return .{ .incomplete = .{
        .property_index = 0, .stage = .scalar, .required_total = 4,
    } };
    if (bytes.len < 6) return .{ .incomplete = .{
        .property_index = 1, .stage = .list_count, .required_total = 6,
    } };
    const first_count: usize = if (endian == .little)
        @as(usize, bytes[4]) | (@as(usize, bytes[5]) << 8)
    else
        (@as(usize, bytes[4]) << 8) | @as(usize, bytes[5]);
    if (first_count > limits.max_list_items_per_record)
        return .{ .rejected = error.ListTooLarge };
    const second_count_at = 6 + first_count * 4;
    if (second_count_at > limits.max_record_bytes)
        return .{ .rejected = error.RecordTooLarge };
    if (bytes.len < second_count_at) return .{ .incomplete = .{
        .property_index = 1, .stage = .list_items, .required_total = second_count_at,
    } };
    const second_count_end = second_count_at + 1;
    if (second_count_end > limits.max_record_bytes)
        return .{ .rejected = error.RecordTooLarge };
    if (bytes.len < second_count_end) return .{ .incomplete = .{
        .property_index = 2, .stage = .list_count, .required_total = second_count_end,
    } };
    const second_count: usize = bytes[second_count_at];
    if (second_count > limits.max_list_items_per_record)
        return .{ .rejected = error.ListTooLarge };
    const stamp_at = second_count_end + second_count;
    if (stamp_at > limits.max_record_bytes)
        return .{ .rejected = error.RecordTooLarge };
    if (bytes.len < stamp_at) return .{ .incomplete = .{
        .property_index = 2, .stage = .list_items, .required_total = stamp_at,
    } };
    const end = stamp_at + 8;
    if (end > limits.max_record_bytes) return .{ .rejected = error.RecordTooLarge };
    if (bytes.len < end) return .{ .incomplete = .{
        .property_index = 3, .stage = .scalar, .required_total = end,
    } };
    return .{ .complete = .{
        .byte_length = end, .items = first_count + second_count,
        .counts = .{ 0, first_count, second_count, 0 },
    } };
}

fn compareOracle(layout: *const Layout, endian: std.builtin.Endian, bytes: []const u8) !void {
    const expected = reference(bytes, endian);
    var counts = [_]usize{ 777, 777, 777, 777 };
    const result = boundary.scanRecord(layout, endian, bytes, limits, &counts) catch |err| {
        switch (expected) {
            .rejected => |want| try std.testing.expectEqual(want, err),
            else => return error.UnexpectedStructuralRejection,
        }
        return;
    };
    switch (expected) {
        .rejected => return error.UnexpectedStructuralAcceptance,
        .complete => |want| switch (result) {
            .incomplete => return error.UnexpectedIncomplete,
            .complete => |got| {
                try std.testing.expectEqual(want.byte_length, got.byte_length);
                try std.testing.expectEqual(want.items, got.total_list_items);
                try std.testing.expectEqualSlices(usize, &want.counts, &counts);
            },
        },
        .incomplete => |want| switch (result) {
            .complete => return error.UnexpectedComplete,
            .incomplete => |got| {
                try std.testing.expectEqual(want.property_index, got.property_index);
                try std.testing.expectEqual(want.stage, got.stage);
                try std.testing.expectEqual(want.required_total, got.required_total);
                try std.testing.expect(got.required_total > bytes.len);
            },
        },
    }
}

test "Phase 10 independent reference scanner agrees on 60000 valid, truncated, and mutated binary prefixes" {
    const layouts = try compile(&properties);
    defer freeLayouts(layouts);
    var prng = std.Random.DefaultPrng.init(0x10d1ff2026);
    const random = prng.random();
    var bytes: [256]u8 = undefined;
    inline for (.{ .little, .big }) |endian| {
        for (0..30_000) |trial| {
            random.bytes(&bytes);
            const a = random.intRangeAtMost(usize, 0, 32);
            const b = random.intRangeAtMost(usize, 0, 32);
            std.mem.writeInt(u16, bytes[4..][0..2], @intCast(a), endian);
            const second_at = 6 + 4 * a;
            bytes[second_at] = @intCast(b);
            const valid_end = second_at + 1 + b + 8;
            const input_len: usize = switch (trial % 6) {
                0 => valid_end, // complete valid record
                1 => random.intRangeAtMost(usize, 0, valid_end - 1), // truncation
                2 => blk: { // invalid first count (often exceeds limits)
                    bytes[4] = random.int(u8);
                    bytes[5] = random.int(u8);
                    break :blk random.intRangeAtMost(usize, 6, bytes.len);
                },
                3 => blk: { // invalid second count
                    bytes[second_at] = random.int(u8);
                    break :blk random.intRangeAtMost(usize, second_at + 1, bytes.len);
                },
                4 => blk: { // fully arbitrary bytes
                    random.bytes(&bytes);
                    break :blk random.intRangeAtMost(usize, 0, bytes.len);
                },
                else => random.intRangeAtMost(usize, valid_end, bytes.len), // trailing bytes
            };
            try compareOracle(&layouts[0], endian, bytes[0..input_len]);
        }
    }
}

const CancellationGate = struct {
    flag: *std.atomic.Value(bool),
    reached: bool = false,
    sequence_seen: u64 = 0,

    fn checkpoint(ctx: *anyopaque, sequence: u64, decoded_items: usize) void {
        const self: *CancellationGate = @ptrCast(@alignCast(ctx));
        if (decoded_items == 4096) {
            self.reached = true;
            self.sequence_seen = sequence;
            self.flag.store(true, .release);
        }
    }
};

test "Phase 10 binary decoder cancels inside a large list without publishing partial columns" {
    const props = [_]Property{Property.list("items", .u32, .i32)};
    const layouts = try compile(&props);
    defer freeLayouts(layouts);
    const item_count: usize = 16_384;
    const raw = try std.testing.allocator.alloc(u8, 4 + item_count * 4);
    defer std.testing.allocator.free(raw);
    std.mem.writeInt(u32, raw[0..4], @intCast(item_count), .big);
    for (0..item_count) |i| {
        std.mem.writeInt(i32, raw[4 + i * 4 ..][0..4], @intCast(i), .big);
    }
    const offsets = [_]usize{ 0, raw.len };
    const totals = [_]usize{item_count};
    const pool = try Pool.create(std.testing.allocator);
    defer pool.destroy();
    const id = try pool.acquireBinaryVariableSized(&layouts[0], &props, 1, &totals);
    var task: internal.execution.DecodeTask = .{
        .sequence = 17,
        .element_index = 0,
        .first_record = 0,
        .record_count = 1,
        .encoding = .binary_variable,
        .input = raw,
        .binary_boundaries = &offsets,
        .binary_totals = &totals,
        .layout = &layouts[0],
        .endian = .big,
        .pool = pool,
        .slot_id = id,
        .target = pool.target(id),
    };
    var gate: CancellationGate = .{ .flag = &task.cancel_requested };
    const hooks: internal.fault_injection.Hooks = .{
        .context = &gate,
        .list_item_checkpoint = CancellationGate.checkpoint,
    };
    task.test_hooks = &hooks;
    try std.testing.expectError(error.Cancelled, task.execute());
    try std.testing.expect(gate.reached);
    try std.testing.expectEqual(@as(u64, 17), gate.sequence_seen);
    try std.testing.expectEqual(internal.execution.task.State.cancelled, task.state);
    try std.testing.expect(task.failure.? == error.Cancelled);
    pool.cancel(id); // no partially decoded batch was ever published

    // Verify the same pool can safely prepare and publish a fresh complete
    // batch after reclaiming the cancelled, partially written destination.
    const replacement = try pool.acquireBinaryVariableSized(&layouts[0], &props, 1, &totals);
    try Pool.decodePreparedBinaryVariable(
        pool.target(replacement), &layouts[0], .big, raw, &offsets, &totals, null,
    );
    var batch = pool.publish(replacement, .{
        .element_index = 0, .first_record = 0, .record_count = 1, .sequence = 18,
    });
    defer batch.release();
    const list_column = try batch.listColumn(0);
    const values = list_column.row(0).?.i32;
    try std.testing.expectEqual(item_count, values.len);
    try std.testing.expectEqual(@as(i32, 0), values[0]);
    try std.testing.expectEqual(@as(i32, @intCast(item_count - 1)), values[item_count - 1]);
}

// Coverage-guided fuzz targets. They share the existing hard-coded reference
// scanner, not the optimized layout/scan operations under test. These are
// deliberately separate from the deterministic 60,000-case regression.
//
// The raw target explores arbitrary count bytes, short prefixes and rejected
// records. The structured target keeps most count fields in range so that the
// fuzzer also reaches list payloads, trailing scalar fields and full records.
// Both targets are allocation-bounded and can be filtered independently.
fn fuzzRawRecord(_: void, smith: *std.testing.Smith) !void {
    const layouts = try compile(&properties);
    defer freeLayouts(layouts);

    const endian: std.builtin.Endian = if (smith.value(bool)) .little else .big;
    const len: usize = smith.value(u8);
    var bytes: [256]u8 = undefined;
    smith.bytes(bytes[0..len]);

    try compareOracle(&layouts[0], endian, bytes[0..len]);
    try compareIncremental(&layouts[0], endian, bytes[0..len]);
}

fn fuzzStructuredRecord(_: void, smith: *std.testing.Smith) !void {
    const layouts = try compile(&properties);
    defer freeLayouts(layouts);

    const endian: std.builtin.Endian = if (smith.value(bool)) .little else .big;
    const first_count: usize = smith.valueRangeAtMost(u8, 0, 32);
    const second_count: usize = smith.valueRangeAtMost(u8, 0, 32);
    const mode: u8 = smith.valueRangeAtMost(u8, 0, 7);
    const variation: usize = smith.value(u8);

    var bytes: [256]u8 = undefined;
    smith.bytes(&bytes);
    std.mem.writeInt(u16, bytes[4..6], @intCast(first_count), endian);
    const second_at = 6 + first_count * 4;
    bytes[second_at] = @intCast(second_count);
    const end = second_at + 1 + second_count + 8;

    const len: usize = switch (mode) {
        0 => end, // complete, valid record
        1 => variation % end, // truncated anywhere in the record
        2 => end + variation % (bytes.len - end + 1), // trailing bytes
        3 => blk: { // invalid or exceptionally large first count
            std.mem.writeInt(u16, bytes[4..6], smith.value(u16), endian);
            break :blk variation;
        },
        4 => blk: { // invalid second count
            bytes[second_at] = smith.value(u8);
            break :blk variation;
        },
        5 => variation % 7, // truncated first scalar / list count
        6 => second_at + variation % (bytes.len - second_at + 1),
        else => end - variation % 9, // final scalar truncation
    };

    try compareOracle(&layouts[0], endian, bytes[0..len]);
    try compareIncremental(&layouts[0], endian, bytes[0..len]);
}

/// Independently check the non-seekable record assembler against the same
/// reference result. A complete record must consume precisely its declared
/// width, leaving all trailing bytes untouched. Truncation must consume the
/// available prefix and fail with the structural stage's specific error.
fn compareIncremental(layout: *const Layout, endian: std.builtin.Endian, bytes: []const u8) !void {
    const expected = reference(bytes, endian);
    var source = std.Io.Reader.fixed(bytes);
    var reader: internal.binary_variable.Reader = .{};
    defer reader.deinit(std.testing.allocator);

    const actual = reader.readRecord(std.testing.allocator, &source, layout, endian, limits) catch |got| {
        try std.testing.expect(reader.failed);
        switch (expected) {
            .complete => return error.UnexpectedIncrementalRejection,
            .rejected => |want| try std.testing.expectEqual(want, got),
            .incomplete => |want| {
                const failure: anyerror = switch (want.stage) {
                    .scalar => error.TruncatedRecord,
                    .list_count => error.TruncatedListCount,
                    .list_items => error.TruncatedListPayload,
                };
                try std.testing.expectEqual(failure, got);
                try std.testing.expectEqual(@as(u64, @intCast(bytes.len)), reader.body_bytes_consumed);
            },
        }
        return;
    };

    switch (expected) {
        .complete => |want| {
            try std.testing.expect(!reader.failed);
            try std.testing.expectEqual(want.byte_length, actual.bytes.len);
            try std.testing.expectEqual(want.items, actual.total_list_items);
            try std.testing.expectEqual(@as(u64, @intCast(want.byte_length)), reader.body_bytes_consumed);
            try std.testing.expectEqual(want.byte_length, source.seek);
            try std.testing.expectEqualSlices(u8, bytes[0..want.byte_length], actual.bytes);
        },
        else => return error.UnexpectedIncrementalAcceptance,
    }
}

test "Phase 10 fuzz raw binary variable record and incremental assembler" {
    try std.testing.fuzz({}, fuzzRawRecord, .{
        .corpus = &.{ "", "\x00", "\xff\xff\xff\xff\xff\xff", "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00" },
    });
}

test "Phase 10 fuzz structured binary variable record and incremental assembler" {
    try std.testing.fuzz({}, fuzzStructuredRecord, .{
        .corpus = &.{ "", "\x01", "\x00\x00\x00\x00", "\xff\xff\xff\xff\xff\xff\xff\xff" },
    });
}
