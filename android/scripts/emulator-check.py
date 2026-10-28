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
import shutil
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
            if "stop-case" in args and (b"Stop scenario dispatched" in result.stdout or result.returncode == 137):
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
        _probe["click"]("Dictation options")
        _probe["wait_for"]("Private session", 20)
        hierarchy = nodes()
        # Private session adds a row above Styles; Custom may be below the scroll viewport.
        if not any(n.get("text") == "Custom" for n in hierarchy):
            screenshot(output / ("emulator-cleanup-menu-before-scroll-" + theme + ".png"))
            (output / ("cleanup-menu-" + theme + ".xml")).write_bytes(adb("shell", "cat", "/sdcard/chirp-windows.xml"))
            popup = next(n for n in hierarchy if n.get("class") == "android.widget.ScrollView")
            x1, y1, x2, y2 = _probe["bounds"](popup)
            adb("shell", "input", "swipe", str((x1 + x2) // 2), str(y2 - 20), str((x1 + x2) // 2), str(y1 + 20), "300")
        _probe["wait_for"]("Custom", 20)
        assert any(n.get("text") == "Chat" for n in nodes()), "Health profiles missing"
        screenshot(output / ("emulator-cleanup-styles-" + theme + ".png"))
        adb("shell", "input", "keyevent", "4")
        focus_editor()
        x, y, _, _ = mic_position(night, work)
        before = editor().get("text", "")
        if before in ("Test dictation here", "Synthetic E2E editor"): before = ""
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
        # The editor and IME update in different processes. Await the restored text, not just
        # the button click; an empty native editor reports its hint through Accessibility.
        deadline = time.monotonic() + 10
        restored = ""
        while time.monotonic() < deadline:
            restored = read_editor()
            suffix = restored[len(before):]
            if len(restored) > len(before) and re.search(r"\bum\b", suffix, re.I) and re.search(r"\buh\b", suffix, re.I):
                break
            time.sleep(.1)
        else:
            raise AssertionError("One-tap raw undo did not restore fixture fillers")
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
            (output / "emulator-cleanup-gfxinfo.txt").write_text(SERIAL + " · debug synthetic cleanup, screen recording enabled\n" + "\n".join(metrics) + "\n")
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
    args.add_argument("--learn-check", action="store_true")
    args.add_argument("--notes-check", action="store_true")
    # Speaker labels alone (the notes check runs them too, at its end).
    args.add_argument("--speakers-check", action="store_true")
    args.add_argument("--keepkb-check", action="store_true")
    args.add_argument("--visual-check", action="store_true")
    args.add_argument("--bubble-check", action="store_true")
    args.add_argument("--quickdictate-check", action="store_true")
    args.add_argument("--serial")
    # CHIRP_E2E_PORT lets parallel runs on one host use different throwaway ports (never 7821).
    args.add_argument("--server-port", type=int, default=int(os.environ.get("CHIRP_E2E_PORT", "7899")))
    args.add_argument("--device-check", action="store_true")
    args.add_argument("--tls", action="store_true")
    args.add_argument("--expect-crash", action="store_true")
    args.add_argument("--server-root", type=Path, default=ROOT / "server")
    args.add_argument("--tls-dir", type=Path, default=ROOT / "android/app/build")
    opt = args.parse_args()
    assert os.environ.get("ANDROID_SERIAL", SERIAL) == SERIAL
    scheme = "https" if opt.tls else "http"
    assert 1024 <= opt.server_port <= 65535, "Use an unprivileged server port"
    assert opt.server_port != 7821, "7821 is the live server's port; use a throwaway one"
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
        # The throwaway server copies and verifies this pinned fixture only after the phone's
        # automatic POST. It never mutates the source model or touches the network.
        speaker_model = Path(os.environ.get("CHIRP_SPEAKER_MODEL") or Path.home() / "Library/Application Support/Chirp/models/speakers/voxceleb_resnet34_LM.onnx")
        speakers_model = None
        speaker_gate = work / "speaker-model-ready"
        if (opt.notes_check or opt.speakers_check) and speaker_model.is_file():
            def speakers_model():
                speaker_gate.touch()
        assert speakers_model or not opt.speakers_check, "--speakers-check needs the speaker model (CHIRP_SPEAKER_MODEL)"
        env = dict(os.environ, HOME=str(home), HF_HOME=os.environ.get("HF_HOME") or str(Path.home() / ".cache/huggingface"),
                   HF_HUB_OFFLINE="1", TRANSFORMERS_OFFLINE="1", PYTHONPATH=str(opt.server_root / "src"))
        if opt.tls: env["SSL_CERT_FILE"] = str(cert)
        command = [opt.python, "-m", "chirp_server", "--port", str(opt.server_port), "--model-dir", opt.model_dir]
        if opt.tls or opt.stop_check or opt.notes_check or opt.speakers_check:
            command = [opt.python, str(Path(__file__).with_name("emulator-stop-server.py")),
                       "--model-dir", opt.model_dir, "--metadata", str(work / "events.json"), "--server-port", str(opt.server_port)]
            if speakers_model: command += ["--speaker-model", str(speaker_model), "--speaker-model-gate", str(speaker_gate)]
            if opt.tls: command += ["--cert", str(cert), "--key", str(opt.tls_dir / "emulator-tls/key.pem")]
            command += ["--ready-delay", "2" if opt.stop_check else "0"]
        server_log = (work / "server.log").open("wb")
        server = subprocess.Popen(command, env=env, stdout=server_log, stderr=subprocess.STDOUT)
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
            # Plain HTTP can be probed without credentials. A TLS server closes plaintext
            # connections (nc can exit nonzero); verified pairing below checks its route and trust.
            if not opt.tls:
                probe = adb("shell", "sh", "-c", shlex.quote("printf 'GET /v1/health HTTP/1.0\\r\\nHost: 10.0.2.2\\r\\n\\r\\n' | toybox nc -w 3 10.0.2.2 " + str(opt.server_port)))
                assert b"200 OK" in probe, "Emulator cannot reach the throwaway HTTP server"
                print("Emulator route to throwaway server: True", flush=True)
            adb("install", "-r", str(Path(opt.apk).resolve()))
            if opt.keepkb_check or opt.bubble_check or opt.quickdictate_check:
                module = runpy.run_path(str(Path(__file__).with_name("emulator-keepkb-check.py")))
                url = scheme + "://10.0.2.2:" + str(opt.server_port)
                def stop_server():
                    server.terminate(); server.wait(timeout=10)
                probe_helpers = dict(_probe, adb=adb, stop_server=stop_server)
                with module["secure_settings"](probe_helpers):
                    if opt.keepkb_check:
                        module["check"](probe_helpers, work, output, url, token)
                    if opt.keepkb_check or opt.quickdictate_check:
                        entries = runpy.run_path(str(Path(__file__).with_name("emulator-quickdictate-check.py")))
                        entries["check"](probe_helpers, work, output, url, token)
                        if opt.keepkb_check:
                            # Each matrix owns its final offline case; reuse only the disposable server config.
                            server = subprocess.Popen(command, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                            wait_health(token, base=base, context=context)
                    if opt.bubble_check or opt.keepkb_check:
                        # #167: the floating mic bubble is the keep-keyboard path's primary surface, so --keepkb-check
                        # runs it after the onboarding checks; --bubble-check runs it alone.
                        bubble = runpy.run_path(str(Path(__file__).with_name("emulator-bubble-check.py")))
                        bubble["check"](probe_helpers, work, output, url, token, cleanup_warm=True, standalone=True)
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
            deadline = time.monotonic() + 60
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
            if opt.visual_check:
                runpy.run_path(str(Path(__file__).with_name("emulator-visual-check.py")))["check"](dict(_probe, adb=adb), work, output)
                return
            if opt.device_check:
                module = runpy.run_path(str(Path(__file__).with_name("emulator-device-check.py")))
                module["check"](dict(_probe, adb=adb), work, output)
                return
            if opt.stop_check:
                module = runpy.run_path(str(Path(__file__).with_name("emulator-stop-check.py")))
                module["check"](dict(_probe, adb=adb), work, opt.expect_crash)
                return
            if opt.speakers_check:
                module = runpy.run_path(str(Path(__file__).with_name("emulator-speakers-check.py")))
                module["check"](dict(_probe, adb=adb, speakers_model=speakers_model, server_home=home, server_log=work / "server.log"), work, output, standalone=True)
                return
            if opt.notes_check:
                module = runpy.run_path(str(Path(__file__).with_name("emulator-notes-check.py")))
                module["check"](dict(_probe, adb=adb, speakers_model=speakers_model, server_home=home, server_log=work / "server.log"), work, output)
                return
            if opt.learn_check:
                runpy.run_path(str(Path(__file__).with_name("emulator-learn-check.py")))["check"](dict(_probe, adb=adb), work, output)
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
                # The strip's ⋯ opens options without starting capture (#172: a hold on the mic is push-to-talk now).
                tap(*center(_probe["wait_for"]("Dictation options")))
                _probe["wait_for"]("Chirp settings")
                adb("shell", "input", "keyevent", "4")
                # Press-and-hold on the strip mic is the reachable push-to-talk gesture: partials while held, a final on release.
                before_hold = editor().get("text", "")
                adb("shell", "input", "swipe", str(x), str(y), str(x), str(y), "2500")
                time.sleep(3)
                held = editor().get("text", "")
                assert held and held != before_hold, "Hold on the strip mic did not dictate on release"
                screenshot(output / ("emulator-keyboard-hold-" + theme + ".png"))
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
            if opt.speakers_check:
                # Counts, fixed action/state codes and slot numbers only; never retain server content.
                try:
                    seen = json.loads((work / "notes.json").read_text())
                    allowed = ("finals", "labelled", "slots", "label_errors", "model", "model_actions", "model_state", "voice_actions", "voice_count", "voices_enabled", "matched", "voices", "voice_errors")
                    (output / "speaker-counts.json").write_text(json.dumps({k: seen[k] for k in allowed if k in seen}, indent=2))
                except (OSError, ValueError):
                    pass
            server.terminate()
            try:
                server.wait(timeout=10)
            except subprocess.TimeoutExpired:
                server.kill(); server.wait()
            server_log.close()
            # Cleanup must not replace the original error when the AVD itself has died.
            try:
                adb("shell", "am", "force-stop", PACKAGE)
                adb("shell", "run-as", PACKAGE, "rm", "-f", "shared_prefs/debug_capture.xml", "shared_prefs/chirp.xml")
                adb("shell", "rm", "-f", "/sdcard/chirp-windows.xml", "/data/local/tmp/chirp-ui-probe.jar")
            except RuntimeError:
                pass


if __name__ == "__main__":
    main()
