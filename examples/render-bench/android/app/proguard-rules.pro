# R8 rules for release builds (isMinifyEnabled in build.gradle.kts).
#
# liboriel.so calls the Kotlin runtime by name over JNI (FindClass
# "dev/oriel/OrielRuntime", GetStaticMethodID, ...), which R8 can't see:
# keep the runtime's classes and members with their names.
-keep class dev.oriel.** { *; }

# Add your own rules below, e.g. for classes your Zig code reaches over JNI.
