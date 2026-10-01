#!/usr/bin/env bash
# Compile the Kotlin runtime (android/template) against the Android
# framework, without the Android SDK: Robolectric's android-all jar (Maven
# Central) plus stubs of the few androidx.webkit signatures it uses. Checks
# that the template's XML parses, then the JNI contract between Zig and
# Kotlin:
#   - every `runtime.call(..., "name", "signature", ...)` in src/ matches a
#     static method of dev.oriel.OrielRuntime;
#   - every `NativeLib` and `NuiNative` (-Dnative_ui) native has a Zig export
#     and vice versa.
# Needs a JDK (17+) and Maven. Usage: scripts/android/check-runtime.sh
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
# The template's XML must parse: AGP's manifest merger and aapt2 reject
# anything expat does (e.g. "--" inside a comment).
python3 - "$root" <<'PY'
import glob, sys, xml.dom.minidom
for f in glob.glob(sys.argv[1] + "/android/template/**/*.xml", recursive=True):
    try:
        xml.dom.minidom.parse(f)
    except Exception as e:
        sys.exit(f"{f}: {e}")
PY
work=${ORIEL_ANDROID_CHECK_DIR:-$root/.zig-cache/android-runtime-check}
mkdir -p "$work"
cd "$work"
cat > pom.xml <<'POM'
<project xmlns="http://maven.apache.org/POM/4.0.0"><modelVersion>4.0.0</modelVersion>
<groupId>dev.oriel</groupId><artifactId>runtime-check</artifactId><version>1</version>
<dependencies>
<dependency><groupId>org.jetbrains.kotlin</groupId><artifactId>kotlin-compiler-embeddable</artifactId><version>2.0.21</version></dependency>
<dependency><groupId>org.robolectric</groupId><artifactId>android-all</artifactId><version>14-robolectric-10818077</version></dependency>
</dependencies></project>
POM
[ -d lib ] || mvn -q dependency:copy-dependencies -DoutputDirectory=lib
android=$(ls lib/android-all-*.jar)
rm -rf stubs out
mkdir -p stubs out
javac -nowarn -d stubs -cp "$android" $(find "$root/scripts/android/androidx-stubs" -name '*.java')
cp=$(ls lib/*.jar | grep -v android-all | tr '\n' ':')
java -cp "$cp" org.jetbrains.kotlin.cli.jvm.K2JVMCompiler -no-stdlib -Werror=false \
  -classpath "$android:stubs:$(ls lib/kotlin-stdlib-*.jar)" -jvm-target 17 -d out \
  "$root"/android/template/app/src/main/java/dev/oriel/*.kt
javap -s -p -cp out dev.oriel.OrielRuntime > runtime.txt
javap -s -p -cp out dev.oriel.NativeLib > natives.txt
javap -s -p -cp out dev.oriel.NuiNative > nui-natives.txt
python3 - "$root" <<'PY'
import glob, re, sys
root = sys.argv[1]
calls = set()
exports = {"NativeLib": set(), "NuiNative": set()}
for f in glob.glob(root + "/src/**/*.zig", recursive=True):
    s = open(f).read()
    for m in re.finditer(r'runtime\.call(?:With)?\([^,]*?\.(?:void|boolean|int|long|object),\s*"(\w+)",\s*"([^"]+)"', s):
        calls.add((m.group(1), m.group(2), f[len(root) + 1:]))
    for cls, names in exports.items():
        names |= set(re.findall(r'"Java_dev_oriel_' + cls + r'_(\w+)"', s))
    prefix = re.search(r'const prefix = "Java_dev_oriel_(\w+?)_"', s)
    if prefix:
        exports.setdefault(prefix.group(1), set()).update(re.findall(r'prefix \+\+ "(\w+)"', s))
lines = open("runtime.txt").read().split("\n")
methods = set()
for i, l in enumerate(lines):
    m = re.search(r"public static .*? (\w+)\(", l)
    if m and i + 1 < len(lines) and "descriptor:" in lines[i + 1]:
        methods.add((m.group(1), lines[i + 1].split("descriptor:")[1].strip()))
natives = {
    "NativeLib": set(re.findall(r"native \S+ (\w+)\(", open("natives.txt").read())),
    "NuiNative": set(re.findall(r"native \S+ (\w+)\(", open("nui-natives.txt").read())),
}
bad = [c for c in calls if (c[0], c[1]) not in methods]
for name, sig, where in bad:
    print(f"{where}: OrielRuntime.{name}{sig} does not exist in the Kotlin runtime")
mismatch = False
for cls in sorted(set(natives) | set(exports)):
    have, want = natives.get(cls, set()), exports.get(cls, set())
    for n in sorted(have - want):
        print(f"{cls}.{n} has no Zig export")
    for n in sorted(want - have):
        print(f"Zig exports {cls}.{n}, which Kotlin doesn't declare")
    mismatch |= have != want
if bad or mismatch:
    sys.exit(1)
print(f"ok: {len(calls)} calls into Kotlin, {sum(len(v) for v in natives.values())} natives")
PY
