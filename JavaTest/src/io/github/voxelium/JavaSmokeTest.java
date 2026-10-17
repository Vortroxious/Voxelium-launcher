package io.github.voxelium;

/**
 * Milestone 5 smoke test: proves a JVM started inside the iOS app can load
 * classes from the JDK module image, allocate, run long enough for the JIT
 * to compile hot code, and use threads. Prints a final marker line that the
 * app looks for.
 */
public final class JavaSmokeTest {
    public static void main(String[] args) throws Exception {
        String[] props = {"java.version", "java.vm.name", "java.vm.version", "java.home", "os.name", "os.arch"};
        for (String p : props) {
            System.out.println(p + "=" + System.getProperty(p));
        }
        Runtime rt = Runtime.getRuntime();
        System.out.println("availableProcessors=" + rt.availableProcessors() + " maxMemoryMB=" + (rt.maxMemory() >> 20));

        // A hot loop, run enough times that HotSpot compiles it.
        long t0 = System.nanoTime();
        long sum = 0;
        for (int round = 0; round < 50; round++) {
            sum += work(200_000);
        }
        long ms = (System.nanoTime() - t0) / 1_000_000;
        System.out.println("compute sum=" + sum + " timeMs=" + ms);

        // Threads and a little allocation.
        Thread t = new Thread(() -> {
            StringBuilder sb = new StringBuilder();
            for (int i = 0; i < 10_000; i++) sb.append(i % 10);
            System.out.println("thread ok length=" + sb.length());
        }, "zl-worker");
        t.start();
        t.join();

        System.out.println("VOXELIUM_JAVA_OK");
    }

    private static long work(int n) {
        long acc = 0;
        for (int i = 0; i < n; i++) {
            acc += (i * 31L) ^ (acc >>> 3);
        }
        return acc;
    }
}
