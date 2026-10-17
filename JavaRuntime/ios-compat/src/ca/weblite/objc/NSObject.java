package ca.weblite.objc;

import com.sun.jna.Pointer;

/** Zalith iOS no-op stub; see {@link Client}. */
public class NSObject {
    public NSObject(Pointer peer) {}

    public NSObject(String className) {}

    public Object send(String selector, Object... args) {
        return null;
    }

    public Object sendRaw(String selector, Object... args) {
        return null;
    }
}
