//! Thin Zig wrapper for llama.cpp.
//!
//! Provides backend initialization, system info reporting, default model parameters,
//! and model loading with error handling.

/// Built for this target (docs/modules.md, "Availability").
pub const available = true;

const std = @import("std");
const oriel = @import("../oriel.zig");

pub const c = @cImport({
    // Zig defines _FORTIFY_SOURCE in optimized builds; translate-c can't
    // read the NDK's fortified <stdio.h> (Android release builds failed).
    // The C code itself is compiled with its own flags.
    @cUndef("_FORTIFY_SOURCE");
    @cInclude("llama.h");
    if (@import("build_options").llama_mtmd) {
        @cInclude("mtmd.h");
        @cInclude("mtmd-helper.h");
    }
});

/// Return a copy of the backend system info string (CPU features); the
/// caller frees it with `gpa`. The C function returns a pointer into a static
/// string it rebuilds on every call, so handing that out would dangle.
pub fn systemInfo(gpa: std.mem.Allocator) ![]u8 {
    return gpa.dupe(u8, std.mem.span(c.llama_print_system_info()));
}

/// Initialize the llama backend.
pub fn initBackend() void {
    c.llama_backend_init();
}

/// Free the llama backend.
pub fn deinitBackend() void {
    c.llama_backend_free();
}

/// Return default model parameters.
pub fn modelDefaultParams() c.llama_model_params {
    return c.llama_model_default_params();
}

/// A loaded llama model handle.
pub const Model = struct {
    handle: *c.llama_model,

    pub fn deinit(self: Model) void {
        c.llama_model_free(self.handle);
    }
};

/// Load a model from the given filesystem path. Returns `error.ModelLoadFailed`
/// if the file does not exist or cannot be parsed.
pub fn loadModel(path: [:0]const u8, params: c.llama_model_params) !Model {
    if (!@import("ggml_gpu.zig").cpuSupported()) return error.CpuUnsupported;
    const handle = c.llama_model_load_from_file(path.ptr, params) orelse return error.ModelLoadFailed;
    return .{ .handle = handle };
}

extern fn oriel_llama_json_schema_to_grammar(schema: [*]const u8, len: usize, err: ?*?[*:0]u8) ?[*:0]u8;
extern fn oriel_llama_free_string(s: ?[*:0]u8) void;

/// The GBNF grammar that constrains output to JSON matching `schema` (a JSON
/// Schema document), for `c.llama_sampler_init_grammar(vocab, grammar, "root")`
/// (llama.cpp's own converter, common/json-schema-to-grammar.cpp). Caller frees
/// the result. On a schema it can't convert: error.InvalidSchema, with the
/// reason in `diag` (owned by `gpa`, caller frees) when given.
pub fn jsonSchemaToGrammar(gpa: std.mem.Allocator, schema: []const u8, diag: ?*?[]u8) ![:0]u8 {
    if (diag) |d| d.* = null;
    var err: ?[*:0]u8 = null;
    const out = oriel_llama_json_schema_to_grammar(schema.ptr, schema.len, &err) orelse {
        defer oriel_llama_free_string(err);
        if (diag) |d| if (err) |e| {
            d.* = try gpa.dupe(u8, std.mem.span(e));
        };
        return error.InvalidSchema;
    };
    defer oriel_llama_free_string(out);
    return gpa.dupeZ(u8, std.mem.span(out));
}

const ChatHandle = opaque {};
const TurnHandle = opaque {};
extern fn oriel_llama_chat_init(model: *const c.llama_model, tmpl: ?[*]const u8, tmpl_len: usize, err: ?*?[*:0]u8) ?*ChatHandle;
extern fn oriel_llama_chat_free(chat: *ChatHandle) void;
extern fn oriel_llama_chat_begin(chat: *ChatHandle, request: [*]const u8, len: usize, think: bool, temperature: f32, seed: u32, prompt: *?[*:0]u8, err: ?*?[*:0]u8) ?*TurnHandle;
extern fn oriel_llama_chat_sample(turn: *TurnHandle, ctx: *c.llama_context) c.llama_token;
extern fn oriel_llama_chat_feed(turn: *TurnHandle, tok: c.llama_token, reasoning: *?[*:0]u8, content: *?[*:0]u8) bool;
extern fn oriel_llama_chat_finish(turn: *TurnHandle, reasoning: *?[*:0]u8, content: *?[*:0]u8) ?[*:0]u8;
extern fn oriel_llama_chat_end(turn: *TurnHandle) void;

/// A model's own chat template (Jinja, from its GGUF; ChatML when it has
/// none), the way llama-server serves `/v1/chat/completions`: an OpenAI chat
/// request (messages with tool calls and results, tools, tool_choice,
/// response_format, chat_template_kwargs) renders into the prompt in the
/// model's native format; a `Turn` samples the answer with the template's
/// tool-call grammar (lazy: it binds once the model starts a call) and parses
/// it back into content, reasoning and tool calls (common/chat.cpp).
pub const ChatTemplates = struct {
    handle: *ChatHandle,

    /// The model's template, or `template` (Jinja source) instead when
    /// given. On a template it can't parse: error.TemplateUnsupported, with
    /// the reason in `diag` (owned by `gpa`, caller frees) when given.
    pub fn init(gpa: std.mem.Allocator, model: *const c.llama_model, template: ?[]const u8, diag: ?*?[]u8) !ChatTemplates {
        if (diag) |d| d.* = null;
        var err: ?[*:0]u8 = null;
        const handle = oriel_llama_chat_init(model, if (template) |t| t.ptr else null, if (template) |t| t.len else 0, &err) orelse {
            defer oriel_llama_free_string(err);
            if (diag) |d| if (err) |e| {
                d.* = try gpa.dupe(u8, std.mem.span(e));
            };
            return error.TemplateUnsupported;
        };
        return .{ .handle = handle };
    }

    pub fn deinit(self: ChatTemplates) void {
        oriel_llama_chat_free(self.handle);
    }

    pub const Options = struct {
        /// The model's reasoning phase (templates that have one).
        think: bool = true,
        temperature: f32 = 0.8,
        seed: u32 = c.LLAMA_DEFAULT_SEED,
    };

    /// One answer to `request` (OpenAI chat request JSON). Tokenize
    /// `Turn.prompt` with add_special and parse_special, decode it, then
    /// `sample` and `feed` each token until an end-of-generation token (or a
    /// stop: `feed` returns `stop`), and `finish`. On a request the template
    /// can't render: error.BadRequest, the reason in `diag`.
    pub fn begin(self: ChatTemplates, gpa: std.mem.Allocator, request: []const u8, opts: Options, diag: ?*?[]u8) !Turn {
        if (diag) |d| d.* = null;
        var err: ?[*:0]u8 = null;
        var prompt: ?[*:0]u8 = null;
        const handle = oriel_llama_chat_begin(self.handle, request.ptr, request.len, opts.think, opts.temperature, opts.seed, &prompt, &err) orelse {
            defer oriel_llama_free_string(err);
            if (diag) |d| if (err) |e| {
                d.* = try gpa.dupe(u8, std.mem.span(e));
            };
            return error.BadRequest;
        };
        defer oriel_llama_free_string(prompt);
        errdefer oriel_llama_chat_end(handle);
        return .{ .handle = handle, .prompt = try gpa.dupeZ(u8, std.mem.span(prompt orelse return error.OutOfMemory)) };
    }

    pub const Turn = struct {
        handle: *TurnHandle,
        /// The rendered prompt (owned by the `begin` allocator).
        prompt: [:0]u8,

        pub fn deinit(self: Turn, gpa: std.mem.Allocator) void {
            oriel_llama_chat_end(self.handle);
            gpa.free(self.prompt);
        }

        /// The next token from the last decoded position's logits.
        pub fn sample(self: Turn, ctx: *c.llama_context) c.llama_token {
            return oriel_llama_chat_sample(self.handle, ctx);
        }

        /// What a token added to the answer (owned by `gpa`; empty: none).
        pub const Delta = struct {
            reasoning: []u8,
            content: []u8,
            /// The answer reached one of the template's stop strings.
            stop: bool = false,

            pub fn deinit(self: Delta, gpa: std.mem.Allocator) void {
                gpa.free(self.reasoning);
                gpa.free(self.content);
            }
        };

        /// Add a generated token (not an end-of-generation one).
        pub fn feed(self: Turn, gpa: std.mem.Allocator, tok: c.llama_token) !Delta {
            var r: ?[*:0]u8 = null;
            var t: ?[*:0]u8 = null;
            const stop = oriel_llama_chat_feed(self.handle, tok, &r, &t);
            return deltaOf(gpa, r, t, stop);
        }

        /// The answer's last reasoning and content, and the whole answer as
        /// OpenAI message JSON: {"role","content","reasoning_content",
        /// "tool_calls":[{"name","arguments"}]} (arguments: JSON text).
        pub const Final = struct {
            delta: Delta,
            message: []u8,

            pub fn deinit(self: Final, gpa: std.mem.Allocator) void {
                self.delta.deinit(gpa);
                gpa.free(self.message);
            }
        };

        pub fn finish(self: Turn, gpa: std.mem.Allocator) !Final {
            var r: ?[*:0]u8 = null;
            var t: ?[*:0]u8 = null;
            const msg = oriel_llama_chat_finish(self.handle, &r, &t);
            defer oriel_llama_free_string(msg);
            const delta = try deltaOf(gpa, r, t, false);
            errdefer delta.deinit(gpa);
            return .{ .delta = delta, .message = try gpa.dupe(u8, std.mem.span(msg orelse return error.OutOfMemory)) };
        }

        fn deltaOf(gpa: std.mem.Allocator, r: ?[*:0]u8, t: ?[*:0]u8, stop: bool) !Delta {
            defer oriel_llama_free_string(r);
            defer oriel_llama_free_string(t);
            const reasoning = try gpa.dupe(u8, if (r) |s| std.mem.span(s) else "");
            errdefer gpa.free(reasoning);
            return .{ .reasoning = reasoning, .content = try gpa.dupe(u8, if (t) |s| std.mem.span(s) else ""), .stop = stop };
        }
    };
};

/// Suppress all ggml and llama log output on stderr (process-wide, for good).
pub fn silenceLogs() void {
    const noop = struct {
        fn cb(_: c.ggml_log_level, _: [*c]const u8, _: ?*anyopaque) callconv(.c) void {}
    }.cb;
    c.llama_log_set(noop, null);
    c.ggml_log_set(noop, null);
}

/// Smoke check for oriel checkAll: verifies backend init and CPU system info.
pub fn check(gpa: std.mem.Allocator, _: oriel.CheckContext) !oriel.Check {
    initBackend();
    defer deinitBackend();

    const info = try systemInfo(gpa);
    defer gpa.free(info);
    const has_cpu = std.mem.indexOf(u8, info, "CPU") != null;
    const trimmed = std.mem.trim(u8, info, " \t\r\n");
    return .{
        .module = "llama",
        .ok = has_cpu,
        .detail = try std.fmt.allocPrint(gpa, "llama.cpp: {s}", .{trimmed}),
    };
}

test {
    std.testing.refAllDecls(@This());
}

test "llama check" {
    silenceLogs();
    const res = try check(std.testing.allocator, undefined);
    defer std.testing.allocator.free(res.detail);
    try std.testing.expect(res.ok);
    try std.testing.expect(std.mem.indexOf(u8, res.detail, "llama.cpp: ") != null);
}

test "jsonSchemaToGrammar: a grammar for an object; a bad schema says why" {
    const gpa = std.testing.allocator;
    const g = try jsonSchemaToGrammar(gpa,
        \\{"type":"object","properties":{"caption":{"type":"string"},"people":{"type":"integer"}},"required":["caption"]}
    , null);
    defer gpa.free(g);
    try std.testing.expect(std.mem.indexOf(u8, g, "root ::=") != null);
    try std.testing.expect(std.mem.indexOf(u8, g, "caption") != null);

    var why: ?[]u8 = null;
    try std.testing.expectError(error.InvalidSchema, jsonSchemaToGrammar(gpa, "{not json", &why));
    defer if (why) |w| gpa.free(w);
    try std.testing.expect(why != null and why.?.len > 0);
}

test "llama backend init, system info, default params, and missing file error" {
    silenceLogs();
    initBackend();
    defer deinitBackend();

    const info = try systemInfo(std.testing.allocator);
    defer std.testing.allocator.free(info);
    try std.testing.expect(info.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, info, "CPU") != null);

    const params = modelDefaultParams();

    const res = loadModel("nonexistent_model_file_that_does_not_exist.gguf", params);
    try std.testing.expectError(error.ModelLoadFailed, res);
}

test "ChatTemplates: Qwen3.5's template renders tools and thinking; a scripted answer parses into reasoning and a tool call" {
    const gpa = std.testing.allocator;
    const files = @import("llama_test_files");
    silenceLogs();
    initBackend();
    defer deinitBackend();

    var params = modelDefaultParams();
    params.vocab_only = true;
    const vocab_path = try gpa.dupeZ(u8, files.qwen35_vocab);
    defer gpa.free(vocab_path);
    const model = try loadModel(vocab_path, params);
    defer model.deinit();
    const template = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, files.qwen35_template, gpa, .limited(1 << 20));
    defer gpa.free(template);
    const chat = try ChatTemplates.init(gpa, model.handle, template, null);
    defer chat.deinit();

    const request =
        \\{"messages":[{"role":"system","content":"Be brief."},{"role":"user","content":"Read a.md"}],
        \\ "tools":[{"type":"function","function":{"name":"read","description":"Read a file",
        \\   "parameters":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}}}]}
    ;
    const turn = try chat.begin(gpa, request, .{ .think = true }, null);
    defer turn.deinit(gpa);
    try std.testing.expect(std.mem.indexOf(u8, turn.prompt, "<tools>") != null);
    try std.testing.expect(std.mem.indexOf(u8, turn.prompt, "\"name\": \"read\"") != null);
    try std.testing.expect(std.mem.endsWith(u8, turn.prompt, "<|im_start|>assistant\n<think>\n"));

    // The model's answer, token by token.
    const answer = "The user wants a.md read.\n</think>\n\n<tool_call>\n<function=read>\n<parameter=path>\na.md\n</parameter>\n</function>\n</tool_call>";
    const vocab = c.llama_model_get_vocab(model.handle);
    var tokens: [256]c.llama_token = undefined;
    const n = c.llama_tokenize(vocab, answer.ptr, answer.len, &tokens, tokens.len, false, true);
    try std.testing.expect(n > 0);
    var reasoning: std.ArrayList(u8) = .empty;
    defer reasoning.deinit(gpa);
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(gpa);
    for (tokens[0..@intCast(n)]) |tok| {
        const d = try turn.feed(gpa, tok);
        defer d.deinit(gpa);
        try std.testing.expect(!d.stop);
        try reasoning.appendSlice(gpa, d.reasoning);
        try content.appendSlice(gpa, d.content);
    }
    const final = try turn.finish(gpa);
    defer final.deinit(gpa);
    try reasoning.appendSlice(gpa, final.delta.reasoning);
    try content.appendSlice(gpa, final.delta.content);
    // As the model wrote it (llama.cpp keeps the newline before </think>).
    try std.testing.expectEqualStrings("The user wants a.md read.", std.mem.trimEnd(u8, reasoning.items, "\n"));
    try std.testing.expectEqualStrings("", content.items);

    const Message = struct { content: []const u8, reasoning_content: []const u8, tool_calls: []const struct { name: []const u8, arguments: []const u8 } };
    const msg = try std.json.parseFromSlice(Message, gpa, final.message, .{ .ignore_unknown_fields = true });
    defer msg.deinit();
    try std.testing.expectEqualStrings("The user wants a.md read.", std.mem.trimEnd(u8, msg.value.reasoning_content, "\n"));
    try std.testing.expectEqual(@as(usize, 1), msg.value.tool_calls.len);
    try std.testing.expectEqualStrings("read", msg.value.tool_calls[0].name);
    try std.testing.expectEqualStrings("{\"path\":\"a.md\"}", msg.value.tool_calls[0].arguments);

    // Thinking off: the template closes the reasoning block itself.
    const off = try chat.begin(gpa, request, .{ .think = false }, null);
    defer off.deinit(gpa);
    try std.testing.expect(std.mem.endsWith(u8, off.prompt, "<think>\n\n</think>\n\n"));

    // A request the template can't take says why.
    var why: ?[]u8 = null;
    try std.testing.expectError(error.BadRequest, chat.begin(gpa, "{\"tools\":[]}", .{}, &why));
    defer if (why) |w| gpa.free(w);
    try std.testing.expect(why != null);
}
