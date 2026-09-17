const std = @import("std");
const Allocator = @import("std").mem.Allocator;
const Plane = @import("renderer").Plane;
const command = @import("command");
const Widget = @import("Widget.zig");
const WidgetList = @import("WidgetList.zig");
const Panel = @import("Panel.zig");
const PanelInput = @import("PanelInput.zig");
const tp = @import("thespian");
const tui = @import("tui.zig");
const syntax = @import("syntax");

pub const name = @typeName(Self);

const Self = @This();

/// Inline emphasis that maps onto a font style rather than a theme scope.
const Emphasis = enum { none, bold, italic };

/// A styled run within a line. `scope` is a tree-sitter capture name or a
/// theme scope, resolved against the active theme at render time; an empty
/// scope leaves the base style alone.
const Span = struct {
    start: usize,
    end: usize,
    scope: []const u8 = "",
    emphasis: Emphasis = .none,
};

const Line = struct {
    text: []const u8,
    spans: []const Span = &.{},
    /// draw as a horizontal rule across the full box width
    rule: bool = false,
};

/// How a line that exceeds the available width may be broken.
const BreakKind = enum {
    /// break at spaces, dropping the space
    word,
    /// prefer a separator, but hard-break rather than overflow
    code,
};

allocator: std.mem.Allocator,
plane: Plane,

view_rows: usize = 0,
lines: std.ArrayList(Line),
/// tree-sitter parsers kept alive per language, keyed by fence tag
parsers: std.StringHashMapUnmanaged(*syntax) = .empty,
widget_type: Widget.Type,
panel_input: ?PanelInput = null,
top: usize = 0,

const default_widget_type: Widget.Type = .panel;

/// continuation indent for wrapped code lines
const code_indent = "    ";

pub const panel_tag = "info";
pub const panel_singleton = true;

pub fn panel_title(_: *Self) []const u8 {
    return "Info";
}

pub fn panel_icon(_: *Self) []const u8 {
    return "\u{ea74}";
}

pub fn create(allocator: Allocator, parent: Plane, _: command.Context) !Panel {
    const self = try init(allocator, parent, default_widget_type);
    errdefer self.deinit(allocator);
    self.panel_input = try PanelInput.init(allocator, "info");
    return Panel.to(self);
}

pub fn create_widget_type(allocator: Allocator, parent: Plane, widget_type: Widget.Type) !Widget {
    const container = try WidgetList.createHStyled(allocator, parent, "panel_frame", .dynamic, widget_type);
    errdefer container.deinit(allocator);
    const self = try init(allocator, parent, widget_type);
    container.ctx = self;
    try container.add(Widget.to(self));
    return container.widget();
}

fn init(allocator: Allocator, parent: Plane, widget_type: Widget.Type) !*Self {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);
    self.* = .{
        .allocator = allocator,
        .plane = try Plane.init(&(Widget.Box{}).opts(name), parent),
        .lines = .empty,
        .widget_type = widget_type,
    };
    return self;
}

pub fn deinit(self: *Self, allocator: Allocator) void {
    if (self.panel_input) |*panel_input| panel_input.deinit(Widget.to(self));
    self.clear();
    self.lines.deinit(self.allocator);
    var it = self.parsers.iterator();
    while (it.next()) |entry| {
        entry.value_ptr.*.destroy();
        self.allocator.free(entry.key_ptr.*);
    }
    self.parsers.deinit(self.allocator);
    self.plane.deinit();
    allocator.destroy(self);
}

pub fn focus(self: *Self) void {
    if (self.panel_input) |*panel_input| panel_input.focus(Widget.to(self));
}

pub fn unfocus(self: *Self) void {
    if (self.panel_input) |*panel_input| panel_input.unfocus(Widget.to(self));
}

pub fn receive(self: *Self, from: tp.pid_ref, m: tp.message) error{Exit}!bool {
    return if (self.panel_input) |*panel_input| panel_input.receive(from, m) else false;
}

pub fn panel_scroll(self: *Self, action: Panel.ScrollAction) void {
    const rows = @max(1, self.view_rows);
    const max_top = self.lines.items.len -| rows;
    self.top = @min(max_top, switch (action) {
        .line_up => self.top -| 1,
        .line_down => self.top + 1,
        .page_up => self.top -| rows,
        .page_down => self.top + rows,
        .top => 0,
        .bottom => max_top,
    });
    tui.need_render(@src());
}

pub fn panel_copy(self: *Self) void {
    var text: std.Io.Writer.Allocating = .init(self.allocator);
    defer text.deinit();
    for (self.lines.items) |line| text.writer.print("{s}\n", .{line.text}) catch return;
    PanelInput.copy_to_clipboard(text.written());
}

pub fn clear(self: *Self) void {
    for (self.lines.items) |line| {
        for (line.spans) |span| if (span.scope.len > 0) self.allocator.free(span.scope);
        if (line.spans.len > 0) self.allocator.free(line.spans);
        self.allocator.free(line.text);
    }
    self.lines.clearRetainingCapacity();
}

pub fn handle_resize(self: *Self, pos: Widget.Box) void {
    self.plane.move_yx(@intCast(pos.y), @intCast(pos.x)) catch return;
    self.plane.resize_simple(@intCast(pos.h), @intCast(pos.w)) catch return;
    self.view_rows = pos.h;
}

// ----------------------------------------------------------------- utf8

fn cp_len(first: u8) usize {
    return std.unicode.utf8ByteSequenceLength(first) catch 1;
}

fn display_width(text: []const u8) usize {
    var cols: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (cols += 1)
        i = @min(i + cp_len(text[i]), text.len);
    return cols;
}

// ------------------------------------------------------------- markdown

/// A markdown horizontal rule (`---`), which servers such as ols emit between
/// a signature and its prose description.
fn is_rule(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len < 3) return false;
    for (trimmed) |c| if (c != '-') return false;
    return true;
}

/// Leading `#` markers of a markdown heading, if any.
fn heading_level(line: []const u8) usize {
    const trimmed = std.mem.trimStart(u8, line, " \t");
    var level: usize = 0;
    while (level < trimmed.len and trimmed[level] == '#') level += 1;
    if (level == 0 or level >= trimmed.len) return 0;
    return if (trimmed[level] == ' ') level else 0;
}

fn fence_language(line: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (!std.mem.startsWith(u8, trimmed, "```")) return null;
    return std.mem.trim(u8, trimmed[3..], " \t\r");
}

/// Length of a markdown list marker (`- `, `* `, `+ `, `1. `), or 0.
fn list_marker_len(line: []const u8) usize {
    const trimmed = std.mem.trimStart(u8, line, " \t");
    if (trimmed.len < 2) return 0;
    if ((trimmed[0] == '-' or trimmed[0] == '*' or trimmed[0] == '+') and trimmed[1] == ' ')
        return 2;
    var i: usize = 0;
    while (i < trimmed.len and std.ascii.isDigit(trimmed[i])) i += 1;
    if (i > 0 and i + 1 < trimmed.len and (trimmed[i] == '.' or trimmed[i] == ')') and trimmed[i + 1] == ' ')
        return i + 2;
    return 0;
}

const Inline = struct {
    text: []u8,
    spans: []Span,

    fn deinit(self: Inline, allocator: Allocator) void {
        allocator.free(self.text);
        allocator.free(self.spans);
    }
};

/// Strip inline markdown and report the runs that carry emphasis. Underscores
/// are left alone: they are far more likely to be part of an identifier than
/// an emphasis marker. Spans borrow static scope names; the caller copies them
/// when it commits a line.
fn parse_inline(allocator: Allocator, line: []const u8) !Inline {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var spans: std.ArrayList(Span) = .empty;
    errdefer spans.deinit(allocator);

    var i: usize = 0;
    while (i < line.len) {
        // [text](url) -> text
        if (line[i] == '[') {
            if (std.mem.indexOfScalarPos(u8, line, i, ']')) |close| {
                if (close + 1 < line.len and line[close + 1] == '(') {
                    if (std.mem.indexOfScalarPos(u8, line, close, ')')) |end| {
                        try out.appendSlice(allocator, line[i + 1 .. close]);
                        i = end + 1;
                        continue;
                    }
                }
            }
        }
        // `code`
        if (line[i] == '`') {
            if (std.mem.indexOfScalarPos(u8, line, i + 1, '`')) |close| {
                const start = out.items.len;
                try out.appendSlice(allocator, line[i + 1 .. close]);
                if (out.items.len > start)
                    try spans.append(allocator, .{ .start = start, .end = out.items.len, .scope = "string" });
                i = close + 1;
                continue;
            }
        }
        // **bold**
        if (line[i] == '*' and i + 1 < line.len and line[i + 1] == '*') {
            if (std.mem.indexOfPos(u8, line, i + 2, "**")) |close| {
                const start = out.items.len;
                try out.appendSlice(allocator, line[i + 2 .. close]);
                if (out.items.len > start)
                    try spans.append(allocator, .{ .start = start, .end = out.items.len, .emphasis = .bold });
                i = close + 2;
                continue;
            }
        }
        // *italic*
        if (line[i] == '*') {
            if (std.mem.indexOfScalarPos(u8, line, i + 1, '*')) |close| {
                const start = out.items.len;
                try out.appendSlice(allocator, line[i + 1 .. close]);
                if (out.items.len > start)
                    try spans.append(allocator, .{ .start = start, .end = out.items.len, .emphasis = .italic });
                i = close + 1;
                continue;
            }
        }
        try out.append(allocator, line[i]);
        i += 1;
    }

    return .{
        .text = try out.toOwnedSlice(allocator),
        .spans = try spans.toOwnedSlice(allocator),
    };
}

// ---------------------------------------------------------------- build

/// Split markdown documentation into prose and fenced code blocks. Prose is
/// wrapped to the box width; code blocks are highlighted with tree-sitter and
/// wrapped with a continuation indent, remapping the highlight spans.
pub fn append_content(self: *Self, content: []const u8) !void {
    var code: std.ArrayList(u8) = .empty;
    defer code.deinit(self.allocator);

    var lang: []const u8 = "";
    var in_code = false;

    var iter = std.mem.splitScalar(u8, content, '\n');
    while (iter.next()) |line| {
        if (fence_language(line)) |tag| {
            try self.append_blank();
            if (in_code) {
                try self.append_code_block(lang, code.items);
                code.clearRetainingCapacity();
                in_code = false;
                lang = "";
            } else {
                in_code = true;
                lang = tag;
            }
            continue;
        }
        if (in_code) {
            try code.appendSlice(self.allocator, line);
            try code.append(self.allocator, '\n');
            continue;
        }
        if (is_rule(line)) {
            try self.append_rule();
            continue;
        }
        if (std.mem.trim(u8, line, " \t\r").len == 0) {
            try self.append_blank();
            continue;
        }
        try self.append_prose_line(line);
    }
    if (in_code and code.items.len > 0)
        try self.append_code_block(lang, code.items);
}

/// A blank separator line. Leading blanks are dropped and runs are collapsed,
/// so paragraph breaks survive without the box growing on empty space.
fn append_blank(self: *Self) !void {
    if (self.lines.items.len == 0) return;
    const last = self.lines.items[self.lines.items.len - 1];
    if (last.rule) return;
    if (std.mem.trim(u8, last.text, " ").len == 0) return;
    (try self.lines.addOne(self.allocator)).* = .{ .text = try self.allocator.dupe(u8, "") };
}

fn append_rule(self: *Self) !void {
    while (self.lines.items.len > 0) {
        const last = self.lines.items[self.lines.items.len - 1];
        if (std.mem.trim(u8, last.text, " ").len != 0 or last.rule) break;
        self.allocator.free(last.text);
        _ = self.lines.pop();
    }
    if (self.lines.items.len == 0) return;
    (try self.lines.addOne(self.allocator)).* = .{
        .text = try self.allocator.dupe(u8, ""),
        .rule = true,
    };
}

fn wrap_width(self: *Self) usize {
    return if (self.widget_type == .info_box)
        tui.config().info_box_width_limit
    else
        tui.screen().w;
}

fn append_prose_line(self: *Self, raw: []const u8) !void {
    const level = heading_level(raw);
    const marker = if (level == 0) list_marker_len(raw) else 0;

    var body = raw;
    var first_prefix: []const u8 = "";
    var cont_prefix: []const u8 = "";

    if (level > 0) {
        body = std.mem.trimStart(u8, std.mem.trimStart(u8, raw, " \t")[level..], " ");
    } else if (marker > 0) {
        const trimmed = std.mem.trimStart(u8, raw, " \t");
        body = trimmed[marker..];
        first_prefix = "\u{2022} ";
        cont_prefix = "  ";
    }

    const parsed = try parse_inline(self.allocator, body);
    defer parsed.deinit(self.allocator);

    var spans = parsed.spans;
    var heading_buf: [1]Span = undefined;
    if (level > 0 and parsed.text.len > 0) {
        heading_buf[0] = .{ .start = 0, .end = parsed.text.len, .scope = "keyword" };
        spans = heading_buf[0..1];
    }

    try self.wrap_line(parsed.text, spans, first_prefix, cont_prefix, .word);
}

/// Emit `text` as one or more lines, prefixing and remapping `spans` onto each
/// wrapped segment. Span scopes are copied here; the caller keeps ownership of
/// whatever it passed in.
fn wrap_line(
    self: *Self,
    text: []const u8,
    spans: []const Span,
    first_prefix: []const u8,
    cont_prefix: []const u8,
    break_kind: BreakKind,
) !void {
    const width = self.wrap_width();
    var start: usize = 0;
    var first = true;

    while (true) {
        const prefix = if (first) first_prefix else cont_prefix;
        const avail = width -| display_width(prefix);
        const end = if (avail == 0) text.len else find_break(text, start, avail, break_kind);

        try self.emit_segment(text, spans, start, end, prefix);

        first = false;
        start = end;
        if (break_kind == .word) {
            while (start < text.len and text[start] == ' ') start += 1;
        }
        if (start >= text.len) break;
        if (end == start and avail == 0) break;
    }
}

fn find_break(text: []const u8, start: usize, avail: usize, break_kind: BreakKind) usize {
    var end = start;
    var cols: usize = 0;
    var candidate: ?usize = null;
    while (end < text.len and cols < avail) {
        const next = @min(end + cp_len(text[end]), text.len);
        switch (break_kind) {
            .word => if (text[end] == ' ') {
                candidate = end;
            },
            .code => if (text[end] == ',' or text[end] == ' ' or text[end] == '(') {
                candidate = next;
            },
        }
        end = next;
        cols += 1;
    }
    if (end >= text.len) return text.len;
    if (candidate) |c| if (c > start) return c;
    return end;
}

fn emit_segment(
    self: *Self,
    text: []const u8,
    spans: []const Span,
    start: usize,
    end: usize,
    prefix: []const u8,
) !void {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(self.allocator);
    if (end > start or prefix.len > 0) {
        try buf.appendSlice(self.allocator, prefix);
        try buf.appendSlice(self.allocator, text[start..end]);
    }
    const line_text = try buf.toOwnedSlice(self.allocator);
    errdefer self.allocator.free(line_text);

    var out: std.ArrayList(Span) = .empty;
    errdefer {
        for (out.items) |span| if (span.scope.len > 0) self.allocator.free(span.scope);
        out.deinit(self.allocator);
    }
    for (spans) |span| {
        const s = @max(span.start, start);
        const e = @min(span.end, end);
        if (e <= s) continue;
        const scope = if (span.scope.len > 0) try self.allocator.dupe(u8, span.scope) else "";
        try out.append(self.allocator, .{
            .start = s - start + prefix.len,
            .end = e - start + prefix.len,
            .scope = scope,
            .emphasis = span.emphasis,
        });
    }

    (try self.lines.addOne(self.allocator)).* = .{
        .text = line_text,
        .spans = try out.toOwnedSlice(self.allocator),
    };
}

// ----------------------------------------------------------------- code

/// Parsers are cached per language: creating one loads and compiles a grammar,
/// which is far too expensive to redo on every selection change.
fn get_parser(self: *Self, lang: []const u8) ?*syntax {
    if (self.parsers.get(lang)) |parser| return parser;
    const parser = syntax.create_file_type_static(self.allocator, lang, tui.query_cache()) catch return null;
    const key = self.allocator.dupe(u8, lang) catch {
        parser.destroy();
        return null;
    };
    self.parsers.put(self.allocator, key, parser) catch {
        self.allocator.free(key);
        parser.destroy();
        return null;
    };
    return parser;
}

const HighlightContext = struct {
    rows: []const []const u8,
    spans: []std.ArrayList(Span),
    allocator: Allocator,
    failed: bool = false,

    fn cb(
        ctx: *HighlightContext,
        sel: syntax.Range,
        scope: []const u8,
        id: u32,
        capture_idx: usize,
        priority: i32,
        pattern_index: u32,
        node: *const syntax.Node,
    ) error{Stop}!void {
        _ = id;
        _ = capture_idx;
        _ = priority;
        _ = pattern_index;
        _ = node;
        // multi-line captures carry no useful per-line colour here
        if (sel.start_point.row != sel.end_point.row) return;
        const row: usize = @intCast(sel.start_point.row);
        if (row >= ctx.rows.len) return;
        const text = ctx.rows[row];
        const start = @min(@as(usize, @intCast(sel.start_point.column)), text.len);
        const end = @min(@as(usize, @intCast(sel.end_point.column)), text.len);
        if (end <= start) return;
        ctx.spans[row].append(ctx.allocator, .{
            .start = start,
            .end = end,
            .scope = scope,
        }) catch {
            ctx.failed = true;
            return error.Stop;
        };
    }
};

fn span_less_than(_: void, a: Span, b: Span) bool {
    if (a.start != b.start) return a.start < b.start;
    return a.end > b.end;
}

fn append_code_block(self: *Self, lang: []const u8, code: []const u8) !void {
    var rows: std.ArrayList([]const u8) = .empty;
    defer rows.deinit(self.allocator);
    var iter = std.mem.splitScalar(u8, code, '\n');
    while (iter.next()) |line| {
        if (iter.peek() == null and line.len == 0) break;
        try rows.append(self.allocator, line);
    }
    if (rows.items.len == 0) return;

    var spans: []std.ArrayList(Span) = &.{};
    defer if (spans.len > 0) {
        for (spans) |*list| list.deinit(self.allocator);
        self.allocator.free(spans);
    };

    if (lang.len > 0) {
        if (self.get_parser(lang)) |parser| blk: {
            parser.refresh_full(code) catch break :blk;
            spans = self.allocator.alloc(std.ArrayList(Span), rows.items.len) catch break :blk;
            for (spans) |*list| list.* = .empty;
            var ctx: HighlightContext = .{
                .rows = rows.items,
                .spans = spans,
                .allocator = self.allocator,
            };
            parser.render(&ctx, HighlightContext.cb, syntax.AcceptAll(*HighlightContext), null) catch {};
            if (ctx.failed) for (spans) |*list| list.clearRetainingCapacity();
        }
    }

    for (rows.items, 0..) |row, i| {
        const row_spans: []Span = if (i < spans.len) spans[i].items else &.{};
        if (row_spans.len > 0) std.mem.sort(Span, row_spans, {}, span_less_than);
        try self.wrap_line(row, row_spans, "", code_indent, .code);
    }
}

pub fn set_content(self: *Self, content: []const u8) !void {
    self.clear();
    self.top = 0;
    return self.append_content(content);
}

pub fn content_size(self: *Self) struct { rows: usize, cols: usize } {
    var cols: usize = 0;
    for (self.lines.items) |line| cols = @max(cols, display_width(line.text));
    return .{ .rows = self.lines.items.len, .cols = cols };
}

// --------------------------------------------------------------- render

pub fn render(self: *Self, theme: *const Widget.Theme) bool {
    const base = if (tui.config().hover_info_mode == .box) theme.editor_widget else theme.panel;
    self.plane.set_base_style(base);
    self.plane.erase();
    self.plane.home();
    for (self.lines.items[@min(self.top, self.lines.items.len)..]) |line| {
        self.render_line(theme, base, line);
        if (self.plane.cursor_y() >= self.view_rows - 1)
            return false;
        self.plane.cursor_move_yx(-1, 0);
        self.plane.cursor_move_rel(1, 0) catch {};
    }
    return false;
}

fn render_line(self: *Self, theme: *const Widget.Theme, base: anytype, line: Line) void {
    if (line.rule) {
        if (tui.find_scope_style(theme, "comment")) |token|
            self.plane.set_style(token.style)
        else
            self.plane.set_style(base);
        const width: usize = @intCast(@max(0, self.plane.dim_x()));
        var i: usize = 0;
        while (i < width) : (i += 1)
            _ = self.plane.putstr("\u{2500}") catch break;
        return;
    }
    if (line.spans.len == 0) {
        self.plane.set_style(base);
        _ = self.plane.putstr(line.text) catch {};
        return;
    }
    var pos: usize = 0;
    for (line.spans) |span| {
        if (span.start < pos) continue; // overlapping capture, first one wins
        if (span.start > pos) {
            self.plane.set_style(base);
            _ = self.plane.putstr(line.text[pos..span.start]) catch {};
        }
        self.plane.set_style(self.span_style(theme, base, span));
        _ = self.plane.putstr(line.text[span.start..span.end]) catch {};
        pos = span.end;
    }
    if (pos < line.text.len) {
        self.plane.set_style(base);
        _ = self.plane.putstr(line.text[pos..]) catch {};
    }
}

fn span_style(_: *Self, theme: *const Widget.Theme, base: anytype, span: Span) @TypeOf(base) {
    var style = base;
    if (span.scope.len > 0) {
        if (tui.find_scope_style(theme, span.scope)) |token| style = token.style;
    }
    switch (span.emphasis) {
        .none => {},
        .bold => style.fs = .bold,
        .italic => style.fs = .italic,
    }
    return style;
}
