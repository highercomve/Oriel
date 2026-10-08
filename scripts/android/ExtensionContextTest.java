package dev.oriel;

import java.util.HashSet;

/** JVM regression check: independently developed extensions cannot collide. */
public final class ExtensionContextTest {
    public static void main(String[] args) {
        var codes = new HashSet<Integer>();
        for (int extension = 0; extension < 64; extension++) {
            var context = new OrielAndroidExtensionContext(extension);
            for (int local = 0; local < 256; local++) {
                int code = context.requestCode(local);
                if (code < 0 || code > 0xffff || (code >= 0x4f00 && code <= 0x4fff) || !codes.add(code)) {
                    throw new AssertionError("Request-code collision or reserved code");
                }
                if (code != context.requestCode(local)) throw new AssertionError("Unstable request code");
            }
            expectInvalid(() -> context.requestCode(-1));
            expectInvalid(() -> context.requestCode(256));
        }
        expectInvalid(() -> new OrielAndroidExtensionContext(-1));
        expectInvalid(() -> new OrielAndroidExtensionContext(64));
        System.out.println("ok: 64 independent extension namespaces, 16384 unique request codes");
    }

    private static void expectInvalid(Runnable operation) {
        try { operation.run(); }
        catch (IllegalArgumentException expected) { return; }
        throw new AssertionError("Invalid request namespace accepted");
    }
}
