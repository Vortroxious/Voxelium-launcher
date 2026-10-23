package ca.weblite.objc;

/** Voxelium no-op stub; see {@link Client}. */
public class Proxy {
    public Object send(String selector, Object... args) {
        return null;
    }

    // Minecraft 26.3's MacosUtil.disableCloseWindowMenuItem walks NSApp's window
    // menu: sendProxy("windowsMenu"), sendInt("numberOfItems"), then per item
    // sendRaw("action"). An empty menu (0 items) makes it do nothing.
    public Proxy sendProxy(String selector, Object... args) {
        return new Proxy();
    }

    public int sendInt(String selector, Object... args) {
        return 0;
    }

    public Object sendRaw(String selector, Object... args) {
        return null;
    }
}
