const std = @import("std");

/// Parses OSC (Operating System Command) escape sequences from the terminal
/// output stream to detect notifications. Supports:
///   - OSC 9   (iTerm2 growl notification)
///   - OSC 99  (kitty notification protocol)
///   - OSC 777 (rxvt-unicode notification)
///   - OSC 7   (CWD reporting — used for sidebar metadata)
///   - OSC 133 (prompt marking — used for semantic zones)
pub const OscParser = struct {
    state: State = .ground,
    buf: [4096]u8 = undefined,
    buf_len: usize = 0,
    osc_num: u32 = 0,

    pub const State = enum {
        ground,
        escape, // Saw ESC
        osc_start, // Saw ESC ]
        osc_num, // Parsing OSC number
        osc_body, // Reading OSC payload
    };

    pub const Notification = struct {
        title: []const u8,
        body: []const u8,
        osc_type: OscType,
    };

    pub const CwdReport = struct {
        uri: []const u8,
    };

    pub const OscType = enum {
        osc9, // iTerm2 growl
        osc99, // kitty notification
        osc777, // rxvt notification
    };

    pub const Event = union(enum) {
        notification: Notification,
        cwd_change: CwdReport,
        prompt_mark,
        none,
    };

    /// Feed bytes from the terminal output stream. Call this with each chunk
    /// of data read from the PTY. Returns an event if a complete OSC sequence
    /// was parsed.
    pub fn feed(self: *OscParser, byte: u8) Event {
        switch (self.state) {
            .ground => {
                if (byte == 0x1B) { // ESC
                    self.state = .escape;
                }
                return .none;
            },
            .escape => {
                if (byte == ']') { // OSC
                    self.state = .osc_start;
                    self.osc_num = 0;
                    self.buf_len = 0;
                } else {
                    self.state = .ground;
                }
                return .none;
            },
            .osc_start => {
                if (byte >= '0' and byte <= '9') {
                    self.osc_num = byte - '0';
                    self.state = .osc_num;
                } else {
                    self.state = .ground;
                }
                return .none;
            },
            .osc_num => {
                if (byte >= '0' and byte <= '9') {
                    self.osc_num = self.osc_num * 10 + (byte - '0');
                } else if (byte == ';') {
                    self.state = .osc_body;
                } else if (byte == 0x07 or byte == 0x1B) { // BEL or ST
                    // OSC with number only, no body
                    return self.processOsc();
                } else {
                    self.state = .ground;
                }
                return .none;
            },
            .osc_body => {
                if (byte == 0x07) { // BEL — terminates OSC
                    return self.processOsc();
                } else if (byte == 0x1B) { // ESC — could be start of ST (ESC \)
                    // For simplicity, treat ESC as terminator
                    return self.processOsc();
                } else {
                    if (self.buf_len < self.buf.len) {
                        self.buf[self.buf_len] = byte;
                        self.buf_len += 1;
                    }
                }
                return .none;
            },
        }
    }

    fn processOsc(self: *OscParser) Event {
        defer {
            self.state = .ground;
            self.buf_len = 0;
        }

        const body = self.buf[0..self.buf_len];

        return switch (self.osc_num) {
            7 => .{ .cwd_change = .{ .uri = body } },
            9 => self.parseNotification(body, .osc9),
            99 => self.parseKittyNotification(body),
            133 => .prompt_mark,
            777 => self.parseRxvtNotification(body),
            else => .none,
        };
    }

    /// Parse OSC 9 (iTerm2 growl): `ESC ] 9 ; <message> BEL`
    fn parseNotification(self: *OscParser, body: []const u8, osc_type: OscType) Event {
        _ = self;
        return .{ .notification = .{
            .title = "",
            .body = body,
            .osc_type = osc_type,
        } };
    }

    /// Parse OSC 99 (kitty notification): `ESC ] 99 ; i=<id>:<title> ; <body> BEL`
    /// Simplified parsing — extract title and body.
    fn parseKittyNotification(self: *OscParser, body: []const u8) Event {
        _ = self;
        // Look for the first semicolon to split title;body
        if (std.mem.indexOf(u8, body, ";")) |sep| {
            // Title may have key=value pairs before the actual title
            var title = body[0..sep];
            if (std.mem.indexOf(u8, title, ":")) |colon| {
                title = title[colon + 1 ..];
            }
            return .{ .notification = .{
                .title = title,
                .body = if (sep + 1 < body.len) body[sep + 1 ..] else "",
                .osc_type = .osc99,
            } };
        }
        return .{ .notification = .{
            .title = "",
            .body = body,
            .osc_type = .osc99,
        } };
    }

    /// Parse OSC 777 (rxvt): `ESC ] 777 ; notify ; <title> ; <body> BEL`
    fn parseRxvtNotification(self: *OscParser, body: []const u8) Event {
        _ = self;
        // Format: "notify;<title>;<body>"
        var iter = std.mem.splitScalar(u8, body, ';');
        const cmd = iter.next() orelse return .none;

        if (!std.mem.eql(u8, cmd, "notify")) return .none;

        const title = iter.next() orelse "";
        const msg_body = iter.next() orelse "";

        return .{ .notification = .{
            .title = title,
            .body = msg_body,
            .osc_type = .osc777,
        } };
    }

    /// Reset parser state.
    pub fn reset(self: *OscParser) void {
        self.state = .ground;
        self.buf_len = 0;
        self.osc_num = 0;
    }
};

test "OscParser: OSC 9 notification" {
    var parser = OscParser{};

    // Feed: ESC ] 9 ; Hello BEL
    const seq = "\x1b]9;Hello World\x07";
    var result: OscParser.Event = .none;
    for (seq) |byte| {
        result = parser.feed(byte);
    }
    switch (result) {
        .notification => |n| {
            try std.testing.expectEqualStrings("Hello World", n.body);
            try std.testing.expectEqual(OscParser.OscType.osc9, n.osc_type);
        },
        else => return error.TestFailed,
    }
}

test "OscParser: OSC 7 CWD" {
    var parser = OscParser{};

    const seq = "\x1b]7;file:///home/user/project\x07";
    var result: OscParser.Event = .none;
    for (seq) |byte| {
        result = parser.feed(byte);
    }
    switch (result) {
        .cwd_change => |cwd| {
            try std.testing.expectEqualStrings("file:///home/user/project", cwd.uri);
        },
        else => return error.TestFailed,
    }
}

test "OscParser: OSC 777 rxvt notification" {
    var parser = OscParser{};

    const seq = "\x1b]777;notify;Build;Complete\x07";
    var result: OscParser.Event = .none;
    for (seq) |byte| {
        result = parser.feed(byte);
    }
    switch (result) {
        .notification => |n| {
            try std.testing.expectEqualStrings("Build", n.title);
            try std.testing.expectEqualStrings("Complete", n.body);
            try std.testing.expectEqual(OscParser.OscType.osc777, n.osc_type);
        },
        else => return error.TestFailed,
    }
}
