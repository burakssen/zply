//! Pure, reusable ASCII PLY parsing primitives. No reader or pool dependencies.
pub const Tokenizer = @import("tokenizer.zig").Tokenizer;
pub const number = @import("number.zig");
pub const record = @import("record.zig");
