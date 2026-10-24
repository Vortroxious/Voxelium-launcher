package io.github.voxelium;

import java.lang.classfile.*;
import java.lang.reflect.AccessFlag;
import java.nio.file.*;
import java.util.*;
import java.util.zip.*;

/**
 * Lists every {@code native} method in the given jars whose JNI symbol ({@code Java_...}, short or
 * long form) is not in the symbol file: one exported symbol name per line, without the leading
 * underscore. Prints "MISSING <class>.<method><descriptor>" per method, then a count.
 *
 *   java JniSurfaceCheck.java symbols.txt lwjgl.jar lwjgl-opengl.jar ...
 */
public final class JniSurfaceCheck {

    public static void main(String[] args) throws Exception {
        Set<String> symbols = new HashSet<>(Files.readAllLines(Path.of(args[0])));
        int natives = 0;
        List<String> missing = new ArrayList<>();
        for (int i = 1; i < args.length; i++) {
            try (ZipFile jar = new ZipFile(args[i])) {
                for (ZipEntry e : Collections.list(jar.entries())) {
                    // Multi-release classes override base ones; their natives are the same or absent.
                    if (!e.getName().endsWith(".class") || e.getName().startsWith("META-INF/")) continue;
                    ClassModel cm = ClassFile.of().parse(jar.getInputStream(e).readAllBytes());
                    String cls = cm.thisClass().asInternalName();
                    for (MethodModel m : cm.methods()) {
                        if (!m.flags().has(AccessFlag.NATIVE)) continue;
                        natives++;
                        String name = m.methodName().stringValue(), desc = m.methodType().stringValue();
                        String shortName = "Java_" + mangle(cls) + "_" + mangle(name);
                        String longName = shortName + "__" + mangle(desc.substring(1, desc.indexOf(')')));
                        if (!symbols.contains(shortName) && !symbols.contains(longName)) {
                            missing.add(cls.replace('/', '.') + "." + name + desc);
                        }
                    }
                }
            }
        }
        Collections.sort(missing);
        missing.forEach(m -> System.out.println("MISSING " + m));
        System.out.println(natives + " native methods, " + missing.size() + " without a symbol");
    }

    /** JNI name mangling (JNI specification, "Resolving Native Method Names"). */
    private static String mangle(String s) {
        StringBuilder b = new StringBuilder();
        for (char c : s.toCharArray()) {
            switch (c) {
                case '/' -> b.append('_');
                case '_' -> b.append("_1");
                case ';' -> b.append("_2");
                case '[' -> b.append("_3");
                default -> {
                    if (c < 128 && Character.isLetterOrDigit(c)) b.append(c);
                    else b.append(String.format("_0%04x", (int)c));
                }
            }
        }
        return b.toString();
    }
}
