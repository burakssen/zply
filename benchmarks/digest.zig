//! Phase 12 M2: order-independent, fixed-width digest for verified benchmark
//! results. Includes the logical record index in each record hash.
//! This is an integrity check, not a cryptographic digest.

pub fn mix(initial: u64) u64 {
    var x = initial;
    x = (x ^ (x >> 30)) *% 0xbf58476d1ce4e5b9;
    x = (x ^ (x >> 27)) *% 0x94d049bb133111eb;
    return x ^ (x >> 31);
}

pub const Digest = struct {
    sum: u64 = 0,
    xor_value: u64 = 0,

    pub fn add(self: *Digest, hash: u64) void {
        const value = mix(hash);
        self.sum +%= value;
        self.xor_value ^= value;
    }

    pub fn eql(self: Digest, other: Digest) bool {
        return self.sum == other.sum and self.xor_value == other.xor_value;
    }
};
