package dev.oriel;

import java.util.HashSet;

/** JVM regression check: independently developed hooks cannot collide. */
public final class HooksContextTest {
    public static void main(String[] args) {
        var codes = new HashSet<Integer>();
        for (int hook = 0; hook < 64; hook++) {
            var context = new OrielAndroidHooksContext(hook);
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
        expectInvalid(() -> new OrielAndroidHooksContext(-1));
        expectInvalid(() -> new OrielAndroidHooksContext(64));
        System.out.println("ok: 64 independent hook namespaces, 16384 unique request codes");
    }

    private static void expectInvalid(Runnable operation) {
        try { operation.run(); }
        catch (IllegalArgumentException expected) { return; }
        throw new AssertionError("Invalid request namespace accepted");
    }
}
