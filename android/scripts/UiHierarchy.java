package dev.chirp.smoke;

import android.accessibilityservice.AccessibilityServiceInfo;
import android.app.UiAutomation;
import android.graphics.Rect;
import android.os.HandlerThread;
import android.util.Xml;
import android.view.accessibility.AccessibilityNodeInfo;
import android.view.accessibility.AccessibilityWindowInfo;
import java.io.FileOutputStream;
import org.xmlpull.v1.XmlSerializer;

/** Shell-only UiAutomator probe. No application permission or release code is added. */
public final class UiHierarchy {
    public static void main(String[] args) throws Exception {
        android.os.Looper.prepareMainLooper();
        HandlerThread thread = new HandlerThread("chirp-ui-probe");
        thread.start();
        UiAutomation automation = null;
        try {
            // These shell APIs are hidden in android.jar, just as in Android's uiautomator CLI.
            Object connection = Class.forName("android.app.UiAutomationConnection").getConstructor().newInstance();
            automation = (UiAutomation) UiAutomation.class.getConstructor(android.os.Looper.class,
                Class.forName("android.app.IUiAutomationConnection")).newInstance(thread.getLooper(), connection);
            UiAutomation.class.getMethod("connect", int.class).invoke(automation, 1); // preserve TalkBack
            AccessibilityServiceInfo info = automation.getServiceInfo();
            info.flags |= AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS | AccessibilityServiceInfo.FLAG_REPORT_VIEW_IDS;
            automation.setServiceInfo(info);
            if (args.length > 0 && (args[0].equals("dictation-cycle") || args[0].equals("click") || args[0].equals("click-if-present") || args[0].equals("long-click") || args[0].equals("tap") || args[0].equals("append-notes") || args[0].equals("click-and-await-action"))) {
                try { automation.waitForIdle(200, 2000); } catch (java.util.concurrent.TimeoutException ignored) { }
            }
            if (args.length == 2 && args[0].equals("shortcut-helper")) {
                Runtime.getRuntime().exec(new String[]{"input", "keycombination", "117", "76"}).waitFor();
                android.os.SystemClock.sleep(2500);
                // Hide Search's IME only when present; Back otherwise dismisses the helper.
                for (AccessibilityWindowInfo window : automation.getWindows()) {
                    if (window.getType() == AccessibilityWindowInfo.TYPE_INPUT_METHOD) {
                        Runtime.getRuntime().exec(new String[]{"input", "keyevent", "4"}).waitFor();
                        android.os.SystemClock.sleep(750);
                        break;
                    }
                }
                for (AccessibilityWindowInfo window : automation.getWindows()) {
                    AccessibilityNodeInfo target = find(window.getRoot(), "App shortcuts");
                    while (target != null && !target.isClickable()) target = target.getParent();
                    if (target != null) { target.performAction(AccessibilityNodeInfo.ACTION_CLICK); break; }
                }
                android.os.SystemClock.sleep(1500);
                for (AccessibilityWindowInfo window : automation.getWindows()) {
                    AccessibilityNodeInfo root = window.getRoot();
                    AccessibilityNodeInfo target = find(root, "Chirp");
                    if (target != null) {
                        while (target != null && !target.isClickable()) target = target.getParent();
                        if (target != null) target.performAction(AccessibilityNodeInfo.ACTION_CLICK);
                    }
                }
                android.os.SystemClock.sleep(1500);
                screenshot(automation, args[1]);
                if (!has(automation, "Chirp") || !has(automation, "New recording note"))
                    throw new IllegalStateException("Chirp's shortcut group was not visible; enable the AVD hardware keyboard");
                System.out.println("PASS: Chirp group and new-note shortcut in the system helper");
            }
            if (args.length == 5 && args[0].equals("dictation-cycle")) {
                dictationCycle(automation, args[1], Float.parseFloat(args[2]), Float.parseFloat(args[3]), args[4]);
                return;
            }
            if (args.length == 4 && args[0].equals("stop-case")) {
                // An uncaught exception ends app_process with SIGKILL, which the check takes for a teardown kill (#344): say why and exit 1.
                try { stopCase(automation, args[1], Float.parseFloat(args[2]), Float.parseFloat(args[3])); }
                catch (IllegalStateException e) { System.out.println("Stop scenario failed: " + e.getMessage()); System.out.flush(); System.exit(1); }
                return;
            }
            if (args.length == 3 && args[0].equals("await-click")) {
                // Keep one UiAutomation connection while a Compose popup settles. Reconnecting
                // for each hierarchy query can temporarily expose only the status-bar window.
                long deadline = android.os.SystemClock.uptimeMillis() + Long.parseLong(args[2]);
                while (android.os.SystemClock.uptimeMillis() < deadline) {
                    java.util.List<AccessibilityNodeInfo> roots = new java.util.ArrayList<>();
                    for (AccessibilityWindowInfo window : automation.getWindows()) {
                        AccessibilityNodeInfo root = window.getRoot();
                        if (root != null) roots.add(root);
                    }
                    AccessibilityNodeInfo active = automation.getRootInActiveWindow();
                    if (active != null) roots.add(active);
                    for (AccessibilityNodeInfo root : roots) {
                        AccessibilityNodeInfo target = find(root, args[1]);
                        while (target != null && !target.isClickable()) target = target.getParent();
                        if (target != null && target.performAction(AccessibilityNodeInfo.ACTION_CLICK)) {
                            System.out.println("CLICKED");
                            return;
                        }
                    }
                    android.os.SystemClock.sleep(100);
                }
                throw new IllegalStateException("Expected accessible action did not arrive");
            }
            if (args.length == 6 && args[0].equals("click-and-await-action")) {
                // Trigger and handle a short-lived notice without reconnecting UiAutomation between them.
                boolean triggered = false;
                for (AccessibilityWindowInfo window : automation.getWindows()) {
                    AccessibilityNodeInfo target = find(window.getRoot(), args[1]);
                    while (target != null && !target.isClickable()) target = target.getParent();
                    if (target != null && target.performAction(AccessibilityNodeInfo.ACTION_CLICK)) { triggered = true; break; }
                }
                if (!triggered) throw new IllegalStateException("Trigger action missing");
                long timeout = Long.parseLong(args[4]);
                if (!awaitAction(automation, false, args[2], timeout)) throw new IllegalStateException("Notice did not arrive");
                if (!args[5].equals("-")) screenshot(automation, args[5]);
                if (!awaitAction(automation, true, args[3], timeout)) throw new IllegalStateException("Notice action expired");
                return;
            }
            if (args.length == 4 && args[0].equals("await-action")) {
                awaitAction(automation, args[1].equals("click"), args[2], Long.parseLong(args[3]));
                return;
            }
            if (args.length == 3 && args[0].equals("tap")) {
                long now = android.os.SystemClock.uptimeMillis();
                float x = Float.parseFloat(args[1]), y = Float.parseFloat(args[2]);
                for (int action : new int[]{android.view.MotionEvent.ACTION_DOWN, android.view.MotionEvent.ACTION_UP}) {
                    android.view.MotionEvent event = android.view.MotionEvent.obtain(now, android.os.SystemClock.uptimeMillis(), action, x, y, 0);
                    event.setSource(android.view.InputDevice.SOURCE_TOUCHSCREEN);
                    automation.injectInputEvent(event, true);
                    event.recycle();
                }
            }
            if (args.length == 2 && (args[0].equals("click") || args[0].equals("click-if-present") || args[0].equals("long-click"))) {
                boolean found = false;
                for (AccessibilityWindowInfo window : automation.getWindows()) {
                    AccessibilityNodeInfo target = find(window.getRoot(), args[1]);
                    if (target != null) {
                        while (target != null && !(args[0].equals("long-click") ? target.isLongClickable() : target.isClickable())) target = target.getParent();
                        if (target == null) throw new IllegalStateException("Accessible action missing");
                        int action = args[0].equals("long-click") ? AccessibilityNodeInfo.ACTION_LONG_CLICK : AccessibilityNodeInfo.ACTION_CLICK;
                        if (!target.performAction(action)) throw new IllegalStateException("Accessibility action rejected");
                        found = true; break;
                    }
                }
                if (!found) {
                    if (args[0].equals("click-if-present")) { System.out.println("MISSING"); return; }
                    throw new IllegalStateException("Accessible target missing");
                }
            }
            if (args.length == 2 && args[0].equals("scroll-forward")) {
                for (AccessibilityWindowInfo window : automation.getWindows()) {
                    if (window.getType() != AccessibilityWindowInfo.TYPE_APPLICATION) continue;
                    AccessibilityNodeInfo target = scrollable(window.getRoot());
                    if (target != null && target.performAction(AccessibilityNodeInfo.ACTION_SCROLL_FORWARD)) return;
                }
                throw new IllegalStateException("Scrollable popup missing");
            }
            if (args.length == 3 && args[0].equals("custom-action")) {
                // Invokes a labelled custom accessibility action, as TalkBack's actions menu does.
                for (AccessibilityWindowInfo window : automation.getWindows()) {
                    AccessibilityNodeInfo target = find(window.getRoot(), args[1]);
                    if (target == null) continue;
                    for (AccessibilityNodeInfo.AccessibilityAction action : target.getActionList())
                        if (args[2].equals(String.valueOf(action.getLabel()))) {
                            if (!target.performAction(action.getId())) throw new IllegalStateException("Custom action rejected");
                            return;
                        }
                }
                throw new IllegalStateException("Custom action missing");
            }
            if (args.length == 1 && args[0].equals("append-notes")) {
                for (AccessibilityWindowInfo window : automation.getWindows()) {
                    AccessibilityNodeInfo target = find(window.getRoot(), "Notes (Markdown)");
                    while (target != null && !target.isEditable() && !"android.widget.EditText".contentEquals(target.getClassName())) {
                        AccessibilityNodeInfo editable = editable(target);
                        target = editable != null ? editable : target.getParent();
                    }
                    if (target == null) continue;
                    android.os.Bundle value = new android.os.Bundle();
                    value.putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE,
                        safe(target.getText()) + "\n- Review the budget with finance before the launch on Monday");
                    if (!target.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, value))
                        throw new IllegalStateException("Notes edit accessibility action rejected");
                    System.out.println("Synthetic notes edit applied");
                    return;
                }
                throw new IllegalStateException("Notes editor accessibility target missing");
            }
            if (args.length == 3 && (args[0].equals("watch") || args[0].equals("watch-undo"))) {
                long deadline = android.os.SystemClock.uptimeMillis() + 35000;
                boolean matched = false;
                java.util.List<AccessibilityNodeInfo> capturedRoots = new java.util.ArrayList<>();
                boolean listening = false, polished = false, cleaned = false, raw = false;
                AccessibilityNodeInfo trackedStatus = null;
                while (android.os.SystemClock.uptimeMillis() < deadline && !matched) {
                    if (trackedStatus != null && trackedStatus.refresh()) {
                        String state = safe(trackedStatus.getText());
                        listening |= state.equals("Listening…"); polished |= state.equals("Polishing…");
                        cleaned |= state.equals("Finished"); raw |= state.equals("Kept what was heard");
                        if (state.equals(args[1])) {
                            matched = true;
                            capturedRoots.clear();
                            for (AccessibilityWindowInfo window : automation.getWindows()) {
                                AccessibilityNodeInfo root = window.getRoot();
                                if (root != null) { root.refresh(); capturedRoots.add(root); }
                            }
                            break;
                        }
                    }
                    if (trackedStatus != null && args[1].equals("Polishing…")) {
                        android.os.SystemClock.sleep(16); continue;
                    }
                    capturedRoots.clear();
                    for (AccessibilityWindowInfo window : automation.getWindows()) {
                        AccessibilityNodeInfo root = window.getRoot();
                        if (root != null) { root.refresh(); capturedRoots.add(root); }
                        if (trackedStatus == null) {
                            trackedStatus = find(root, "Listening…");
                            if (trackedStatus == null) trackedStatus = find(root, "Finishing…");
                            if (trackedStatus == null) trackedStatus = find(root, "Connecting to your computer…");
                        }
                        listening |= find(root, "Listening…") != null;
                        polished |= find(root, "Polishing…") != null;
                        cleaned |= find(root, "Finished") != null;
                        raw |= find(root, "Kept what was heard") != null;
                        if (find(root, args[1]) != null) matched = true;
                    }
                    if (!matched) android.os.SystemClock.sleep(16);
                }
                if (!matched) {
                    System.out.println("State trace: listening=" + listening + " polishing=" + polished + " cleaned=" + cleaned + " kept_original=" + raw);
                    throw new IllegalStateException("Expected UI state did not arrive");
                }
                // Capture before hierarchy serialization can outlast a short transition.
                android.graphics.Bitmap capture = automation.takeScreenshot();
                if (capture == null) throw new IllegalStateException("State screenshot unavailable");
                try (FileOutputStream output = new FileOutputStream(args[2])) {
                    capture.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, output);
                } finally { capture.recycle(); }
                if (args[0].equals("watch-undo")) {
                    boolean undone = false;
                    for (AccessibilityWindowInfo window : automation.getWindows()) {
                        AccessibilityNodeInfo button = find(window.getRoot(), "Use raw");
                        if (button != null && button.isClickable()) {
                            undone = button.performAction(AccessibilityNodeInfo.ACTION_CLICK); break;
                        }
                    }
                    if (!undone) throw new IllegalStateException("Raw undo accessibility action unavailable");
                }
                return;
            }
            if (args.length == 0) {
                try { automation.waitForIdle(250, 4000); } catch (java.util.concurrent.TimeoutException ignored) { }
            }
            XmlSerializer xml = Xml.newSerializer();
            try (FileOutputStream output = new FileOutputStream("/sdcard/chirp-windows.xml")) {
                xml.setOutput(output, "UTF-8");
                xml.startDocument("UTF-8", true);
                xml.startTag(null, "hierarchy");
                for (AccessibilityWindowInfo window : automation.getWindows()) {
                    AccessibilityNodeInfo root = window.getRoot();
                    if (root != null) {
                        xml.startTag(null, "window");
                        xml.attribute(null, "type", String.valueOf(window.getType()));
                        dump(xml, root);
                        xml.endTag(null, "window");
                    }
                }
                xml.endTag(null, "hierarchy");
                xml.endDocument();
            }
        } finally {
            if (automation != null) UiAutomation.class.getMethod("disconnect").invoke(automation);
            thread.quitSafely();
        }
    }
    /**
     * Tight-polls (20 ms, no hierarchy dump) for a transient action such as "Use raw", whose window is only 5 s, and
     * clicks it the moment it is visible ("click") or only reports it ("observe"). Prints PRESENT/CLICKED/EXPIRED followed by
     * fillers_before=true|false: whether the app's editor held a spoken filler (um/uh) at that instant. A boolean only, never text.
     */
    private static boolean awaitAction(UiAutomation automation, boolean click, String label, long timeoutMs) {
        long deadline = android.os.SystemClock.uptimeMillis() + timeoutMs;
        while (android.os.SystemClock.uptimeMillis() < deadline) {
            for (AccessibilityWindowInfo window : automation.getWindows()) {
                AccessibilityNodeInfo root = window.getRoot();
                if (root == null) continue;
                for (AccessibilityNodeInfo node : root.findAccessibilityNodeInfosByText(label)) {
                    if (!node.isVisibleToUser() || !(safe(node.getText()).equals(label) || safe(node.getContentDescription()).startsWith(label))) continue;
                    String state = " fillers_before=" + hasFillers(automation);
                    if (!click) { System.out.println("PRESENT" + state); return true; }
                    AccessibilityNodeInfo target = node;
                    while (target != null && !target.isClickable()) target = target.getParent();
                    if (target == null || !target.performAction(AccessibilityNodeInfo.ACTION_CLICK)) throw new IllegalStateException("Accessibility action rejected");
                    System.out.println("CLICKED" + state);
                    return true;
                }
            }
            android.os.SystemClock.sleep(20);
        }
        System.out.println("EXPIRED fillers_before=" + hasFillers(automation));
        return false;
    }
    private static boolean hasFillers(UiAutomation automation) {
        return java.util.regex.Pattern.compile("(?i)\\b(um|uh)\\b").matcher(appEditorText(automation)).find();
    }
    private static String appEditorText(UiAutomation automation) {
        for (AccessibilityWindowInfo window : automation.getWindows()) {
            AccessibilityNodeInfo field = appEditor(window.getRoot());
            if (field != null) return safe(field.getText());
        }
        return "";
    }
    private static AccessibilityNodeInfo appEditor(AccessibilityNodeInfo node) {
        if (node == null) return null;
        if ("android.widget.EditText".contentEquals(node.getClassName()) && "dev.chirp.android".contentEquals(safe(node.getPackageName()))) return node;
        for (int i = 0; i < node.getChildCount(); i++) {
            AccessibilityNodeInfo result = appEditor(node.getChild(i));
            if (result != null) return result;
        }
        return null;
    }
    private static AccessibilityNodeInfo editable(AccessibilityNodeInfo node) {
        if (node == null) return null;
        if (node.isEditable() || "android.widget.EditText".contentEquals(node.getClassName())) return node;
        for (int i = 0; i < node.getChildCount(); i++) {
            AccessibilityNodeInfo result = editable(node.getChild(i));
            if (result != null) return result;
        }
        return null;
    }
    private static AccessibilityNodeInfo find(AccessibilityNodeInfo node, String label) {
        if (node == null || !node.isVisibleToUser()) return null;
        if (java.util.Arrays.asList(safe(node.getText()).split("\n")).contains(label) || safe(node.getContentDescription()).startsWith(label)) return node;
        for (int i = 0; i < node.getChildCount(); i++) {
            AccessibilityNodeInfo found = find(node.getChild(i), label);
            if (found != null) return found;
        }
        return null;
    }
    private static void dump(XmlSerializer xml, AccessibilityNodeInfo node) throws Exception {
        if (!node.isVisibleToUser()) return;
        Rect bounds = new Rect();
        node.getBoundsInScreen(bounds);
        xml.startTag(null, "node");
        xml.attribute(null, "text", safe(node.getText()));
        xml.attribute(null, "content-desc", safe(node.getContentDescription()));
        xml.attribute(null, "package", safe(node.getPackageName()));
        xml.attribute(null, "class", safe(node.getClassName()));
        xml.attribute(null, "resource-id", safe(node.getViewIdResourceName()));
        xml.attribute(null, "bounds", bounds.toShortString());
        xml.attribute(null, "long-clickable", String.valueOf(node.isLongClickable()));
        xml.attribute(null, "clickable", String.valueOf(node.isClickable()));
        xml.attribute(null, "checkable", String.valueOf(node.isCheckable()));
        xml.attribute(null, "checked", String.valueOf(node.isChecked()));
        xml.attribute(null, "selected", String.valueOf(node.isSelected()));
        xml.attribute(null, "enabled", String.valueOf(node.isEnabled()));
        // Caret position and custom action labels (the floating mic's TalkBack actions); never text.
        xml.attribute(null, "selection", node.getTextSelectionStart() + "," + node.getTextSelectionEnd());
        StringBuilder custom = new StringBuilder();
        for (AccessibilityNodeInfo.AccessibilityAction action : node.getActionList())
            if (action.getLabel() != null && action.getId() > 0x01ffffff) custom.append(custom.length() == 0 ? "" : "|").append(action.getLabel());
        xml.attribute(null, "actions", custom.toString());
        for (int i = 0; i < node.getChildCount(); i++) {
            AccessibilityNodeInfo child = node.getChild(i);
            if (child != null) dump(xml, child);
        }
        xml.endTag(null, "node");
    }
    private static String safe(CharSequence value) { return value == null ? "" : value.toString(); }

    private static void tap(UiAutomation automation, float x, float y) {
        long now = android.os.SystemClock.uptimeMillis();
        for (int action : new int[]{0, 1}) {
            android.view.MotionEvent event = android.view.MotionEvent.obtain(now, android.os.SystemClock.uptimeMillis(), action, x, y, 0);
            event.setSource(android.view.InputDevice.SOURCE_TOUCHSCREEN);
            automation.injectInputEvent(event, true); event.recycle();
        }
    }
    private static boolean has(UiAutomation automation, String label) {
        // Ask the framework for matching text instead of materializing every virtual
        // key at 10 Hz. Full-tree traversal can exhaust the shell JVM on API 37.
        for (AccessibilityWindowInfo window : automation.getWindows()) {
            AccessibilityNodeInfo root = window.getRoot();
            if (root == null) continue;
            for (AccessibilityNodeInfo node : root.findAccessibilityNodeInfosByText(label)) {
                if (node.isVisibleToUser() && (safe(node.getText()).equals(label)
                        || safe(node.getContentDescription()).startsWith(label))) return true;
            }
        }
        return false;
    }
    private static void await(UiAutomation automation, String label) {
        long deadline = android.os.SystemClock.uptimeMillis() + 35000;
        while (android.os.SystemClock.uptimeMillis() < deadline) {
            // Retire stale virtual-key trees between observations and bound traversal pressure.
            automation.clearCache();
            if (has(automation, label)) return;
            android.os.SystemClock.sleep(100);
        }
        throw new IllegalStateException("Stop scenario state missing: " + label);
    }
    private static String editorText(UiAutomation automation) {
        for (AccessibilityWindowInfo window : automation.getWindows()) {
            AccessibilityNodeInfo field = editable(window.getRoot());
            if (field != null) return safe(field.getText());
        }
        throw new IllegalStateException("Editor accessibility root unavailable");
    }
    private static void screenshot(UiAutomation automation, String path) throws Exception {
        android.graphics.Bitmap capture = automation.takeScreenshot();
        if (capture == null) throw new IllegalStateException("Screenshot unavailable");
        try (FileOutputStream output = new FileOutputStream(path)) {
            capture.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, output);
        } finally { capture.recycle(); }
    }
    private static AccessibilityNodeInfo scrollable(AccessibilityNodeInfo node) {
        if (node == null) return null;
        if (node.isScrollable()) return node;
        for (int i = 0; i < node.getChildCount(); i++) {
            AccessibilityNodeInfo found = scrollable(node.getChild(i));
            if (found != null) return found;
        }
        return null;
    }
    private static void dictationCycle(UiAutomation automation, String mode, float x, float y, String path) throws Exception {
        String before = editorText(automation);
        long down = android.os.SystemClock.uptimeMillis();
        boolean hold = mode.equals("hold");
        if (hold) {
            android.view.MotionEvent event = android.view.MotionEvent.obtain(down, down, 0, x, y, 0);
            event.setSource(android.view.InputDevice.SOURCE_TOUCHSCREEN);
            automation.injectInputEvent(event, true); event.recycle();
        } else tap(automation, x, y);
        try {
            await(automation, "Listening…");
            // This connection watches the actual transient state, rather than
            // starting another shell JVM after a short utterance has finished.
            screenshot(automation, path);
            long deadline = android.os.SystemClock.uptimeMillis() + 12000;
            boolean partial = false;
            while (android.os.SystemClock.uptimeMillis() < deadline && has(automation, "Listening…")) {
                if (!editorText(automation).equals(before)) { partial = true; break; }
                android.os.SystemClock.sleep(100);
            }
            if (!partial) throw new IllegalStateException("No composing partial while listening");
            if (has(automation, "Listening…")) screenshot(automation, path);
            if (!hold) tap(automation, x, y);
        } finally {
            if (hold) {
                android.view.MotionEvent event = android.view.MotionEvent.obtain(down, android.os.SystemClock.uptimeMillis(), 1, x, y, 0);
                event.setSource(android.view.InputDevice.SOURCE_TOUCHSCREEN);
                automation.injectInputEvent(event, true); event.recycle();
            }
        }
        await(automation, "Use raw");
        if (editorText(automation).equals(before)) throw new IllegalStateException("No final committed");
        System.out.println("PASS: " + mode + " composing partial, stop, cleaned final");
    }
    private static void stopCase(UiAutomation automation, String mode, float x, float y) {
        AccessibilityNodeInfo status = null;
        tap(automation, x, y);
        if (mode.equals("immediate")) {
            // Stop while still connecting. The synthetic input holds its first frame for 4 s, so nothing has been sent yet.
            long deadline = android.os.SystemClock.uptimeMillis() + 1500;
            while (!has(automation, "Connecting to your computer…")) {
                if (android.os.SystemClock.uptimeMillis() > deadline) throw new IllegalStateException("Immediate stop was not before Ready");
                android.os.SystemClock.sleep(10);
            }
        } else {
            await(automation, "Listening…");
            if (mode.equals("polishing")) {
                for (AccessibilityWindowInfo window : automation.getWindows()) {
                    status = find(window.getRoot(), "Listening…");
                    if (status != null) break;
                }
            }
            // Pacing synthetic input; partial observation is checked independently on the server.
            android.os.SystemClock.sleep(mode.equals("listening") ? 100 : 2700);
        }
        tap(automation, x, y);
        if (mode.equals("immediate")) await(automation, "Didn't catch that");
        if (mode.equals("double")) { tap(automation, x, y); tap(automation, x, y); }
        if (mode.equals("polishing")) {
            long deadline = android.os.SystemClock.uptimeMillis() + 35000;
            boolean seen = false;
            while (android.os.SystemClock.uptimeMillis() < deadline) {
                if (status != null && status.refresh() && safe(status.getText()).equals("Polishing…")) { seen = true; break; }
                android.os.SystemClock.sleep(16);
            }
            if (!seen) throw new IllegalStateException("Polishing stop state missing");
            tap(automation, x, y);
        }
        if (mode.equals("hide") || mode.equals("focus") || mode.equals("unbind")) {
            int code = mode.equals("hide") ? android.view.KeyEvent.KEYCODE_BACK : android.view.KeyEvent.KEYCODE_HOME;
            for (int action : new int[]{0, 1}) automation.injectInputEvent(new android.view.KeyEvent(action, code), true);
        }
        System.out.println("Stop scenario dispatched: " + mode);
    }
}
