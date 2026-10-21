package io.github.voxelium.boot;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.net.URL;
import java.net.URLClassLoader;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.jar.JarFile;

/**
 * Entry point for Forge and NeoForge versions on iOS.
 *
 * Their installers have Java "processors" (binary patcher, remapper, …) that must
 * run once before the first launch. iOS allows one JVM per app launch, so instead of
 * a separate installer JVM they run here, in the game's JVM, each in its own class
 * loader; then the real main class starts as usual. The plan file is written by
 * VoxeliumCore's ForgeInstaller:
 *
 *   processor <name>      start of a processor
 *   jar <path>            its jar (Main-Class is read from the manifest)
 *   cp <path>             a classpath entry (repeatable)
 *   arg <value>           an argument (repeatable, in order)
 *   out <path> <sha1>     an output to check afterwards (sha1 may be "-")
 *   end
 *
 * System properties: voxelium.processors (plan path), voxelium.mainClass (game main).
 * A "<plan>.done" file is written once every processor succeeded.
 */
public final class Boot {
    private Boot() {}

    static final class Processor {
        String name;
        String jar;
        final List<String> classpath = new ArrayList<String>();
        final List<String> args = new ArrayList<String>();
        final Map<String, String> outputs = new LinkedHashMap<String, String>();
    }

    public static void main(String[] args) throws Throwable {
        String plan = System.getProperty("voxelium.processors");
        String mainClass = System.getProperty("voxelium.mainClass");
        if (mainClass == null || mainClass.isEmpty()) {
            throw new IllegalStateException("voxelium.mainClass is not set");
        }
        if (plan != null && !plan.isEmpty()) {
            File done = new File(plan + ".done");
            if (!done.exists()) {
                runProcessors(new File(plan));
                OutputStream o = new FileOutputStream(done);
                o.write("ok\n".getBytes("UTF-8"));
                o.close();
                // The processors' classes and buffers are garbage now; give the heap back
                // before the game starts (iOS counts every resident page against the app).
                System.gc();
            }
        }
        Class<?> cls = Class.forName(mainClass, true, ClassLoader.getSystemClassLoader());
        Method m = cls.getMethod("main", String[].class);
        log("starting " + mainClass);
        try {
            m.invoke(null, (Object) args);
        } catch (InvocationTargetException e) {
            throw e.getCause();
        }
    }

    static List<Processor> read(File plan) throws Exception {
        List<Processor> list = new ArrayList<Processor>();
        BufferedReader r = new BufferedReader(new InputStreamReader(new FileInputStream(plan), "UTF-8"));
        try {
            Processor cur = null;
            String line;
            while ((line = r.readLine()) != null) {
                if (line.isEmpty()) continue;
                int sp = line.indexOf(' ');
                String key = sp < 0 ? line : line.substring(0, sp);
                String value = sp < 0 ? "" : line.substring(sp + 1);
                if (key.equals("processor")) {
                    cur = new Processor();
                    cur.name = value;
                } else if (cur == null) {
                    throw new IllegalArgumentException("plan: '" + key + "' outside a processor");
                } else if (key.equals("jar")) {
                    cur.jar = value;
                } else if (key.equals("cp")) {
                    cur.classpath.add(value);
                } else if (key.equals("arg")) {
                    cur.args.add(value);
                } else if (key.equals("out")) {
                    int s = value.lastIndexOf(' ');
                    cur.outputs.put(value.substring(0, s), value.substring(s + 1));
                } else if (key.equals("end")) {
                    list.add(cur);
                    cur = null;
                } else {
                    throw new IllegalArgumentException("plan: unknown key '" + key + "'");
                }
            }
        } finally {
            r.close();
        }
        return list;
    }

    static void runProcessors(File plan) throws Exception {
        List<Processor> list = read(plan);
        long all = System.currentTimeMillis();
        log("setting up the mod loader: " + list.size() + " steps (first launch only)");
        for (int i = 0; i < list.size(); i++) {
            Processor p = list.get(i);
            if (!p.outputs.isEmpty() && outputsValid(p)) {
                log("step " + (i + 1) + "/" + list.size() + " " + p.name + ": already done");
                continue;
            }
            long start = System.currentTimeMillis();
            log("step " + (i + 1) + "/" + list.size() + " " + p.name);
            run(p);
            for (Map.Entry<String, String> out : p.outputs.entrySet()) {
                File f = new File(out.getKey());
                if (!f.isFile()) throw new IllegalStateException(p.name + " did not write " + f);
                if (!out.getValue().equals("-")) {
                    String sha1 = sha1(f);
                    if (!sha1.equalsIgnoreCase(out.getValue())) {
                        f.delete();
                        throw new IllegalStateException(p.name + " wrote " + f + " with SHA-1 " + sha1 + ", expected " + out.getValue());
                    }
                }
            }
            log("step " + (i + 1) + " done in " + (System.currentTimeMillis() - start) + " ms");
        }
        log("mod loader set up in " + (System.currentTimeMillis() - all) + " ms");
    }

    static boolean outputsValid(Processor p) throws Exception {
        for (Map.Entry<String, String> out : p.outputs.entrySet()) {
            File f = new File(out.getKey());
            if (!f.isFile()) return false;
            if (!out.getValue().equals("-") && !sha1(f).equalsIgnoreCase(out.getValue())) return false;
        }
        return true;
    }

    static void run(Processor p) throws Exception {
        String main;
        JarFile jar = new JarFile(p.jar);
        try {
            main = jar.getManifest() == null ? null : jar.getManifest().getMainAttributes().getValue("Main-Class");
        } finally {
            jar.close();
        }
        if (main == null) throw new IllegalStateException(p.jar + " has no Main-Class");

        URL[] urls = new URL[p.classpath.size() + 1];
        urls[0] = new File(p.jar).toURI().toURL();
        for (int i = 0; i < p.classpath.size(); i++) urls[i + 1] = new File(p.classpath.get(i)).toURI().toURL();
        // Parent: the platform (Java 9+) or extension (Java 8) loader, so the tool sees
        // only the JDK and its own jars, not the game's classpath.
        ClassLoader parent = ClassLoader.getSystemClassLoader().getParent();
        URLClassLoader loader = new URLClassLoader(urls, parent);
        Thread t = Thread.currentThread();
        ClassLoader previous = t.getContextClassLoader();
        t.setContextClassLoader(loader);
        try {
            Method m = Class.forName(main, true, loader).getMethod("main", String[].class);
            m.invoke(null, (Object) p.args.toArray(new String[0]));
        } catch (InvocationTargetException e) {
            Throwable cause = e.getCause();
            if (cause instanceof Exception) throw (Exception) cause;
            if (cause instanceof Error) throw (Error) cause;
            throw e;
        } finally {
            t.setContextClassLoader(previous);
            try { loader.close(); } catch (Exception ignored) {}
        }
    }

    static String sha1(File f) throws Exception {
        MessageDigest md = MessageDigest.getInstance("SHA-1");
        InputStream in = new FileInputStream(f);
        try {
            byte[] buf = new byte[1 << 16];
            int n;
            while ((n = in.read(buf)) > 0) md.update(buf, 0, n);
        } finally {
            in.close();
        }
        StringBuilder sb = new StringBuilder();
        for (byte b : md.digest()) sb.append(String.format("%02x", b));
        return sb.toString();
    }

    static void log(String s) {
        System.out.println("[Voxelium] " + s);
        System.out.flush();
    }
}
