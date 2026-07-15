# virtual-hardware

Reusable, dependency-free virtual hardware models in Zig: a bit/byte utility
library and a set of memory-mapped device models (16550 UART, virtio-blk).

Extracted from a deterministic RISC-V emulator so the same device models can be
shared with other guests and machine implementations. The models are pure state
machines — `load`/`store` take a runtime access width and never perform I/O of
their own, so a caller can drive them from an instruction decoder, from a
hardware fault handler, or from a test.

## Modules

The package exposes two modules:

| Module    | Root            | Contents                                             |
|-----------|-----------------|------------------------------------------------------|
| `bits`    | `src/bits.zig`  | Bit-field extract/insert, mask building, alignment and bounds predicates, little-endian readers. |
| `devices` | `src/root.zig`  | `Uart` (16550) and `Virtio` (virtio-blk MMIO). Imports `bits`. |

## Usage

Add the dependency:

```sh
zig fetch --save git+https://github.com/ozencozturk/virtual-hardware.git
```

Wire the modules into your build (`build.zig`):

```zig
const vhw = b.dependency("virtual_hardware", .{});
your_module.addImport("bits", vhw.module("bits"));
your_module.addImport("devices", vhw.module("devices"));
```

Then in source:

```zig
const bits = @import("bits");
const devices = @import("devices");

var uart: devices.Uart = .{};
try uart.store(devices.Uart.THR_DLL, 1, 'H'); // width is a runtime argument

var disk: devices.Virtio = .{};
_ = disk;
```

## Testing

```sh
zig build test --summary all
```

Runs the `bits` unit tests plus the `Uart`/`Virtio` model tests.

## License

MIT — see [LICENSE](LICENSE).
