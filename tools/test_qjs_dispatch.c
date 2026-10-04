// Correctness and bridge-only benchmark; see docs/native-renderer.md.
#include <assert.h>
#include <stdio.h>
#include <time.h>
#include "../src/native_ui/qjs_dispatch.h"

static void eval(JSContext *ctx, const char *source) {
    JSValue value = JS_Eval(ctx, source, strlen(source), "test", JS_EVAL_TYPE_GLOBAL);
    assert(!JS_IsException(value));
    JS_FreeValue(ctx, value);
}

static void truth(JSContext *ctx, JSValue value) {
    assert(!JS_IsException(value));
    assert(JS_ToBool(ctx, value) == 1);
    JS_FreeValue(ctx, value);
}

static double milliseconds(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000.0 + ts.tv_nsec / 1e6;
}

static void bench(JSContext *ctx, const char *method, const char *source, int count) {
    for (int direct = 0; direct <= 1; direct++) {
        double start = milliseconds();
        for (int i = 0; i < count; i++) {
            JSValue value;
            if (!direct) value = JS_Eval(ctx, source, strlen(source), "bench", JS_EVAL_TYPE_GLOBAL);
            else if (!strcmp(method, "event")) value = nui_event(ctx, 42, "click", 5, "0", 1);
            else if (!strcmp(method, "vsync")) value = nui_number_call(ctx, method, 16.667);
            else value = nui_dispatch(ctx, method, 0, NULL);
            assert(!JS_IsException(value));
            JS_FreeValue(ctx, value);
        }
        printf("%s %s %.3f us/call\n", method, direct ? "direct" : "eval", (milliseconds() - start) * 1000 / count);
    }
}

int main(void) {
    JSRuntime *rt = JS_NewRuntime();
    assert(rt);
    JSContext *ctx = JS_NewContext(rt);
    assert(ctx);
    eval(ctx, "globalThis.__oriel = {event(id, kind, data) {globalThis.last=[id,kind,data]; return this === __oriel},"
              "timer(id) {globalThis.timerId=id; return this === __oriel}, vsync(ms) {globalThis.ms=ms}, render() {}};");
    // Non-terminated slices and names containing quotes remain data, never code.
    const char payload[] = {'[', '1', ',', '"', 'x', '"', ']', '!'};
    truth(ctx, nui_event(ctx, 42, "click\"\\", 7, payload, 7));
    eval(ctx, "if(last[0]!==42 || last[1] !== 'click\"\\\\' || last[2][1] !== 'x') throw Error('event arguments');");
    truth(ctx, nui_event(ctx, 7, "input", 5, "\"héllo 👋\\n\\u0000\"", strlen("\"héllo 👋\\n\\u0000\"")));
    eval(ctx, "if(last[2] !== 'héllo 👋\\n\\u0000') throw Error('unicode');");
    truth(ctx, nui_event(ctx, 0, "back", 4, "null", 4));
    eval(ctx, "if(last[2] !== null) throw Error('null');");
    truth(ctx, nui_number_call(ctx, "timer", 4294967295.0));
    eval(ctx, "if(timerId !== 4294967295) throw Error('timer id');");
    JSValue value = nui_event(ctx, 1, "input", 5, "{", 1);
    assert(JS_IsException(value));
    JS_FreeValue(ctx, JS_GetException(ctx));
    // Resolve the method on each call so page replacements still work.
    eval(ctx, "__oriel.event = () => false;");
    value = nui_event(ctx, 1, "click", 5, "0", 1);
    assert(JS_ToBool(ctx, value) == 0);
    JS_FreeValue(ctx, value);
    eval(ctx, "__oriel.event = () => {throw Error('expected')};");
    value = nui_event(ctx, 1, "click", 5, "0", 1);
    assert(JS_IsException(value));
    JS_FreeValue(ctx, JS_GetException(ctx));
    eval(ctx, "__oriel.event = (id,kind,data) => id===42 && kind==='click' && data===0;");
    bench(ctx, "event", "__oriel.event(42,\"click\",0)", 20000);
    bench(ctx, "vsync", "__oriel.vsync(16.667)", 20000);
    bench(ctx, "render", "__oriel.render()", 20000);
    JS_FreeContext(ctx);
    JS_FreeRuntime(rt);
    puts("dispatch correctness: ok");
    return 0;
}
