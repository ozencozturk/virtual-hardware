# virtual-platform

Reusable, dependency-free virtual hardware models in Zig: a bit/byte utility
library and a set of memory-mapped device models (16550 UART, virtio-blk,
virtio-console).

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
| `devices` | `src/root.zig`  | `Uart` (16550), `Virtio` (virtio-blk MMIO) and `VirtioConsole` (virtio-console MMIO). Imports `bits`. |

## Usage

Add the dependency:

```sh
zig fetch --save git+https://github.com/ozencozturk/virtual-platform.git
```

Wire the modules into your build (`build.zig`):

```zig
const vp = b.dependency("virtual_platform", .{});
your_module.addImport("bits", vp.module("bits"));
your_module.addImport("virtual_devices", vp.module("virtual_devices"));
```

Then in source:

```zig
const bits = @import("bits");
const devices = @import("virtual_devices");

var uart: devices.Uart = .{};
try uart.store(devices.Uart.THR_DLL, 1, 'H'); // width is a runtime argument

var disk: devices.Virtio = .{};
_ = disk;

// The console performs no I/O itself; the owner supplies the sink.
var console: devices.VirtioConsole = .{};
_ = console;
```

## Testing

```sh
zig build test --summary all
```

Runs the `bits` unit tests plus the `Uart`/`Virtio`/`VirtioConsole` model tests.

## License

MIT — see [LICENSE](LICENSE).

## Acknowledgements

Parts of this project were developed with assistance from AI coding tools
(Claude). All code was reviewed and is maintained by the author.
