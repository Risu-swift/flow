const std = @import("std");
const Allocator = @import("std").mem.Allocator;
const Plane = @import("renderer").Plane;
const command = @import("command");
const Widget = @import("Widget.zig");
const WidgetList = @import("WidgetList.zig");
const Panel = @import("Panel.zig");
const PanelInput = @import("PanelInput.zig");
const tp = @import("thespian");
const reflow = @import("Buffer").reflow;
const tui = @import("tui.zig");
const syntax = @import("syntax");

pub const name = @typeName(Self);

const Self = @This();

/// A syntax-highlighted run within a line. `scope` is a tree-sitter capture
/// name; it is resolved against the active theme at render time.
const Span = struct {
    start: usize,
    end: usize,
    scope: []const u8,
};

const Line = struct {
    text: []const u8,
    spans: []const Span = &.{},
    /// draw as a horizontal rule across the full box width
    rule: bool = false,
};

allocator: std.mem.Allocator,
plane: Plane,

view_rows: usize = 0,
lines: std.ArrayList(Line),
widget_type: Widget.Type,
panel_input: ?PanelInput = null,
top: usize = 0,

const default_widget_type: Widget.Type = .panel;

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
        for (line.spans) |span| self.allocator.free(span.scope);
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

/// Drop inline markdown emphasis that flow cannot render. Underscores are
/// left alone: they are far more likely to be part of an identifier.
fn clean_inline(allocator: Allocator, line: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < line.len) {
        if (line[i] == '`') {
            i += 1;
            continue;
        }
        if (line[i] == '*' and i + 1 < line.len and line[i + 1] == '*') {
            i += 2;
            continue;
        }
        try out.append(allocator, line[i]);
        i += 1;
    }
    return out.toOwnedSlice(allocator);
}

fn fence_language(line: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (!std.mem.startsWith(u8, trimmed, "```")) return null;
    return std.mem.trim(u8, trimmed[3..], " \t\r");
}

/// Split markdown documentation into prose and fenced code blocks. Prose is
/// reflowed to the box width; code blocks are handed to tree-sitter and kept
/// verbatim so that column offsets stay meaningful.
pub fn append_content(self: *Self, content: []const u8) !void {
    var code: std.ArrayList(u8) = .empty;
    defer code.deinit(self.allocator);

    var lang: []const u8 = "";
    var in_code = false;

    var iter = std.mem.splitScalar(u8, content, '\n');
    while (iter.next()) |line| {
        if (fence_language(line)) |tag| {
            if (in_code) {
                try self.append_code_block(lang, code.items);
                code.clearRetainingCapacity();
                in_code = false;
                lang = "";
                try self.append_blank();
            } else {
                in_code = true;
                lang = tag;
                try self.append_blank();
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

fn append_prose_line(self: *Self, line_: []const u8) !void {
    const level = heading_level(line_);
    const stripped = if (level > 0)
        std.mem.trimStart(u8, std.mem.trimStart(u8, line_, " \t")[level..], " ")
    else
        line_;

    const line = try clean_inline(self.allocator, stripped);
    defer self.allocator.free(line);

    const width = if (self.widget_type == .info_box)
        tui.config().info_box_width_limit
    else
        tui.screen().w;
    const text = try reflow(self.allocator, line, width, .screen, .spaces, self.plane.metrics(tui.config().tab_width));
    defer self.allocator.free(text);
    var iter = std.mem.splitScalar(u8, text, '\n');
    while (iter.next()) |wrapped| if (wrapped.len > 0) {
        const owned = try self.allocator.dupe(u8, wrapped);
        var spans: []const Span = &.{};
        if (level > 0) spans = self.heading_span(owned) catch &.{};
        (try self.lines.addOne(self.allocator)).* = .{ .text = owned, .spans = spans };
    };
}

/// Colour a heading line using the theme's keyword scope.
fn heading_span(self: *Self, text: []const u8) ![]const Span {
    const scope = try self.allocator.dupe(u8, "keyword");
    errdefer self.allocator.free(scope);
    const spans = try self.allocator.alloc(Span, 1);
    spans[0] = .{ .start = 0, .end = text.len, .scope = scope };
    return spans;
}

fn append_code_lines(self: *Self, code: []const u8) !usize {
    const first = self.lines.items.len;
    var iter = std.mem.splitScalar(u8, code, '\n');
    while (iter.next()) |line| {
        // the split of a trailing newline yields one empty tail entry
        if (iter.peek() == null and line.len == 0) break;
        (try self.lines.addOne(self.allocator)).* = .{ .text = try self.allocator.dupe(u8, line) };
    }
    return first;
}

const HighlightContext = struct {
    self: *Self,
    first: usize,
    spans: []std.ArrayList(Span),
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
        if (row >= ctx.spans.len) return;
        const idx = ctx.first + row;
        if (idx >= ctx.self.lines.items.len) return;
        const text = ctx.self.lines.items[idx].text;
        const start = @min(@as(usize, @intCast(sel.start_point.column)), text.len);
        const end = @min(@as(usize, @intCast(sel.end_point.column)), text.len);
        if (end <= start) return;
        const owned = ctx.self.allocator.dupe(u8, scope) catch {
            ctx.failed = true;
            return error.Stop;
        };
        ctx.spans[row].append(ctx.self.allocator, .{
            .start = start,
            .end = end,
            .scope = owned,
        }) catch {
            ctx.self.allocator.free(owned);
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
    const first = try self.append_code_lines(code);
    if (lang.len == 0) return;

    const row_count = self.lines.items.len - first;
    if (row_count == 0) return;

    const parser = syntax.create_file_type_static(self.allocator, lang, tui.query_cache()) catch return;
    defer parser.destroy();
    parser.refresh_full(code) catch return;

    const spans = self.allocator.alloc(std.ArrayList(Span), row_count) catch return;
    defer self.allocator.free(spans);
    for (spans) |*list| list.* = .empty;
    defer for (spans) |*list| list.deinit(self.allocator);

    var ctx: HighlightContext = .{ .self = self, .first = first, .spans = spans };
    parser.render(&ctx, HighlightContext.cb, syntax.AcceptAll(*HighlightContext), null) catch {};
    if (ctx.failed) {
        for (spans) |*list| for (list.items) |span| self.allocator.free(span.scope);
        return;
    }

    for (spans, 0..) |*list, row| {
        if (list.items.len == 0) continue;
        std.mem.sort(Span, list.items, {}, span_less_than);
        self.lines.items[first + row].spans = list.toOwnedSlice(self.allocator) catch {
            for (list.items) |span| self.allocator.free(span.scope);
            continue;
        };
    }
}

pub fn set_content(self: *Self, content: []const u8) !void {
    self.clear();
    self.top = 0;
    return self.append_content(content);
}

pub fn content_size(self: *Self) struct { rows: usize, cols: usize } {
    var cols: usize = 0;
    for (self.lines.items) |line| cols = @max(cols, line.text.len);
    return .{ .rows = self.lines.items.len, .cols = cols };
}

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
        if (tui.find_scope_style(theme, span.scope)) |token|
            self.plane.set_style(token.style)
        else
            self.plane.set_style(base);
        _ = self.plane.putstr(line.text[span.start..span.end]) catch {};
        pos = span.end;
    }
    if (pos < line.text.len) {
        self.plane.set_style(base);
        _ = self.plane.putstr(line.text[pos..]) catch {};
    }
}
