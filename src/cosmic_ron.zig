//! #700 — COSMIC 단축키 파일 (`com.system76.CosmicSettings.Shortcuts/v1/custom`) 을 **줄이 아니라
//! 구조로** 다룬다.
//!
//! 그 파일은 RON 맵 (`{ 키: 값, … }`) 이다. 예전 코드는 "한 항목은 한 줄" 이라고 보고 줄을 지웠는데,
//! COSMIC 설정 화면은 항목을 여러 줄로 다시 쓴다 (`ron::ser::to_string_pretty`). 그러면 우리 항목의
//! 일부 줄만 지워져 파일이 깨지고, COSMIC 은 사용자 단축키 **전체**를 버렸다 (#681).
//!
//! RON 전체를 해석하지는 않는다. 필요한 것은 셋뿐이다.
//!   1. 파일이 괄호 · 문자열 짝이 맞는 맵 하나인지.
//!   2. 항목마다 시작과 끝 위치.
//!   3. 키 튜플 (`Binding`) 의 `modifiers` · `key` · `description`, 값의 `Spawn("…")` 명령.
//! 그래서 글자를 앞에서부터 읽으며 괄호 깊이 · 문자열 · 문자 · 주석만 알아보는 작은 스캐너다.
//! 쓸 수 있는 Zig RON 라이브러리가 없어서 직접 둔다 (#700 — 유일한 Zig 판은 2021 년에 멈췄고
//! 쓰기가 없다). 문법 세부 (raw 문자열 `r#"…"#`, 중첩 블록 주석) 는 Rust `ron` crate 를 따른다.
//!
//! 고칠 때는 우리 항목의 바이트 범위만 빼고 넣는다. **우리 항목 밖의 글자는 한 글자도 바꾸지 않는다**
//! — 원래 COSMIC 이 읽던 파일이면 고친 뒤에도 그대로 읽힌다. 고친 결과는 다시 스캔해서 온전하고
//! 항목 수가 맞을 때만 돌려준다.
const std = @import("std");

pub const Error = error{UnsupportedCosmicShortcutFormat};

pub const Entry = struct {
    /// 키 튜플이 시작하는 위치.
    start: usize,
    /// 값이 끝나는 위치 (뒤따르는 쉼표 앞).
    end: usize,
    /// 뒤따르는 쉼표 다음 위치. 쉼표가 없으면 `end` 와 같다.
    after: usize,
    key: []const u8,
    value: []const u8,

    pub fn hasComma(self: Entry) bool {
        return self.after != self.end;
    }
};

pub const Map = struct {
    /// 여는 `{` 위치.
    open: usize,
    /// 닫는 `}` 위치.
    close: usize,
    entries: []Entry,

    pub fn deinit(self: Map, allocator: std.mem.Allocator) void {
        allocator.free(self.entries);
    }
};

const Scanner = struct {
    src: []const u8,
    pos: usize = 0,

    fn isSpace(c: u8) bool {
        return c == ' ' or c == '\t' or c == '\n' or c == '\r';
    }

    fn isIdent(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '_';
    }

    fn atComment(s: *const Scanner) bool {
        return s.pos + 1 < s.src.len and s.src[s.pos] == '/' and (s.src[s.pos + 1] == '/' or s.src[s.pos + 1] == '*');
    }

    /// 공백과 주석을 넘긴다. RON 의 블록 주석은 중첩된다.
    fn skipTrivia(s: *Scanner) Error!void {
        while (s.pos < s.src.len) {
            if (isSpace(s.src[s.pos])) {
                s.pos += 1;
            } else if (s.atComment()) {
                try s.skipComment();
            } else break;
        }
    }

    fn skipComment(s: *Scanner) Error!void {
        if (s.src[s.pos + 1] == '/') {
            s.pos = std.mem.findScalarPos(u8, s.src, s.pos, '\n') orelse s.src.len;
            return;
        }
        var depth: usize = 0;
        while (s.pos + 1 < s.src.len) {
            if (s.src[s.pos] == '/' and s.src[s.pos + 1] == '*') {
                depth += 1;
                s.pos += 2;
            } else if (s.src[s.pos] == '*' and s.src[s.pos + 1] == '/') {
                depth -= 1;
                s.pos += 2;
                if (depth == 0) return;
            } else s.pos += 1;
        }
        return error.UnsupportedCosmicShortcutFormat;
    }

    fn skipString(s: *Scanner) Error!void {
        s.pos += 1; // 여는 "
        while (s.pos < s.src.len) {
            switch (s.src[s.pos]) {
                '\\' => s.pos += 2,
                '"' => {
                    s.pos += 1;
                    return;
                },
                else => s.pos += 1,
            }
        }
        return error.UnsupportedCosmicShortcutFormat;
    }

    /// `r"…"` · `r#"…"#`. `r#ident` (raw 식별자) 는 `#` 뒤에 `"` 가 없어 식별자로 넘긴다.
    fn skipRaw(s: *Scanner) Error!void {
        s.pos += 1; // r
        var hashes: usize = 0;
        while (s.pos < s.src.len and s.src[s.pos] == '#') : (s.pos += 1) hashes += 1;
        if (s.pos >= s.src.len or s.src[s.pos] != '"') {
            while (s.pos < s.src.len and isIdent(s.src[s.pos])) s.pos += 1;
            return;
        }
        s.pos += 1;
        while (s.pos < s.src.len) : (s.pos += 1) {
            if (s.src[s.pos] != '"') continue;
            var n: usize = 0;
            while (n < hashes and s.pos + 1 + n < s.src.len and s.src[s.pos + 1 + n] == '#') n += 1;
            if (n == hashes) {
                s.pos += 1 + hashes;
                return;
            }
        }
        return error.UnsupportedCosmicShortcutFormat;
    }

    /// 문자 리터럴 `'x'` · `'\n'` · 여러 바이트 UTF-8 글자.
    fn skipChar(s: *Scanner) Error!void {
        s.pos += 1;
        if (s.pos >= s.src.len) return error.UnsupportedCosmicShortcutFormat;
        if (s.src[s.pos] == '\\') {
            s.pos += 2;
            // `'\u{1F600}'` 같은 긴 escape 는 닫는 따옴표까지 간다.
            while (s.pos < s.src.len and s.src[s.pos] != '\'') s.pos += 1;
        } else {
            s.pos += std.unicode.utf8ByteSequenceLength(s.src[s.pos]) catch 1;
        }
        if (s.pos >= s.src.len or s.src[s.pos] != '\'') return error.UnsupportedCosmicShortcutFormat;
        s.pos += 1;
    }

    /// 값 하나 (키 튜플 · 값) 를 넘긴다. 깊이 0 에서 `stops` 의 글자를 만나면 멈추고, 그 앞의 마지막
    /// 의미 있는 글자까지를 `[시작, 끝)` 으로 돌려준다 (뒤의 공백 · 주석은 빼고).
    fn skipValue(s: *Scanner, stops: []const u8) Error![2]usize {
        try s.skipTrivia();
        const start = s.pos;
        var last_end = s.pos;
        var depth: usize = 0;
        while (s.pos < s.src.len) {
            const c = s.src[s.pos];
            if (depth == 0 and std.mem.findScalar(u8, stops, c) != null) break;
            if (isSpace(c)) {
                s.pos += 1;
                continue;
            }
            if (s.atComment()) {
                try s.skipComment();
                continue;
            }
            switch (c) {
                '(', '[', '{' => {
                    depth += 1;
                    s.pos += 1;
                },
                ')', ']', '}' => {
                    if (depth == 0) return error.UnsupportedCosmicShortcutFormat;
                    depth -= 1;
                    s.pos += 1;
                },
                '"' => try s.skipString(),
                '\'' => try s.skipChar(),
                'r' => {
                    const raw_start = s.pos + 1 < s.src.len and (s.src[s.pos + 1] == '"' or s.src[s.pos + 1] == '#');
                    const at_boundary = s.pos == 0 or !isIdent(s.src[s.pos - 1]);
                    if (raw_start and at_boundary) try s.skipRaw() else s.pos += 1;
                },
                else => s.pos += 1,
            }
            last_end = s.pos;
        }
        if (depth != 0 or last_end == start) return error.UnsupportedCosmicShortcutFormat;
        return .{ start, last_end };
    }
};

/// 파일 전체를 맵 하나로 읽는다. 맵이 아니거나 짝이 안 맞거나 뒤에 다른 것이 있으면 오류다 — 그런
/// 파일은 **쓰지 않는다** (호출부가 그대로 둔다).
pub fn scan(allocator: std.mem.Allocator, src: []const u8) (Error || std.mem.Allocator.Error)!Map {
    var s: Scanner = .{ .src = src };
    if (std.mem.startsWith(u8, src, "\xEF\xBB\xBF")) s.pos = 3;
    try s.skipTrivia();
    if (s.pos >= src.len or src[s.pos] != '{') return error.UnsupportedCosmicShortcutFormat;
    const open = s.pos;
    s.pos += 1;

    var entries: std.ArrayList(Entry) = .empty;
    errdefer entries.deinit(allocator);
    while (true) {
        try s.skipTrivia();
        if (s.pos >= src.len) return error.UnsupportedCosmicShortcutFormat;
        if (src[s.pos] == '}') break;

        const key = try s.skipValue(":");
        if (s.pos >= src.len or src[s.pos] != ':') return error.UnsupportedCosmicShortcutFormat;
        s.pos += 1;
        // 값은 깊이 0 에서 `:` 를 품을 수 없다 — 거기서 멈춰야 쉼표가 빠진 파일을 깨진 것으로 본다.
        const value = try s.skipValue(",}:");
        if (s.pos >= src.len) return error.UnsupportedCosmicShortcutFormat;
        var after = value[1];
        if (src[s.pos] == ',') {
            s.pos += 1;
            after = s.pos;
        }
        try entries.append(allocator, .{
            .start = key[0],
            .end = value[1],
            .after = after,
            .key = src[key[0]..key[1]],
            .value = src[value[0]..value[1]],
        });
        // 쉼표가 없으면 그것이 마지막 항목이어야 한다.
        if (after == value[1] and src[s.pos] != '}') return error.UnsupportedCosmicShortcutFormat;
    }
    const close = s.pos;
    s.pos += 1;
    try s.skipTrivia();
    if (s.pos != src.len) return error.UnsupportedCosmicShortcutFormat;
    return .{ .open = open, .close = close, .entries = try entries.toOwnedSlice(allocator) };
}

/// 튜플 `(이름: 값, …)` 에서 `name` 필드의 값 텍스트. 키 튜플 (`Binding`) 의 필드를 꺼낼 때 쓴다.
pub fn field(tuple: []const u8, name: []const u8) ?[]const u8 {
    if (tuple.len < 2 or tuple[0] != '(' or tuple[tuple.len - 1] != ')') return null;
    var s: Scanner = .{ .src = tuple[1 .. tuple.len - 1] };
    while (true) {
        s.skipTrivia() catch return null;
        if (s.pos >= s.src.len) return null;
        const name_start = s.pos;
        while (s.pos < s.src.len and Scanner.isIdent(s.src[s.pos])) s.pos += 1;
        const got = s.src[name_start..s.pos];
        if (got.len == 0) return null;
        s.skipTrivia() catch return null;
        if (s.pos >= s.src.len or s.src[s.pos] != ':') return null;
        s.pos += 1;
        const value = s.skipValue(",") catch return null;
        if (std.mem.eql(u8, got, name)) return s.src[value[0]..value[1]];
        if (s.pos >= s.src.len) return null;
        s.pos += 1; // ,
    }
}

/// `"…"` 를 escape 를 풀어 `buf` 에 담는다. 문자열이 아니거나 버퍼가 모자라면 `null`.
pub fn string(text: []const u8, buf: []u8) ?[]const u8 {
    if (text.len < 2 or text[0] != '"' or text[text.len - 1] != '"') return null;
    const inner = text[1 .. text.len - 1];
    var out: usize = 0;
    var i: usize = 0;
    while (i < inner.len) : (i += 1) {
        var byte = inner[i];
        if (byte == '"') return null;
        if (byte == '\\') {
            i += 1;
            if (i >= inner.len) return null;
            byte = switch (inner[i]) {
                'n' => '\n',
                't' => '\t',
                'r' => '\r',
                '0' => 0,
                else => |b| b, // `\\` · `\"` · `\'`
            };
        }
        if (out >= buf.len) return null;
        buf[out] = byte;
        out += 1;
    }
    return buf[0..out];
}

/// `Some("…")` 의 문자열. `None` 이나 다른 모양이면 `null`.
pub fn someString(text: []const u8, buf: []u8) ?[]const u8 {
    const open = "Some(";
    if (!std.mem.startsWith(u8, text, open) or text[text.len - 1] != ')') return null;
    return string(std.mem.trim(u8, text[open.len .. text.len - 1], " \t\r\n"), buf);
}

/// 값 `Spawn("…")` 의 명령 문자열.
pub fn spawnCommand(value: []const u8, buf: []u8) ?[]const u8 {
    const open = "Spawn(";
    if (!std.mem.startsWith(u8, value, open) or value[value.len - 1] != ')') return null;
    return string(std.mem.trim(u8, value[open.len .. value.len - 1], " \t\r\n"), buf);
}

/// 줄 끝까지 공백뿐이면 그 줄바꿈 다음 위치, 아니면 `null`.
fn restOfLineBlank(src: []const u8, from: usize) ?usize {
    var i = from;
    while (i < src.len and (src[i] == ' ' or src[i] == '\t' or src[i] == '\r')) i += 1;
    if (i == src.len) return i;
    if (src[i] == '\n') return i + 1;
    return null;
}

/// 줄 시작부터 `to` 까지 공백뿐이면 그 줄 시작 위치, 아니면 `null`.
fn lineStartIfBlank(src: []const u8, to: usize) ?usize {
    var i = to;
    while (i > 0 and (src[i - 1] == ' ' or src[i - 1] == '\t')) i -= 1;
    if (i == 0 or src[i - 1] == '\n') return i;
    return null;
}

const Edit = struct { pos: usize, delete_to: usize, text: []const u8 };

fn lessEdit(_: void, a: Edit, b: Edit) bool {
    return a.pos < b.pos;
}

/// `remove[i]` 가 참인 항목을 빼고, 닫는 `}` 앞에 `insert` 를 넣는다. `insert` 는 완성된 줄들이다
/// (줄마다 들여쓰기 + 항목 + `,\n`). `insert_count` 는 그 안의 항목 수 — 결과를 다시 스캔해서
/// 항목 수가 `남긴 수 + insert_count` 와 같은지 확인한다.
///
/// 빼는 항목이 한 줄을 통째로 차지하면 그 줄 (들여쓰기 · 줄바꿈 포함) 을 지운다. 같은 줄에 다른
/// 것이 있으면 항목과 쉼표만 지운다. 남는 마지막 항목에 쉼표가 없는데 뒤에 넣을 것이 있으면
/// 그 항목 끝에 쉼표를 붙인다. 그 밖의 글자는 그대로 둔다.
pub fn rewrite(
    allocator: std.mem.Allocator,
    src: []const u8,
    map: Map,
    remove: []const bool,
    insert: []const u8,
    insert_count: usize,
) (Error || std.mem.Allocator.Error)![]u8 {
    std.debug.assert(remove.len == map.entries.len);
    var edits: std.ArrayList(Edit) = .empty;
    defer edits.deinit(allocator);

    // `{}` 처럼 한 줄인 맵에 넣을 때 만드는 글자 (`\n` + insert). 함수 끝에서 한 번 해제한다.
    var owned_text: ?[]u8 = null;
    defer if (owned_text) |t| allocator.free(t);

    var kept: usize = 0;
    var last_kept: ?Entry = null;
    for (map.entries, remove) |entry, gone| {
        if (!gone) {
            kept += 1;
            last_kept = entry;
            continue;
        }
        var from = entry.start;
        var to = entry.after;
        if (lineStartIfBlank(src, entry.start)) |line_start| {
            if (restOfLineBlank(src, entry.after)) |line_end| {
                from = line_start;
                to = line_end;
            }
        }
        if (to == entry.after) {
            // 같은 줄에 다른 것이 남는다 — 항목 뒤의 공백만 함께 지운다.
            while (to < src.len and (src[to] == ' ' or src[to] == '\t')) to += 1;
        }
        try edits.append(allocator, .{ .pos = from, .delete_to = to, .text = "" });
    }

    if (insert.len != 0) {
        if (last_kept) |entry| {
            if (!entry.hasComma()) try edits.append(allocator, .{ .pos = entry.end, .delete_to = entry.end, .text = "," });
        }
        if (lineStartIfBlank(src, map.close)) |line_start| {
            // 닫는 `}` 가 제 줄에 있다 — 그 줄 앞에 넣는다. 다만 바로 앞이 지울 줄이면 그 줄이
            // 끝나는 자리와 같으니 순서가 그대로다 (지우기의 `pos` 가 더 앞이다).
            try edits.append(allocator, .{ .pos = line_start, .delete_to = line_start, .text = insert });
        } else {
            // `{}` 처럼 한 줄 — `}` 앞에서 줄을 바꿔 넣는다.
            owned_text = try std.mem.concat(allocator, u8, &.{ "\n", insert });
            try edits.append(allocator, .{ .pos = map.close, .delete_to = map.close, .text = owned_text.? });
        }
    }

    std.mem.sort(Edit, edits.items, {}, lessEdit);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var cursor: usize = 0;
    for (edits.items) |edit| {
        std.debug.assert(edit.pos >= cursor);
        try out.appendSlice(allocator, src[cursor..edit.pos]);
        try out.appendSlice(allocator, edit.text);
        cursor = edit.delete_to;
    }
    try out.appendSlice(allocator, src[cursor..]);

    // 고친 결과가 온전한지 다시 본다. 아니면 쓰지 않는다.
    const result = try out.toOwnedSlice(allocator);
    errdefer allocator.free(result);
    const check = try scan(allocator, result);
    defer check.deinit(allocator);
    if (check.entries.len != kept + insert_count) return error.UnsupportedCosmicShortcutFormat;
    return result;
}

// ---------------------------------------------------------------------------------------------
// 테스트 — 표본은 실제 COSMIC 파일의 모양이다.

/// #681 본문의 실제 모양 — COSMIC 설정 화면이 쓴 여러 줄 항목.
const pretty_sample =
    \\{
    \\    (
    \\        modifiers: [
    \\            Super,
    \\        ],
    \\        key: "Print",
    \\    ): System(Screenshot),
    \\    (
    \\        modifiers: [],
    \\        key: "F1",
    \\        description: Some("TildaZ_0"),
    \\    ): Spawn("/home/myuser/tildaz/tildaz --toggle 0"),
    \\    (
    \\        modifiers: [
    \\            Super,
    \\        ],
    \\        key: "v",
    \\    ): Spawn("vicinae vicinae://launch/clipboard/history"),
    \\}
;

test "#700 scan reads multi-line entries written by COSMIC Settings" {
    const a = std.testing.allocator;
    const map = try scan(a, pretty_sample);
    defer map.deinit(a);
    try std.testing.expectEqual(@as(usize, 3), map.entries.len);
    var buf: [256]u8 = undefined;
    const second = map.entries[1];
    try std.testing.expectEqualStrings("\"F1\"", field(second.key, "key").?);
    try std.testing.expectEqualStrings("[]", field(second.key, "modifiers").?);
    try std.testing.expectEqualStrings("TildaZ_0", someString(field(second.key, "description").?, &buf).?);
    try std.testing.expectEqualStrings("/home/myuser/tildaz/tildaz --toggle 0", spawnCommand(second.value, &buf).?);
    try std.testing.expect(field(map.entries[0].key, "description") == null);
    try std.testing.expectEqualStrings("System(Screenshot)", map.entries[0].value);
}

test "#700 scan reads one-line entries and keeps brackets inside strings and comments" {
    const a = std.testing.allocator;
    const src =
        \\// user's note: { not a map }
        \\{
        \\    (modifiers: [], key: "F1", description: Some("TildaZ_0")): Spawn("/usr/bin/tildaz --toggle 0"),
        \\    /* nested /* comment */ with ) and } */
        \\    (modifiers: [Ctrl], key: "x"): Spawn("sh -c 'echo }, ) ]; printf \"q\"'"),
        \\    (modifiers: [Alt], key: "y"): Spawn(r#"raw "quoted" } string"#),
        \\    (modifiers: [Super], key: "z"): Spawn("last without comma")
        \\}
        \\
    ;
    const map = try scan(a, src);
    defer map.deinit(a);
    try std.testing.expectEqual(@as(usize, 4), map.entries.len);
    try std.testing.expect(map.entries[2].hasComma());
    try std.testing.expect(!map.entries[3].hasComma());
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("sh -c 'echo }, ) ]; printf \"q\"'", spawnCommand(map.entries[1].value, &buf).?);
}

test "#700 scan refuses a file it cannot read safely" {
    const a = std.testing.allocator;
    const broken = [_][]const u8{
        "",
        "not a map",
        "{ (modifiers: [], key: \"F1\"): Spawn(\"x\"), ",
        "{ (modifiers: [], key: \"F1\"): Spawn(\"unclosed), }",
        "{ (modifiers: [, key: \"F1\"): Close, }",
        "{ (modifiers: [], key: \"F1\"): Close } trailing",
        "{ (modifiers: [], key: \"F1\") Close, }",
        "{ (a: 1): Close (b: 2): Close }",
        // #681 의 결과물 — 우리 옛 코드가 남긴 깨진 파일.
        "{\n    (\n        modifiers: [],\n        key: \"F1\",\n    (modifiers: [], key: \"F1\", description: Some(\"TildaZ_0\")):\n}\n",
    };
    for (broken) |src| {
        try std.testing.expectError(error.UnsupportedCosmicShortcutFormat, scan(a, src));
    }
    const empty = try scan(a, "{}");
    defer empty.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), empty.entries.len);
}

test "#700 rewrite removes a multi-line entry and adds ours without touching the rest" {
    const a = std.testing.allocator;
    const map = try scan(a, pretty_sample);
    defer map.deinit(a);
    const line = "    (modifiers: [], key: \"F2\", description: Some(\"TildaZ_0\")): Spawn(\"/usr/bin/tildaz --toggle 0\"),\n";
    const out = try rewrite(a, pretty_sample, map, &.{ false, true, false }, line, 1);
    defer a.free(out);
    try std.testing.expectEqualStrings(
        \\{
        \\    (
        \\        modifiers: [
        \\            Super,
        \\        ],
        \\        key: "Print",
        \\    ): System(Screenshot),
        \\    (
        \\        modifiers: [
        \\            Super,
        \\        ],
        \\        key: "v",
        \\    ): Spawn("vicinae vicinae://launch/clipboard/history"),
        \\    (modifiers: [], key: "F2", description: Some("TildaZ_0")): Spawn("/usr/bin/tildaz --toggle 0"),
        \\}
    , out);
}

test "#700 rewrite adds the missing comma and handles an empty one-line map" {
    const a = std.testing.allocator;
    const line = "    (modifiers: [], key: \"F1\", description: Some(\"TildaZ_0\")): Spawn(\"t --toggle 0\"),\n";

    const no_comma = "{\n    (modifiers: [Super], key: \"z\"): Close\n}\n";
    const map1 = try scan(a, no_comma);
    defer map1.deinit(a);
    const out1 = try rewrite(a, no_comma, map1, &.{false}, line, 1);
    defer a.free(out1);
    try std.testing.expectEqualStrings("{\n    (modifiers: [Super], key: \"z\"): Close,\n" ++ line ++ "}\n", out1);

    const map2 = try scan(a, "{}");
    defer map2.deinit(a);
    const out2 = try rewrite(a, "{}", map2, &.{}, line, 1);
    defer a.free(out2);
    try std.testing.expectEqualStrings("{\n" ++ line ++ "}", out2);

    // 지우기만 — 넣을 것이 없으면 쉼표도 줄바꿈도 더하지 않는다.
    const two = "{\n    (modifiers: [], key: \"a\"): Close,\n    (modifiers: [], key: \"b\"): Close,\n}\n";
    const map3 = try scan(a, two);
    defer map3.deinit(a);
    const out3 = try rewrite(a, two, map3, &.{ false, true }, "", 0);
    defer a.free(out3);
    try std.testing.expectEqualStrings("{\n    (modifiers: [], key: \"a\"): Close,\n}\n", out3);
}

test "#700 rewrite removes an entry that shares its line with another" {
    const a = std.testing.allocator;
    const src = "{ (modifiers: [], key: \"a\"): Close, (modifiers: [], key: \"b\"): Close }";
    const map = try scan(a, src);
    defer map.deinit(a);
    const out = try rewrite(a, src, map, &.{ true, false }, "", 0);
    defer a.free(out);
    try std.testing.expectEqualStrings("{ (modifiers: [], key: \"b\"): Close }", out);
}
