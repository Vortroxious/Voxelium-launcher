package ca.weblite.objc;

/**
 * Voxelium compatibility stub, written from scratch (not the java-objc-bridge
 * library). Minecraft treats iOS as macOS (os.name is "Mac OS X") and its
 * MacosUtil / text2speech NarratorMac message AppKit through this API, which
 * does not exist on iOS. Every message is a no-op returning null.
 */
public class Client {
    private static final Client INSTANCE = new Client();

    public static Client getInstance() {
        return INSTANCE;
    }

    public Proxy sendProxy(String className, String selector, Object... args) {
        return new Proxy();
    }
}
