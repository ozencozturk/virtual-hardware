const std = @import("std");
const testing = std.testing;

pub const Uart = struct {
    pub const UART_SIZE = 0x1000;

    pub const RBR_DLL: u8 = 0;
    pub const THR_DLL: u8 = 0;
    pub const IER_DLM: u8 = 1;
    pub const IIR: u8 = 2;
    pub const FCR: u8 = 2;
    pub const LCR: u8 = 3;
    pub const MCR: u8 = 4;
    pub const LSR: u8 = 5;
    pub const MSR: u8 = 6;
    pub const SCR: u8 = 7;

    ier: u8 = 0,
    iir: u8 = 0,
    fcr: u8 = 0,
    lcr: u8 = 0,
    mcr: u8 = 0,
    lsr: u8 = 0,
    msr: u8 = 0,
    scr: u8 = 0,
    dlm: u8 = 0,
    dll: u8 = 0,
    tx_buffer: UartBuffer = .{},
    rx_fifo: UartRingBuffer = .{},
    tx_int_pending: bool = false,

    pub fn store(self: *Uart, addr: u64, size: usize, value: u64) !void {
        if (size != 1) {
            return error.AccessFault;
        }
        switch (addr) {
            THR_DLL => {
                if (Lcr.fromBits(self.lcr).dlab == 1) {
                    self.dll = @truncate(value);
                } else {
                    self.tx_buffer.push(@truncate(value));
                    self.tx_int_pending = true;
                }
            },
            IER_DLM => {
                if (Lcr.fromBits(self.lcr).dlab == 1) {
                    self.dlm = @truncate(value);
                } else {
                    self.ier = @truncate(value);
                }
            },
            FCR => {
                self.fcr = @truncate(value);
                if (Fcr.fromBits(self.fcr).receive_fifo_reset == 1) {
                    self.rx_fifo = .{};
                }
            },
            LCR => self.lcr = @truncate(value),
            MCR => self.mcr = @truncate(value),
            SCR => self.scr = @truncate(value),
            else => {},
        }
    }
    pub fn load(self: *Uart, addr: u64, size: usize) !u64 {
        if (size != 1) {
            return error.AccessFault;
        }
        return switch (addr) {
            RBR_DLL => if (Lcr.fromBits(self.lcr).dlab == 1) self.dll else self.rx_fifo.pop(),
            IER_DLM => if (Lcr.fromBits(self.lcr).dlab == 1) self.dlm else self.ier,
            IIR => blk: {
                const iir = Iir{ .pending = @intFromBool(self.tx_int_pending) };
                self.tx_int_pending = false; // reading IIR/ISR acks the TX-complete interrupt
                break :blk iir.toBits();
            },
            LCR => self.lcr,
            MCR => self.mcr,
            LSR => Lsr.readView(self.lsr, self.rx_fifo.dataReady()),
            MSR => self.msr,
            SCR => self.scr,
            else => 0,
        };
    }

    pub fn receive(self: *Uart, byte: u8) void {
        self.rx_fifo.push(byte);
    }

    pub fn rxHasSpace(self: *const Uart) bool {
        return !self.rx_fifo.isFull();
    }

    pub fn irqAsserted(self: *const Uart) bool {
        const ier = Ier.fromBits(self.ier);
        return (ier.rx_int_enable == 1 and self.rx_fifo.dataReady()) or (ier.tx_int_enable == 1 and self.tx_int_pending);
    }

    pub fn hash(self: *const Uart, h: *std.hash.Wyhash) void {
        self.tx_buffer.hash(h);
        h.update(std.mem.asBytes(&self.ier));
        h.update(std.mem.asBytes(&self.iir));
        h.update(std.mem.asBytes(&self.fcr));
        h.update(std.mem.asBytes(&self.lcr));
        h.update(std.mem.asBytes(&self.mcr));
        h.update(std.mem.asBytes(&self.lsr));
        h.update(std.mem.asBytes(&self.msr));
        h.update(std.mem.asBytes(&self.scr));
        h.update(std.mem.asBytes(&self.dlm));
        h.update(std.mem.asBytes(&self.dll));
        h.update(std.mem.asBytes(&self.tx_int_pending));
        self.rx_fifo.hash(h);
    }
};

test "compiles" {
    var uart = Uart{};
    try testing.expectEqual(0, try uart.load(0, 1));
    var lcr = Lcr{};
    lcr.dlab = 1;
    try std.testing.expectEqual(0x80, lcr.toBits());
    // 0x03 => 0000 0011
}

test "init sequence no fault" {
    var uart = Uart{};
    try uart.store(Uart.IER_DLM, 1, 0); // disable interrupts for uart

    const lcr_control = Lcr{ .dlab = 1 }; // active dlab for setting baud rate - dlab actives control flow
    try uart.store(Uart.LCR, 1, lcr_control.toBits());

    try uart.store(Uart.THR_DLL, 1, 0x03); // set baud rate lower half - we ignore baud rate
    try uart.store(Uart.IER_DLM, 1, 0x00); // set baud rate upper half

    const lcr_data = Lcr{ .wlen = 3 };
    try uart.store(Uart.LCR, 1, lcr_data.toBits()); // define data format(8 bytes) and clear DLAB

    const fcr = Fcr{ .enable_fifos = 1, .receive_fifo_reset = 1, .transmit_fifo_reset = 1 };
    try uart.store(Uart.FCR, 1, fcr.toBits()); // turn on transmit and receive fifos and clear them (wo this flag, it accepts one byte at a time)

    const ier = Ier{ .rx_int_enable = 1, .tx_int_enable = 1 }; // enable interrupts
    try uart.store(Uart.IER_DLM, 1, ier.toBits()); // disable interrupts for uart

    try testing.expectEqual(0, uart.tx_buffer.len);

    //IER=0x00` → `LCR=0x80` → `DLL=0x03; DLM=0x00` → `LCR=0x03` → `FCR=0x07` →
    //`IER=0x03`; then TX = `while ((LSR & (1<<5))==0){}; THR=c`.
}

pub const Lsr = packed struct {
    dr: u1 = 0,
    _err1: u4 = 0,
    thre: u1 = 0,
    temt: u1 = 0,
    _err2: u1 = 0,
    comptime {
        std.debug.assert(@bitSizeOf(Lsr) == 8);
    }

    pub fn fromBits(v: u8) Lsr {
        return @bitCast(v);
    }
    pub fn toBits(self: Lsr) u8 {
        return @bitCast(self);
    }
    pub fn readView(v: u8, data_ready: bool) u64 {
        var m = fromBits(v);
        m.thre = 1;
        m.temt = 1;
        m.dr = @intFromBool(data_ready);
        return toBits(m);
    }
};
// 00001000
pub const Lcr = packed struct {
    wlen: u2 = 0,
    _res: u5 = 0,
    dlab: u1 = 0,
    comptime {
        std.debug.assert(@bitSizeOf(Lcr) == 8);
    }

    pub fn fromBits(v: u8) Lcr {
        return @bitCast(v);
    }
    pub fn toBits(self: Lcr) u8 {
        return @bitCast(self);
    }
};
pub const Ier = packed struct {
    rx_int_enable: u1 = 0,
    tx_int_enable: u1 = 0,
    _res: u6 = 0,
    comptime {
        std.debug.assert(@bitSizeOf(Ier) == 8);
    }

    pub fn fromBits(v: u8) Ier {
        return @bitCast(v);
    }
    pub fn toBits(self: Ier) u8 {
        return @bitCast(self);
    }
};

pub const Iir = packed struct {
    pending: u1 = 0,
    _res: u7 = 0,
    comptime {
        std.debug.assert(@bitSizeOf(Iir) == 8);
    }

    pub fn fromBits(v: u8) Iir {
        return @bitCast(v);
    }
    pub fn toBits(self: Iir) u8 {
        return @bitCast(self);
    }
};
// 0x07
// // 00000111
pub const Fcr = packed struct {
    enable_fifos: u1 = 0,
    receive_fifo_reset: u1 = 0,
    transmit_fifo_reset: u1 = 0,
    _res: u5 = 0,
    comptime {
        std.debug.assert(@bitSizeOf(Fcr) == 8);
    }

    pub fn fromBits(v: u8) Fcr {
        return @bitCast(v);
    }
    pub fn toBits(self: Fcr) u8 {
        return @bitCast(self);
    }
};

pub const UartBuffer = struct {
    pub const UART_TX_CAP = 1 << 16;
    data: [UART_TX_CAP]u8 = @splat(0),
    len: usize = 0,
    dropped: usize = 0,

    pub fn push(self: *UartBuffer, byte: u8) void {
        if (self.len < UART_TX_CAP) {
            self.data[self.len] = byte;
            self.len += 1;
        } else {
            self.dropped += 1;
        }
    }
    pub fn hash(self: *const UartBuffer, h: *std.hash.Wyhash) void {
        h.update(self.data[0..self.len]);
        h.update(std.mem.asBytes(&self.len));
        h.update(std.mem.asBytes(&self.dropped));
    }
};

const BUFFER_SIZE = 16;
const UartRingBuffer = struct {
    data: [BUFFER_SIZE]u8 = @splat(0),
    head: usize = 0, // read index (oldest byte)
    len: usize = 0, // number of queued bytes, 0..BUFFER_SIZE
    dropped: usize = 0, // overrun count (bytes dropped on full FIFO)

    pub fn push(self: *UartRingBuffer, val: u8) void {
        if (self.len == BUFFER_SIZE) {
            self.dropped += 1; // §4.5 datasheet: full RX FIFO drops the incoming byte
            return;
        }
        const tail = (self.head + self.len) % BUFFER_SIZE;
        self.data[tail] = val;
        self.len += 1;
    }

    pub fn pop(self: *UartRingBuffer) u8 {
        if (self.len == 0) {
            return 0;
        }
        const res = self.data[self.head];
        self.head = (self.head + 1) % BUFFER_SIZE;
        self.len -= 1;
        return res;
    }

    pub fn dataReady(self: *const UartRingBuffer) bool {
        return self.len > 0;
    }

    pub fn isFull(self: *const UartRingBuffer) bool {
        return self.len == BUFFER_SIZE;
    }

    pub fn hash(self: *const UartRingBuffer, h: *std.hash.Wyhash) void {
        h.update(std.mem.asBytes(&self.data));
        h.update(std.mem.asBytes(&self.head));
        h.update(std.mem.asBytes(&self.len));
        h.update(std.mem.asBytes(&self.dropped));
    }
};
test "store tests" {
    var uart: Uart = .{};
    var lcr = Lcr{ .dlab = 1 };
    try uart.store(Uart.LCR, 1, lcr.toBits());
    try testing.expectEqual(lcr.toBits(), try uart.load(Uart.LCR, 1));

    try uart.store(Uart.THR_DLL, 1, 4);
    try testing.expectEqual(4, try uart.load(Uart.THR_DLL, 1));
    try testing.expectEqual(4, uart.dll);

    try uart.store(Uart.IER_DLM, 1, 5);
    try testing.expectEqual(5, try uart.load(Uart.IER_DLM, 1));
    try testing.expectEqual(5, uart.dlm);

    try uart.store(Uart.MCR, 1, 2);
    try testing.expectEqual(2, try uart.load(Uart.MCR, 1));

    try uart.store(Uart.SCR, 1, 3);
    try testing.expectEqual(3, try uart.load(Uart.SCR, 1));

    try testing.expectEqual(try uart.load(8, 1), 0);

    try testing.expectError(error.AccessFault, uart.load(0, 2));
    try testing.expectError(error.AccessFault, uart.store(0, 2, 1));

    try uart.store(Uart.LSR, 1, 5);
    try testing.expectEqual(0, uart.lsr);
    const lsr = Lsr{ .thre = 1, .temt = 1 };
    try testing.expectEqual(lsr.toBits(), try uart.load(Uart.LSR, 1));
}

test "txbuffer tests" {
    {
        var uart: Uart = .{}; // fresh → dlab=0
        try uart.store(Uart.THR_DLL, 1, 'H');
        try uart.store(Uart.THR_DLL, 1, 'i');
        try testing.expectEqualStrings("Hi", uart.tx_buffer.data[0..uart.tx_buffer.len]);
    }
    {
        var uart: Uart = .{}; // fresh → dlab=0
        var lcr = Lcr{ .dlab = 1 };
        try uart.store(Uart.LCR, 1, lcr.toBits());
        try uart.store(Uart.THR_DLL, 1, 'H');
        try uart.store(Uart.THR_DLL, 1, 'i');
        try testing.expectEqual(0, uart.tx_buffer.len);
    }
}
// RX FIFO push/pop order, DR reflects non-empty, drain clears DR, empty reads 0.
test "rx fifo push/pop order + DR" {
    var uart: Uart = .{}; // dlab=0
    uart.rx_fifo.push('H');
    uart.rx_fifo.push('i');

    // DR set while data queued.
    try testing.expectEqual(1, Lsr.fromBits(@truncate(try uart.load(Uart.LSR, 1))).dr);

    // RBR pops oldest-first.
    try testing.expectEqual('H', try uart.load(Uart.RBR_DLL, 1));
    try testing.expectEqual('i', try uart.load(Uart.RBR_DLL, 1));

    // Drained: DR clears, further reads return 0.
    try testing.expectEqual(0, Lsr.fromBits(@truncate(try uart.load(Uart.LSR, 1))).dr);
    try testing.expectEqual(0, try uart.load(Uart.RBR_DLL, 1));
}

// DLAB routing intact: with DLAB=1, offset 0 reads DLL, NOT the RX FIFO (RX must not pop).
test "rx does not break DLAB baud path" {
    var uart: Uart = .{};
    uart.rx_fifo.push('Z');

    const lcr = Lcr{ .dlab = 1 };
    try uart.store(Uart.LCR, 1, lcr.toBits());
    try uart.store(Uart.THR_DLL, 1, 0x03); // DLAB=1 write → DLL

    try testing.expectEqual(0x03, try uart.load(Uart.RBR_DLL, 1)); // reads DLL, not 'Z'
    try testing.expectEqual(1, uart.rx_fifo.len); // FIFO untouched (no pop)
}

// load(RBR) is a mutating read: it pops the FIFO rather than peeking.
test "rbr read mutates the fifo" {
    var uart: Uart = .{};
    uart.rx_fifo.push('A');
    try testing.expectEqual(1, uart.rx_fifo.len);
    _ = try uart.load(Uart.RBR_DLL, 1);
    try testing.expectEqual(0, uart.rx_fifo.len);
}

// irqAsserted() == (ERBFI && DR) || (ETBEI && tx_int_pending). Both terms are required:
// without the ERBFI gate an RX interrupt asserts even when RX interrupts are disabled; without
// the ETBEI gate an interrupt-driven writer that sleeps on the TX-empty interrupt never wakes.
test "irqAsserted truth table" {
    var uart: Uart = .{};
    const erbfi = Ier{ .rx_int_enable = 1 };
    const etbei = Ier{ .tx_int_enable = 1 };

    // --- RX half: ERBFI && DR ---
    // ERBFI=0, data present → false.
    uart.rx_fifo.push('x');
    uart.ier = 0;
    try testing.expect(!uart.irqAsserted());

    // ERBFI=1, FIFO empty → false.
    _ = uart.rx_fifo.pop();
    uart.ier = erbfi.toBits();
    try testing.expect(!uart.irqAsserted());

    // ERBFI=1, data present → true.
    uart.rx_fifo.push('y');
    try testing.expect(uart.irqAsserted());

    // --- TX half: ETBEI && tx_int_pending ---
    uart = .{};

    // ETBEI=0, a THR write set tx_int_pending → still false (masked).
    try uart.store(Uart.THR_DLL, 1, 'A'); // non-DLAB THR write arms tx_int_pending
    try testing.expect(uart.tx_int_pending);
    uart.ier = 0;
    try testing.expect(!uart.irqAsserted());

    // ETBEI=1, tx_int_pending set → true.
    uart.ier = etbei.toBits();
    try testing.expect(uart.irqAsserted());

    // Reading IIR acks/clears the TX interrupt → back to false (edge, not level → no storm).
    _ = try uart.load(Uart.IIR, 1);
    try testing.expect(!uart.tx_int_pending);
    try testing.expect(!uart.irqAsserted());

    // A DLAB-gated write to THR (divisor latch) must NOT arm the TX interrupt.
    uart.lcr = (Lcr{ .dlab = 1 }).toBits();
    try uart.store(Uart.THR_DLL, 1, 0x03); // this is a DLL divisor write, not a transmit
    try testing.expect(!uart.tx_int_pending);
}

// Overflow rule: a full (16-deep) FIFO deterministically drops the incoming byte.
test "rx fifo overflow drops incoming byte" {
    var uart: Uart = .{};
    var i: u8 = 0;
    while (i < BUFFER_SIZE) : (i += 1) uart.rx_fifo.push('a' + i);
    try testing.expectEqual(BUFFER_SIZE, uart.rx_fifo.len);

    uart.rx_fifo.push('Z'); // 17th → dropped
    try testing.expectEqual(BUFFER_SIZE, uart.rx_fifo.len);
    try testing.expectEqual(1, uart.rx_fifo.dropped);

    // The 16 originally-queued bytes are intact and in order (oldest = 'a').
    try testing.expectEqual('a', try uart.load(Uart.RBR_DLL, 1));
}

// receive() is the serial RX line entry (≈ QEMU serial_receive): one byte in → queued in the
// FIFO, DR reflects it, RBR reads it back. rxHasSpace() is the delivery-layer flow-control gate —
// TRUE while there's room, FALSE at capacity. Mutation/inversion of isFull flips the gate → the pump
// refuses to feed an empty FIFO or overruns a full one (silent keystroke loss).
test "receive enqueues a byte; rxHasSpace tracks capacity" {
    var uart: Uart = .{};
    try testing.expect(uart.rxHasSpace()); // empty → has space

    uart.receive('Q');
    try testing.expectEqual(1, Lsr.fromBits(@truncate(try uart.load(Uart.LSR, 1))).dr); // DR set
    try testing.expectEqual('Q', try uart.load(Uart.RBR_DLL, 1)); // reads back through RBR

    // Fill to capacity → no space left (a further receive would drop; the guard lives at the pump).
    var i: u8 = 0;
    while (i < BUFFER_SIZE) : (i += 1) uart.receive('a' + i);
    try testing.expect(!uart.rxHasSpace()); // full → no space
}
