//! Minimal JNI bindings (the parts of <jni.h> Oriel uses), in plain Zig so
//! the Android backend needs no NDK headers to type-check.
//!
//! Strings never cross JNI as `jstring` here: Java's "modified UTF-8"
//! (`NewStringUTF`, `GetStringUTFChars`) mangles NUL and characters outside
//! the BMP (emoji). Text travels as UTF-8 `byte[]` and Kotlin decodes it
//! with `String(bytes, Charsets.UTF_8)`.

const std = @import("std");

pub const jint = i32;
pub const jlong = i64;
pub const jboolean = u8;
pub const jsize = jint;
pub const jobject = ?*anyopaque;
pub const jclass = jobject;
pub const jmethodID = ?*anyopaque;

pub const jvalue = extern union {
    z: jboolean,
    b: i8,
    c: u16,
    s: i16,
    i: jint,
    j: jlong,
    f: f32,
    d: f64,
    l: jobject,
};

pub const JNI_OK: jint = 0;
pub const JNI_EDETACHED: jint = -2;
pub const JNI_VERSION_1_6: jint = 0x00010006;

/// `JNIEnv`: a pointer to the function table.
pub const Env = extern struct {
    functions: *const Functions,

    /// Log and clear a pending Java exception; true if there was one.
    pub fn clearException(env: *Env) bool {
        if (env.functions.ExceptionCheck(env) == 0) return false;
        env.functions.ExceptionDescribe(env); // to logcat
        env.functions.ExceptionClear(env);
        return true;
    }

    /// A new local `byte[]` holding `bytes`, or null (out of memory).
    pub fn newBytes(env: *Env, bytes: []const u8) jobject {
        const len: jsize = std.math.cast(jsize, bytes.len) orelse return null;
        const arr = env.functions.NewByteArray(env, len) orelse {
            _ = env.clearException();
            return null;
        };
        if (len > 0) env.functions.SetByteArrayRegion(env, arr, 0, len, bytes.ptr);
        return arr;
    }

    /// Copy a `byte[]` into memory from `gpa` (caller frees); null for a null array.
    pub fn bytesAlloc(env: *Env, gpa: std.mem.Allocator, arr: jobject) !?[]u8 {
        if (arr == null) return null;
        const len: usize = @intCast(@max(env.functions.GetArrayLength(env, arr), 0));
        const out = try gpa.alloc(u8, len);
        if (len > 0) env.functions.GetByteArrayRegion(env, arr, 0, @intCast(len), out.ptr);
        return out;
    }
};

/// `JavaVM`.
pub const Vm = extern struct {
    functions: *const InvokeFunctions,

    /// The calling thread's env, or null if it isn't attached to the VM.
    pub fn getEnv(vm: *Vm) ?*Env {
        var env: ?*Env = null;
        if (vm.functions.GetEnv(vm, &env, JNI_VERSION_1_6) != JNI_OK) return null;
        return env;
    }
};

pub const InvokeFunctions = extern struct {
    reserved0: ?*anyopaque,
    reserved1: ?*anyopaque,
    reserved2: ?*anyopaque,
    DestroyJavaVM: *const fn (*Vm) callconv(.c) jint,
    AttachCurrentThread: *const fn (*Vm, *?*Env, ?*anyopaque) callconv(.c) jint,
    DetachCurrentThread: *const fn (*Vm) callconv(.c) jint,
    GetEnv: *const fn (*Vm, *?*Env, jint) callconv(.c) jint,
    AttachCurrentThreadAsDaemon: *const fn (*Vm, *?*Env, ?*anyopaque) callconv(.c) jint,
};

/// `JNINativeInterface`, in <jni.h> order.
pub const Functions = extern struct {
    reserved0: ?*const anyopaque,
    reserved1: ?*const anyopaque,
    reserved2: ?*const anyopaque,
    reserved3: ?*const anyopaque,
    GetVersion: *const fn (*Env) callconv(.c) jint,
    DefineClass: ?*const anyopaque,
    FindClass: *const fn (*Env, [*:0]const u8) callconv(.c) jclass,
    FromReflectedMethod: ?*const anyopaque,
    FromReflectedField: ?*const anyopaque,
    ToReflectedMethod: ?*const anyopaque,
    GetSuperclass: ?*const anyopaque,
    IsAssignableFrom: ?*const anyopaque,
    ToReflectedField: ?*const anyopaque,
    Throw: ?*const anyopaque,
    ThrowNew: ?*const anyopaque,
    ExceptionOccurred: ?*const anyopaque,
    ExceptionDescribe: *const fn (*Env) callconv(.c) void,
    ExceptionClear: *const fn (*Env) callconv(.c) void,
    FatalError: ?*const anyopaque,
    PushLocalFrame: *const fn (*Env, jint) callconv(.c) jint,
    PopLocalFrame: *const fn (*Env, jobject) callconv(.c) jobject,
    NewGlobalRef: *const fn (*Env, jobject) callconv(.c) jobject,
    DeleteGlobalRef: *const fn (*Env, jobject) callconv(.c) void,
    DeleteLocalRef: *const fn (*Env, jobject) callconv(.c) void,
    IsSameObject: ?*const anyopaque,
    NewLocalRef: ?*const anyopaque,
    EnsureLocalCapacity: ?*const anyopaque,
    AllocObject: ?*const anyopaque,
    NewObject: ?*const anyopaque,
    NewObjectV: ?*const anyopaque,
    NewObjectA: ?*const anyopaque,
    GetObjectClass: *const fn (*Env, jobject) callconv(.c) jclass,
    IsInstanceOf: ?*const anyopaque,
    GetMethodID: *const fn (*Env, jclass, [*:0]const u8, [*:0]const u8) callconv(.c) jmethodID,
    CallObjectMethod: ?*const anyopaque,
    CallObjectMethodV: ?*const anyopaque,
    CallObjectMethodA: *const fn (*Env, jobject, jmethodID, ?[*]const jvalue) callconv(.c) jobject,
    CallBooleanMethod: ?*const anyopaque,
    CallBooleanMethodV: ?*const anyopaque,
    CallBooleanMethodA: *const fn (*Env, jobject, jmethodID, ?[*]const jvalue) callconv(.c) jboolean,
    CallByteMethod: ?*const anyopaque,
    CallByteMethodV: ?*const anyopaque,
    CallByteMethodA: ?*const anyopaque,
    CallCharMethod: ?*const anyopaque,
    CallCharMethodV: ?*const anyopaque,
    CallCharMethodA: ?*const anyopaque,
    CallShortMethod: ?*const anyopaque,
    CallShortMethodV: ?*const anyopaque,
    CallShortMethodA: ?*const anyopaque,
    CallIntMethod: ?*const anyopaque,
    CallIntMethodV: ?*const anyopaque,
    CallIntMethodA: *const fn (*Env, jobject, jmethodID, ?[*]const jvalue) callconv(.c) jint,
    CallLongMethod: ?*const anyopaque,
    CallLongMethodV: ?*const anyopaque,
    CallLongMethodA: ?*const anyopaque,
    CallFloatMethod: ?*const anyopaque,
    CallFloatMethodV: ?*const anyopaque,
    CallFloatMethodA: ?*const anyopaque,
    CallDoubleMethod: ?*const anyopaque,
    CallDoubleMethodV: ?*const anyopaque,
    CallDoubleMethodA: ?*const anyopaque,
    CallVoidMethod: ?*const anyopaque,
    CallVoidMethodV: ?*const anyopaque,
    CallVoidMethodA: *const fn (*Env, jobject, jmethodID, ?[*]const jvalue) callconv(.c) void,
    CallNonvirtualObjectMethod: ?*const anyopaque,
    CallNonvirtualObjectMethodV: ?*const anyopaque,
    CallNonvirtualObjectMethodA: ?*const anyopaque,
    CallNonvirtualBooleanMethod: ?*const anyopaque,
    CallNonvirtualBooleanMethodV: ?*const anyopaque,
    CallNonvirtualBooleanMethodA: ?*const anyopaque,
    CallNonvirtualByteMethod: ?*const anyopaque,
    CallNonvirtualByteMethodV: ?*const anyopaque,
    CallNonvirtualByteMethodA: ?*const anyopaque,
    CallNonvirtualCharMethod: ?*const anyopaque,
    CallNonvirtualCharMethodV: ?*const anyopaque,
    CallNonvirtualCharMethodA: ?*const anyopaque,
    CallNonvirtualShortMethod: ?*const anyopaque,
    CallNonvirtualShortMethodV: ?*const anyopaque,
    CallNonvirtualShortMethodA: ?*const anyopaque,
    CallNonvirtualIntMethod: ?*const anyopaque,
    CallNonvirtualIntMethodV: ?*const anyopaque,
    CallNonvirtualIntMethodA: ?*const anyopaque,
    CallNonvirtualLongMethod: ?*const anyopaque,
    CallNonvirtualLongMethodV: ?*const anyopaque,
    CallNonvirtualLongMethodA: ?*const anyopaque,
    CallNonvirtualFloatMethod: ?*const anyopaque,
    CallNonvirtualFloatMethodV: ?*const anyopaque,
    CallNonvirtualFloatMethodA: ?*const anyopaque,
    CallNonvirtualDoubleMethod: ?*const anyopaque,
    CallNonvirtualDoubleMethodV: ?*const anyopaque,
    CallNonvirtualDoubleMethodA: ?*const anyopaque,
    CallNonvirtualVoidMethod: ?*const anyopaque,
    CallNonvirtualVoidMethodV: ?*const anyopaque,
    CallNonvirtualVoidMethodA: ?*const anyopaque,
    GetFieldID: ?*const anyopaque,
    GetObjectField: ?*const anyopaque,
    GetBooleanField: ?*const anyopaque,
    GetByteField: ?*const anyopaque,
    GetCharField: ?*const anyopaque,
    GetShortField: ?*const anyopaque,
    GetIntField: ?*const anyopaque,
    GetLongField: ?*const anyopaque,
    GetFloatField: ?*const anyopaque,
    GetDoubleField: ?*const anyopaque,
    SetObjectField: ?*const anyopaque,
    SetBooleanField: ?*const anyopaque,
    SetByteField: ?*const anyopaque,
    SetCharField: ?*const anyopaque,
    SetShortField: ?*const anyopaque,
    SetIntField: ?*const anyopaque,
    SetLongField: ?*const anyopaque,
    SetFloatField: ?*const anyopaque,
    SetDoubleField: ?*const anyopaque,
    GetStaticMethodID: *const fn (*Env, jclass, [*:0]const u8, [*:0]const u8) callconv(.c) jmethodID,
    CallStaticObjectMethod: ?*const anyopaque,
    CallStaticObjectMethodV: ?*const anyopaque,
    CallStaticObjectMethodA: *const fn (*Env, jclass, jmethodID, ?[*]const jvalue) callconv(.c) jobject,
    CallStaticBooleanMethod: ?*const anyopaque,
    CallStaticBooleanMethodV: ?*const anyopaque,
    CallStaticBooleanMethodA: *const fn (*Env, jclass, jmethodID, ?[*]const jvalue) callconv(.c) jboolean,
    CallStaticByteMethod: ?*const anyopaque,
    CallStaticByteMethodV: ?*const anyopaque,
    CallStaticByteMethodA: ?*const anyopaque,
    CallStaticCharMethod: ?*const anyopaque,
    CallStaticCharMethodV: ?*const anyopaque,
    CallStaticCharMethodA: ?*const anyopaque,
    CallStaticShortMethod: ?*const anyopaque,
    CallStaticShortMethodV: ?*const anyopaque,
    CallStaticShortMethodA: ?*const anyopaque,
    CallStaticIntMethod: ?*const anyopaque,
    CallStaticIntMethodV: ?*const anyopaque,
    CallStaticIntMethodA: *const fn (*Env, jclass, jmethodID, ?[*]const jvalue) callconv(.c) jint,
    CallStaticLongMethod: ?*const anyopaque,
    CallStaticLongMethodV: ?*const anyopaque,
    CallStaticLongMethodA: *const fn (*Env, jclass, jmethodID, ?[*]const jvalue) callconv(.c) jlong,
    CallStaticFloatMethod: ?*const anyopaque,
    CallStaticFloatMethodV: ?*const anyopaque,
    CallStaticFloatMethodA: ?*const anyopaque,
    CallStaticDoubleMethod: ?*const anyopaque,
    CallStaticDoubleMethodV: ?*const anyopaque,
    CallStaticDoubleMethodA: ?*const anyopaque,
    CallStaticVoidMethod: ?*const anyopaque,
    CallStaticVoidMethodV: ?*const anyopaque,
    CallStaticVoidMethodA: *const fn (*Env, jclass, jmethodID, ?[*]const jvalue) callconv(.c) void,
    GetStaticFieldID: ?*const anyopaque,
    GetStaticObjectField: ?*const anyopaque,
    GetStaticBooleanField: ?*const anyopaque,
    GetStaticByteField: ?*const anyopaque,
    GetStaticCharField: ?*const anyopaque,
    GetStaticShortField: ?*const anyopaque,
    GetStaticIntField: ?*const anyopaque,
    GetStaticLongField: ?*const anyopaque,
    GetStaticFloatField: ?*const anyopaque,
    GetStaticDoubleField: ?*const anyopaque,
    SetStaticObjectField: ?*const anyopaque,
    SetStaticBooleanField: ?*const anyopaque,
    SetStaticByteField: ?*const anyopaque,
    SetStaticCharField: ?*const anyopaque,
    SetStaticShortField: ?*const anyopaque,
    SetStaticIntField: ?*const anyopaque,
    SetStaticLongField: ?*const anyopaque,
    SetStaticFloatField: ?*const anyopaque,
    SetStaticDoubleField: ?*const anyopaque,
    NewString: ?*const anyopaque,
    GetStringLength: ?*const anyopaque,
    GetStringChars: ?*const anyopaque,
    ReleaseStringChars: ?*const anyopaque,
    NewStringUTF: ?*const anyopaque,
    GetStringUTFLength: ?*const anyopaque,
    GetStringUTFChars: ?*const anyopaque,
    ReleaseStringUTFChars: ?*const anyopaque,
    GetArrayLength: *const fn (*Env, jobject) callconv(.c) jsize,
    NewObjectArray: *const fn (*Env, jsize, jclass, jobject) callconv(.c) jobject,
    GetObjectArrayElement: *const fn (*Env, jobject, jsize) callconv(.c) jobject,
    SetObjectArrayElement: *const fn (*Env, jobject, jsize, jobject) callconv(.c) void,
    NewBooleanArray: ?*const anyopaque,
    NewByteArray: *const fn (*Env, jsize) callconv(.c) jobject,
    NewCharArray: ?*const anyopaque,
    NewShortArray: ?*const anyopaque,
    NewIntArray: *const fn (*Env, jsize) callconv(.c) jobject,
    NewLongArray: ?*const anyopaque,
    NewFloatArray: ?*const anyopaque,
    NewDoubleArray: ?*const anyopaque,
    GetBooleanArrayElements: ?*const anyopaque,
    GetByteArrayElements: ?*const anyopaque,
    GetCharArrayElements: ?*const anyopaque,
    GetShortArrayElements: ?*const anyopaque,
    GetIntArrayElements: ?*const anyopaque,
    GetLongArrayElements: ?*const anyopaque,
    GetFloatArrayElements: ?*const anyopaque,
    GetDoubleArrayElements: ?*const anyopaque,
    ReleaseBooleanArrayElements: ?*const anyopaque,
    ReleaseByteArrayElements: ?*const anyopaque,
    ReleaseCharArrayElements: ?*const anyopaque,
    ReleaseShortArrayElements: ?*const anyopaque,
    ReleaseIntArrayElements: ?*const anyopaque,
    ReleaseLongArrayElements: ?*const anyopaque,
    ReleaseFloatArrayElements: ?*const anyopaque,
    ReleaseDoubleArrayElements: ?*const anyopaque,
    GetBooleanArrayRegion: ?*const anyopaque,
    GetByteArrayRegion: *const fn (*Env, jobject, jsize, jsize, [*]u8) callconv(.c) void,
    GetCharArrayRegion: ?*const anyopaque,
    GetShortArrayRegion: ?*const anyopaque,
    GetIntArrayRegion: *const fn (*Env, jobject, jsize, jsize, [*]jint) callconv(.c) void,
    GetLongArrayRegion: ?*const anyopaque,
    GetFloatArrayRegion: ?*const anyopaque,
    GetDoubleArrayRegion: ?*const anyopaque,
    SetBooleanArrayRegion: ?*const anyopaque,
    SetByteArrayRegion: *const fn (*Env, jobject, jsize, jsize, [*]const u8) callconv(.c) void,
    SetCharArrayRegion: ?*const anyopaque,
    SetShortArrayRegion: ?*const anyopaque,
    SetIntArrayRegion: *const fn (*Env, jobject, jsize, jsize, [*]const jint) callconv(.c) void,
    SetLongArrayRegion: ?*const anyopaque,
    SetFloatArrayRegion: ?*const anyopaque,
    SetDoubleArrayRegion: ?*const anyopaque,
    RegisterNatives: ?*const anyopaque,
    UnregisterNatives: ?*const anyopaque,
    MonitorEnter: ?*const anyopaque,
    MonitorExit: ?*const anyopaque,
    GetJavaVM: *const fn (*Env, *?*Vm) callconv(.c) jint,
    GetStringRegion: ?*const anyopaque,
    GetStringUTFRegion: ?*const anyopaque,
    GetPrimitiveArrayCritical: ?*const anyopaque,
    ReleasePrimitiveArrayCritical: ?*const anyopaque,
    GetStringCritical: ?*const anyopaque,
    ReleaseStringCritical: ?*const anyopaque,
    NewWeakGlobalRef: ?*const anyopaque,
    DeleteWeakGlobalRef: ?*const anyopaque,
    ExceptionCheck: *const fn (*Env) callconv(.c) jboolean,
    NewDirectByteBuffer: ?*const anyopaque,
    GetDirectBufferAddress: ?*const anyopaque,
    GetDirectBufferCapacity: ?*const anyopaque,
    GetObjectRefType: ?*const anyopaque,
};

comptime {
    // Spot checks against the table indices of <jni.h>.
    const idx = struct {
        fn of(comptime name: []const u8) usize {
            return @offsetOf(Functions, name) / @sizeOf(usize);
        }
    };
    std.debug.assert(idx.of("FindClass") == 6);
    std.debug.assert(idx.of("GetMethodID") == 33);
    std.debug.assert(idx.of("GetStaticMethodID") == 113);
    std.debug.assert(idx.of("NewStringUTF") == 167);
    std.debug.assert(idx.of("RegisterNatives") == 215);
    std.debug.assert(idx.of("GetJavaVM") == 219);
    std.debug.assert(idx.of("ExceptionCheck") == 228);
    std.debug.assert(@sizeOf(Functions) == 233 * @sizeOf(usize));
}
