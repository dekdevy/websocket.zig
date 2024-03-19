const std = @import("std");
const lib = @import("lib.zig");
const builtin = @import("builtin");

const buffer = lib.buffer;
const framing = lib.framing;
const handshake = lib.handshake;

const Reader = lib.Reader;
const OpCode = framing.OpCode;

const os = std.os;
const net = std.net;
const Loop = std.event.Loop;
const log = std.log.scoped(.websocket);

const Allocator = std.mem.Allocator;

pub const Config = struct {
	port: u16 = 9223,
	max_size: usize = 65536,
	max_headers: usize = 0,
	buffer_size: usize = 4096,
	unix_path: ?[]const u8 = null,
	address: []const u8 = "127.0.0.1",
	handshake_max_size: usize = 1024,
	handshake_pool_count: usize = 50,
	handshake_timeout_ms: ?u32 = 10_000,
	handle_ping: bool = false,
	handle_pong: bool = false,
	handle_close: bool = false,
	large_buffer_pool_count: u16 = 32,
	large_buffer_size: usize = 32768,
};

pub fn listen(comptime H: type, allocator: Allocator, context: anytype, config: Config) !void {
	var server = try Server.init(allocator, config);
	defer server.deinit(allocator);



	var no_delay = true;
	const address = blk: {
		if (comptime builtin.os.tag != .windows) {
			if (config.unix_path) |unix_path| {
				no_delay = false;
				std.fs.deleteFileAbsolute(unix_path) catch {};
				break :blk try net.Address.initUnix(unix_path);
			}
		}
		break :blk try net.Address.parseIp(config.address, config.port);
	};

	var listener = net.Address.listen(address, .{
		.reuse_address = true,
		.kernel_backlog = 1024,
	});
	defer listener.deinit();

	try listener.listen(address);

	if (no_delay) {
		// TODO: Broken on darwin:
		// https://github.com/ziglang/zig/issues/17260
		// if (@hasDecl(os.TCP, "NODELAY")) {
		//  try os.setsockopt(socket.sockfd.?, os.IPPROTO.TCP, os.TCP.NODELAY, &std.mem.toBytes(@as(c_int, 1)));
		// }
		try os.setsockopt(listener.sockfd.?, os.IPPROTO.TCP, 1, &std.mem.toBytes(@as(c_int, 1)));
	}

	while (true) {
		if (listener.accept()) |conn| {
			const args = .{&server, H, context, conn.stream};
			const thread = try std.Thread.spawn(.{}, Server.accept, args);
			thread.detach();
		} else |err| {
			log.err("failed to accept connection {}", .{err});
		}
	}
}

pub const Server = struct {
	config: Config,
	handshake_pool: handshake.Pool,
	buffer_provider: buffer.Provider,


	pub fn init(allocator: Allocator, config: Config) !Server {
		const buffer_pool = try allocator.create(buffer.Pool);
		errdefer allocator.destroy(buffer_pool);

		buffer_pool.* = try buffer.Pool.init(allocator, config.large_buffer_pool_count, config.large_buffer_size);
		errdefer buffer_pool.deinit();

		const buffer_provider = buffer.Provider.init(allocator, buffer_pool, config.large_buffer_size);

		const handshake_pool = try handshake.Pool.init(allocator, config.handshake_pool_count, config.handshake_max_size, config.max_headers);
		errdefer handshake_pool.deinit();

		return .{
			.config = config,
			.handshake_pool = handshake_pool,
			.buffer_provider = buffer_provider,
		};
	}

	pub fn deinit(self: *Server, allocator: Allocator) void {
		self.handshake_pool.deinit();
		self.buffer_provider.pool.deinit();
		allocator.destroy(self.buffer_provider.pool);
	}

	fn accept(self: *Server, comptime H: type, context: anytype, stream: net.Stream) void {
		std.os.maybeIgnoreSigpipe();
		errdefer stream.close();

		const Handshake = handshake.Handshake;
		var conn = self.newConn(stream);

		var handler: H = undefined;

		{
			// This block represents handshake_state's lifetime
			var handshake_state = self.handshake_pool.acquire() catch |err| {
				log.err("Failed to get a handshake state from the handshake pool, connection is being closed. The error was: {}", .{err});
				return;
			};
			defer self.handshake_pool.release(handshake_state);

			const request = readRequest(stream, handshake_state.buffer, self.config.handshake_timeout_ms) catch |err| {
				const s = switch (err) {
					error.Invalid => "HTTP/1.1 400 Invalid\r\nerror: invalid\r\ncontent-length: 0\r\n\r\n",
					error.TooLarge => "HTTP/1.1 400 Invalid\r\nerror: too large\r\ncontent-length: 0\r\n\r\n",
					error.Timeout, error.WouldBlock => "HTTP/1.1 400 Invalid\r\nerror: timeout\r\ncontent-length: 0\r\n\r\n",
					else => "HTTP/1.1 400 Invalid\r\nerror: unknown\r\ncontent-length: 0\r\n\r\n",
				};
				stream.writeAll(s) catch {};
				return;
			};

			const hshake = Handshake.parse(request, &handshake_state.headers) catch |err| {
				Handshake.close(stream, err) catch {};
				return;
			};

			handler = H.init(hshake, &conn, context) catch |err| {
				Handshake.close(stream, err) catch {};
				return;
			};

			// handshake_state (via `hshake` which references it), must be valid up until
			// this call to reply
			Handshake.reply(hshake.key, stream) catch {
				handler.close();
				return;
			};
		}
		self.handle(H, &handler, &conn);
	}

	pub fn newConn(self: *Server, stream: net.Stream) Conn {
		const config = &self.config;
		return .{
			.stream = stream,
			._bp = &self.buffer_provider,
			._handle_ping = config.handle_ping,
			._handle_pong = config.handle_pong,
			._handle_close = config.handle_close,
		};
	}

	pub fn handle(self: *Server, comptime H: type, handler: *H, conn: *Conn) void {
		defer handler.close();
		defer conn.stream.close();

		if (comptime std.meta.hasFn(H, "afterInit")) {
			handler.afterInit() catch return;
		}

		const config = &self.config;
		var reader = Reader.init(config.buffer_size, config.max_size, &self.buffer_provider) catch |err| {
			log.err("Failed to create a Reader, connection is being closed. The error was: {}", .{err});
			return;
		};
		defer reader.deinit();
		conn.readLoop(handler, &reader) catch {};
	}
};

const EMPTY_PONG = ([2]u8{ @intFromEnum(OpCode.pong), 0 })[0..];
// CLOSE, 2 length, code
const CLOSE_NORMAL = ([_]u8{ @intFromEnum(OpCode.close), 2, 3, 232 })[0..]; // code: 1000
const CLOSE_PROTOCOL_ERROR = ([_]u8{ @intFromEnum(OpCode.close), 2, 3, 234 })[0..]; //code: 1002

pub const Conn = struct {
	stream: net.Stream,
	closed: bool = false,
	_bp: *buffer.Provider,
	_handle_pong: bool = false,
	_handle_ping: bool = false,
	_handle_close: bool = false,

	pub fn writeBin(self: Conn, data: []const u8) !void {
		return self.writeFrame(.binary, data);
	}

	pub fn writeText(self: Conn, data: []const u8) !void {
		return self.writeFrame(.text, data);
	}

	pub fn write(self: Conn, data: []const u8) !void {
		return self.writeFrame(.text, data);
	}

	pub fn writePing(self: *Conn, data: []u8) !void {
		return self.writeFrame(.ping, data);
	}

	pub fn writePong(self: *Conn, data: []u8) !void {
		return self.writeFrame(.pong, data);
	}

	pub fn writeClose(self: *Conn) !void {
		return self.stream.writeAll(CLOSE_NORMAL);
	}

	pub fn writeCloseWithCode(self: *Conn, code: u16) !void {
		var buf: [2]u8 = undefined;
		std.mem.writeInt(u16, &buf, code, .Big);
		return self.writeFrame(.close, &buf);
	}

	pub fn writeFrame(self: Conn, op_code: OpCode, data: []const u8) !void {
		const stream = self.stream;
		const l = data.len;

		// maximum possible prefix length. op_code + length_type + 8byte length
		var buf: [10]u8 = undefined;
		buf[0] = @intFromEnum(op_code);

		if (l <= 125) {
			buf[1] = @intCast(l);
			try stream.writeAll(buf[0..2]);
		} else if (l < 65536) {
			buf[1] = 126;
			buf[2] = @intCast((l >> 8) & 0xFF);
			buf[3] = @intCast(l & 0xFF);
			try stream.writeAll(buf[0..4]);
		} else {
			buf[1] = 127;
			buf[2] = @intCast((l >> 56) & 0xFF);
			buf[3] = @intCast((l >> 48) & 0xFF);
			buf[4] = @intCast((l >> 40) & 0xFF);
			buf[5] = @intCast((l >> 32) & 0xFF);
			buf[6] = @intCast((l >> 24) & 0xFF);
			buf[7] = @intCast((l >> 16) & 0xFF);
			buf[8] = @intCast((l >> 8) & 0xFF);
			buf[9] = @intCast(l & 0xFF);
			try stream.writeAll(buf[0..]);
		}
		if (l > 0) {
			try stream.writeAll(data);
		}
	}

	pub fn writeFramed(self: Conn, data: []const u8) !void {
		try self.stream.writeAll(data);
	}

	pub fn writeBuffer(self: *Conn, op_code: OpCode) !Writer {
		return Writer.init(self, op_code);
	}

	pub fn close(self: *Conn) void {
		self.closed = true;
	}

	fn readLoop(self: *Conn, handler: anytype, reader: *Reader) !void {
		const stream = self.stream;
		const handle_ping = self._handle_ping;
		const handle_pong = self._handle_pong;
		const handle_close = self._handle_close;

		while (true) {
			const message = reader.readMessage(stream) catch |err| {
				switch (err) {
					error.LargeControl => try stream.writeAll(CLOSE_PROTOCOL_ERROR),
					error.ReservedFlags => try stream.writeAll(CLOSE_PROTOCOL_ERROR),
					else => {},
				}
				return;
			};

			switch (message.type) {
				.text, .binary => {
					try handler.handle(message);
					reader.handled();
					if (self.closed) {
						return;
					}
				},
				.pong => {
					if (handle_pong) {
						try handler.handle(message);
					}
				},
				.ping => {
					if (handle_ping) {
						try handler.handle(message);
					} else {
						const data = message.data;
						if (data.len == 0) {
							try stream.writeAll(EMPTY_PONG);
						} else {
							try self.writeFrame(.pong, data);
						}
					}
				},
				.close => {
					if (handle_close) {
						return handler.handle(message);
					}

					const data = message.data;
					const l = data.len;

					if (l == 0) {
						return self.writeClose();
					}

					if (l == 1) {
						// close with a payload always has to have at least a 2-byte payload,
						// since a 2-byte code is required
						return stream.writeAll(CLOSE_PROTOCOL_ERROR);
					}

					const code = @as(u16, @intCast(data[1])) | (@as(u16, @intCast(data[0])) << 8);
					if (code < 1000 or code == 1004 or code == 1005 or code == 1006 or (code > 1013 and code < 3000)) {
						return stream.writeAll(CLOSE_PROTOCOL_ERROR);
					}

					if (l == 2) {
						return try stream.writeAll(CLOSE_NORMAL);
					}

					const payload = data[2..];
					if (!std.unicode.utf8ValidateSlice(payload)) {
						// if we have a payload, it must be UTF8 (why?!)
						return try stream.writeAll(CLOSE_PROTOCOL_ERROR);
					}
					return self.writeClose();
				},
			}
		}
	}

	pub const Writer = struct {
		pos: usize,
		conn: *Conn,
		op_code: OpCode,
		bp: *buffer.Provider,
		buffer: buffer.Buffer,

		pub const Error = Allocator.Error;
		pub const IOWriter = std.io.Writer(*Writer, error{OutOfMemory}, Writer.write);

		fn init(conn: *Conn, op_code: OpCode) !Writer {
			return .{
				.pos = 0,
				.conn = conn,
				.bp = conn._bp,
				.op_code = op_code,
				.buffer = try conn._bp.allocPooledOr(512),
			};
		}

		pub fn deinit(self: *Writer) void {
			self.bp.free(self.buffer);
		}

		pub fn writer(self: *Writer) IOWriter {
			return .{.context = self};
		}

		pub fn write(self: *Writer, data: []const u8) Allocator.Error!usize {
			try self.ensureSpace(data.len);
			const pos = self.pos;
			const end_pos = pos + data.len;
			@memcpy(self.buffer.data[pos..end_pos], data);
			self.pos = end_pos;
			return data.len;
		}

		pub fn flush(self: *Writer) !void {
			try self.conn.writeFrame(self.op_code, self.buffer.data[0..self.pos]);
		}

		fn ensureSpace(self: *Writer, n: usize) !void {
			const pos = self.pos;
			const buf = self.buffer;
			const required_capacity = pos + n;

			if (buf.data.len >= required_capacity) {
				// we have enough space in our body as-is
				return;
			}

			// taken from std.ArrayList
			var new_capacity = buf.data.len;
			while (true) {
				new_capacity +|= new_capacity / 2 + 8;
				if (new_capacity >= required_capacity) break;
			}
			self.buffer = try self.bp.grow(&self.buffer, pos, new_capacity);
		}
	};
};

const read_no_timeout = std.mem.toBytes(os.timeval{
	.tv_sec = 0,
	.tv_usec = 0,
});

// used in handshake tests
pub fn readRequest(stream: anytype, buf: []u8, timeout: ?u32) ![]u8 {
	var deadline: ?i64 = null;
	var read_timeout: ?[@sizeOf(os.timeval)]u8 = null;
	if (timeout) |ms| {
		// our timeout for each individual read
		read_timeout = std.mem.toBytes(os.timeval{
			.tv_sec = @intCast(@divTrunc(ms, 1000)),
			.tv_usec = @intCast(@mod(ms, 1000) * 1000),
		});
		// our absolute deadline for reading the header
		deadline = std.time.milliTimestamp() + ms;
	}

	var total: usize = 0;
	while (true) {
		if (total == buf.len) {
			return error.TooLarge;
		}

		if (read_timeout) |to| {
			try os.setsockopt(stream.handle, os.SOL.SOCKET, os.SO.RCVTIMEO, &to);
		}

		const n = try stream.read(buf[total..]);
		if (n == 0) {
			return error.Invalid;
		}
		total += n;
		const request = buf[0..total];
		if (std.mem.endsWith(u8, request, "\r\n\r\n")) {
			if (read_timeout != null) {
				try os.setsockopt(stream.handle, os.SOL.SOCKET, os.SO.RCVTIMEO, &read_no_timeout);
			}
			return request;
		}

		if (deadline) |dl| {
			if (std.time.milliTimestamp() > dl) {
				return error.Timeout;
			}
		}
	}
}

const t = lib.testing;
test "Server: accept" {
	// we don't currently use this
	const context = TestContext{};
	const config = Config{
		.handshake_timeout_ms = null,
	};

	var server = try Server.init(t.allocator, config);
	defer server.deinit(t.allocator);

	var pair = t.SocketPair.init();
	defer pair.deinit();

	pair.handshakeRequest();
	const thrd = try std.Thread.spawn(.{}, Server.accept, .{&server, TestHandler, context, pair.server});
	try pair.handshakeReply();
	pair.textFrame(true, &.{0});
	pair.textFrame(true, &.{0});
	pair.binaryFrame(true, &.{255,255}); // special close frame
	pair.sendBuf();
	thrd.join();


	const r = pair.asReceived();
	defer r.deinit();
	try t.expectSlice(u8, &.{2, 0, 0, 0}, r.messages[0].data);
	try t.expectSlice(u8, &.{3, 0, 0, 0}, r.messages[1].data);
}

test "read messages" {
	{
		// simple small message
		var pair = t.SocketPair.init();
		pair.textFrame(true, "over 9000!");
		try testReadFrames(&pair, &.{Expect.text("over 9000!")});
	}

	{
		// single message exactly TEST_BUFFER_SIZE
		// header will be 8 bytes, so we make the message TEST_BUFFER_SIZE - 8 bytes
		const msg = [_]u8{'a'} ** (TEST_BUFFER_SIZE - 8);
		var pair = t.SocketPair.init();
		pair.textFrame(true, msg[0..]);
		try testReadFrames(&pair, &.{Expect.text(msg[0..])});
	}

	{
		// single message that is bigger than TEST_BUFFER_SIZE
		// header is 8 bytes, so if we make our message TEST_BUFFER_SIZE - 7, we'll
		// end up with a message which is exactly 1 byte larger than TEST_BUFFER_SIZE
		const msg = [_]u8{'a'} ** (TEST_BUFFER_SIZE - 7);
		var pair = t.SocketPair.init();
		pair.textFrame(true, msg[0..]);
		try testReadFrames(&pair, &.{Expect.text(msg[0..])});
	}

	{
		// single message that is much bigger than TEST_BUFFER_SIZE
		const msg = [_]u8{'a'} ** (TEST_BUFFER_SIZE * 2);
		var pair = t.SocketPair.init();
		pair.textFrame(true, msg[0..]);
		try testReadFrames(&pair, &.{Expect.text(msg[0..])});
	}

	{
		// multiple small messages
		var pair = t.SocketPair.init();
		pair.textFrame(true, "over");
		pair.textFrame(true, " ");
		pair.ping();
		pair.textFrame(true, "9000");
		pair.textFrame(true, "!");

		try testReadFrames(&pair, &.{
			Expect.text("over"),
			Expect.text(" "),
			Expect.pong(""),
			Expect.text("9000"),
			Expect.text("!")
		});
	}

	{
		// two messages, individually smaller than TEST_BUFFER_SIZE, but
		// their total length is greater than TEST_BUFFER_SIZE (this is an important
		// test as it requires special handling since the two messages are valid
		// but don't fit in a single buffer)
		const msg1 = [_]u8{'a'} ** (TEST_BUFFER_SIZE - 100);
		const msg2 = [_]u8{'b'} ** 200;
		var pair = t.SocketPair.init();
		pair.textFrame(true, msg1[0..]);
		pair.textFrame(true, msg2[0..]);

		try testReadFrames(&pair, &.{
			Expect.text(msg1[0..]),
			Expect.text(msg2[0..])
		});
	}

	{
		// two messages, the first bigger than TEST_BUFFER_SIZE, the second smaller
		const msg1 = [_]u8{'a'} ** (TEST_BUFFER_SIZE + 100);
		const msg2 = [_]u8{'b'} ** 200;
		var pair = t.SocketPair.init();
		pair.textFrame(true, msg1[0..]);
		pair.textFrame(true, msg2[0..]);

		try testReadFrames(&pair, &.{
			Expect.text(msg1[0..]),
			Expect.text(msg2[0..])
		});
	}

	{
		// Simple fragmented (websocket fragmentation)
		var pair = t.SocketPair.init();
		pair.textFrame(false, "over");
		pair.cont(true, " 9000!");
		try testReadFrames(&pair, &.{Expect.text("over 9000!")});
	}

	{
		// large fragmented (websocket fragmentation)
		const msg = [_]u8{'a'} ** (TEST_BUFFER_SIZE * 2 + 600);
		var pair = t.SocketPair.init();
		pair.textFrame(false, msg[0 .. TEST_BUFFER_SIZE + 100]);
		pair.cont(true, msg[TEST_BUFFER_SIZE + 100 ..]);
		try testReadFrames(&pair, &.{Expect.text(msg[0..])});
	}

	{
		// Fragmented with control in between
		var pair = t.SocketPair.init();
		pair.textFrame(false, "over");
		pair.ping();
		pair.cont(false, " ");
		pair.ping();
		pair.cont(true, "9000!");
		try testReadFrames(&pair, &.{
			Expect.pong(""),
			Expect.pong(""),
			Expect.text("over 9000!")
		});
	}

	{
		// Large Fragmented with control in between
		const msg = [_]u8{'b'} ** (TEST_BUFFER_SIZE * 2 + 600);
		var pair = t.SocketPair.init();
		pair.textFrame(false, msg[0 .. TEST_BUFFER_SIZE + 100]);
		pair.ping();
		pair.cont(false, msg[TEST_BUFFER_SIZE + 100 .. TEST_BUFFER_SIZE + 110]);
		pair.ping();
		pair.cont(true, msg[TEST_BUFFER_SIZE + 110 ..]);
		try testReadFrames(&pair, &.{
			Expect.pong(""),
			Expect.pong(""),
			Expect.text(msg[0..])
		});
	}

	{
		// Empty fragmented messages
		var pair = t.SocketPair.init();
		pair.textFrame(false, "");
		pair.cont(false, "");
		pair.cont(true, "");
		try testReadFrames(&pair, &.{Expect.text("")});
	}

	{
		// max-size control
		const msg = [_]u8{'z'} ** 125;
		var pair = t.SocketPair.init();
		pair.pingPayload(msg[0..]);
		try testReadFrames(&pair, &.{Expect.pong(msg[0..])});
	}
}

test "readFrame errors" {
	{
		// Nested non-control fragmented (websocket fragmentation)
		var pair = t.SocketPair.init();
		pair.textFrame(false, "over");
		pair.textFrame(false, " 9000!");
		try testReadFrames(&pair, &.{});
	}

	{
		// Nested non-control fragmented FIN (websocket fragmentation)
		var pair = t.SocketPair.init();
		pair.textFrame(false, "over");
		pair.textFrame(true, " 9000!");
		try testReadFrames(&pair, &.{});
	}

	{
		// control too big
		const msg = [_]u8{'z'} ** 126;
		var pair = t.SocketPair.init();
		pair.pingPayload(msg[0..]);
		try testReadFrames(&pair, &.{Expect.close(&.{3, 234})});
	}

	{
		// reserved bit1
		var pair = t.SocketPair.init();
		pair.textFrameReserved(true, "over9000", 64);
		try testReadFrames(&pair, &.{Expect.close(&.{3, 234})});

	}

	{
		// reserved bit2
		var pair = t.SocketPair.init();
		pair.textFrameReserved(true, "over9000", 32);
		try testReadFrames(&pair, &.{Expect.close(&.{3, 234})});
	}

	{
		// reserved bit3
		var pair = t.SocketPair.init();
		pair.textFrameReserved(true, "over9000", 16);
		try testReadFrames(&pair, &.{Expect.close(&.{3, 234})});
	}
}

test "conn: writer" {
	{
		var pair = t.SocketPair.init();
		defer pair.deinit();

		var tf = TestConnFactory.init(pair.server);
		defer tf.deinit();

		// short message (no growth)
		var conn = tf.conn();
		var wb = try conn.writeBuffer(.text);
		defer wb.deinit();

		try std.fmt.format(wb.writer(), "it's over {d}!!!", .{9000});
		try wb.flush();
		pair.server.close();
		try expectFrames(&.{Expect.text("it's over 9000!!!")}, &pair);
	}

	{
		var pair = t.SocketPair.init();
		defer pair.deinit();

		var tf = TestConnFactory.init(pair.server);
		defer tf.deinit();

		// message requiring growth
		var conn = tf.conn();
		var wb = try conn.writeBuffer(.binary);
		defer wb.deinit();

		var writer = wb.writer();
		for (0..1000) |_| {
			try writer.writeAll(".");
		}
		try wb.flush();
		pair.server.close();
		try expectFrames(&.{Expect.binary("." ** 1000)}, &pair);
	}
}

test "conn: writeFramed" {
	var pair = t.SocketPair.init();
	defer pair.deinit();

	var tf = TestConnFactory.init(pair.server);
	defer tf.deinit();

	var conn = tf.conn();
	try conn.writeFramed(&lib.framing.frame(.text, "must flow"));
	pair.server.close();
	try expectFrames(&.{Expect.text("must flow")}, &pair);
}

fn testReadFrames(pair: *t.SocketPair, expected: []const Expect) !void {
	defer pair.deinit();

	// we don't currently use this
	const context = TestContext{};

	// test with various random  TCP fragmentations
	// our t.Stream automatically fragments the frames on the first
	// call to read. Note this is TCP fragmentation, not websocket fragmentation
	const config = Config{
		.buffer_size = TEST_BUFFER_SIZE,
		.max_size = TEST_BUFFER_SIZE * 10,
		.handshake_timeout_ms = null,
	};

	var server = try Server.init(t.allocator, config);
	defer server.deinit(t.allocator);

	pair.handshakeRequest();
	const thrd = try std.Thread.spawn(.{}, Server.accept, .{&server, TestHandler, context, pair.server});
	try pair.handshakeReply();
	pair.binaryFrame(true, &.{255,255}); // special close frame
	pair.sendBuf();
	thrd.join();
	try expectFrames(expected, pair);
}

fn expectFrames(expected: []const Expect, pair: *t.SocketPair) !void {
	const r = pair.asReceived();
	defer r.deinit();
	const messages = r.messages;

	try t.expectEqual(expected.len, messages.len);
	var i: usize = 0;
	while (i < expected.len) : (i += 1) {
		const e = expected[i];
		const actual = messages[i];
		try t.expectEqual(e.type, actual.type);
		try t.expectString(e.data, actual.data);
	}
}

const TEST_BUFFER_SIZE = 512;
const TestContext = struct {};
const TestHandler = struct {
	conn: *Conn,
	counter: i32,
	init_ptr: usize,

	pub fn init(_: anytype, conn: *Conn, _: TestContext) !TestHandler {
		return .{
			.conn = conn,
			.counter = 0,
			.init_ptr = 0,
		};
	}

	pub fn afterInit(self: *TestHandler) !void {
		self.counter = 1;
		self.init_ptr = @intFromPtr(self);
	}

	// echo it back, so that it gets written back into our t.Stream
	pub fn handle(self: *TestHandler, message: lib.Message) !void {
		self.counter += 1;
		const data = message.data;
		switch (message.type) {
			.binary => {
				if (data.len == 2 and data[0] == 255 and data[1] == 255) {
					self.conn.close();
				} else {
					try self.conn.writeBin(data);
				}
			},
			.text => {
				if (data.len == 1 and data[0] == 0) {
					std.debug.assert(self.init_ptr == @intFromPtr(self));
					var buf: [4]u8 = undefined;
					std.mem.writeInt(i32, &buf, self.counter, .little);
					try self.conn.write(&buf);
				} else {
					try self.conn.write(data);
				}
			},
			else => unreachable,
		}
	}

	pub fn close(_: TestHandler) void {}
};

const Expect = struct {
	data: []const u8,
	type: lib.MessageType,

	fn text(data: []const u8) Expect {
		return .{
			.data = data,
			.type = .text,
		};
	}

	fn binary(data: []const u8) Expect {
		return .{
			.data = data,
			.type = .binary,
		};
	}

	fn pong(data: []const u8) Expect {
		return .{
			.data = data,
			.type = .pong,
		};
	}

	fn close(data: []const u8) Expect {
		return .{
			.data = data,
			.type = .close,
		};
	}
};

const TestConnFactory = struct {
	stream: net.Stream,
	bp: buffer.Provider,

	fn init(stream: net.Stream) TestConnFactory {
		const pool = t.allocator.create(buffer.Pool) catch unreachable;
		pool.* = buffer.Pool.init(t.allocator, 2, 100) catch unreachable;

		return .{
			.stream = stream,
			.bp = buffer.Provider.init(t.allocator, pool, 10),
		};
	}

	fn deinit(self: *TestConnFactory) void {
		self.bp.pool.deinit();
		t.allocator.destroy(self.bp.pool);
	}

	fn conn(self: *TestConnFactory) Conn {
		return .{
			._bp = &self.bp,
			.stream = self.stream,
		};
	}
};
