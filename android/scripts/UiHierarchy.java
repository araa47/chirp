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
            if (args.length > 0 && (args[0].equals("dictation-cycle") || args[0].equals("click") || args[0].equals("long-click") || args[0].equals("tap") || args[0].equals("append-notes"))) {
                try { automation.waitForIdle(200, 2000); } catch (java.util.concurrent.TimeoutException ignored) { }
            }
            if (args.length == 5 && args[0].equals("dictation-cycle")) {
                dictationCycle(automation, args[1], Float.parseFloat(args[2]), Float.parseFloat(args[3]), args[4]);
                return;
            }
            if (args.length == 4 && args[0].equals("stop-case")) {
                stopCase(automation, args[1], Float.parseFloat(args[2]), Float.parseFloat(args[3]));
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
            if (args.length == 2 && (args[0].equals("click") || args[0].equals("long-click"))) {
                boolean found = false;
                for (AccessibilityWindowInfo window : automation.getWindows()) {
                    AccessibilityNodeInfo target = find(window.getRoot(), args[1]);
                    if (target != null) {
                        while (target != null && !(args[0].equals("click") ? target.isClickable() : target.isLongClickable())) target = target.getParent();
                        if (target == null) throw new IllegalStateException("Accessible action missing");
                        int action = args[0].equals("click") ? AccessibilityNodeInfo.ACTION_CLICK : AccessibilityNodeInfo.ACTION_LONG_CLICK;
                        if (!target.performAction(action)) throw new IllegalStateException("Accessibility action rejected");
                        found = true; break;
                    }
                }
                if (!found) throw new IllegalStateException("Accessible target missing");
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
                        cleaned |= state.equals("cleaned"); raw |= state.equals("kept original");
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
                            if (trackedStatus == null) trackedStatus = find(root, "Connecting to Mac…");
                        }
                        listening |= find(root, "Listening…") != null;
                        polished |= find(root, "Polishing…") != null;
                        cleaned |= find(root, "cleaned") != null;
                        raw |= find(root, "kept original") != null;
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
                    if (root != null) dump(xml, root);
                }
                xml.endTag(null, "hierarchy");
                xml.endDocument();
            }
        } finally {
            if (automation != null) UiAutomation.class.getMethod("disconnect").invoke(automation);
            thread.quitSafely();
        }
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
        for (AccessibilityWindowInfo window : automation.getWindows())
            if (find(window.getRoot(), label) != null) return true;
        return false;
    }
    private static void await(UiAutomation automation, String label) {
        long deadline = android.os.SystemClock.uptimeMillis() + 35000;
        while (android.os.SystemClock.uptimeMillis() < deadline) {
            if (has(automation, label)) return;
            android.os.SystemClock.sleep(16);
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
            android.os.SystemClock.sleep(10);
            if (!has(automation, "Connecting to Mac…"))
                throw new IllegalStateException("Immediate stop was not before Ready");
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
