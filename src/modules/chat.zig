//! Chat and completion with a local LLM, tuned out of the box: the llama.cpp
//! counterpart of `dictation`.
//!
//! - Models: small multilingual instruct models in q4_0 (ggml repacks it
//!   for ARM's dotprod/i8mm kernels and the GPU backends run it natively),
//!   and on desktops Qwen3.5 9B and Gemma 4 12B, downloaded from Hugging
//!   Face (`download`, `delete`, `status`).
//! - The model's own chat template (from its GGUF), so `messages` are
//!   plain `{ role, content }` pairs. Gemma 4 and Qwen3/3.5 are rendered
//!   here, with their reasoning off unless `.think` (then hidden from the
//!   reply); a template that fails falls back to ChatML.
//! - Tuned like llama-server (and GhostPen): a resident threadpool, prompts
//!   in 2048-token batches on desktops, a q8_0 KV cache with flash
//!   attention where the backend has it (else f16), and a context capped at
//!   what the model was trained for and halved when memory runs out. A GPU
//!   that can't hold the model falls back to the CPU.
//! - `.schema`: a JSON schema the reply follows (a grammar, checked per
//!   token only when the usual pick breaks it).
//! - Tokens stream to the page as "chat:token" events; `cancel` stops a
//!   reply (and a long prompt) early.
//! - Turns reuse the conversation's KV cache: only what's new since the
//!   last reply is evaluated, so a long chat doesn't get slower per turn.
//! - The CPU or the GPU per device and model (`.backend = .auto`): what
//!   `compare` measured (remembered next to the models), else the GPU on
//!   desktops and the CPU on phones. A GPU model gets an untimed warm-up
//!   when it loads (Vulkan builds its pipelines on first use).
//! - A conversation longer than the context drops its oldest turns (the
//!   system prompt stays).
//!
//! The building blocks stay public: `oriel.llama` (the C API, JSON-schema
//! grammars) and `oriel.ggml_gpu`. Needs `-Dllama`.

const std = @import("std");
const builtin = @import("builtin");
const oriel = @import("../oriel.zig");
const llama = @import("llama.zig");
const c = llama.c;
const ggml_gpu = @import("ggml_gpu.zig");
const format = @import("chat/format.zig");
const App = @import("../core/App.zig");
const model_download = @import("model_download.zig");

const log = std.log.scoped(.chat);
const is_phone = builtin.abi.isAndroid() or builtin.os.tag == .ios;

pub const Model = struct {
    name: []const u8,
    /// For people: "Qwen2.5 1.5B".
    label: []const u8,
    /// Hugging Face repository and file.
    repo: []const u8,
    file: []const u8,
    mb: u32,
    /// Only offered on desktops (too big for a phone's memory).
    desktop_only: bool = false,
};

/// Small instruct models, smallest first; all speak English, Spanish,
/// German, French and more.
pub const models = [_]Model{
    .{ .name = "qwen2.5-0.5b", .label = "Qwen2.5 0.5B", .repo = "Qwen/Qwen2.5-0.5B-Instruct-GGUF", .file = "qwen2.5-0.5b-instruct-q4_0.gguf", .mb = 409 },
    .{ .name = "llama3.2-1b", .label = "Llama 3.2 1B", .repo = "bartowski/Llama-3.2-1B-Instruct-GGUF", .file = "Llama-3.2-1B-Instruct-Q4_0.gguf", .mb = 737 },
    .{ .name = "qwen2.5-1.5b", .label = "Qwen2.5 1.5B", .repo = "Qwen/Qwen2.5-1.5B-Instruct-GGUF", .file = "qwen2.5-1.5b-instruct-q4_0.gguf", .mb = 1017 },
    // Desktops with 16 GB of memory (or a GPU with 8 GB).
    .{ .name = "qwen3.5-9b", .label = "Qwen3.5 9B", .repo = "unsloth/Qwen3.5-9B-GGUF", .file = "Qwen3.5-9B-Q4_K_M.gguf", .mb = 5418, .desktop_only = true },
    .{ .name = "gemma4-12b", .label = "Gemma 4 12B", .repo = "unsloth/gemma-4-12b-it-GGUF", .file = "gemma-4-12b-it-Q4_K_M.gguf", .mb = 6792, .desktop_only = true },
};

/// The `models` this device offers: all on desktops, the small ones on
/// phones.
pub const device_models = blk: {
    var list: []const *const Model = &.{};
    for (&models) |*m| if (!(is_phone and m.desktop_only)) {
        list = list ++ .{m};
    };
    break :blk list[0..list.len].*;
};

pub const Backend = enum { auto, cpu, gpu };

pub const Message = struct {
    /// "system", "user" or "assistant".
    role: []const u8,
    content: []const u8,
};

pub const Options = struct {
    /// A `models` name, or "auto": the largest one on the device.
    model: []const u8 = "auto",
    backend: Backend = .auto,
    /// Reply length limit, in tokens.
    max_tokens: u32 = 512,
    /// 0: greedy (always the likeliest token).
    temperature: f32 = 0.7,
    top_p: f32 = 0.95,
    /// Context window in tokens (prompt + reply), at most what the model
    /// was trained for.
    context: u32 = 4096,
    /// Let a reasoning model (Qwen3.5, Gemma 4) think before answering:
    /// better answers to hard questions, much later. The thinking is not in
    /// the reply.
    think: bool = false,
    /// A JSON schema the reply must follow; "" for free text.
    schema: []const u8 = "",
};

pub const Events = struct {
    @"chat:download": struct { model: []const u8, done_mb: u32, total_mb: u32 },
    /// The reply so far grew by `text` (whole UTF-8 characters).
    @"chat:token": struct { text: []const u8 },
    /// `compare`: one backend's run finished.
    @"chat:compare": struct { backend: []const u8, tokens_per_s: f32 },
};

fn emit(comptime name: []const u8, payload: @FieldType(Events, name)) void {
    App.emit(name, payload);
}

var io: std.Io = undefined;
var gpa: std.mem.Allocator = undefined;
var models_dir: []const u8 = "";

/// Guards everything below except `cancelled`.
var mutex: std.Io.Mutex = .init;
var backend_ready = false;
var backend_name: []const u8 = "CPU";
var gpu_name: ?[]const u8 = null;
var downloading: ?*const Model = null;
var generating = std.atomic.Value(bool).init(false);
var cancelled = std.atomic.Value(bool).init(false);

const Loaded = struct {
    model: *const Model,
    gpu: bool,
    /// Asked for the GPU, but the model didn't fit there.
    fell_back: bool,
    handle: *c.llama_model,
    ctx: *c.llama_context,
    threadpool: c.ggml_threadpool_t,
    /// What the context was asked for (`n_ctx` may be less).
    asked_ctx: u32,
    n_ctx: u32,
    format: format.Format,
    /// The tokens in the KV cache, in order: what the next turn can reuse.
    cache: std.ArrayList(c.llama_token) = .empty,

    fn deinit(self: *Loaded) void {
        self.cache.deinit(gpa);
        c.llama_free(self.ctx);
        c.ggml_threadpool_free(self.threadpool);
        c.llama_model_free(self.handle);
    }
};
var loaded: ?Loaded = null;

/// Call once at startup. `dir`: where the models live (created when
/// needed); must outlive the app.
pub fn init(app_io: std.Io, app_gpa: std.mem.Allocator, dir: []const u8) void {
    io = app_io;
    gpa = app_gpa;
    models_dir = dir;
    llama.silenceLogs();
}

/// llama.cpp's backend and the GPU backends, once. Caller holds `mutex`.
fn ensureBackend() void {
    if (backend_ready) return;
    backend_ready = true;
    c.llama_backend_init();
    if (ggml_gpu.load(io) > 0) {
        backend_name = ggml_gpu.backendName() orelse "GPU";
        gpu_name = ggml_gpu.gpuName();
    }
    log.info("llama backend: {s}{s}{s}", .{ backend_name, if (gpu_name != null) " on " else "", gpu_name orelse "" });
}

pub fn find(name: []const u8) !*const Model {
    for (&models) |*m| if (std.mem.eql(u8, m.name, name)) return m;
    return error.UnknownModel;
}

pub fn present(m: *const Model) bool {
    return model_download.present(io, models_dir, m.file);
}

fn resolveModel(name: []const u8) !*const Model {
    if (!std.mem.eql(u8, name, "auto")) return find(name);
    var best: ?*const Model = null;
    for (device_models) |m| if (present(m)) {
        best = m;
    };
    return best orelse error.NoModel;
}

// ---------------------------------------------------------------------------
// Status, download, delete

pub const ModelStatus = struct {
    name: []const u8,
    label: []const u8,
    mb: u32,
    present: bool,
    /// What `compare` found faster on this device ("gpu"/"cpu"), if run.
    faster: ?[]const u8,
};

pub const Status = struct {
    backend: []const u8,
    gpu: ?[]const u8,
    models_dir: []const u8,
    models: [device_models.len]ModelStatus,
    loaded: ?[]const u8,
    downloading: ?[]const u8,
    generating: bool,
};

pub fn status() Status {
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    ensureBackend();
    var list: [device_models.len]ModelStatus = undefined;
    for (device_models, &list) |m, *s| s.* = .{
        .name = m.name,
        .label = m.label,
        .mb = m.mb,
        .present = present(m),
        .faster = if (prefs.get(io, models_dir, m.name)) |g| (if (g) "gpu" else "cpu") else null,
    };
    return .{
        .backend = backend_name,
        .gpu = gpu_name,
        .models_dir = models_dir,
        .models = list,
        .loaded = if (loaded) |l| l.model.name else null,
        .downloading = if (downloading) |m| m.name else null,
        .generating = generating.load(.acquire),
    };
}

/// Fetch a model from Hugging Face, emitting "chat:download". Blocks:
/// call it from a worker.
pub fn download(name: []const u8) !void {
    const m = try find(name);
    {
        mutex.lockUncancelable(io);
        defer mutex.unlock(io);
        if (downloading != null) return error.AlreadyDownloading;
        downloading = m;
    }
    defer {
        mutex.lockUncancelable(io);
        downloading = null;
        mutex.unlock(io);
    }
    const url = try std.fmt.allocPrint(gpa, "https://huggingface.co/{s}/resolve/main/{s}", .{ m.repo, m.file });
    defer gpa.free(url);
    try model_download.fetch(io, gpa, url, models_dir, m.file, m.mb, m, struct {
        fn f(model: *const Model, done_mb: u32, total_mb: u32) void {
            emit("chat:download", .{ .model = model.name, .done_mb = done_mb, .total_mb = total_mb });
        }
    }.f);
}

/// Remove a model from the device (unloading it first).
pub fn delete(name: []const u8) !void {
    const m = try find(name);
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    if (downloading == m) return error.Downloading;
    if (loaded) |*l| if (l.model == m) {
        if (generating.load(.acquire)) return error.Generating;
        l.deinit();
        loaded = null;
    };
    try model_download.remove(io, models_dir, m.file);
}

/// Memory pressure (the app in the background): free the model unless it
/// is answering or loading (then it returns at once: safe to call on the
/// main thread); the next reply loads it again.
pub fn unloadIdle() void {
    if (generating.load(.acquire)) return;
    if (!mutex.tryLock()) return;
    defer mutex.unlock(io);
    if (loaded) |*l| {
        l.deinit();
        loaded = null;
        log.info("memory pressure: unloaded the chat model", .{});
    }
}

// ---------------------------------------------------------------------------
// Loading, and the CPU/GPU choice

const prefs: model_download.Preferences = .{ .file = "chat-backends.txt" };

fn useGpu(m: *const Model, b: Backend) bool {
    ensureBackend();
    if (gpu_name == null) return false;
    return switch (b) {
        .gpu => true,
        .cpu => false,
        .auto => prefs.get(io, models_dir, m.name) orelse !is_phone,
    };
}

fn threads() i32 {
    // Phones: the big cores (more threads land on the little ones and
    // slow it down). Desktops: every core, but only one thread per
    // physical core on big CPUs (SMT siblings share the math units).
    const cpus = std.Thread.getCpuCount() catch 4;
    if (is_phone) return @intCast(@min(cpus, 4));
    return @intCast(if (cpus >= 16) cpus / 2 else cpus);
}

/// Prompt tokens per decode call. Phones: smaller compute buffers.
const n_batch: u32 = if (is_phone) 512 else 2048;

/// Load `m` (replacing another loaded model). Caller holds `mutex`.
/// Milliseconds spent, 0 if already loaded.
fn ensureModel(m: *const Model, want_gpu: bool, n_ctx: u32) !u64 {
    ensureBackend();
    if (loaded) |*l| {
        if (l.model == m and (l.gpu == want_gpu or l.fell_back) and l.asked_ctx >= n_ctx) return 0;
        l.deinit();
        loaded = null;
    }
    const path = try std.fs.path.joinZ(gpa, &.{ models_dir, m.file });
    defer gpa.free(path);
    const t0 = std.Io.Clock.awake.now(io);

    // The model: on the GPU, else (not enough memory there) on the CPU.
    var gpu = want_gpu;
    const model = while (true) {
        var mp = c.llama_model_default_params();
        mp.n_gpu_layers = if (gpu) 999 else 0;
        // Phones: read the weights into memory. Models live in the app's
        // external files directory, behind Android's FUSE layer, where a
        // mapped file the CPU reads every token is slow; memory reclaim
        // also drops clean mapped pages sooner than the app's own.
        if (is_phone) mp.load_mode = c.LLAMA_LOAD_MODE_NONE;
        if (llama.loadModel(path, mp)) |loaded_model| break loaded_model.handle else |err| {
            if (gpu and err != error.CpuUnsupported) {
                log.warn("cannot load {s} on the GPU ({s}): using the CPU", .{ m.name, @errorName(err) });
                gpu = false;
                continue;
            }
            log.err("cannot load {s}: {s}", .{ path, @errorName(err) });
            return if (err == error.CpuUnsupported) err else error.ModelNotFound;
        }
    };
    errdefer c.llama_model_free(model);

    // The context: capped at what the model was trained for. A q8_0 KV
    // cache (half the memory of f16, and faster to read) needs flash
    // attention: without it, f16. Out of memory: half the context, down to
    // 2048 tokens.
    const trained: u32 = @intCast(@max(c.llama_model_n_ctx_train(model), 512));
    var ctx_size = @max(@min(n_ctx, trained), 512);
    var kv_q8 = true;
    const n_threads = threads();
    const ctx = while (true) {
        var cp = c.llama_context_default_params();
        cp.n_ctx = ctx_size;
        cp.n_batch = n_batch;
        cp.n_ubatch = 512;
        cp.n_threads = n_threads;
        cp.n_threads_batch = n_threads;
        cp.no_perf = true;
        cp.flash_attn_type = c.LLAMA_FLASH_ATTN_TYPE_AUTO;
        cp.type_k = if (kv_q8) c.GGML_TYPE_Q8_0 else c.GGML_TYPE_F16;
        cp.type_v = cp.type_k;
        // CPU: keep the KV cache and every op there too.
        cp.offload_kqv = gpu;
        cp.op_offload = gpu;
        cp.abort_callback = abortCallback;
        if (c.llama_init_from_model(model, cp)) |ctx| break ctx;
        if (kv_q8) {
            kv_q8 = false;
            continue;
        }
        if (ctx_size <= 2048) return error.ContextFailed;
        ctx_size = @max(ctx_size / 2, 2048);
        kv_q8 = true;
        log.warn("retrying with a {d}-token context", .{ctx_size});
    };
    errdefer c.llama_free(ctx);

    // A resident threadpool (what llama-server does): without one, ggml
    // spawns and joins its threads for every graph, once per token.
    var tpp = c.ggml_threadpool_params_default(n_threads);
    const tp = c.ggml_threadpool_new(&tpp) orelse return error.OutOfMemory;
    c.llama_attach_threadpool(ctx, tp, tp);

    const tmpl = c.llama_model_chat_template(model, null);
    loaded = .{
        .model = m,
        .gpu = gpu,
        .fell_back = gpu != want_gpu,
        .handle = model,
        .ctx = ctx,
        .threadpool = tp,
        .asked_ctx = n_ctx,
        .n_ctx = ctx_size,
        .format = format.detect(if (tmpl != null) std.mem.span(tmpl) else null),
    };
    log.info("{s} on the {s}: {d}-token context, {s} KV cache, {d} threads", .{ m.name, if (gpu) "GPU" else "CPU", ctx_size, if (kv_q8) "q8_0" else "f16", n_threads });
    if (gpu) warmUp(&loaded.?);
    return elapsedMs(t0);
}

fn abortCallback(_: ?*anyopaque) callconv(.c) bool {
    return cancelled.load(.acquire);
}

/// One untimed decode on the GPU: Vulkan builds its pipelines on first use.
fn warmUp(l: *Loaded) void {
    const vocab = c.llama_model_get_vocab(l.handle);
    var toks: [16]c.llama_token = undefined;
    const n = c.llama_tokenize(vocab, "Hello, how are you?", 19, &toks, toks.len, true, false);
    if (n <= 0) return;
    _ = c.llama_decode(l.ctx, c.llama_batch_get_one(&toks, n));
    c.llama_memory_clear(c.llama_get_memory(l.ctx), true);
    l.cache.clearRetainingCapacity();
}

fn elapsedMs(since: std.Io.Timestamp) u64 {
    const ns = since.durationTo(std.Io.Clock.awake.now(io)).toNanoseconds();
    return @intCast(@divTrunc(@max(ns, 0), std.time.ns_per_ms));
}

// ---------------------------------------------------------------------------
// Replies

pub const Result = struct {
    text: []const u8,
    model: []const u8,
    backend: []const u8,
    /// "eos" (the model finished), "length" (max_tokens), "cancelled".
    stop: []const u8,
    prompt_tokens: u32,
    /// Prompt tokens already in the KV cache from the previous turn.
    reused_tokens: u32,
    tokens: u32,
    load_ms: u64,
    prompt_ms: u64,
    generate_ms: u64,
    tokens_per_s: f32,
};

/// Stop the reply being written (any thread). It returns what it has, with
/// `stop = "cancelled"`.
pub fn cancel() void {
    cancelled.store(true, .release);
}

/// The assistant's reply to `messages`, streamed as "chat:token" events
/// and returned whole (allocated with `a`). Blocks: call it from a worker.
pub fn generate(a: std.mem.Allocator, messages: []const Message, opts: Options) !Result {
    if (messages.len == 0) return error.NoMessages;
    const m = try resolveModel(opts.model);
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    if (generating.swap(true, .acq_rel)) return error.Generating;
    defer generating.store(false, .release);
    cancelled.store(false, .release);

    const load_ms = try ensureModel(m, useGpu(m, opts.backend), opts.context);
    const l = &loaded.?;
    const vocab = c.llama_model_get_vocab(l.handle);

    // The prompt, dropping the oldest turns until it fits with the reply.
    var first: usize = 0;
    var prompt: std.ArrayList(c.llama_token) = .empty;
    defer prompt.deinit(gpa);
    while (true) {
        prompt.clearRetainingCapacity();
        try tokenizeChat(l, vocab, messages, first, opts.think, &prompt);
        if (prompt.items.len + opts.max_tokens <= l.n_ctx) break;
        first = nextDroppable(messages, first) orelse return error.PromptTooLong;
    }

    // Reuse the KV cache's common prefix; always evaluate at least one token
    // (the logits for the first reply token come from the last one).
    const mem = c.llama_get_memory(l.ctx);
    var reuse = std.mem.indexOfDiff(c.llama_token, l.cache.items, prompt.items) orelse prompt.items.len;
    reuse = @min(reuse, prompt.items.len - 1);
    if (!c.llama_memory_seq_rm(mem, 0, @intCast(reuse), -1)) {
        c.llama_memory_clear(mem, true);
        reuse = 0;
    }
    l.cache.shrinkRetainingCapacity(reuse);

    const t_prompt = std.Io.Clock.awake.now(io);
    var pos = reuse;
    while (pos < prompt.items.len) {
        const n = @min(prompt.items.len - pos, n_batch);
        if (c.llama_decode(l.ctx, c.llama_batch_get_one(prompt.items[pos..].ptr, @intCast(n))) != 0) {
            l.cache.shrinkRetainingCapacity(0);
            c.llama_memory_clear(mem, true);
            if (cancelled.load(.acquire)) return error.Cancelled;
            return error.DecodeFailed;
        }
        try l.cache.appendSlice(gpa, prompt.items[pos..][0..n]);
        pos += n;
    }
    const prompt_ms = elapsedMs(t_prompt);

    // Sampling (llama.cpp's defaults): greedy at temperature 0, else a light
    // repetition penalty (small models loop without it), top-k 40, top-p,
    // min-p 0.05 and the temperature.
    const sampler = c.llama_sampler_chain_init(c.llama_sampler_chain_default_params()) orelse return error.OutOfMemory;
    defer c.llama_sampler_free(sampler);
    if (opts.temperature <= 0) {
        c.llama_sampler_chain_add(sampler, c.llama_sampler_init_greedy());
    } else {
        c.llama_sampler_chain_add(sampler, c.llama_sampler_init_penalties(c.llama_vocab_n_tokens(vocab), 64, 1.05, 0, 0));
        c.llama_sampler_chain_add(sampler, c.llama_sampler_init_top_k(40));
        c.llama_sampler_chain_add(sampler, c.llama_sampler_init_top_p(opts.top_p, 1));
        c.llama_sampler_chain_add(sampler, c.llama_sampler_init_min_p(0.05, 1));
        c.llama_sampler_chain_add(sampler, c.llama_sampler_init_temp(opts.temperature));
        c.llama_sampler_chain_add(sampler, c.llama_sampler_init_dist(c.LLAMA_DEFAULT_SEED));
    }

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The schema's grammar, and room to sample the whole vocabulary with it.
    const grammar: ?*c.llama_sampler = if (opts.schema.len > 0) blk: {
        const gbnf = try llama.jsonSchemaToGrammar(arena, opts.schema, null);
        break :blk c.llama_sampler_init_grammar(vocab, gbnf.ptr, "root") orelse return error.InvalidSchema;
    } else null;
    defer if (grammar) |g| c.llama_sampler_free(g);
    const candidates: []c.llama_token_data = if (grammar != null)
        try arena.alloc(c.llama_token_data, @intCast(c.llama_vocab_n_tokens(vocab)))
    else
        &.{};

    // `raw`: the whole output, special tokens as text (so the reasoning
    // block's markers can be found); `sent` bytes of its visible part went
    // out. The grammar binds to the answer, after any reasoning.
    var raw: std.ArrayList(u8) = .empty;
    var filter: format.ReasoningFilter = .init(l.format, opts.think);
    var answering = filter.visible(raw.items) != null;
    var sent: usize = 0;
    var stop: []const u8 = "length";
    var n_gen: u32 = 0;
    const t_gen = std.Io.Clock.awake.now(io);
    while (n_gen < opts.max_tokens) {
        if (cancelled.load(.acquire)) {
            stop = "cancelled";
            break;
        }
        var tok = if (grammar != null and answering)
            sampleWithGrammar(l.ctx, sampler, grammar.?, candidates)
        else
            c.llama_sampler_sample(sampler, l.ctx, -1);
        if (c.llama_vocab_is_eog(vocab, tok)) {
            stop = "eos";
            break;
        }
        n_gen += 1;
        var piece: [256]u8 = undefined;
        const len = c.llama_token_to_piece(vocab, tok, &piece, piece.len, 0, true);
        if (len > 0) {
            try raw.appendSlice(arena, piece[0..@intCast(len)]);
        } else if (len < 0) { // longer than the buffer: -len bytes
            const big = try arena.alloc(u8, @intCast(-len));
            const n = c.llama_token_to_piece(vocab, tok, big.ptr, @intCast(big.len), 0, true);
            if (n > 0) try raw.appendSlice(arena, big[0..@intCast(n)]);
        }
        if (filter.visible(raw.items)) |vis| {
            answering = true;
            const upto = format.completeUtf8(vis);
            if (upto > sent) {
                emit("chat:token", .{ .text = try format.validUtf8(arena, vis[sent..upto]) });
                sent = upto;
            }
        }
        if (l.cache.items.len >= l.n_ctx) break;
        if (c.llama_decode(l.ctx, c.llama_batch_get_one(@ptrCast(&tok), 1)) != 0) {
            if (cancelled.load(.acquire)) stop = "cancelled";
            break;
        }
        try l.cache.append(gpa, tok);
    }
    const visible = filter.visible(raw.items) orelse "";
    if (visible.len > sent) emit("chat:token", .{ .text = try format.validUtf8(arena, visible[sent..]) });
    const generate_ms = elapsedMs(t_gen);
    return .{
        .text = try a.dupe(u8, try format.validUtf8(arena, visible)),
        .model = m.name,
        .backend = if (l.gpu) backend_name else "CPU",
        .stop = stop,
        .prompt_tokens = @intCast(prompt.items.len),
        .reused_tokens = @intCast(reuse),
        .tokens = n_gen,
        .load_ms = load_ms,
        .prompt_ms = prompt_ms,
        .generate_ms = generate_ms,
        .tokens_per_s = if (generate_ms > 0) @as(f32, @floatFromInt(n_gen)) * 1000 / @as(f32, @floatFromInt(generate_ms)) else 0,
    };
}

/// The next token under `grammar`: drawn from the usual chain and only
/// checked against the grammar; only when it breaks it does the grammar
/// filter the whole vocabulary before drawing again (much faster than
/// filtering every time). Both samplers accept the token.
fn sampleWithGrammar(ctx: *c.llama_context, chain: *c.llama_sampler, grammar: *c.llama_sampler, candidates: []c.llama_token_data) c.llama_token {
    const logits = c.llama_get_logits_ith(ctx, -1);
    for (candidates, 0..) |*cd, i| cd.* = .{ .id = @intCast(i), .logit = logits[i], .p = 0 };
    var all: c.llama_token_data_array = .{ .data = candidates.ptr, .size = candidates.len, .selected = -1, .sorted = false };
    c.llama_sampler_apply(chain, &all);
    var tok = all.data[@intCast(all.selected)].id;

    var one = [1]c.llama_token_data{.{ .id = tok, .logit = 1, .p = 0 }};
    var single: c.llama_token_data_array = .{ .data = &one, .size = 1, .selected = -1, .sorted = false };
    c.llama_sampler_apply(grammar, &single);
    if (one[0].logit == -std.math.inf(f32)) {
        for (candidates, 0..) |*cd, i| cd.* = .{ .id = @intCast(i), .logit = logits[i], .p = 0 };
        all = .{ .data = candidates.ptr, .size = candidates.len, .selected = -1, .sorted = false };
        c.llama_sampler_apply(grammar, &all);
        c.llama_sampler_apply(chain, &all);
        tok = all.data[@intCast(all.selected)].id;
    }
    c.llama_sampler_accept(grammar, tok);
    c.llama_sampler_accept(chain, tok);
    return tok;
}

/// `messages[first..]` (plus a leading system message, always kept) in the
/// model's chat format, tokenized into `out`.
fn tokenizeChat(l: *const Loaded, vocab: ?*const c.llama_vocab, messages: []const Message, first: usize, think: bool, out: *std.ArrayList(c.llama_token)) !void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var turns: std.ArrayList(format.Turn) = .empty;
    for (messages, 0..) |msg, i| {
        const keep = i >= first or (i == 0 and std.mem.eql(u8, msg.role, "system"));
        if (keep) try turns.append(arena, .{ .role = msg.role, .content = msg.content });
    }
    const text = try format.render(arena, l.format, turns.items, think) orelse try applyTemplate(arena, l.handle, turns.items);
    // The template writes the special tokens as text: parse them; the BOS
    // too, when the vocabulary adds one and the template didn't.
    const add_bos = c.llama_vocab_get_add_bos(vocab);
    try out.ensureTotalCapacity(gpa, text.len + 8);
    var count = c.llama_tokenize(vocab, text.ptr, @intCast(text.len), out.items.ptr, @intCast(out.capacity), add_bos, true);
    if (count < 0) {
        try out.ensureTotalCapacity(gpa, @intCast(-count));
        count = c.llama_tokenize(vocab, text.ptr, @intCast(text.len), out.items.ptr, @intCast(out.capacity), add_bos, true);
    }
    if (count < 0) return error.TokenizeFailed;
    out.items.len = @intCast(count);
}

/// llama.cpp's built-in templates: the GGUF's (it recognizes the common
/// families: ChatML, Llama 3, Gemma, Mistral, Phi...), else ChatML.
fn applyTemplate(arena: std.mem.Allocator, model: *c.llama_model, turns: []const format.Turn) ![]const u8 {
    const msgs = try arena.alloc(c.llama_chat_message, turns.len);
    var size: usize = 512;
    for (turns, msgs) |t, *msg| {
        msg.* = .{ .role = (try arena.dupeZ(u8, t.role)).ptr, .content = (try arena.dupeZ(u8, t.content)).ptr };
        size += t.content.len * 2;
    }
    const own = c.llama_model_chat_template(model, null);
    while (true) {
        const buf = try arena.alloc(u8, size);
        var n: i32 = -1;
        if (own != null) n = c.llama_chat_apply_template(own, msgs.ptr, msgs.len, true, buf.ptr, @intCast(buf.len));
        if (n < 0) n = c.llama_chat_apply_template("chatml", msgs.ptr, msgs.len, true, buf.ptr, @intCast(buf.len));
        if (n < 0) return error.ChatTemplateFailed;
        if (@as(usize, @intCast(n)) <= buf.len) return buf[0..@intCast(n)];
        size = @intCast(n);
    }
}

/// The index after the oldest droppable turn (a user message and the
/// assistant's answer to it), or null when only the last message is left.
fn nextDroppable(messages: []const Message, first: usize) ?usize {
    var i = first;
    if (i == 0 and std.mem.eql(u8, messages[0].role, "system")) i = 1;
    if (i + 1 >= messages.len) return null;
    i += 1;
    while (i + 1 < messages.len and !std.mem.eql(u8, messages[i].role, "user")) i += 1;
    return i;
}

// ---------------------------------------------------------------------------
// Compare: the GPU against the CPU on this device

pub const Run = struct { tokens_per_s: f32, prompt_ms: u64, tokens: u32 };

pub const Comparison = struct {
    model: []const u8,
    gpu: ?Run,
    cpu: Run,
    /// What `.auto` uses for this model from now on.
    faster: []const u8,
};

/// The same short prompt and a 64-token greedy reply on the GPU (after a
/// warm-up) and on the CPU; the faster one is remembered for `Backend.auto`.
/// On phones the GPU must be 1.3x faster: phone CPUs vary with heat.
pub fn compare(opts: Options) !Comparison {
    const m = try resolveModel(opts.model);
    ensureBackendLocked();
    const messages = [_]Message{.{ .role = "user", .content = "Describe the sea in three sentences." }};
    var o = opts;
    o.model = m.name;
    o.temperature = 0;
    o.max_tokens = 64;
    var gpu_run: ?Run = null;
    if (gpu_name != null) {
        o.backend = .gpu;
        gpu_run = try timed(&messages, o);
        emit("chat:compare", .{ .backend = "GPU", .tokens_per_s = gpu_run.?.tokens_per_s });
    }
    o.backend = .cpu;
    const cpu_run = try timed(&messages, o);
    emit("chat:compare", .{ .backend = "CPU", .tokens_per_s = cpu_run.tokens_per_s });
    const gpu_wins = if (gpu_run) |g| gpuWins(g.tokens_per_s, cpu_run.tokens_per_s, is_phone) else false;
    if (gpu_run != null) prefs.set(io, gpa, models_dir, m.name, gpu_wins);
    return .{ .model = m.name, .gpu = gpu_run, .cpu = cpu_run, .faster = if (gpu_wins) "gpu" else "cpu" };
}

/// Whether Compare picks the GPU: at least as fast on desktops; on phones
/// 1.3× the CPU, since a GPU barely faster isn't worth its heat and battery.
fn gpuWins(gpu_tps: f32, cpu_tps: f32, phone: bool) bool {
    const margin: f32 = if (phone) 1.3 else 1.0;
    return gpu_tps >= cpu_tps * margin;
}

test gpuWins {
    try std.testing.expect(gpuWins(20, 20, false));
    try std.testing.expect(!gpuWins(19, 20, false));
    try std.testing.expect(!gpuWins(25, 20, true)); // 1.25×: not enough on a phone
    try std.testing.expect(gpuWins(26, 20, true));
}

fn ensureBackendLocked() void {
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    ensureBackend();
}

/// One fresh reply (no KV reuse), timed.
fn timed(messages: []const Message, o: Options) !Run {
    {
        mutex.lockUncancelable(io);
        defer mutex.unlock(io);
        if (loaded) |*l| {
            c.llama_memory_clear(c.llama_get_memory(l.ctx), true);
            l.cache.clearRetainingCapacity();
        }
    }
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const r = try generate(arena.allocator(), messages, o);
    return .{ .tokens_per_s = r.tokens_per_s, .prompt_ms = r.prompt_ms, .tokens = r.tokens };
}

test nextDroppable {
    const msgs = [_]Message{
        .{ .role = "system", .content = "s" },
        .{ .role = "user", .content = "1" },
        .{ .role = "assistant", .content = "a1" },
        .{ .role = "user", .content = "2" },
    };
    try std.testing.expectEqual(@as(?usize, 3), nextDroppable(&msgs, 0));
    try std.testing.expectEqual(@as(?usize, null), nextDroppable(&msgs, 3));
}

test {
    _ = format;
}
