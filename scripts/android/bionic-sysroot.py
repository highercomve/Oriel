#!/usr/bin/env python3
"""Make a stand-in NDK for link checks where the real one can't be
downloaded (dl.google.com unreachable): bionic's headers and stub libraries
built from AOSP's bionic sources (GitHub mirror), laid out like
<ndk>/toolchains/llvm/prebuilt/linux-x86_64/sysroot.

  scripts/android/bionic-sysroot.py <out-dir> [--api 29] [--bionic <checkout>]
  ANDROID_NDK_HOME=<out-dir> zig build -Dtarget=x86_64-linux-android

What it makes:
  - usr/include: bionic's libc headers, kernel UAPI, per-arch asm/, plus a
    minimal android/log.h;
  - usr/lib/<triple>/<api>: libc, libm, libdl stubs from bionic's .map.txt
    files (NDK-visible symbols up to the API level, with bionic's symbol
    versions, like the NDK's ndkstubgen), liblog, libandroid and libaaudio
    stubs with the symbols Oriel and ggml use, crtbegin_so.o and
    crtend_so.o built from bionic's sources;
  - shader-tools/linux-x86_64/glslc: glslc from PATH, if any.

A library linked against it loads the same symbols the NDK would give it,
so undefined or wrongly versioned imports show up (`readelf --dyn-syms`).
It is for checking builds only: ship with the real NDK. Needs zig and git.
"""
import argparse, os, re, shutil, subprocess, tempfile

ARCHES = {  # NDK arch name: (triple, UAPI asm dir, Zig arch)
    "x86_64": ("x86_64-linux-android", "asm-x86", "x86_64"),
    "arm64": ("aarch64-linux-android", "asm-arm64", "aarch64"),
}
ALL_ARCHES = {"arm", "arm64", "x86", "x86_64", "riscv64"}
CODENAMES = {"J": 16, "J-MR1": 17, "J-MR2": 18, "K": 19, "L": 21, "L-MR1": 22, "M": 23, "N": 24,
             "N-MR1": 25, "O": 26, "O-MR1": 27, "P": 28, "Q": 29, "R": 30, "S": 31, "Sv2": 32,
             "Tiramisu": 33, "UpsideDownCake": 34, "VanillaIceCream": 35}
BIONIC_URL = "https://github.com/aosp-mirror/platform_bionic"
BIONIC_TAG = "android-15.0.0_r1"

# NDK libraries outside bionic: the symbols Oriel (src/platform/android,
# src/modules) and ggml use, plus close neighbours.
LOG = """__android_log_assert __android_log_buf_print __android_log_buf_write __android_log_print
__android_log_vprint __android_log_write __android_log_is_loggable""".split()
ANDROID = """ALooper_acquire ALooper_addFd ALooper_forThread ALooper_pollOnce ALooper_prepare
ALooper_release ALooper_removeFd ALooper_wake AAssetManager_fromJava AAssetManager_open AAsset_close
AAsset_getBuffer AAsset_getLength AAsset_read ANativeWindow_fromSurface ANativeWindow_release
ANativeWindow_acquire ANativeWindow_getWidth ANativeWindow_getHeight ASharedMemory_create""".split()
AAUDIO = """AAudioStreamBuilder_delete AAudioStreamBuilder_openStream AAudioStreamBuilder_setChannelCount
AAudioStreamBuilder_setDeviceId AAudioStreamBuilder_setDirection AAudioStreamBuilder_setFormat
AAudioStreamBuilder_setInputPreset AAudioStreamBuilder_setPerformanceMode AAudioStreamBuilder_setSampleRate
AAudioStreamBuilder_setSharingMode AAudioStreamBuilder_setDataCallback AAudioStreamBuilder_setErrorCallback
AAudioStreamBuilder_setBufferCapacityInFrames AAudioStreamBuilder_setFramesPerDataCallback
AAudioStream_close AAudioStream_getChannelCount AAudioStream_getSampleRate AAudioStream_read
AAudioStream_write AAudioStream_requestStart AAudioStream_requestStop AAudioStream_getState
AAudio_convertResultToText AAudio_createStreamBuilder""".split()

LOG_H = """#pragma once
/* Minimal <android/log.h> (bionic-sysroot.py): what Oriel and ggml use. */
#include <stdarg.h>
#include <sys/cdefs.h>
__BEGIN_DECLS
typedef enum android_LogPriority { ANDROID_LOG_UNKNOWN = 0, ANDROID_LOG_DEFAULT, ANDROID_LOG_VERBOSE,
  ANDROID_LOG_DEBUG, ANDROID_LOG_INFO, ANDROID_LOG_WARN, ANDROID_LOG_ERROR, ANDROID_LOG_FATAL,
  ANDROID_LOG_SILENT } android_LogPriority;
int __android_log_write(int prio, const char* tag, const char* text);
int __android_log_print(int prio, const char* tag, const char* fmt, ...) __attribute__((__format__(printf, 3, 4)));
int __android_log_vprint(int prio, const char* tag, const char* fmt, va_list ap) __attribute__((__format__(printf, 3, 0)));
void __android_log_assert(const char* cond, const char* tag, const char* fmt, ...) __attribute__((__noreturn__));
__END_DECLS
"""


def level(v):
    return CODENAMES[v] if v in CODENAMES else int(v)


def visible(tags, arch, api):
    """Whether a map.txt symbol or block with these tags is in the NDK for arch/api."""
    t = tags.split()
    if any(x in ("llndk", "apex", "systemapi", "platform-only") for x in t):
        return False
    arches = [x for x in t if x in ALL_ARCHES]
    if arches and arch not in arches:
        return False
    introduced = None
    for x in t:
        if x.startswith("introduced=") and introduced is None:
            introduced = level(x.split("=", 1)[1])
        if x.startswith(f"introduced-{arch}="):
            introduced = level(x.split("=", 1)[1])
    return introduced is None or introduced <= api


def parse_map(path, arch, api):
    """-> [(version, parent version, [(symbol, is_variable)])], NDK symbols only."""
    blocks, cur = [], None
    for raw in open(path):
        code, _, tags = raw.strip().partition("#")
        code = code.strip()
        if not code:
            continue
        if m := re.match(r"(\w+)\s*\{", code):
            skip = m.group(1).endswith(("_PRIVATE", "_PLATFORM")) or not visible(tags, arch, api)
            cur = {"name": m.group(1), "syms": [], "skip": skip}
        elif m := re.match(r"\}\s*(\w+)?\s*;", code):
            cur["parent"] = m.group(1)
            blocks.append(cur)
            cur = None
        elif cur and code not in ("global:", "local:", "*;") and not cur["skip"] and visible(tags, arch, api):
            cur["syms"].append((code.rstrip(";").strip(), "var" in tags.split()))
    kept = {b["name"] for b in blocks if not b["skip"]}
    parents = {b["name"]: b["parent"] for b in blocks}
    out = []
    for b in blocks:
        if b["skip"]:
            continue
        parent = b["parent"]
        while parent and parent not in kept:
            parent = parents.get(parent)
        out.append((b["name"], parent, b["syms"]))
    return out


def stub_lib(name, versions, zig_arch, out_dir, work):
    """lib<name>.so defining every symbol with its version (assembly, so no
    symbol clashes with compiler builtins)."""
    asm, script = [], []
    for version, parent, syms in versions:
        body = "".join(f"    {s};\n" for s, _ in syms)
        script.append(f"{version} {{\n  global:\n{body}}}{' ' + parent if parent else ''};")
        for s, is_var in syms:
            asm.append(f".data\n.globl {s}\n.type {s},@object\n.size {s},8\n{s}: .quad 0\n" if is_var
                       else f".text\n.globl {s}\n.type {s},@function\n{s}: ret\n")
    src, ver = os.path.join(work, f"{name}.S"), os.path.join(work, f"{name}.map")
    open(src, "w").write("".join(asm))
    open(ver, "w").write("\n".join(script) + "\n")
    subprocess.check_call(["zig", "cc", "-target", f"{zig_arch}-linux-none", "-shared", "-nostdlib", "-fPIC",
                           f"-Wl,--version-script={ver}", f"-Wl,-soname,lib{name}.so",
                           "-o", os.path.join(out_dir, f"lib{name}.so"), src])


def headers(bionic, inc):
    shutil.copytree(os.path.join(bionic, "libc/include"), inc, dirs_exist_ok=True)
    uapi = os.path.join(bionic, "libc/kernel/uapi")
    for d in os.listdir(uapi):
        if not d.startswith("asm-") or d == "asm-generic":
            shutil.copytree(os.path.join(uapi, d), os.path.join(inc, d), dirs_exist_ok=True)
    android_uapi = os.path.join(bionic, "libc/kernel/android/uapi")
    if os.path.isdir(android_uapi):
        for d in os.listdir(android_uapi):
            shutil.copytree(os.path.join(android_uapi, d), os.path.join(inc, d), dirs_exist_ok=True)
    for triple, asm_dir, _ in ARCHES.values():
        shutil.copytree(os.path.join(uapi, asm_dir, "asm"), os.path.join(inc, triple, "asm"), dirs_exist_ok=True)
    open(os.path.join(inc, "android/log.h"), "w").write(LOG_H)


def crt(bionic, inc, triple, zig_arch, api, out_dir, work):
    common = os.path.join(bionic, "libc/arch-common/bionic")
    zig_include = os.path.join(os.path.dirname(os.path.realpath(shutil.which("zig"))), "lib", "include")
    cc = ["zig", "cc", "-target", f"{zig_arch}-linux-none", "-c", "-fPIC", "-O2", "-nostdinc",
          "-D__ANDROID__", f"-D__ANDROID_API__={api}", f"-DPLATFORM_SDK_VERSION={api}", "-isystem", inc, "-isystem", os.path.join(inc, triple),
          "-isystem", zig_include, "-I", common, "-I", os.path.join(bionic, "libc")]
    subprocess.check_call(cc + ["-o", f"{work}/crtbegin_so_c.o", f"{common}/crtbegin_so.c"])
    subprocess.check_call(cc + ["-o", f"{work}/crtbrand.o", f"{common}/crtbrand.S"])
    subprocess.check_call(["zig", "cc", "-target", f"{zig_arch}-linux-none", "-r", "-nostdlib", "-o",
                           f"{out_dir}/crtbegin_so.o", f"{work}/crtbegin_so_c.o", f"{work}/crtbrand.o"])
    subprocess.check_call(cc + ["-o", f"{out_dir}/crtend_so.o", f"{common}/crtend_so.S"])


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("out", help="stand-in NDK root to create (use as $ANDROID_NDK_HOME)")
    p.add_argument("--api", type=int, default=29, help="API level (Oriel's minimum: 29)")
    p.add_argument("--bionic", help=f"bionic checkout (default: clone {BIONIC_URL} at {BIONIC_TAG})")
    args = p.parse_args()
    with tempfile.TemporaryDirectory() as tmp:
        bionic = args.bionic
        if not bionic:
            bionic = os.path.join(tmp, "bionic")
            subprocess.check_call(["git", "clone", "-q", "--depth", "1", "--branch", BIONIC_TAG, BIONIC_URL, bionic])
        sysroot = os.path.join(args.out, "toolchains/llvm/prebuilt/linux-x86_64/sysroot")
        inc = os.path.join(sysroot, "usr/include")
        headers(bionic, inc)
        for arch, (triple, _, zig_arch) in ARCHES.items():
            out_dir = os.path.join(sysroot, "usr/lib", triple, str(args.api))
            work = os.path.join(tmp, arch)
            os.makedirs(out_dir, exist_ok=True)
            os.makedirs(work, exist_ok=True)
            for name, path in (("c", "libc/libc.map.txt"), ("m", "libm/libm.map.txt"), ("dl", "libdl/libdl.map.txt")):
                stub_lib(name, parse_map(os.path.join(bionic, path), arch, args.api), zig_arch, out_dir, work)
            for name, syms in (("log", LOG), ("android", ANDROID), ("aaudio", AAUDIO)):
                stub_lib(name, [(f"LIB{name.upper()}", None, [(s, False) for s in syms])], zig_arch, out_dir, work)
            crt(bionic, inc, triple, zig_arch, args.api, out_dir, work)
            print(f"{out_dir}: {' '.join(sorted(os.listdir(out_dir)))}")
    glslc = shutil.which("glslc")
    if glslc:
        tools = os.path.join(args.out, "shader-tools/linux-x86_64")
        os.makedirs(tools, exist_ok=True)
        link = os.path.join(tools, "glslc")
        if os.path.lexists(link):
            os.remove(link)
        os.symlink(glslc, link)


main()
