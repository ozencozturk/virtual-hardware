//! arm64 platform interfaces the guest talks to.
//!
//! NOTE the shape here differs from the MMIO devices elsewhere in this module:
//! PSCI has no memory-mapped window, so it exposes no load/store. It is reached
//! by an `hvc` call and services registers through the caller's vCPU seam.

pub const psci = @import("psci.zig");

test {
    _ = @import("psci.zig");
}
