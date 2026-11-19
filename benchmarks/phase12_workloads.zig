//! Phase 12 M3: extended workload matrix for the unified harness.
//!
//! The seven Phase 11 workloads remain in `phase11_performance.zig` and keep
//! their `bench-phase11` CSV contract untouched. This module adds wide,
//! mixed-type, multi-element, large-list and varied-ASCII-text fixtures using
//! the same measurement protocol.
//!
//! Every fixture is generated from a pure value model. The verified consumer
//! recomputes that model and compares each decoded scalar bit-for-bit before
//! folding it into an order-independent digest, so a decode regression cannot
//! hide behind a matching aggregate.
const std = @import("std");
const zply = @import("zply");
const digest_util = @import("digest.zig");
const timing = @import("timing.zig");
const m16 = @import("phase11_performance.zig");
const minimal_consumer = @import("minimal_consumer.zig");

const mix = digest_util.mix;
const Digest = digest_util.Digest;
const ScalarType = zply.ScalarType;
const IntegerType = zply.IntegerType;

pub const Kind = enum {
    /// Six float32 normal components per record (24-byte fixed records).
    binary_normals,
    /// Mixed-width scalars: uchar, short, ushort, int, uint, float, double.
    binary_wide,
    /// Two elements in one file: fixed vertex records then face lists.
    binary_mixed_elements,
    /// A single list property with up to 64 items and a double tail scalar.
    binary_large_lists,
    /// Two list properties with different count and item types.
    binary_multi_list,
    /// ASCII integer properties covering every integer width.
    ascii_ints,
    /// ASCII decimal-exponent spellings with exactly representable values.
    ascii_scientific,
    /// Long ASCII records with 20 numeric tokens.
    ascii_long,
    /// Wide mixed ASCII records: floats, integers and doubles.
    ascii_wide,

    pub fn isAscii(self: Kind) bool {
        return switch (self) {
            .ascii_ints, .ascii_scientific, .ascii_long, .ascii_wide => true,
            else => false,
        };
    }

    pub fn isList(self: Kind) bool {
        return switch (self) {
            .binary_mixed_elements, .binary_large_lists, .binary_multi_list => true,
            else => false,
        };
    }

    fn encoding(self: Kind) []const u8 {
        return if (self.isAscii()) "ascii" else "binary_little_endian";
    }
};

pub const workloads = [_]Kind{
    .binary_normals,
    .binary_wide,
    .binary_mixed_elements,
    .binary_large_lists,
    .binary_multi_list,
    .ascii_ints,
    .ascii_scientific,
    .ascii_long,
    .ascii_wide,
};

pub const ListKind = struct {
    count: IntegerType,
    item: ScalarType,
};

pub const PropKind = union(enum) {
    scalar: ScalarType,
    list: ListKind,
};

pub const Prop = struct {
    name: []const u8,
    kind: PropKind,
};

pub const ElementSchema = struct {
    name: []const u8,
    props: []const Prop,
};

fn scalar(name: []const u8, tag: ScalarType) Prop {
    return .{ .name = name, .kind = .{ .scalar = tag } };
}

fn list(name: []const u8, count: IntegerType, item: ScalarType) Prop {
    return .{ .name = name, .kind = .{ .list = .{ .count = count, .item = item } } };
}

const normals_props = [_]Prop{
    scalar("x", .f32),  scalar("y", .f32),  scalar("z", .f32),
    scalar("nx", .f32), scalar("ny", .f32), scalar("nz", .f32),
};

const wide_props = [_]Prop{
    scalar("r", .u8),    scalar("g", .u8),       scalar("b", .u8),
    scalar("sx", .i16),  scalar("sy", .i16),     scalar("ux", .u16),
    scalar("uy", .u16),  scalar("ix", .i32),     scalar("iy", .i32),
    scalar("ux2", .u32), scalar("x", .f32),      scalar("y", .f32),
    scalar("z", .f32),   scalar("weight", .f64),
};

const vertex_props = [_]Prop{
    scalar("x", .f32),
    scalar("y", .f32),
    scalar("z", .f32),
};

const face_props = [_]Prop{
    list("indices", .u8, .i32),
    scalar("material", .u8),
};

const large_face_props = [_]Prop{
    list("indices", .u32, .i32),
    scalar("area", .f64),
};

const multi_list_props = [_]Prop{
    list("indices", .u8, .i32),
    list("weights", .u16, .f32),
    scalar("material", .u16),
};

const ascii_int_props = [_]Prop{
    scalar("c", .i8),   scalar("uc", .u8), scalar("s", .i16),
    scalar("us", .u16), scalar("i", .i32), scalar("ui", .u32),
};

const ascii_scientific_props = [_]Prop{
    scalar("x", .f32),
    scalar("y", .f32),
    scalar("z", .f32),
};

const ascii_long_props = [_]Prop{
    scalar("f00", .f32), scalar("f01", .f32), scalar("f02", .f32),
    scalar("f03", .f32), scalar("f04", .f32), scalar("f05", .f32),
    scalar("f06", .f32), scalar("f07", .f32), scalar("f08", .f32),
    scalar("f09", .f32), scalar("f10", .f32), scalar("f11", .f32),
    scalar("i00", .i32), scalar("i01", .i32), scalar("i02", .i32),
    scalar("i03", .i32), scalar("u00", .u16), scalar("u01", .u16),
    scalar("u02", .u16), scalar("u03", .u16),
};

const ascii_wide_props = [_]Prop{
    scalar("x", .f32),      scalar("y", .f32),      scalar("z", .f32),
    scalar("r", .u8),       scalar("g", .u8),       scalar("b", .u8),
    scalar("ix", .i32),     scalar("iy", .i32),     scalar("iz", .i32),
    scalar("weight", .f64), scalar("height", .f64), scalar("radius", .f64),
};

const normals_elements = [_]ElementSchema{.{ .name = "vertex", .props = &normals_props }};
const wide_elements = [_]ElementSchema{.{ .name = "vertex", .props = &wide_props }};
const mixed_elements = [_]ElementSchema{
    .{ .name = "vertex", .props = &vertex_props },
    .{ .name = "face", .props = &face_props },
};
const large_list_elements = [_]ElementSchema{.{ .name = "face", .props = &large_face_props }};
const multi_list_elements = [_]ElementSchema{.{ .name = "face", .props = &multi_list_props }};
const ascii_int_elements = [_]ElementSchema{.{ .name = "vertex", .props = &ascii_int_props }};
const ascii_scientific_elements = [_]ElementSchema{.{ .name = "vertex", .props = &ascii_scientific_props }};
const ascii_long_elements = [_]ElementSchema{.{ .name = "vertex", .props = &ascii_long_props }};
const ascii_wide_elements = [_]ElementSchema{.{ .name = "vertex", .props = &ascii_wide_props }};

pub fn schema(kind: Kind) []const ElementSchema {
    return switch (kind) {
        .binary_normals => &normals_elements,
        .binary_wide => &wide_elements,
        .binary_mixed_elements => &mixed_elements,
        .binary_large_lists => &large_list_elements,
        .binary_multi_list => &multi_list_elements,
        .ascii_ints => &ascii_int_elements,
        .ascii_scientific => &ascii_scientific_elements,
        .ascii_long => &ascii_long_elements,
        .ascii_wide => &ascii_wide_elements,
    };
}

fn seedOf(element: usize, prop: usize, record: u64, item: usize) u64 {
    return record *% 0x9e3779b97f4a7c15 +%
        @as(u64, @intCast(element)) *% 0x100000001b3 +%
        @as(u64, @intCast(prop)) *% 0xc2b2ae3d27d4eb4f +%
        @as(u64, @intCast(item)) *% 0x165667b19e3779f9;
}

fn intValue(comptime T: type, seed: u64) T {
    const info = @typeInfo(T).int;
    const max: i64 = if (info.signedness == .signed)
        (@as(i64, 1) << @intCast(info.bits - 1)) - 1
    else
        (@as(i64, 1) << @intCast(info.bits)) - 1;
    const raw: i64 = @intCast(seed % @as(u64, @intCast(max)));
    const value = if (info.signedness == .signed) raw - @divTrunc(max, 4) else raw;
    return @intCast(value);
}

const ScientificParts = struct {
    mantissa: u32,
    exponent: u32,
    negative: bool,
    negative_exponent: bool,
};

fn scientificParts(seed: u64) ScientificParts {
    return .{
        // Multiples of 125 make every m * 10^e and m / 10^e exact in f32/f64.
        .mantissa = 125 * @as(u32, @intCast(1 + seed % 7)),
        .exponent = @intCast(seed % 3),
        .negative = (seed >> 8) & 1 != 0,
        .negative_exponent = (seed >> 9) & 1 != 0,
    };
}

fn scientificValue(comptime T: type, parts: ScientificParts) T {
    const base: T = @floatFromInt(parts.mantissa);
    const power: T = switch (parts.exponent) {
        0 => 1.0,
        1 => 10.0,
        2 => 100.0,
        else => unreachable,
    };
    const magnitude = if (parts.negative_exponent) base / power else base * power;
    return if (parts.negative) -magnitude else magnitude;
}

fn floatValue(comptime T: type, kind: Kind, seed: u64) T {
    if (kind == .ascii_scientific) return scientificValue(T, scientificParts(seed));
    const span: u64 = if (T == f32) 2001 else 4001;
    const denominator: T = if (T == f32) 8.0 else 16.0;
    const centered: i32 = @as(i32, @intCast(seed % span)) - @as(i32, @intCast(span / 2));
    return @as(T, @floatFromInt(centered)) / denominator;
}

fn valueAt(comptime T: type, kind: Kind, element: usize, prop: usize, record: u64, item: usize) T {
    const seed = seedOf(element, prop, record, item);
    return switch (@typeInfo(T)) {
        .int => intValue(T, seed),
        .float => floatValue(T, kind, seed),
        else => @compileError("PLY scalar must be an integer or float"),
    };
}

fn listCount(kind: Kind, element: usize, prop: usize, record: u64) usize {
    const seed = seedOf(element, prop, record, 0);
    return switch (kind) {
        .binary_large_lists => @intCast(seed % 65),
        else => @intCast(seed % 6),
    };
}

fn valueBits(value: anytype) u64 {
    const T = @TypeOf(value);
    const U = @Int(.unsigned, @bitSizeOf(T));
    return @intCast(@as(U, @bitCast(value)));
}

fn addScalar(h: *u64, prop: usize, item: usize, value: anytype) void {
    h.* +%= mix(mix(prop) ^ mix(item) ^ mix(valueBits(value)));
}

fn addCount(h: *u64, prop: usize, count: usize) void {
    h.* +%= mix(mix(prop) ^ 0x6c697374 ^ mix(count));
}

fn recordHashBase(element: usize, record: u64) u64 {
    return mix(@intCast(element)) ^ mix(record);
}

fn appendText(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: anytype) !void {
    var buffer: [96]u8 = undefined;
    const text = try std.fmt.bufPrint(&buffer, "{d} ", .{value});
    try out.appendSlice(allocator, text);
}

fn appendBinary(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: anytype, endian: std.builtin.Endian) !void {
    const T = @TypeOf(value);
    const U = @Int(.unsigned, @bitSizeOf(T));
    const width = @bitSizeOf(T) / 8;
    const destination = try out.addManyAsSlice(allocator, width);
    std.mem.writeInt(U, destination[0..width], @bitCast(value), endian);
}

fn appendScientific(allocator: std.mem.Allocator, out: *std.ArrayList(u8), seed: u64) !void {
    const parts = scientificParts(seed);
    var buffer: [48]u8 = undefined;
    const text = if (parts.negative_exponent and parts.exponent != 0)
        try std.fmt.bufPrint(&buffer, "{s}{d}e-{d} ", .{
            if (parts.negative) "-" else "",
            parts.mantissa,
            parts.exponent,
        })
    else
        try std.fmt.bufPrint(&buffer, "{s}{d}e{d} ", .{
            if (parts.negative) "-" else "",
            parts.mantissa,
            parts.exponent,
        });
    try out.appendSlice(allocator, text);
}

fn writeRecord(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    kind: Kind,
    element_index: usize,
    record: u64,
    expected: *Digest,
) !void {
    const elements = schema(kind);
    const element = elements[element_index];
    const endian: std.builtin.Endian = .little;
    var h = recordHashBase(element_index, record);
    for (element.props, 0..) |prop, pi| {
        switch (prop.kind) {
            .scalar => |tag| switch (tag) {
                inline else => |scalar_tag| {
                    const T = scalar_tag.zigType();
                    const value = valueAt(T, kind, element_index, pi, record, 0);
                    if (kind.isAscii()) {
                        if (T == f32 and kind == .ascii_scientific) {
                            try appendScientific(allocator, out, seedOf(element_index, pi, record, 0));
                        } else {
                            try appendText(allocator, out, value);
                        }
                    } else {
                        try appendBinary(allocator, out, value, endian);
                    }
                    addScalar(&h, pi, 0, value);
                },
            },
            .list => |list_kind| {
                const count = listCount(kind, element_index, pi, record);
                if (kind.isAscii()) {
                    try appendText(allocator, out, count);
                } else {
                    switch (list_kind.count) {
                        inline else => |count_tag| {
                            const CountT = count_tag.zigType();
                            try appendBinary(allocator, out, @as(CountT, @intCast(count)), endian);
                        },
                    }
                }
                addCount(&h, pi, count);
                var item: usize = 0;
                while (item < count) : (item += 1) {
                    switch (list_kind.item) {
                        inline else => |item_tag| {
                            const T = item_tag.zigType();
                            const value = valueAt(T, kind, element_index, pi, record, item);
                            if (kind.isAscii()) {
                                try appendText(allocator, out, value);
                            } else {
                                try appendBinary(allocator, out, value, endian);
                            }
                            addScalar(&h, pi, item + 1, value);
                        },
                    }
                }
            },
        }
    }
    if (kind.isAscii()) try out.append(allocator, '\n');
    expected.add(h);
}

pub const Input = struct {
    records: usize,
    records_per_element: usize,
    bytes: []u8,
    body_bytes: usize,
    list_items: usize,
    kind: Kind,
    expected: Digest,

    pub fn deinit(self: Input, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
    }
};

pub fn createInputWithRecords(allocator: std.mem.Allocator, kind: Kind, records_per_element: usize) !Input {
    const elements = schema(kind);
    const total_records = std.math.mul(usize, records_per_element, elements.len) catch return error.SizeOverflow;

    var header: std.ArrayList(u8) = .empty;
    defer header.deinit(allocator);
    try header.appendSlice(allocator, "ply\n");
    var line_buffer: [128]u8 = undefined;
    try header.appendSlice(allocator, try std.fmt.bufPrint(&line_buffer, "format {s} 1.0\n", .{kind.encoding()}));
    for (elements) |element| {
        try header.appendSlice(allocator, try std.fmt.bufPrint(&line_buffer, "element {s} {d}\n", .{ element.name, records_per_element }));
        for (element.props) |prop| {
            const text = switch (prop.kind) {
                .scalar => |tag| try std.fmt.bufPrint(&line_buffer, "property {s} {s}\n", .{ tag.name(), prop.name }),
                .list => |list_kind| try std.fmt.bufPrint(&line_buffer, "property list {s} {s} {s}\n", .{
                    list_kind.count.scalar().name(),
                    list_kind.item.name(),
                    prop.name,
                }),
            };
            try header.appendSlice(allocator, text);
        }
    }
    try header.appendSlice(allocator, "end_header\n");

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(allocator);
    var expected: Digest = .{};
    var list_items: usize = 0;
    const per_element: u64 = @intCast(records_per_element);
    for (elements, 0..) |element, element_index| {
        var record: u64 = 0;
        while (record < per_element) : (record += 1) {
            try writeRecord(allocator, &body, kind, element_index, record, &expected);
            for (element.props, 0..) |prop, pi| switch (prop.kind) {
                .scalar => {},
                .list => list_items += listCount(kind, element_index, pi, record),
            };
        }
    }

    const bytes = try allocator.alloc(u8, header.items.len + body.items.len);
    errdefer allocator.free(bytes);
    @memcpy(bytes[0..header.items.len], header.items);
    @memcpy(bytes[header.items.len..], body.items);
    return .{
        .records = total_records,
        .records_per_element = records_per_element,
        .bytes = bytes,
        .body_bytes = body.items.len,
        .list_items = list_items,
        .kind = kind,
        .expected = expected,
    };
}

pub const Sample = struct {
    body_nanoseconds: i96,
    nanoseconds: i96,
    batches: usize,
    peak_bytes: usize,
    allocation_count: u64,
    native_submissions: u64,
    inline_decodes: u64,
    max_active: usize,
    consumer_digest: Digest,
};

pub const RunOptions = struct {
    chunk_size: usize,
    memory_budget: usize,
    consumer: m16.Consumer = .validation,
};

const max_elements = 8;

fn sameBits(a: anytype, b: @TypeOf(a)) bool {
    return valueBits(a) == valueBits(b);
}

fn consumeBatch(
    batch: zply.Batch,
    kind: Kind,
    records_per_element: usize,
    seen: *[max_elements]usize,
    digest: *Digest,
    item_total: *usize,
) !void {
    const info = batch.info();
    const elements = schema(kind);
    if (info.element_index >= elements.len) return error.InvalidBatchMetadata;
    const element = elements[info.element_index];
    if (batch.columnCount() != element.props.len) return error.InvalidColumnShape;
    const start_record: usize = @intCast(info.first_record);
    if (start_record + info.record_count > records_per_element) return error.InvalidBatchMetadata;

    for (element.props, 0..) |prop, pi| {
        const column = batch.column(pi) orelse return error.InvalidColumnShape;
        if (column.property_index != pi) return error.InvalidColumnShape;
        switch (prop.kind) {
            .scalar => |tag| {
                if (column.list != null or column.values.scalarType() != tag) return error.InvalidColumnShape;
                if (column.values.len() != info.record_count) return error.InvalidColumnShape;
            },
            .list => |list_kind| {
                const list_column = column.list orelse return error.InvalidColumnShape;
                if (list_column.values.scalarType() != list_kind.item) return error.InvalidColumnShape;
                if (list_column.offsets.len != info.record_count + 1) return error.InvalidColumnShape;
            },
        }
    }

    var row: usize = 0;
    while (row < info.record_count) : (row += 1) {
        const record = info.first_record + row;
        var h = recordHashBase(info.element_index, record);
        for (element.props, 0..) |prop, pi| {
            const column = batch.column(pi).?;
            switch (prop.kind) {
                .scalar => |tag| switch (tag) {
                    inline else => |scalar_tag| {
                        const T = scalar_tag.zigType();
                        const decoded = @field(column.values, @tagName(scalar_tag))[row];
                        const expected_value = valueAt(T, kind, info.element_index, pi, record, 0);
                        if (!sameBits(decoded, expected_value)) return error.IncorrectDecodedOutput;
                        addScalar(&h, pi, 0, decoded);
                    },
                },
                .list => |list_kind| {
                    const values = column.list.?.row(row) orelse return error.InvalidColumnShape;
                    if (values.len() != listCount(kind, info.element_index, pi, record)) return error.IncorrectDecodedOutput;
                    addCount(&h, pi, values.len());
                    item_total.* += values.len();
                    switch (list_kind.item) {
                        inline else => |item_tag| {
                            const T = item_tag.zigType();
                            const items = @field(values, @tagName(item_tag));
                            for (items, 0..) |decoded, item| {
                                const expected_value = valueAt(T, kind, info.element_index, pi, record, item);
                                if (!sameBits(decoded, expected_value)) return error.IncorrectDecodedOutput;
                                addScalar(&h, pi, item + 1, decoded);
                            }
                        },
                    }
                },
            }
        }
        digest.add(h);
    }
    seen[info.element_index] += info.record_count;
}

/// Same verified parser/consumer path as the M16 workloads, generalized to
/// arbitrary compiled schemas, multiple elements and list properties.
pub fn runOnceConfigured(
    allocator: std.mem.Allocator,
    io: std.Io,
    input: Input,
    mode: m16.Mode,
    options: RunOptions,
) !Sample {
    var reader: std.Io.Reader = .fixed(input.bytes);
    const start = std.Io.Clock.awake.now(io);
    var parser = try zply.Parser.init(allocator, io, &reader, .{
        .chunk_size = options.chunk_size,
        .memory_budget = options.memory_budget,
        .preserve_order = mode != .threaded_unordered,
    });
    var parser_live = true;
    errdefer if (parser_live) parser.deinit();
    const body_start = std.Io.Clock.awake.now(io);
    var digest: Digest = .{};
    var seen: [max_elements]usize = @splat(0);
    var item_total: usize = 0;
    var batches: usize = 0;
    while (try parser.next()) |result| {
        var batch = result;
        defer batch.release();
        if (options.consumer == .minimal) {
            const info = batch.info();
            const first_record: usize = @intCast(info.first_record);
            if (info.element_index >= seen.len or
                first_record > input.records_per_element or
                info.record_count > input.records_per_element - first_record)
            {
                return error.InvalidBatchMetadata;
            }
            item_total += try minimal_consumer.consume(batch, &digest);
            seen[info.element_index] += info.record_count;
        } else {
            try consumeBatch(batch, input.kind, input.records_per_element, &seen, &digest, &item_total);
        }
        batches += 1;
    }
    const body_end = std.Io.Clock.awake.now(io);
    const memory = parser.memoryStats();
    const execution = parser.executionStats();
    parser.deinit();
    parser_live = false;
    if ((mode == .threaded_ordered or mode == .threaded_unordered) and
        execution.native_submissions == 0) return error.NativeConcurrencyInactive;
    const end = std.Io.Clock.awake.now(io);
    var records: usize = 0;
    for (seen[0..schema(input.kind).len]) |count| {
        if (count != input.records_per_element) return error.IncorrectDecodedOutput;
        records += count;
    }
    if (memory.peak_total_bytes > options.memory_budget or
        records != input.records or
        item_total != input.list_items or
        (options.consumer == .validation and !digest.eql(input.expected)))
    {
        std.debug.print("INVALID BENCHMARK workload={s} mode={s} records={d}/{d} items={d}/{d}\n", .{
            @tagName(input.kind), mode.label(), records, input.records, item_total, input.list_items,
        });
        return error.IncorrectDecodedOutput;
    }
    std.mem.doNotOptimizeAway(digest);
    const elapsed = try timing.elapsedNs(start, end);
    const body_elapsed = try timing.elapsedNs(body_start, body_end);
    if (body_elapsed > elapsed) return error.InvalidMeasurement;
    return .{
        .nanoseconds = elapsed,
        .body_nanoseconds = body_elapsed,
        .batches = batches,
        .peak_bytes = memory.peak_total_bytes,
        .allocation_count = memory.allocation_count,
        .native_submissions = execution.native_submissions,
        .inline_decodes = execution.inline_decodes,
        .max_active = execution.max_active_decodes,
        .consumer_digest = digest,
    };
}
