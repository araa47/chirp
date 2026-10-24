#!/usr/bin/env python3
"""Explicitly opt-in emulator E2E; no phone, real microphone, production server or user speech.
Run with the Android toolchain sourced and the built debug APK. Requires Pillow and the
existing server venv/model paths passed on the command line. All runtime secrets/audio stay
outside git; only screenshots and a content-free result are retained.
"""
import argparse
import runpy
import json
import os
from pathlib import Path
import re
import socket
import ssl
import shlex
import subprocess
import tempfile
import time
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

from emulator_serial import emulator_serial

SERIAL = emulator_serial()

PACKAGE = "dev.chirp.android"
IME = PACKAGE + "/.ChirpImeService"
ROOT = Path(__file__).resolve().parents[2]


def adb(*args, capture=True, data=None):
    # Never fall back to adb's default device, regardless of caller environment.
    # The stop-case probe prints only a scenario name or an assertion message: safe to show.
    show_stderr = any(action in args for action in ("stop-case", "dictation-cycle", "click", "append-notes")) or args[0] == "install"
    result = subprocess.run(["adb", "-s", SERIAL, *args], input=data, check=False,
                            stdout=subprocess.PIPE if capture else subprocess.DEVNULL,
                            stderr=subprocess.PIPE if show_stderr else subprocess.DEVNULL)
    if result.returncode:
        if show_stderr:
            print("ADB diagnostic:", (result.stdout + result.stderr).decode(errors="replace")[-600:], flush=True)
            # On a contended host the shell can SIGKILL the probe during teardown, after the scenario
            # was already dispatched; the server-side assertions that follow still judge the outcome.
            # exit 137 = SIGKILL (key-injecting cases tear the probe's own process down); the
            # stop-check then requires the server to have seen STOP, so an early kill cannot pass.
            if b"Stop scenario dispatched" in result.stdout or result.returncode == 137:
                return result.stdout
        if result.stdout and b"State trace:" in result.stdout:
            print(next(line.decode() for line in result.stdout.splitlines() if b"State trace:" in line), flush=True)
        raise RuntimeError("ADB action failed (arguments redacted): " + args[0])
    return result.stdout


# Stock uiautomator dump omits the IME window on API 37. Share the shell-only
# all-window probe with release smoke; this never ships in either APK.
_probe = runpy.run_path(str(Path(__file__).with_name("emulator-smoke.py")))
nodes = _probe["nodes"]


def center(node):
    x1, y1, x2, y2 = map(int, re.findall(r"\d+", node.attrib["bounds"]))
    return (x1 + x2) // 2, (y1 + y2) // 2


def tap(x, y):
    adb("shell", "input", "tap", str(x), str(y))


def click(label):
    # Cold start of the pairing screen takes 10+ s on a contended host: wait first, scroll later.
    started = time.monotonic()
    while time.monotonic() - started < 60:
        matches = [n for n in nodes() if n.get("text") == label and center(n) != (0, 0)]
        if matches:
            tap(*center(matches[-1])); time.sleep(.5); return
        if time.monotonic() - started > 20:
            adb("shell", "input", "swipe", "1100", "1800", "1100", "900", "300")
    raise RuntimeError("UI action missing: " + label)


def editor():
    # A Compose/IME resize can briefly expose no editor accessibility root.
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        node = next((n for n in nodes() if n.get("class") == "android.widget.EditText"), None)
        if node is not None:
            return node
    screenshot(Path("/tmp/chirp-e2e-editor-missing.png"))
    raise RuntimeError("Test editor did not return after IME transition")


def focus_editor():
    if os.environ.get("CHIRP_E2E_NATIVE_EDITOR") == "1":
        focus = adb("shell", "dumpsys", "window").decode(errors="replace")
        if "E2eEditorActivity" not in focus:
            _probe["fresh_editor"]()
        else:
            _probe["focus_editor"]()
        return
    if _probe["find"]("Finish") is not None:
        _probe["click"]("Finish")
        _probe["wait_for"]("Dictate")
    if _probe["find"]("Dictate") is not None:
        _probe["click"]("Dictate")
        _probe["wait_for_editor"]()
    _probe["focus_editor"]()


def screenshot(path):
    data = adb("exec-out", "screencap", "-p")
    path.write_bytes(data[data.index(b"\x89PNG"):])


def mic_position(night, work):
    node = next((n for n in nodes() if n.get("content-desc", "").startswith("Microphone: tap to dictate,") and n.get("class") == "android.widget.Button" and center(n) != (0, 0)), None)
    if node is None:
        raise RuntimeError("Accessible Chirp mic is missing")
    x, y = center(node)
    width, height = _probe["size"]()
    return x, y, width, height


def wait_health(token, timeout=150, base="http://127.0.0.1:7899", context=None):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            req = urllib.request.Request(base + "/v1/health", headers={"Authorization": "Bearer " + token})
            with urllib.request.urlopen(req, timeout=2, context=context) as response:
                if json.load(response).get("ready"):
                    return
        except Exception:
            pass
        time.sleep(1)
    raise RuntimeError("Throwaway model server did not become ready")


def cleanup_check(output, work):
    # Snapshot without UiAutomation's idle wait so a short cleanup state cannot be skipped.
    def fast_nodes():
        adb("shell", "CLASSPATH=/data/local/tmp/chirp-ui-probe.jar", "app_process", "/", "dev.chirp.smoke.UiHierarchy", "snapshot-now")
        return list(ET.fromstring(adb("shell", "cat", "/sdcard/chirp-windows.xml")).iter("node"))
    def read_editor():
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            node = next((n for n in fast_nodes() if n.get("class") == "android.widget.EditText"), None)
            if node is not None: return node.get("text", "")
        raise AssertionError("Editor accessibility root did not return")
    normal_nodes = _probe["wait_for"].__globals__["nodes"]
    # Real managed cleanup, full synthetic utterances, and native one-tap raw replacement.
    for night in (False, True):
        theme = "dark" if night else "light"
        adb("shell", "cmd", "uimode", "night", "yes" if night else "no")
        focus_editor()
        x, y, _, _ = mic_position(night, work)
        adb("shell", "input", "swipe", str(x), str(y), str(x), str(y), "700")
        _probe["wait_for"]("Custom", 20)
        hierarchy = nodes()
        assert any(n.get("text") == "Custom" for n in hierarchy), "Custom style missing"
        assert any(n.get("text") == "Chat" for n in hierarchy), "Health profiles missing"
        screenshot(output / ("emulator-cleanup-styles-" + theme + ".png"))
        adb("shell", "input", "keyevent", "4")
        focus_editor()
        x, y, _, _ = mic_position(night, work)
        before = editor().get("text", "")
        if before == "Test dictation here": before = ""
        _probe["wait_for"].__globals__["nodes"] = fast_nodes
        recording = None
        if not night:
            adb("shell", "dumpsys", "gfxinfo", PACKAGE, "reset")
            recording = subprocess.Popen(["adb", "-s", SERIAL, "shell", "screenrecord", "--time-limit", "10", "--bit-rate", "1500000", "--size", "770x800", "/sdcard/chirp-cleanup.mp4"],
                                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        tap(x, y)
        # A device-side watcher observes transient states in one accessibility connection;
        # launching a new app_process for each poll can miss a warm helper's short turnaround.
        try:
            adb("shell", "CLASSPATH=/data/local/tmp/chirp-ui-probe.jar", "app_process", "/", "dev.chirp.smoke.UiHierarchy", "watch", "Polishing…", "/sdcard/chirp-polishing.png")
        except RuntimeError:
            screenshot(Path("/tmp/chirp-cleanup-state.png"))
            raise
        adb("pull", "/sdcard/chirp-polishing.png", str(output / ("emulator-cleanup-polishing-" + theme + ".png")))
        adb("shell", "CLASSPATH=/data/local/tmp/chirp-ui-probe.jar", "app_process", "/", "dev.chirp.smoke.UiHierarchy", "watch-undo", shlex.quote("Use raw"), "/sdcard/chirp-cleaned.png")
        adb("pull", "/sdcard/chirp-cleaned.png", str(output / ("emulator-cleanup-cleaned-" + theme + ".png")))
        restored = read_editor()
        # Accessibility can cache an earlier partial on the editor while the IME already
        # exposes polishing. Exact raw replacement is covered with real InputConnections;
        # here verify the native action restored the fixture fillers removed by cleanup.
        assert len(restored) > len(before) and re.search(r"\bum\b", restored[len(before):], re.I) and re.search(r"\buh\b", restored[len(before):], re.I), "One-tap raw undo did not restore fixture fillers"
        assert adb("shell", "settings", "get", "secure", "default_input_method").decode().strip() == IME
        if recording is not None:
            recording.wait(timeout=15)
            adb("pull", "/sdcard/chirp-cleanup.mp4", str(output / "emulator-cleanup-streaming.mp4"))
            # screenrecord can flush one frame beyond --time-limit on a slow emulator.
            # Bound the deliverable strictly below ten seconds; no audio is recorded.
            shortened = work / "streaming-short.mp4"
            subprocess.run(["ffmpeg", "-v", "error", "-i", str(output / "emulator-cleanup-streaming.mp4"),
                            "-t", "9.5", "-an", "-c:v", "libx264", "-fps_mode", "vfr", "-y", str(shortened)],
                           check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            (output / "emulator-cleanup-streaming.mp4").write_bytes(shortened.read_bytes())
            gfx = adb("shell", "dumpsys", "gfxinfo", PACKAGE).decode(errors="replace")
            metrics = [line.strip() for line in gfx.splitlines() if re.match(r"\s*(Total frames rendered:|Janky frames:|50th percentile:|90th percentile:|95th percentile:|99th percentile:)", line)]
            assert any(line.startswith("Total frames rendered:") and int(line.split(":")[1]) > 0 for line in metrics), "No frame metrics recorded"
            (output / "emulator-cleanup-gfxinfo.txt").write_text("emulator-5580 · debug synthetic cleanup, screen recording enabled\n" + "\n".join(metrics) + "\n")
            print("Frame metrics:", "; ".join(metrics), flush=True)
        _probe["wait_for"].__globals__["nodes"] = normal_nodes
        adb("shell", "input", "keyevent", "4")
    print("PASS: managed offline cleanup; health styles + Custom; raw composing during polishing; cleaned + one-tap raw undo; light/dark screenshots; IME retained.")


def cleanup_frames(output, work):
    import wave
    focus_editor()
    x, y, _, _ = mic_position(False, work)
    with wave.open(str(ROOT / "android/app/build/generated/chirp-debug-assets/synthetic.wav")) as wav:
        duration = wav.getnframes() / wav.getframerate()
    adb("shell", "dumpsys", "gfxinfo", PACKAGE, "reset")
    tap(x, y)
    # Test pacing only: leave rendering alone during the known synthetic fixture.
    time.sleep(duration + 3)
    gfx = adb("shell", "dumpsys", "gfxinfo", PACKAGE).decode(errors="replace")
    metrics = [line.strip() for line in gfx.splitlines() if re.match(r"\s*(Total frames rendered:|Janky frames:|50th percentile:|90th percentile:|95th percentile:|99th percentile:)", line)]
    assert any(line.startswith("Total frames rendered:") and int(line.split(":")[1]) > 0 for line in metrics), "No frame metrics recorded"
    text = editor().get("text", "")
    assert text and not re.search(r"\b(?:um|uh)\b", text, re.I), "Managed cleanup did not remove fixture fillers"
    (output / "emulator-cleanup-uninstrumented-gfxinfo.txt").write_text("emulator-5580 · debug synthetic cleanup, no recording or accessibility polling during speech\n" + "\n".join(metrics) + "\n")
    print("Uninstrumented cleanup:", "; ".join(metrics), flush=True)


def warm_cleanup(python, token_path, env, tls=False, port=7899):
    # Warm the throwaway helper, including first-use Metal compilation in its empty HOME.
    # The subprocess uses the server venv's websocket package; it prints metadata only.
    code = r'''import asyncio, json, sys, wave, ssl
from pathlib import Path
import websockets
async def warm():
    token = Path(sys.argv[1]).read_text().strip()
    with wave.open(sys.argv[2]) as wav: pcm = wav.readframes(wav.getnframes())
    options = {"ssl": ssl.create_default_context()} if sys.argv[3] == "tls" else {}
    url = ("wss" if options else "ws") + "://127.0.0.1:" + sys.argv[4] + "/v1/stream"
    async with websockets.connect(url, additional_headers={"Authorization":"Bearer " + token}, **options) as ws:
        await ws.send(json.dumps({"type":"start","sample_rate":16000,"encoding":"pcm_s16le","client":"android","correction":True}))
        assert json.loads(await ws.recv())["type"] == "ready"
        for start in range(0,len(pcm),3200): await ws.send(pcm[start:start+3200])
        await ws.send('{"type":"stop"}')
        while True:
            event=json.loads(await asyncio.wait_for(ws.recv(),90))
            if event["type"] == "final":
                assert event["corrected"], "Managed warmup did not clean synthetic fixture"
                print(json.dumps({"corrected":event["corrected"]}), flush=True)
                return
asyncio.run(warm())'''
    result = subprocess.run([python, "-c", code, str(token_path), str(ROOT / "android/app/build/generated/chirp-debug-assets/synthetic.wav"), "tls" if tls else "http", str(port)],
                   env=env, check=True, timeout=120, stdout=subprocess.PIPE)
    warm = json.loads(result.stdout)
    print("Managed warmup: corrected=" + str(warm["corrected"]), flush=True)


def main():
    args = argparse.ArgumentParser()
    args.add_argument("--python", required=True)
    args.add_argument("--model-dir", required=True)
    args.add_argument("--apk", required=True)
    args.add_argument("--cleanup-only", action="store_true")
    args.add_argument("--frames-only", action="store_true")
    args.add_argument("--stop-check", action="store_true")
    args.add_argument("--history-check", action="store_true")
    args.add_argument("--notes-check", action="store_true")
    args.add_argument("--keepkb-check", action="store_true")
    args.add_argument("--serial")
    args.add_argument("--server-port", type=int, default=7899)
    args.add_argument("--device-check", action="store_true")
    args.add_argument("--tls", action="store_true")
    args.add_argument("--expect-crash", action="store_true")
    args.add_argument("--server-root", type=Path, default=ROOT / "server")
    args.add_argument("--tls-dir", type=Path, default=ROOT / "android/app/build")
    opt = args.parse_args()
    assert os.environ.get("ANDROID_SERIAL", SERIAL) == SERIAL
    scheme = "https" if opt.tls else "http"
    assert 1024 <= opt.server_port <= 65535, "Use an unprivileged server port"
    base = scheme + "://127.0.0.1:" + str(opt.server_port)
    cert = opt.tls_dir / "generated/chirp-debug-res/raw/emulator_ca.pem"
    context = ssl.create_default_context(cafile=str(cert)) if opt.tls else None
    assert adb("get-serialno").strip().decode() == SERIAL
    subprocess.run([str(Path(__file__).with_name("build-ui-probe.sh"))], check=True)
    # Refuse to disturb any service already using this test port.
    with socket.socket() as probe:
        probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        probe.bind(("127.0.0.1", opt.server_port))
    output = Path(os.environ.get("CHIRP_E2E_OUTPUT", ROOT / "docs/screenshots/android"))
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="chirp-emulator-") as name:
        work = Path(name)
        home = work / "home"
        home.mkdir()
        config = home / ".config/chirp/server.toml"
        config.parent.mkdir(parents=True)
        config.write_text('[correction]\nmode = "managed"\ntimeout = 60.0\n')
        env = dict(os.environ, HOME=str(home), HF_HOME=str(Path.home() / ".cache/huggingface"),
                   HF_HUB_OFFLINE="1", TRANSFORMERS_OFFLINE="1", PYTHONPATH=str(opt.server_root / "src"))
        if opt.tls: env["SSL_CERT_FILE"] = str(cert)
        command = [opt.python, "-m", "chirp_server", "--port", str(opt.server_port), "--model-dir", opt.model_dir]
        if opt.tls or opt.stop_check or opt.notes_check:
            command = [opt.python, str(Path(__file__).with_name("emulator-stop-server.py")),
                       "--model-dir", opt.model_dir, "--metadata", str(work / "events.json"), "--server-port", str(opt.server_port)]
            if opt.tls: command += ["--cert", str(cert), "--key", str(opt.tls_dir / "emulator-tls/key.pem")]
            command += ["--ready-delay", "2" if opt.stop_check else "0"]
        server = subprocess.Popen(command,
                                  env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        safe_capture = False
        try:
            token_path = home / ".config/chirp/token"
            for _ in range(100):
                if token_path.exists():
                    break
                if server.poll() is not None:
                    raise RuntimeError("Throwaway server exited before initialization")
                time.sleep(.1)
            token = token_path.read_text().strip()
            wait_health(token, base=base, context=context)
            warm_cleanup(opt.python, token_path, env, opt.tls, opt.server_port)
            # Independent host-routing probe, no authentication or private response content.
            probe = adb("shell", "sh", "-c", shlex.quote("printf 'GET /v1/health HTTP/1.0\\r\\nHost: 10.0.2.2\\r\\n\\r\\n' | toybox nc -w 3 10.0.2.2 " + str(opt.server_port)))
            print("Emulator route to throwaway server:", opt.tls or b"200 OK" in probe, flush=True)
            adb("install", "-r", str(Path(opt.apk).resolve()))
            if opt.keepkb_check:
                module = runpy.run_path(str(Path(__file__).with_name("emulator-keepkb-check.py")))
                module["check"](dict(_probe, adb=adb), work, output, scheme + "://10.0.2.2:" + str(opt.server_port), token)
                return
            if opt.device_check:
                runpy.run_path(str(Path(__file__).with_name("emulator-device-check.py")))["onboarding"](dict(_probe, adb=adb))
            adb("shell", "am", "force-stop", PACKAGE)
            if opt.stop_check:
                adb("shell", "run-as", PACKAGE, "rm", "-f", "shared_prefs/crash_diagnostics.xml")
            adb("shell", "run-as", PACKAGE, "mkdir", "-p", "shared_prefs")
            adb("shell", "run-as", PACKAGE, "sh", "-c", shlex.quote("cat > shared_prefs/debug_capture.xml"),
                data=b'<?xml version="1.0" encoding="utf-8"?><map><boolean name="synthetic" value="true" /></map>')
            adb("shell", "pm", "grant", PACKAGE, "android.permission.RECORD_AUDIO")
            adb("shell", "pm", "grant", PACKAGE, "android.permission.POST_NOTIFICATIONS")
            adb("shell", "pm", "grant", PACKAGE, "android.permission.ACCESS_LOCAL_NETWORK")
            adb("shell", "ime", "enable", IME)
            adb("shell", "ime", "set", IME)
            adb("shell", "settings", "put", "secure", "show_ime_with_hard_keyboard", "1")
            adb("logcat", "-b", "crash", "-c")
            # adb prints the intent URI, so output is deliberately never forwarded to logs.
            link = "chirp://pair?" + urllib.parse.urlencode({"url": scheme + "://10.0.2.2:" + str(opt.server_port), "token": token})
            adb("shell", "am", "start", "-a", "android.intent.action.VIEW", "-d", shlex.quote(link))
            # The link is tested and saved on arrival. The pairing UI holds the throwaway credential; never retain a capture here.
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline:
                if any(n.get("text", "").startswith(("Connected", "Paired")) for n in nodes()):
                    break
                time.sleep(.3)
            else:
                statuses = [n.get("text", "") for n in nodes() if n.get("text", "").startswith(("Mac ", "Couldn", "Invalid Chirp", "Connecting", "Connected", "Paired", "Checking Mac"))]
                # Pairing screens contain credentials: never capture them.
                print("Pairing status:", statuses, flush=True)
                diagnostic = adb("shell", "run-as", PACKAGE, "cat", "shared_prefs/debug_capture.xml")
                for item in ET.fromstring(diagnostic):
                    if item.get("name") in ("failure_class", "cleartext_allowed"):
                        print(item.get("name"), item.text or item.get("value"), flush=True)
                raise RuntimeError("Emulator did not save pairing")
            if _probe["find"]("Finish") is not None:
                _probe["click"]("Finish")
            adb("shell", "am", "force-stop", PACKAGE)
            adb("shell", "ime", "enable", IME)
            adb("shell", "ime", "set", IME)
            adb("shell", "am", "start", "-n", PACKAGE + "/.SetupActivity", "--es", "section", "try")
            _probe["wait_for"]("Dictate", 60)
            safe_capture = True
            if opt.device_check:
                module = runpy.run_path(str(Path(__file__).with_name("emulator-device-check.py")))
                module["check"](dict(_probe, adb=adb), work, output)
                return
            if opt.stop_check:
                module = runpy.run_path(str(Path(__file__).with_name("emulator-stop-check.py")))
                module["check"](dict(_probe, adb=adb), work, opt.expect_crash)
                return
            if opt.notes_check:
                module = runpy.run_path(str(Path(__file__).with_name("emulator-notes-check.py")))
                module["check"](dict(_probe, adb=adb), work, output)
                return
            if opt.history_check:
                module = runpy.run_path(str(Path(__file__).with_name("emulator-history-check.py")))
                module["check"](dict(_probe, adb=adb), work, output)
                return
            if opt.frames_only:
                cleanup_frames(output, work)
                return
            if opt.cleanup_only:
                cleanup_check(output, work)
                return
            if os.environ.get("CHIRP_E2E_NATIVE_EDITOR") == "1":
                runpy.run_path(str(Path(__file__).with_name("emulator-dictation-check.py")))["check"](dict(_probe, adb=adb), work, output)
                return
            focus_editor()
            for night in (False, True):
                theme = "dark" if night else "light"
                adb("shell", "cmd", "uimode", "night", "yes" if night else "no")
                time.sleep(1)
                focus_editor()
                x, y, width, height = mic_position(night, work)
                # The strip must live in the keyboard's lower frame, leaving the editor visible.
                assert y > height // 3, "Keyboard unexpectedly fills the screen"
                screenshot(output / ("emulator-keyboard-idle-" + theme + ".png"))
                before = editor().get("text", "")
                tap(x, y)
                time.sleep(2.5)
                live = editor().get("text", "")
                screenshot(Path("/tmp/chirp-listening-check.png"))
                if live == before:
                    diagnostic = adb("shell", "run-as", PACKAGE, "cat", "shared_prefs/debug_capture.xml")
                    for item in ET.fromstring(diagnostic):
                        if item.get("name") in ("touch", "start", "synthetic"):
                            print(item.get("name"), item.text or item.get("value"), flush=True)
                    raise RuntimeError("No live composing partial reached the editor")
                screenshot(output / ("emulator-keyboard-listening-" + theme + ".png"))
                # Tap toggles stop. Wait for final; only synthetic content is inspected in memory.
                tap(x, y)
                time.sleep(3)
                final = editor().get("text", "")
                assert final and final != before, "Final was not committed"
                screenshot(output / ("emulator-keyboard-final-" + theme + ".png"))
                assert adb("shell", "settings", "get", "secure", "default_input_method").decode().strip() == IME
                # Repeat immediately: the original reported first-use behavior must not recur.
                before_repeat = editor().get("text", "")
                boundary = before_repeat + ("" if not before_repeat or before_repeat[-1].isspace() else " ")
                tap(x, y); time.sleep(2.5)
                repeat_live = editor().get("text", "")
                assert repeat_live.startswith(boundary) and len(repeat_live) > len(boundary), "Repeat partial lacks a word separator"
                assert not repeat_live[len(boundary)].isspace(), "Repeat partial doubled the separator"
                tap(x, y); time.sleep(2)
                repeat_final = editor().get("text", "")
                assert repeat_final.startswith(boundary) and len(repeat_final) > len(boundary), "Repeat final lacks a word separator"
                assert not repeat_final[len(boundary)].isspace(), "Repeat final doubled the separator"
                screenshot(output / ("emulator-keyboard-final-" + theme + ".png"))
                assert adb("shell", "settings", "get", "secure", "default_input_method").decode().strip() == IME
                # Tap the actual QWERTY 'a' key after dictation to verify HeliBoard's
                # composing/cache handoff, rather than injecting text via adb input text.
                before_type = editor().get("text", "")
                tap(round(width * .10), round(height * .72))
                typed = editor().get("text", "")
                assert typed in (before_type + "a", before_type + "A"), "Typing after dictation failed"
                # Toolbar long-press opens options without starting capture; voice-key
                # push-to-talk remains covered by the real host touch regression tests.
                adb("shell", "input", "swipe", str(x), str(y), str(x), str(y), "700")
                _probe["wait_for"]("Chirp settings")
                adb("shell", "input", "keyevent", "4")
                before_cancel = editor().get("text", "")
                tap(x, y); time.sleep(.5); tap(width - x, y); time.sleep(.5)
                assert editor().get("text", "") == before_cancel, "Cancel changed committed text"
                adb("shell", "input", "keyevent", "4")
                time.sleep(.5)
                crash = adb("logcat", "-b", "crash", "-d").decode(errors="replace")
                assert "Process: dev.chirp.android" not in crash and ">>> dev.chirp.android <<<" not in crash, "Chirp crash recorded"

            print("PASS: real Parakeet server; Keystore pairing; composing partials/finals; two utterances with smart spacing; tap/options/cancel/hide; typing after dictation; keyboard settings/setup/diagnostics; light/dark screenshots; IME retained; no Chirp crash.")
        except Exception:
            if safe_capture:
                try:
                    screenshot(output / "failure.png")
                    nodes()
                    (output / "failure.xml").write_bytes(adb("shell", "cat", "/sdcard/chirp-windows.xml"))
                except Exception:
                    pass
            raise
        finally:
            server.terminate()
            try:
                server.wait(timeout=10)
            except subprocess.TimeoutExpired:
                server.kill(); server.wait()
            # Cleanup must not replace the original error when the AVD itself has died.
            try:
                adb("shell", "am", "force-stop", PACKAGE)
                adb("shell", "run-as", PACKAGE, "rm", "-f", "shared_prefs/debug_capture.xml", "shared_prefs/chirp.xml")
                adb("shell", "rm", "-f", "/sdcard/chirp-windows.xml", "/data/local/tmp/chirp-ui-probe.jar")
            except RuntimeError:
                pass


if __name__ == "__main__":
    main()
