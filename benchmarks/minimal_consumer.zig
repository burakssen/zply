//! Low-overhead observable consumer for throughput-oriented benchmark runs.
//!
//! It validates batch shape and samples each published column without walking
//! every decoded scalar. The resulting digest is order independent, so it is
//! valid for both ordered and unordered parser delivery. Full value-by-value
//! verification remains available through the validation consumer.
const zply = @import("zply");
const digest_mod = @import("digest.zig");

const Digest = digest_mod.Digest;
const mix = digest_mod.mix;

fn valueBits(value: anytype) u64 {
    const T = @TypeOf(value);
    const U = @Int(.unsigned, @bitSizeOf(T));
    return @intCast(@as(U, @bitCast(value)));
}

fn sampleValues(values: anytype) u64 {
    return switch (values) {
        inline else => |items, tag| blk: {
            var hash = mix(@backingInt(tag)) ^ mix(items.len);
            if (items.len > 0) hash ^= mix(valueBits(items[0]));
            if (items.len > 1) hash ^= mix(valueBits(items[items.len - 1]));
            break :blk hash;
        },
    };
}

/// Consumes a published batch without constructing per-record descriptors or
/// walking every scalar. The returned item count is exact because list-column
/// value lengths are part of the published batch metadata.
pub fn consume(batch: zply.Batch, digest: *Digest) error{InvalidColumnShape}!usize {
    const info = batch.info();
    var hash = mix(info.element_index) ^ mix(info.first_record) ^ mix(info.record_count) ^ mix(info.sequence);
    var list_items: usize = 0;

    for (0..batch.columnCount()) |index| {
        const column = batch.column(index) orelse return error.InvalidColumnShape;
        if (column.property_index != index) return error.InvalidColumnShape;
        hash ^= mix(index);
        if (column.list) |list| {
            if (list.offsets.len != info.record_count + 1 or
                list.offsets[0] != 0 or
                list.offsets[list.offsets.len - 1] != list.values.len())
            {
                return error.InvalidColumnShape;
            }
            list_items += list.values.len();
            hash ^= mix(list.offsets[info.record_count / 2]);
            hash ^= sampleValues(list.values);
        } else {
            if (column.values.len() != info.record_count) return error.InvalidColumnShape;
            hash ^= sampleValues(column.values);
        }
    }
    digest.add(hash);
    return list_items;
}
