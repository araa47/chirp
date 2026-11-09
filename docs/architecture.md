# Chirp architecture (v1)

Status: agreed direction for the v1 build. Every performance number below is either a measured result or marked **TBM** (to be measured by the milestone that owns it). We do not claim budgets we have not measured.

## 1. Shape

```
 ┌──────────── Your computer (e.g. Mac) ────────────────────────┐
 │                                                              │
 │  ChirpMac.app (Swift, menu bar)   chirp-server (Python, uv)  │
 │  hotkey → mic → WS ───────────►  127.0.0.1:7821             │
 │  HUD shows partials  ◄───────────  partial / final           │
 │  insert: AX → ⌘V paste → copy      ├─ engine thread (MLX)    │
 │                                    ├─ optional correction ───┼──► OpenAI-compatible LLM
 │                                    └─ debug retention (opt-in)│    (local LM Studio or remote,
 │                                                              │     off by default, final only)
 │  tailscale serve  https://<computer>.<tailnet>.ts.net/chirp ─┤
 └──────────────────────────────▲───────────────────────────────┘
                                │ wss over the tailnet (WireGuard)
 ┌─────────────── Galaxy Z Fold 8 ──────┴────────────────────────┐
 │  Chirp IME (Kotlin InputMethodService)                        │
 │  mic key → AudioRecord 16 kHz → WS → partial = composing text │
 │  final → commitText; then back to the previous keyboard       │
 └───────────────────────────────────────────────────────────────┘
```

There is one Chirp server (`chirp-server`), running on your own computer, which can be a Mac, a Windows PC or a Linux box. The diagram shows a Mac running the Mac app beside it, and a phone as a thin client; the Windows/Linux desktop app and the iPhone and iPad app are further clients of the same server. All recognition and correction run on that computer. A phone only captures audio, streams it and inserts text.

## 2. Reuse decisions (and why)

Koi already ships a proven, privacy-reviewed local dictation stack on this exact machine. Its source is the installed `koi` package (`site-packages/koi/voice/*`, `ui/routes_voice.py`, `tailscale*.py`) and its voice docs. Chirp adapts its patterns and code rather than importing Koi as a dependency, because Koi is a large orchestration app.

| Concern | Options considered | Decision | Evidence / rationale |
|---|---|---|---|
| ASR engine | parakeet-mlx (MLX/GPU), onnx-asr Parakeet int8 (CPU), FluidAudio (Swift CoreML/ANE Parakeet), WhisperKit / whisper.cpp, Apple SpeechAnalyzer | **parakeet-mlx 0.5.x, Parakeet TDT 0.6B v2 (English) as the default**, behind an `Engine` interface. onnx-asr is the fallback. FluidAudio and SpeechAnalyzer are bench candidates in M1. | Koi runs parakeet-mlx 0.5.2 / mlx 0.32.3 on this machine today, and its weights are cached at `~/.koi/voice-models/parakeet-mlx` (2.3 GB). Parakeet TDT v2 has a leading English WER on the Open ASR leaderboard, and v3 trades English accuracy for multilingual support. M1 must publish `docs/bench.md` with RTFx, first-partial latency, final latency after stop and memory for each engine on this Mac, using the same WAV set. The default flips only if a candidate wins by measurement. |
| Streaming | Re-decode the growing buffer (Koi's interim uploads), parakeet-mlx `transcribe_stream` (incremental, cached context), a VAD-chunk + stitch approach (Koi `voice/stitch.py`) | **WebSocket PCM streaming. M1 measurements select rolling MLX windows with timestamped token merging; the upstream streaming context remains an explicit benchmark option.** The default final is a full-utterance decode (≤ 30 s) or overlapping stitched chunks. Optional `--finalization segments` freezes full-decoded segments at pauses of at least 400 ms and decodes only the remaining tail; it remains opt-in after a short-utterance latency regression. The default `stable` prefix is deliberately empty because the final can revise any word. See `docs/bench.md` for WER parity, latency and contention caveats. | This gives the Koi experience (live text while speaking) without re-uploading audio. M1 measures both strategies and records the decision in `bench.md`. |
| Server language/framework | Python + Starlette/uvicorn, Swift (Vapor/Hummingbird + FluidAudio), Rust | **Python 3.13 + Starlette + uvicorn**, managed by uv | The engine is Python/MLX. Inference is GPU-bound, so the web layer is not the bottleneck. This matches Koi's proven code, which keeps the least code to own. |
| MLX threading | — | **Load the model and run every decode on one dedicated thread.** The asyncio loop hands work over a queue. | Koi PR #3595: MLX streams are thread-local, and decoding on another thread raises "There is no Stream(cpu, 1) in current thread". |
| Mac client | Fork Handy (Tauri/Rust), VoiceInk (Swift, GPL-3), or a minimal Swift menu-bar app | **A minimal native Swift app (SwiftPM, AppKit, AVAudioEngine)**, with KeyboardShortcuts (sindresorhus, MIT) for the hotkey | System APIs do the heavy lifting: AX insertion, the pasteboard and CGEvent. A fork would carry its own engine, UI and settings, all of which we would replace. GPL code is avoided. It builds with Command Line Tools only (no Xcode). |
| Android client | Fork FUTO Keyboard / HeliBoard, Whisper To Input or Dictate, or a minimal IME | **A minimal Kotlin voice-only IME** with OkHttp WebSocket, AudioRecord and Android Keystore. It is used alongside Samsung Keyboard. | A voice-only IME is small: one view and one service. Switching back to the previous IME keeps Samsung Keyboard for typing. Full-keyboard forks are large and outside v1. |
| Network | Bind to the 100.x address, or `tailscale serve` (tailnet-only HTTPS, identity headers) | **Bind to 127.0.0.1 only, published with `tailscale serve --set-path /chirp`** (never Funnel). Plus a bearer token. | Koi already uses `tailscale serve` on this host (`/koi`, `/proxy`). That gives TLS from the tailnet cert, WebSocket support and `Tailscale-User-Login` headers for free. |
| Correction | — | Koi's `voice/cleanup.py` contract: an OpenAI-compatible `base_url`/`model`/`prompt`, a timeout (default 8 s), final transcript only, falling back to raw text on timeout, error or answer-shaped output | This is proven in Koi. The client receives both `raw` and `text`, so it can undo the correction. |

## 3. Wire protocol (v1, frozen for parallel work)

All endpoints sit under a base URL: either `http://127.0.0.1:7821` (Mac local) or `https://<computer>.<tailnet>.ts.net/chirp` (tailnet). The server honours `X-Forwarded-Prefix` or is started with `--root-path /chirp`.

Every request carries `Authorization: Bearer <token>`. WebSocket clients that cannot set headers may send the token as the first text frame `{"type":"auth","token":"…"}` instead. The token is never put in a URL.

The token is either the shared one or a per-device token minted by `chirp-server pair --name` (see [server/README.md](../server/README.md#per-device-tokens)). A revoked device token gets `auth` (WS close 4401) everywhere and HTTP 401 `auth` even on health, so clients route it to re-pair; other unauthenticated health requests still get only `{"ok":true}`.

### Endpoints

- `GET /v1/health` → `{"ok":true,"engine":"parakeet-mlx:tdt-0.6b-v2","ready":true,"debug_retention":false,"correction":"off|available","correction_mode":"off|managed|endpoint","correction_leaves_machine":false,"correction_host":null,"correction_profiles":[{"id":"default","name":"Default","description":"Conservative transcript cleanup.","rewrites":false},…],…,"notes_structure":true,"notes_correction":true,"notes_reorganize":true,"notes_context":true,"notes_edit":true}`. The unauthenticated variant returns only `{"ok":true}`. For endpoint correction, `correction_host` is its hostname (no credentials, path or port); otherwise it is `null`. `correction_leaves_machine` is true only for enabled, non-loopback correction.
- `GET /v1/correction/profiles` (authenticated) → `{"profiles":[{"id":"default","name":"Default","description":"Conservative transcript cleanup.","rewrites":false,"prompt":"<editable default style>","max_prompt_chars":4000},…]}`. Fixed safety rules are excluded; `custom` has an empty built-in prompt. Available even when correction is off. Invalid or missing bearer credentials return HTTP 401 with `WWW-Authenticate: Bearer`.
- `POST /v1/notes/structure` (authenticated, JSON): stateless Live Notes structuring, specified [below](#live-notes-structuring-v1-compatible-addition). `/v1/stream` is unchanged.
- `POST /v1/notes/reorganize` (authenticated, JSON): stateless reorganize of a whole Live Notes document (or its trailing sections), specified [below](#live-notes-reorganize-v1-compatible-addition). `/v1/stream` and `/v1/notes/structure` are unchanged.
- `POST /v1/notes/edit` (authenticated, JSON): stateless voice edit of a Live Notes document (notes + a spoken instruction → edited notes), specified [below](#live-notes-edit-v1-compatible-addition).
- `GET /v1/devices/activity` (owner token, direct loopback only; a v1-compatible addition no phone calls): which devices used the server, specified in [Device activity](#device-activity-v1-compatible-addition) below. `PUT /v1/devices/activity/settings` with `{"keep":bool}` turns the recording off (deleting what is stored) or on.
- `POST /v1/transcribe`: the body is 16 kHz mono PCM16 WAV, capped at 120 s. It returns the same object as a `final` message. Used for tests and as a fallback.
- `WS /v1/stream`:
  - client → `{"type":"start","sample_rate":16000,"encoding":"pcm_s16le","client":"mac|android|ios|desktop","correction":false,"correction_profile":"default","correction_instructions":"","context":"…"}` (`correction_prompt`, `word_timings`, `context` and `learned` are optional)
  - client → binary frames: raw PCM16LE mono at 16 kHz, 20–100 ms per frame
  - client → `{"type":"stop"}` (finalize; may carry the optional `context`, see Live Notes below) or `{"type":"cancel"}` (discard, no final). The server keeps reading control/disconnect frames during finalization; cancel or disconnect discards the utterance (no correction request — an in-flight one is cancelled, no retained debug files). A cancelled utterance sends no final and no error, and the socket stays usable for the next start; a disconnect has nobody to tell.
  - server → `{"type":"ready","session":"<random id>","engine":"…","debug_retention":bool}`
  - server → `{"type":"partial","seq":n,"text":"…","stable":"…"}`. `stable` is the prefix that will not change, which clients may commit early. With `start.word_timings` the message also carries `"words":[{"text":"…","start":s,"end":s,"stable":bool},…]` (see below).
  - server → `{"type":"correcting","seq":n,"raw":"<full raw transcript>","profile":"<id>"}` immediately after full-utterance decode, before cleanup runs and before `final`. It shares the increasing partial sequence counter. Sent only when correction will run (both server and utterance enabled, nonempty raw). Cancel during correction cancels the helper and sends nothing further, including no final or error; the socket remains reusable.
  - server → `{"type":"final","text":"…","raw":"…","corrected":bool,"correction_error":null|"timeout|http|rejected","timings_ms":{"audio":…,"first_partial":…,"finalize":…,"correction":…}}`
  - server → `{"type":"error","code":"auth|busy|too_long|bad_audio|bad_request|engine","message":"safe text"}`
  - One utterance per `start`/`final` pair. A socket may carry several utterances in turn, so clients keep it open while active. The server closes idle sockets after 60 s.
- Limits: 120 s per utterance, and frames ≥ 1 MB are rejected. Requests queue for one engine.

Authenticated health also includes the selected `speech_model` and `correction_model` IDs. These optional metadata fields contain no token, prompt, audio, or transcript. Unauthenticated health remains minimal.

### Notes re-transcription (v1-compatible addition, issue #287 S)

`WS /v1/stream` accepts optional `start.retranscribe: true`. A non-boolean returns `bad_audio`;
omitted or false preserves the live protocol. The client sends one kept clip per utterance,
decoded in memory to 16 kHz mono PCM16 in frames of at most 100 ms, then `stop` with the
optional previous segment's new text as `context` (at most 500 characters). The normal auth,
120-second utterance limit, frame limit, cancel and debug-retention behavior apply.

The server buffers audio without preview inference and emits no `partial`. Its full decode,
optional `correcting`, clean-up, word timings and optional speakers use the live final pipeline.
Only flagged finals add `engine`, equal to `ready.engine`, so clients can record provenance per
segment; live clients use `ready.engine`. There is one loaded speech model and no per-request
model selection. The default profile and `speakers` remain allowed. Re-transcription clients
preserve existing speaker turns rather than requesting new labels.

The engine lease has two FIFO priorities. Live streams and `/v1/transcribe` go before waiting
re-transcriptions after the current utterance releases the lease; an active decode is never
interrupted. Live queue timeout stays 10 s; re-transcriptions wait up to the positive, finite
`retranscribe_queue_timeout` (60 s by default, top-level `server.toml`) before `busy` and socket
close. Clients retry the same clip with 2/4/8/…/30 s backoff, at most 10 tries. The final deadline
is 25 s after `stop`, extended on `correcting` to `operation_deadlines.notes_correction` + 5 s.
Per-segment errors keep the old text; authentication failure stops the run for re-pairing.

Authenticated health adds `notes_retranscribe: true` and the same capability; API level stays 2.
Unauthenticated health stays `{"ok":true}`. Clients require this capability before sending.
Activity uses the audio kind `notes_retranscribe` with `audio_ms`. Audio and text stay in memory,
except explicit debug retention; session logs and activity contain metadata only. Each client
owns per-action consent, progress, retries, staged replacement and Undo. This server change
provides the transport; client workflows ship separately.

### Device activity (v1-compatible addition)

Metadata about who used the server, for Settings → Devices on the Mac. Phones never call it, so the protocol stays v1; clients must ignore unknown fields, kinds and outcomes.

- **Auth.** `Authorization: Bearer <owner token>` (`~/.config/chirp/owner-token`, `0600`, created on first start, never printed by `pair`, never in a link, never shown in health) **and** a direct loopback connection: the peer is `127.0.0.1`/`::1` and none of `X-Forwarded-For`, `X-Forwarded-Host`, `Forwarded`, `X-Real-IP`, `Tailscale-User-Login`, `Tailscale-User-Name` is present (a `tailscale serve` request carries them). No or a wrong token → 401 `auth`. A valid shared or device token, or the owner token through a proxy → 403 `forbidden`. The owner token is refused (401) by every other endpoint.
- **Source** of a request, from the credential that passed auth: `{"kind":"device","id","name","revoked"}` (names and `revoked` are joined at read time), `{"kind":"local"}` (the shared token used directly on this machine, "This Mac") or `{"kind":"shared"}` (the shared token through the proxy). A label, not a security boundary.
- **Events** are one per `/v1/stream` utterance (`start` to final, cancel or error, not per socket), per `/v1/transcribe`, `/v1/notes/{structure,reorganize,edit}` and `/v1/speakers/model` request. Health, `/v1/correction/profiles` and `/v1/correction/settings` are not recorded. `kind` is `dictation`, `notes_segment` (a live stream utterance with the `live_notes` style), `notes_retranscribe` (a flagged re-transcription, regardless of style), `transcribe`, `notes_structure`, `notes_reorganize`, `notes_edit` or `speaker_model`. `outcome` is `ok`, `cancelled`, `rejected`, `timeout`, `busy`, `preempted`, `disconnected`, `notes_off` or an error code. `audio_ms` is set for audio kinds only.
- **Refusals** (bad or missing token on a protected endpoint, WS auth failures including the pending-auth cap, a revoked device's token anywhere) are counters with the last time only; an unauthenticated health probe is not counted.
- **Retention.** Written to `device-activity.json` (`0600`, atomically replaced, at most every 5 s and on shutdown) so a restart keeps it; at most `[activity] max_events` (5000) events and `max_days` (30) days, pruned at read time. `[activity] keep = false` or `PUT /v1/devices/activity/settings {"keep":false}` stops recording and deletes the file's contents; that choice is saved with it and wins over `server.toml`. Nothing is logged.

```json
{
  "started": "2026-10-26T09:12:00Z",
  "keep": true,
  "retention": {"max_events": 5000, "max_age_days": 30},
  "active": [
    {"source": {"kind": "device", "id": "9f3a1c52", "name": "Pixel 8", "revoked": false},
     "client": "android", "kind": "dictation", "profile": "default", "since": "2026-10-26T10:15:03Z"}
  ],
  "events": [
    {"at": "2026-10-26T10:14:40Z", "source": {"kind": "shared"}, "client": "ios",
     "kind": "notes_segment", "profile": "live_notes", "corrected": true,
     "duration_ms": 2310, "audio_ms": 41800, "outcome": "ok"}
  ],
  "refused": [
    {"reason": "unknown_token", "count": 3, "last": "2026-10-26T10:10:00Z"},
    {"reason": "revoked", "device": {"id": "11aa22bb", "name": "Old Pixel"}, "count": 2, "last": "2026-10-26T10:11:00Z"}
  ]
}
```

`events` is newest first, `at` is when the request ended, `since` when it began. `reason` is `unknown_token`, `no_token` or `revoked`.

### Optional correction fields (v1-compatible additions)

The additions are optional and v1 compatible: omitted `correction_profile` selects `default`;
`correction_instructions` is a string of at most 2000 characters, used only for `custom`.
`start.correction_prompt` is an optional string of at most 4000 Unicode characters. When
present (including an empty string), it replaces the selected profile's editable style for
that utterance. For `custom` it takes precedence over `correction_instructions`. Clients send
it only when the user edited the style; otherwise omit it to follow server defaults and updates.
A non-string or oversized `correction_prompt` returns `bad_request` before engine leasing.
Unknown profile IDs or invalid legacy field types/lengths return `bad_audio` before engine leasing.
Old clients ignore unknown message types, including `correcting`, and consume the existing final.
Authenticated health lists every profile's `id`, `name`, `description` and boolean `rewrites`,
even when correction is off; it never exposes prompts or client instructions.

### Live Notes speaker labels (v1-compatible addition)

`start` may carry `"speakers": {"session": "<16-64 of [A-Za-z0-9_-]>"}` (a random id per note, issue
#187); its final then carries `"speakers": {"generation": "…", "turns": [{"speaker": n, "start": s,
"end": s, "text": "…", "raw": "…", "approximate": bool, "kept_original": bool}, …]}`, or
`{"error": "unavailable|failed"}`. Turn texts cover the final's `text` in order; `speaker` is the
note's slot, numbered by first appearance; a new `generation` means the server lost the note (its
slots are new voices). Any other `speakers` value is `bad_audio`; without the field nothing changes.
`POST /v1/speakers/model` (authenticated, `{"action":"download"|"cancel"|"remove"}`) fetches the pinned
speaker model or deletes it (200/202 with `{"state":…,"size_bytes":…}`,
409 for remove while downloading, 400 `bad_speakers` otherwise). `cancel` is idempotent: it stops
the owned download process and removes partial files, returning 200 `not_downloaded`; an already
installed model is preserved (200 `ready`). A deliberate cancel clears `failed`. It does not change
saved voices or other clients' preferences. Authenticated health adds
`"notes_speakers": true` (also in `capabilities`) and `"speakers_model": {"state":
"ready|downloading|not_downloaded|failed", "size_bytes": n}`. Details in
[server/README.md](../server/README.md#speaker-labels).

### Saved voices (v1-compatible addition, issue #247)

One library of saved voices per Chirp server, shared by every client paired to it: a name and a
voiceprint (the unit mean of the pinned WeSpeaker ResNet34-LM's 256-number embeddings of the
person's speech) per person, at most 50, in `data_dir()/speakers/voices.json` (folder 0700, file
0600, owner-only ACL on Windows; `~/Library/Application Support/Chirp/speakers/` on a Mac). A voice
named on one device is recognised on every other device that uses the same server; a client on
another server has that server's library. No `api` bump: a client that does not see the
capability hides "remember voice" and the Saved voices screen ("Update Chirp on your computer to save
voices").

- **Capability.** Authenticated health adds `"speaker_voices": true` (also in `capabilities`) and
  `"speakers_voices": {"enabled": bool, "count": n, "model": "wespeaker-voxceleb-resnet34-LM@f0c48c29"}`
  (`"error": "unreadable"` when the file is damaged; Forget all starts again).
- **`final.speakers.matches`.** With a `start.speakers.session`, the library on and at least one
  voice of the server's model saved, `final.speakers` gains `"matches": [{"speaker": slot, "voice":
  "<16 hex>", "name": "Maya"}]` (possibly `[]`). Each match is the note's slot (as in `turns`) the
  server recognises now, over the whole note so far, not only this segment's turns: a slot with
  ≥ 10 s of embedded speech, whose voiceprint is at least 0.7 alike to a
  saved voice and 0.10 ahead of the next saved voice; one slot per voice and one voice per slot,
  the closest first (the Mac's `VoiceMatch`). The name is included so a device that never saw the
  voice can show it. A slot absent from a present list is not recognised (yet); clients keep a name
  they already applied. Without saved voices, with the library off or unreadable, the message is
  byte-identical to before.
- **`GET /v1/speakers/voices`** → `{"enabled": bool, "model": "…", "voices": [{"id": "<16 hex>",
  "name": "Maya", "seconds": 46.0, "created": "2026-10-12T09:00:00Z", "updated": "…", "compatible":
  bool}]}`. Never a voiceprint. `compatible: false` is a voice from another model: listed ("name them
  again"), never compared.
- **`POST /v1/speakers/voices`** takes one action (JSON, at most 8 × 30 s of clips) and answers the
  same listing, except `identify`:
  - `{"action": "remember", "name": "Maya", "from": {"session": "<the note's session>",
    "generation": "<final.speakers.generation>", "speaker": slot}}`: the phone path, from the note's
    speaker the server holds in memory. Its listing adds `"voice": {…}`, the saved voice.
  - `{"action": "remember", "name": "Maya", "audio": "<base64 PCM16 LE 16 kHz mono, ≤ 30 s>"}`: the
    Mac path, a clip of the person's settled turns (≥ 2 s each, the last 30 s). Voiced 1.5 s windows
    are embedded and averaged; the clip is held only for the request.
  - Either with `"voice": "<id>"` updates that voice (renaming it to `name`): a seconds-weighted mean
    of the two voiceprints; a voice of another model is replaced. Without `voice` it is always a new
    voice, even under a name already saved (the client decides; it has the list).
  - `{"action": "import", "name": "Maya", "embedding": "<base64 256 float32 LE>", "seconds": 31.0,
    "model": "wespeaker_v2@df2625a"}`: once, for a voice the Mac saved in its Keychain before the
    shared library (#18). Only that model id is accepted (it agrees with the server's; see below), and
    the voice is stored as this server's model. Its listing adds `"voice": {…}`.
  - `{"action": "identify", "people": [{"person": n, "audio": "<clip>"}, …]}` (1–8 people, `person`
    0–999, unique) → `{"matches": [{"person": n, "voice": "<id>", "name": "Maya"}]}`, one-to-one with
    the same rule as `matches`. The Mac sends it once per person at 10 s of speech, and again if not
    matched by 30 s. With no voice saved it answers `[]` without the model.
  - `{"action": "rename", "voice", "name"}` renames the saved voice only (notes keep their names);
    `{"action": "forget", "voice"}`; `{"action": "forget_all"}` deletes the file (while off, it
    keeps an empty, off library); `{"action": "enable"}`; `{"action": "disable", "forget": bool}`.
  - Names follow the notes' speaker-label rule (#212): one line, no colon, a letter, ≤ 60
    characters; runs of spaces collapse.
  - Errors are `{"type": "error", "code", "message"}`: `400 bad_speakers` (malformed, or a name the
    rule refuses), `404 gone` (the server no longer holds that note or generation: "Record a little
    more with them, then try again"), `404 no_voice`, `409 too_short` (under 20 s of embedded speech), `409 disabled`, `409 full` (50 voices), `409 unavailable`
    (a clip needs the speaker model), `413 clip_too_long`, `500 voices_file` (the file could not be
    read or written), `500 failed`, `401 auth`. An older server answers 404/405 without a code.
- **Thresholds** are this model's own (0.7 / 0.10; the Mac's `wespeaker_v2` profiles use 0.75), from
  [bench.md](bench.md#saved-voices-server-247). The Mac's `wespeaker_v2` is the same
  network as the server's model, quantised: their embeddings of the same clip agree (cosine
  0.98–0.99), so the Mac's Keychain voices (#18) can move to the server once with `import` (same
  bench).
- **Switch.** `enabled` is the server-wide "Remember voices": off, nothing is saved or recognised and
  `remember`/`identify` answer `409 disabled`; listing, rename and forget still work. Removing the
  speaker model keeps the voices. `chirp-server voices list | forget <name or id> | forget-all | off
  [--forget] | on` does the same at the Mac; the server picks the change up on the next request.

### Live Notes structuring (v1-compatible addition)

`POST /v1/notes/structure` turns a window of corrected transcript into Markdown notes. The server
keeps no notes state: the client sends the window to structure each time.

Request (`Content-Type: application/json`, body at most 64 KiB):

```json
{"transcript": "corrected text of the open window, segments joined with \n", "outline": ["Project kickoff", "Budget"], "final": false}
```

- `transcript`: a string of 1-6000 Unicode characters after trimming.
- `outline`: optional, at most 24 strings of at most 120 characters and 1500 characters in total. These are the headings already written, oldest first, and are context only.
- `final`: optional bool (default false), a hint that this is the session's last pass. It changes nothing but the log line.
- Unknown keys are rejected.

Responses:

| Status | Body | When |
|---|---|---|
| 200 | `{"markdown":"## …\n- …","structured":true,"error":null,"timings_ms":{"structure":1234.5}}` | The model's output passed the guards |
| 200 | `{"markdown":null,"structured":false,"error":"timeout\|http\|rejected","reason":"novel…\|null","timings_ms":{…}}` | Fails closed like `correction_error`: guard rejection, helper failure, timeout or endpoint error. The client keeps its previous block. `reason` (failures only, optional for clients) names the guard that rejected the output, e.g. `name`, `number`, `date`, `negation`, `novel`, `length`, `grammar`, `forbidden`, `finish`; `null` for timeouts and transport or parse errors. It is a name only, never text, and is also in the log line |
| 400 | `{"type":"error","code":"bad_notes","message":"Invalid notes request"}` | Malformed JSON, wrong types, limits exceeded, unknown keys, body over 64 KiB |
| 401 | `{"type":"error","code":"auth",…}` with `WWW-Authenticate: Bearer` | Missing or wrong bearer token |
| 409 | `{"type":"error","code":"notes_off","message":"Notes structuring needs correction enabled on the server"}` | `correction.mode == "off"` |
| 503 | `{"type":"error","code":"busy",…}` | Another structuring request is already running server-wide (one at a time, never queued) |

Authenticated `GET /v1/health` also says what the process is, so a client can tell it is older than itself: `"version"` (package version), `"commit"` (short git commit, or `null`), `"api"` (an integer bumped when a client starts needing something older servers lack; currently 2), `"capabilities"` (the `notes_*` feature names that are true), `"started_at"` (Unix seconds), `"pid"` and `"source"` (the server folder it runs from, home shown as `~`). A server that predates these fields has none of them, which clients treat as out of date. None of it is secret or user data, and unauthenticated health still returns only `{"ok":true}`.

Authenticated `GET /v1/health` always carries `"notes_structure": true` on servers that have
the endpoint, whatever the correction mode, so a client tells an old server (field absent) from
correction being off (`correction == "off"`).

Authenticated health also carries `"notes_correction": true` on servers with the hidden
`live_notes` correction style for Live Notes segments. It is never listed in
`correction_profiles` or `/v1/correction/profiles` (and cannot be overridden in config), but a
`start` with `correction_profile: "live_notes"` is accepted. Its guard (`notes_faithful`) is
separate from the dictation guards, which are unchanged: the output may only delete words, in
order, with free casing and punctuation, and only spoken fillers (um, uh, er, ah, hmm, oh, like,
yeah, yes, okay, ok, so, well, basically, actually, literally, right, just, anyway, kind of,
sort of, you know, I mean), the first copy of a phrase of up to four words said twice in a row
(fillers and filler phrases skipped between copies; never a phrase of only number words), a short
restart (up to five words, when the speaker starts again with the same word, every dropped word is
a grammar word or said again right after, and none is a negation or number), a sentence-initial
"and", a restated subject after a verb ("the list is, it's nice") or repeated within two words
("it's just, it's not"), an article swapped for another ("a, an"), and up to four words taken back
with "sorry" plus the marker (never an apology, a number or a negation). Negations, numbers,
names, hedges and every other word must survive. When the only unlicensed edit is a dropped "I
think", "I guess" or "I'd say", the hedge is put back where it was and the result must pass the
same guard. The call is bounded by `[correction] notes_timeout` (default 15 s; dictation keeps
`timeout`), the output by `64 + len(segment) / 2` tokens.

Structuring uses the configured correction backend (the managed Qwen helper or the endpoint) but
never takes the engine lease, so it does not block `/v1/stream`. The whole pass is bounded by
`[correction] structure_timeout` (default 30 s), the output by 768 tokens, and a model output is
accepted only if it passes `notes_rejected`, one function per check: no think blocks, code fences,
H1 titles, tables, links or assistant openers; at most `max(1.2 x transcript, 300)` characters;
every line within the allowed Markdown subset (`##`/`###` headings of at most 6 words, `-` bullets
with one nested level, `- [ ]` tasks, plain lines); every number, as digits, number words or an
abbreviated scale (`$300M`), was spoken; no weekday or month, email address, URL or domain that was
not spoken; no capitalised word (a name, place, product or acronym) that was not spoken, checking
bold words and a to-do's owner even at the start of a line (a bold phrase opening a line is sentence
case); names, numbers and dates may also come from the request's outline; at least 50 % of the content words (stemmed, outside stopwords and
labels such as "Decision" or "Suggestion") occur in the transcript, so paraphrase passes but an
unrelated answer does not; and no flipped negation: a line that restates a negated transcript
clause's head and most of its content words ("we will not ship on friday" to "- Ship on Friday")
without a negation, negative wording ("lacks", "unclear") or a hedge is rejected, while leaving an
incidental negation out ("whether it works or not") is allowed. Like the correction guards these
are heuristics: they catch invented names and numbers, answers and flipped statements but cannot
prove semantic equivalence, and they are tuned for English. The transcript pane is always one click away in the client.

### Live Notes reorganize (v1-compatible addition)

`POST /v1/notes/reorganize` regroups an editable notes document: it merges duplicate sections and
bullets and gathers tasks, decisions and questions, without dropping or inventing content. Like
structuring it is stateless: the client sends the Markdown each time and applies the answer only
if the document has not changed since (no merge).

Request (`Content-Type: application/json`, body at most 64 KiB):

```json
{"notes": "## Launch plan\n- …", "outline": ["Earlier heading"], "final": false}
```

- `notes`: the user's and the AI's Markdown source, 1-3500 Unicode characters after trimming
  (`MAX_REORGANIZE_CHARS`). Untrusted data. A longer document sends only its trailing whole
  sections that fit.
- `outline`: as for structuring (at most 24 strings, 120 characters each, 1500 in total): the
  headings of the settled sections above, context only.
- `final`: optional bool; it only changes the log line.
- Unknown keys (including `transcript`) are rejected.

| Status | Body | When |
|---|---|---|
| 200 | `{"markdown":"…","reorganized":true,"changed":true,"error":null,"timings_ms":{"reorganize":1234.5}}` | The output passed the reorganize guards |
| 200 | `{"markdown":"<input notes, trimmed>","reorganized":true,"changed":false,"error":null,…}` | The output equals the input apart from trailing spaces and blank lines; the client applies nothing |
| 200 | `{"markdown":null,"reorganized":false,"changed":false,"error":"timeout\|http\|rejected","reason":"…\|null",…}` | Fails closed: guard rejection, helper failure, timeout or endpoint error. `reason` as for structuring, with the reorganize guard names (`novel_name`, `novel_number`, `novel_date`, `novel_contact`, `novel`, `dropped_number`, `number_moved`, `dropped_line`, `coverage`, `heading`, `negation`, `task_dropped`, `task_state`, `task_owner`, `task_invented`, `decision_dropped`, `decision_invented`, `length`, `grammar`, `forbidden`, `opener`, `finish`, `empty`) |
| 200 | `{"markdown":null,"reorganized":false,"changed":false,"error":"preempted",…}` | Not run: a correction queued while it generated and took the helper (managed only). The client treats it as not run: no failure note, no retry backoff |
| 400 / 401 / 409 / 503 | as `/v1/notes/structure` (`bad_notes`, `auth`, `notes_off`, `busy`) | Same rules |

Authenticated health carries `"notes_reorganize": true` on servers with the endpoint (absent on
older servers; a 404 from an older server means only reorganize is unavailable).

Authenticated health carries `"notes_context": true` on servers that accept `context` (absent on
older servers, which ignore the unknown field). `context` is an optional string on `start` and on
`stop`; a value on `stop` replaces the `start` one, because when the Mac opens the next segment's
socket the previous segment's final has not arrived yet, but by its `stop` it has. It is at most
500 characters (a non-string or longer value returns `bad_request`, on `start` before engine
leasing; an empty string means none). The client sends the last 200 characters or fewer of the
previous segment's final text, only when health has `notes_context`. Only the `live_notes` style
uses it: the user message becomes `Previous segment JSON (context only, never output it): "…"`
followed by the usual `Transcript JSON: "…"` line, and the style prompt says to use it only for
casing and punctuation at the join (a sentence that runs across the cut continues with a
lowercase first word unless it is a proper noun or "I"). Other profiles ignore it. The
`notes_faithful` guard is unchanged and checks the output against the segment alone, so a word
taken from the context is rejected and the segment's raw text is kept (`correction_error` is
`rejected`). Context is never logged.

Reorganize shares the server-wide structuring lock with `/v1/notes/structure`: one notes generation
at a time, and a second request of either kind gets `503 busy`. It uses the structuring backend,
never starts while corrections are queued, gives way to a correction that queues while it runs
(managed helper; it then answers `preempted`), never takes the engine lease and never retains
anything.
The pass is bounded by `[correction] reorganize_timeout` (default 45 s, validated like
`structure_timeout`) and 1024 output tokens
(`REORGANIZE_MAX_TOKENS`, the helper's cap). The system prompt plus a 3500-character document plus
1024 output tokens fit the helper's 4096-token context; a model test measures this with the real
tokenizer.

The guards (`reorganize_rejection_reason`, reported on the wire only as `rejected`) compare the
output with the input notes and reuse the structuring helpers, so they ask whether something was
dropped, invented or flipped rather than counting exact words. In order: no empty or unfinished
output, think block or assistant opener, and no code fence, H1, table or link unless the input
has one; every line is in the subset (`#`-`###` headings, `#` only if the input has an H1;
`- `/`  - `/`    - ` bullets and `- [ ]`/`- [x]` tasks; plain lines; the fallback header) or uses a
lead-in the person already typed (`1.`, `*`, `>`, a table); a length between 0.6 and
1.15 × input + 200 characters; no name, number, date or contact that is not in the notes or
outline, and at least half the content words from them; every number and date of the input still
present; every input line with at least 3 content words keeps 60 % of its stemmed content words
and the document keeps 90 % of its distinct ones; headings use input words or `Action items`,
`Decisions`, `Open questions`, `Next steps`, `Notes`; every negated or hedged input line keeps a
negation (a negated line) or a negation or hedge (a hedged one) in the output line that holds its
content, no negation is added, and the structuring flip check passes on the output lines whose
source is not itself an affirmative line next to a negated one in the notes; every distinct task keeps exactly its checked state and its people
(bold names and a capitalised owner), no task is invented, and every `**Decision:**`/`**Question:**` line keeps its label. These are heuristics
tuned for English, like the other guards.

### Live Notes edit (v1-compatible addition)

`POST /v1/notes/edit` applies one spoken instruction ("remove the pricing section", "go to the top
and clean that up", "make the action items a checklist") to the notes. It is stateless like
reorganize: the client sends the Markdown and applies the answer only if the document has not
changed since.

Request (`Content-Type: application/json`, body at most 64 KiB):

```json
{"notes": "## Launch plan\n- …", "instruction": "remove the pricing section", "selection": "## Pricing\n- …"}
```

- `notes`: the Markdown source, 1-3500 characters after trimming (`MAX_EDIT_CHARS`), or up to
  32000 with a `selection`. Untrusted data.
- `instruction`: what the person said, 1-400 characters after collapsing whitespace. It is the
  only instruction; names, numbers and dates in it may appear in the output ("change Friday to
  Thursday").
- `selection`: optional, 1-3500 characters after trimming, and it must occur exactly once in
  `notes`. Only the selection is sent to the model and checked; the edited text replaces it in
  place and `markdown` is the whole document.
- Unknown keys are rejected (`bad_notes`).

| Status | Body | When |
|---|---|---|
| 200 | `{"markdown":"…","edited":true,"changed":true,"error":null,"timings_ms":{"edit":1234.5}}` | The output passed the edit guards; `markdown` is the whole new document |
| 200 | `{"markdown":"<input notes, trimmed>","edited":true,"changed":false,…}` | The model returned the notes unchanged (apart from trailing spaces and blank lines): nothing to apply |
| 200 | `{"markdown":null,"edited":false,"changed":false,"error":"refused","reason":"adds_content\|unclear\|not_an_edit",…}` | The instruction asks for something an edit may not do: new writing (a summary, explanation, ideas, an answer, a translation; `adds_content`, refused before the model runs when the word does not already appear in the notes), a part that is not there (`unclear`) or something that is not an edit (`not_an_edit`). The client shows the reason |
| 200 | `{"markdown":null,"edited":false,"changed":false,"error":"rejected\|timeout\|http\|preempted","reason":"…\|null",…}` | Fails closed as reorganize; `reason` is a guard name (the reorganize names plus `dropped_unasked` and `summary`) |
| 400 / 401 / 409 / 503 | as `/v1/notes/structure` (`bad_notes`, `auth`, `notes_off`, `busy`) | Same rules |

Authenticated health carries `"notes_edit": true` (and `notes_edit` in `capabilities`). The pass shares the structuring lock (`503
busy` while a structure, reorganize or edit runs), has reorganize's helper priority (never starts
while corrections queue, preempted by one that queues while it runs), is bounded by
`[correction] reorganize_timeout` and 1024 output tokens, never takes the engine lease and never
retains anything; the log line has lengths, whether a selection was sent, the outcome and the
reason.

The guards (`edit_rejection_reason`) are the reorganize guards with the instruction as an extra
source, relaxed only where the instruction's own words allow it:

- **Delete** (remove, delete, drop, cut, get rid of, take out, trim, shorten, …): input lines
  missing from the output (under 60 % of their content words kept) are the deleted lines. Each
  section that lost lines or its heading must mention one of the instruction's topic words (its
  words other than verbs and place words such as "top", "last", "section", "bit") in its heading
  or a deleted line; an instruction with only place words ("delete the last line") may delete
  from one section. The remaining lines are then held to every reorganize check. Otherwise:
  `dropped_unasked`.
- **Replace** (change, replace, correct, rename, update, …): a number or date may leave its line.
- **Tasks**: checklist, task, to-do or action item words allow new `- [ ]` tasks made from
  existing lines; existing tasks still keep their state. Done, check, tick, complete, open, …
  allow state changes on the tasks that share the instruction's topic words (every task when it
  has none). Decision or question words allow new labels from existing lines. A name the
  instruction mentions may leave a task.
- **Numbered list**: "number" or "numbered" makes `1.` markers markup rather than numbers.
- Always: no new Summary, Overview, Recap, Takeaways or Conclusion heading (`summary`); no name,
  number, date or contact outside the notes and instruction; length at most 1.15 × input + 200 +
  the instruction's length (and at least 0.6 × input unless deleting); negations and hedges kept;
  instruction-like lines in the notes are content.

**Managed helper pipe protocol** (private to `managed_cleanup.py` and `cleanup_worker.py`). The
request `{"text","system"}` is unchanged. Two optional keys exist for structuring: `"user"`, a
string that is the *entire* user message and replaces the `Transcript JSON: …` wrapper, and
`"max_tokens"`, an int in 1-1024 that replaces the 512-token output cap for that request (the
context check becomes `len(tokens) + max_tokens <= 4096`). Anything else gives `{"ok": false}`.
The server writes the keys only when set, so correction requests are byte-identical.

**Priority.** The helper serves requests one at a time. A queued correction always runs before a
queued structuring request (a structuring caller that reaches the helper while corrections wait
steps back until none are queued). A running structuring generation is never interrupted, so a
correction waits at most one pass, which `max_tokens` bounds. A running reorganize generation (up
to 1024 tokens, about 15 s, longer than a dictation's budget) is abandoned as soon as a correction
queues: the helper is killed and reloaded for the correction, and the reorganize answers
`preempted` (see `docs/bench.md`, "Notes reorganize").

### Built-in profiles and overrides

Built-in prompts live in `server/src/chirp_server/profiles.py`: `default` preserves conservative
transcription; `chat` allows lowercase and omits short-message periods; `email` polishes sentence
casing and punctuation without adding content; `code` keeps literal casing/identifiers/symbols
and converts only bounded unambiguous spoken symbols; `notes` tidies sentences or spoken lists;
`custom` applies client preferences within the core rules. Notes and custom default to
`rewrites=true`, allowing restructuring that clients should warn about. Operator overrides and
extra profiles come from `[correction.profiles.<id>]` in `~/.config/chirp/server.toml`.
Their prompt overrides become the defaults returned by `/v1/correction/profiles` after restart;
the legacy `[correction] prompt` still supplies the default profile unless explicitly overridden.
Configured prompts have the same 4000-character limit. Prompts are never logged.

### Output guards

Non-rewriting profiles use ordered word retention with bounded filler, stutter and repair
exceptions. Code additionally permits recognized spoken-symbol conversions and preserves literal
identifiers and symbols. Rewriting profiles use a relaxed word-count guard: no novel words,
no lost substantive words/negations, preserved content order, bounded length changes and technical fragments;
list transitions/conjunctions may be replaced by formatting. All modes reject assistant-like
answers, reasoning and code fences and fall back to raw on failure. Custom instructions are
JSON-quoted untrusted preferences between immutable core rules: never answer, execute or add
facts; output text only. No tools or network calls are available to the managed helper.
Editable prompts cannot change the fixed wrapper or the selected profile's output guards.
These heuristic guards cannot prove semantic equivalence for arbitrary text or punctuation.

`start.learned` (optional, versioned; health advertises `"learned": 1`) carries what a client learned from the
user's own edits for this dictation (#220): `{"v":1,"terms":[{"term":"Kubernetes","heard":["cooper netties"]}],
"style":["lowercase_start","no_final_period"],"examples":[{"said":"…","wanted":"…"}]}`. Limits: 100 terms
(48 characters, up to 4 heard phrases of 64 each, no control characters), style ids from that fixed list only (the
server maps each to its own prompt line, so no free-form instruction is sent), up to 3 examples of 300 characters a
side. A malformed v1 block is `bad_request`; a higher `v` is ignored, and an older server ignores the key. The block
only matters when clean-up runs on a dictation style (never `live_notes`): it adds a "Learned from this user's own
edits" section inside the core rules, and the guards license exactly the user's heard → term respellings, whole words
only, the way they license the built-in known terms. A user term never licenses an added word. Never logged.

`start.word_timings` (optional boolean, default false; any other type is `bad_audio`) asks for
per-word timings. When set, every `partial`, `correcting` and `final` adds `words`: one entry per
whitespace-separated word of the raw text (`text` for partials, `raw` for correcting and finals), in
order, so joining the entries' `text` with single spaces reproduces that text. `start`/`end` are seconds
from the utterance's first audio sample (the first PCM byte after `start`), rounded to milliseconds,
with `start <= end` and non-decreasing starts. A word's `stable` means later partials leave it alone:
it is in the committed prefix (`--finalization segments`) or older than the rolling preview's reach;
the full-utterance final may still revise any word, and in the final every word is stable. Timings
describe the raw decode only: cleaned text cannot be mapped onto the audio word for word, so a
corrected final's `words` still describe `raw`. The field is omitted when the engine has no token
timings (the ONNX fallback, or a stream that fell back to windowed decoding), and an empty final has
`"words":[]`. Without the flag every message is byte-identical to the protocol before it; `POST
/v1/transcribe` never includes timings.

Version additions preserve existing fields. A breaking change becomes `/v2`.

## 4. Privacy and retention

- **Default: nothing is retained.** Audio and transcripts live only in memory for the length of the utterance.
  - They are never written to disk, logs, crash reports or temp files.
  - Logs contain only session ids, durations, byte counts, peak/RMS levels, timings and error codes.
  - A test asserts that a full session writes no files except the activity list below, and that the log contains no transcript text.
- **Device activity is metadata only, local and switchable.** `device-activity.json` (`0600`, beside the server state; 5000 events / 30 days, `[activity] keep = false` or the Mac switch deletes it) holds times, device ids, client and request kinds, style ids, durations, audio lengths and outcome codes; never text, audio, prompts, learned items, outlines, addresses, identities or tokens. Readable only with the owner token over direct loopback. See [Device activity](#device-activity-v1-compatible-addition).
- **Debug retention is opt-in, local only and loudly visible.**
  - Enable it with `chirp-server --debug-retain` or `[debug] retain = true` in `~/.config/chirp/server.toml`.
  - It writes `<session>.wav` plus a `<session>.json` transcript/timings file to `~/Library/Application Support/Chirp/debug/` (mode 0700/0600).
  - Files are purged after `retain_days` (default 3), on start and hourly. `chirp-server debug purge` deletes them all now.
  - `ready` and `health` report `debug_retention: true`. Both clients then show a persistent red "DEBUG: recordings kept" indicator, and the server logs a warning banner at start.
- **Notes structuring and reorganize are stateless and never retained.** `POST /v1/notes/structure` and `POST /v1/notes/reorganize` write no files, not even with debug retention, and their log lines carry only lengths, counts, flags, the error code and timings, never the transcript, notes, outline, prompt or Markdown. Segment audio follows the per-utterance rules above.
- **Speaker labels (Mac Live Notes) never leave the Mac, and are on by default.** Diarization runs in the ChirpMac process with CoreML (FluidAudio's streaming Sortformer). The preference is `stored ?? true`: only the user's own Turn off (or Remove) stores a value, and a one-time migration (`speakerLabelsDefault = 2`) clears an older stored `false`, which the app used to write itself when the model was missing. A missing or failed model is a model state (`SpeakerModelState`), never a preference change. The model downloads once from `https://huggingface.co` (the host is fixed in the app; FluidAudio's `REGISTRY_URL` environment override is ignored) at a pinned revision, into `~/Library/Application Support/FluidAudio/Models/sortformer`, and every file is checked against pinned SHA-256 hashes (a mismatch is deleted). With labels on and the model missing, the first labelled recording starts that download in the background with no prompt; Record never waits (text starts at once, the diarizer joins the running recording when the model is ready, and earlier audio stays unlabelled). The Notes window shows one status line (progress, or "couldn't download" with Retry) with Turn off, which cancels the download. Every other load runs FluidAudio in offline mode: a damaged model fails, shows Retry, and is re-downloaded only by that Retry, never fetched or purged silently. Settings › Notes removes the model, partial downloads included, and turns labels off. Third-party notices (FluidAudio's Apache-2.0 licence, the model's CC BY 4.0 attribution) ship in the app bundle and open from Settings › About.
  - The diarizer state, the speaker timeline and the voiceprints are memory-only and go with New, a discarded close or quit. The roster (Person N, the names you give, merges, turns reassigned by hand) and every label are saved with the note in the library (`note.json`, the same 0600 file as its text) and come back when the note is reopened. Audio is held only in Sortformer's rolling context (and a bounded 30 s queue). No embedding is written to disk, UserDefaults or logs, or sent anywhere.
  - Labels reach the server only as text: `Person 2: …` lines in the existing structuring request, and the labels the notes already hold in a reorganize request (only such requests get the speaker rule; every other prompt is unchanged), under the same rules as the transcript (off while health is unknown, per-host opt-in off the machine). `/v1/stream` is unchanged; the only addition there is the existing opt-in `word_timings`, asked for only while labels are on.
  - **Saved voices use the shared server library above (#247 item 3b).** Naming remembers by default while its server-wide switch is on. The first save explains this once; Don’t remember voices disables it server-wide. An unticked Remember voice keeps the name only in the note.
    - The Mac collects PCM16 from settled turns of at least 2 s, bounded to 30 s per diarizer slot and again per person after merges. It sends clips only to its configured server: remember at 20 s (a name given sooner waits in that note), identify at 10 s and again at 30 s if unmatched. Clips remain in memory; they never enter note files, journals, preferences, exports or structuring requests.
    - Matches automatically rename the person with ✓ and Not X. Rejecting restores Person N and blocks that saved voice for the person in this note, without changing the library. Late matches are fenced by server, note and speaker edits; one saved voice names at most one person per note.
    - Settings → Notes → Saved voices opens the server library with the shared switch, saved/updated dates, speech durations and compatibility status. Rename changes the library only. Forget and Forget all confirm; disabling offers to delete too. An older server hides Remember voice and shows the update explanation.
    - The app never loads or prompts for the old 8 MB CoreML voice model. It requests the server’s pinned speaker model on first clip use if needed. The old embedding code remains only for the agreement bench. Existing Keychain embeddings are imported after the measured ≥ 0.98 agreement, then deleted only after server acknowledgement; failed deletion retries from a content-free local acknowledgement marker. Voiceprints are never returned to the Mac and never logged.
  - Logs carry `notes labels speakers=N lag_ms=… tentative=…` only. Tests assert the log line's shape, that a full labelled session writes nothing under Application Support or Chirp's caches, and (against a local stand-in for the Hub) that only the consented download makes a request.
- **Saved voices on the server (#247) stay on the user's server.** Names and voiceprints are kept in one file, `voices.json` (0600, folder 0700) in the server's data folder, and never logged (`speakers voices action=remember code=ok`, `speakers voices count=N matched=N` only). Voiceprints are never returned to a client; the API lists names, seconds and dates. Nothing is sent outside the user's machines. A clip sent to remember or identify a voice is held only for the request; per-note centroids stay in the bounded in-memory session cache. The server-wide "Remember voices" switch stops saving and recognising; Forget and Forget all delete. Tests check the logs for names, ids, sessions and voiceprint digits, and that the only file written is `voices.json` (and its lock).
- **Correction is off by default.** When it is enabled with a non-loopback `base_url`, health reports `correction_leaves_machine: true`, and clients label the toggle "sends text to <host>". Audio never leaves your computer. Only the final text does, and only when correction is on.
- **Secrets:**
  - Owner token: `~/.config/chirp/owner-token`, 0600, generated on first run; read by the Mac app on the server machine for device activity, never put in a pairing link and accepted by no other endpoint.
  - Server token: `~/.config/chirp/token`, 0600, generated on first run. `chirp-server pair` prints it as a `chirp://pair?url=…&token=…` QR code and string, shown locally in the terminal only.
  - LLM API key: Keychain or an env var, never in the repo.
  - Android: the token is encrypted with an Android Keystore AES key.
  - Mac client: it reads the token file.

## 5. Permissions and platform constraints

**Mac:**
- Hardware: the Mac mini has **no built-in mic**. The USB BOYA CM40 is the default input. The client follows the system default input and shows the device name in the menu.
- TCC permissions:
  - Microphone (`NSMicrophoneUsageDescription`)
  - Accessibility, for AX insertion and posting ⌘V
  - The hotkey uses a Carbon hot key through KeyboardShortcuts, so it needs no Input Monitoring.
- Signing: Command Line Tools only, so no Xcode. `mac/scripts/bundle.sh` builds with SwiftPM, assembles `Chirp.app` (`LSUIElement`) and signs it with a **stable local self-signed identity** ("Chirp Local Dev", created by `mac/scripts/make-cert.sh`). TCC grants then survive rebuilds; an ad-hoc signature would lose them each time. If the certificate is missing, it falls back to ad-hoc signing.
- Insertion order:
  1. AX: set `kAXSelectedTextAttribute` on the focused element and verify that the value changed.
  2. Paste: save the pasteboard, write the text plus the `org.nspasteboard.TransientType` marker, post ⌘V, restore the pasteboard after about 250 ms.
  3. Copy only, with a HUD toast "Copied — press ⌘V".
- Secure input fields: when `IsSecureEventInputEnabled()` is true, dictation refuses to insert anything.

**Android (Galaxy Z Fold 8, One UI / Android 16+):**
- Permissions: `RECORD_AUDIO` and `INTERNET`. An IME cannot show a permission dialog, so the companion `SetupActivity` requests the mic and walks the user through *Settings → General management → Keyboard list → Chirp* and enabling the IME.
- The mic is only opened while the IME window is visible and the user has started dictation. It is released on stop, `onFinishInputView` and `onWindowHidden`. There is no foreground service and no wake lock.
- The user switches to Chirp from the keyboard picker (the navigation-bar keyboard icon) or through the `voice` subtype. The Chirp view offers "⌨ back" (`switchToPreviousInputMethod`).
- Fold specifics: the cover and inner screens differ in width, and configuration changes must not drop an active utterance. The layout is a single large mic button with a partial-text strip, so it works at both widths.
- The phone needs the Tailscale Android app connected. Chirp uses `https://<computer>.<tailnet>.ts.net/chirp`, which resolves through MagicDNS on the tailnet.

## 6. Interaction model (Koi parity)

- **Auto-stop or hold to talk (Mac).** Auto-stop: a press starts, a pause (or the next press) stops. Hold to talk: talk while held, release finishes; a press shorter than 300 ms is dropped. Right ⌥ (the default) does both in auto-stop: a tap toggles, a hold talks until let go. Esc on Mac, or ✕ on Android, cancels and inserts nothing. **Keep listening until I stop** (#381, every platform, off by default) overrides the pause, the no-speech timeout, the 10-minute ceiling and digital silence after the microphone has carried sound: only an explicit stop ends it.
- **Live text while speaking:**
  - Mac: a non-activating floating HUD at the bottom centre of the screen shows the partial text and a level meter.
  - Android: partials are shown as **composing text** (underlined) in the target field, via `setComposingText`. The final replaces them with `commitText`.
- Short start and stop cues, off by default.
- Silence guard: if peak/RMS stays at zero for 1.5 s, the client shows "No microphone signal" and sends nothing, the same as Koi.
- Undo: after a corrected final, the Mac HUD offers a 5 s "Use raw". Android shows a chip on the strip.
- **Live Notes (every client).** On the Mac, ⌃⌥N (or the menu) starts a long session with the microphone open the whole time, shown in a Notes window rather than the HUD; the Android, iPhone/iPad and Windows/Linux desktop apps have a notes library with a Record button and use the same endpoints. The details below were written for the Mac, the reference client.
  - **Rolling segments.** The client cuts the audio into ordinary `/v1/stream` utterances of at most 45 s (never before 12 s; at a 0.6 s pause, 0.3 s after 30 s), so each segment's clean-up stays short and inside its budget. At a cut it opens the next socket and routes capture to it first, then sends `stop` on the old one, which finalizes and corrects in the background. No audio is dropped, the protocol is unchanged, and the 120 s cap and 60 s idle timeout never apply to the session as a whole. Each segment uses the hidden `live_notes` style when health has `notes_correction` (fillers, stutters and restarts removed under its own guard; the user's edited dictation prompt does not apply), otherwise the `default` style plus the user's edited default prompt.
  - **One editable document, an AI-owned tail.** The notes are one Markdown source string (`NotesDocument.text`) that the user can edit at any time. The AI owns only a suffix, the tail (`text[tailStart...]`): an append pass only ever replaces the tail, so nothing before `tailStart` is touched. An edit wholly before the tail shifts `tailStart`; an edit that touches a non-empty tail *claims* it — the whole tail becomes user text, the window moves past the segments it covered (they are never re-sent) and a `windowGeneration` bump makes any pass in flight for the old tail stale. Typing at the end with an empty tail stays the user's, and so does an insertion right before the tail's separator newline (the end of the user's own last line): it shifts `tailStart` instead of claiming. Every AI mutation returns the `NotesTextChange` it made; the Mac editor replays exactly that delta onto its `NSTextStorage` as one undo group and checks the result matches the model. Live partials and unstructured speech are never in the text: they show in a separate "Hearing" strip.
  - **Structuring.** After a segment's final (at most every 15 s, never while a segment of the session is still correcting) the client posts the open window's corrected text and the settled text's headings to `POST /v1/notes/structure`, and the answer replaces the tail. Once a window passes 1600 characters the tail settles (it becomes ordinary text) and a new window starts, so every pass is bounded. A window the server *rejects* is structured again in halves at a sentence end, then quarters (min 400 characters); the parts are appended in order and the tail settles, and only a part that still fails becomes a "Not structured" section. Otherwise a window past 3600 characters, or past 1600 after two failed passes (timeouts, busy), is appended as an ordinary, editable "Not structured" section. If the caret is in the tail while the user is typing (or an input method is composing), the newest answer is held until the caret leaves, focus leaves or 10 s pass without a keystroke. Stop waits for the last final, runs one `final` pass and settles everything. With correction off or an older server, Notes is a live transcript and a plain editor.
  - **Reorganize and the shared pass slot.** `POST /v1/notes/reorganize` rewrites the longest suffix of whole sections within 3500 characters (earlier headings go along as context only). Append and reorganize share one client pass slot (and the server's `structuring` lock), so they never overlap and only the user can change the text while a reorganize runs; append wins when both are due. Auto-reorganize runs after ≥ 1200 inserted characters, ≥ 180 s since the last one and 15 s without typing, but while recording only within 5 s of a segment commit and on at most the trailing 1200 characters of whole sections (a segment clean-up queued at the next cut preempts it; the server answers `error: "preempted"`, which the client treats as not run: no note, no backoff, retry after the next commit). Stop runs one full-scope pass unless one ended under 30 s ago on the same text. The Organize button skips the thresholds: it first re-structures the pending window and every fallback block the user has not edited (tracked verbatim; replaced in place as one version-checked undo group), then reorganizes the full scope. A result is applied only if `version` is unchanged since the request; otherwise it is discarded (auto retries after 60 s; a manual one says the notes changed). An applied reorganize settles everything and is one undo step. A 404 hides only reorganize.
  - **Mutual exclusion.** Notes holds the engine lease almost continuously, so on the Mac Notes and dictation exclude each other: the dictation hotkey shows "Notes is recording — stop it to dictate" and Start Dictation is disabled while Notes records; Notes cannot start mid-dictation. Phone clients may see `busy` meanwhile. Pausing Chirp stops Notes and keeps the notes.
  - There is no Save step. Every note is a document in a local library on the device that recorded it (the Mac under `~/Library/Application Support/Chirp/Notes/<uuid>/note.json`, `0600` in a `0700` folder; sealed on Android and iOS), written atomically and flushed at segment commits, AI changes and Stop, so a crash or power loss shows the note as Recovered instead of losing it. Notes stay until you delete them (Recently Deleted keeps them 30 days); Export Markdown writes a separate copy. See §4.

## 7. Measurement plan

The numbers live in `docs/bench.md` and are regenerated by scripts. Nothing is claimed without them.

- **Server engine bench (`server/scripts/bench.py`):**
  - Input: a fixed set of `say`-generated and recorded English WAVs (5 s, 15 s, 60 s), plus LibriSpeech test-clean samples if they are downloaded locally.
  - Per engine: load time, warm RTFx, WER vs reference, peak RSS.
  - Streaming: time from audio-in to first partial, partial cadence, and time from stop to final.
- **End-to-end latency:**
  - Mac: `chirp-mac --selftest` plays a WAV through the protocol and logs the time from stop to inserted text.
  - Android: the IME logs the time from stop to `commitText`, plus round-trip time. Both are shown in debug overlay only, never with the text.
- **Battery (Fold 8):**
  1. `adb shell dumpsys batterystats --reset`.
  2. A scripted session of 10 utterances of 10 s each, over Wi-Fi and then over LTE.
  3. `adb shell dumpsys batterystats --charged <pkg>` and a Perfetto trace with power rails where Samsung exposes them.
  4. Report mAh per minute of dictation, and the idle drain with the keyboard shown but not recording, which should be ~0 because the mic and socket are closed.
  - If radio time dominates, add Opus framing (`encoding:"opus"`, MediaCodec) as v1.1. PCM at 16 kHz is 256 kbps, which is acceptable on the tailnet for v1.

## 8. Model acquisition and tests

- The default model is reused from `~/.koi/voice-models/parakeet-mlx`, with `config.json` checked for Parakeet TDT v2. Otherwise `chirp-server model fetch` downloads `mlx-community/parakeet-tdt-0.6b-v2` into `~/Library/Application Support/Chirp/models/` with a pinned revision.
- Unit tests use a fake engine. Integration tests (marked `@pytest.mark.model`) run the real model on `say`-generated WAVs and assert on keywords, not exact text.

## 9. Repo layout

```
server/   Python package chirp_server (uv project), tests, scripts/bench.py
mac/      SwiftPM package ChirpMac + scripts/bundle.sh, make-cert.sh
android/  Gradle project (app = IME + SetupActivity), Gradle wrapper
docs/     architecture.md, protocol (section 3), bench.md, milestones/, TESTING.md
```

## 10. Branching

- `main` holds only operator-approved merges.
- `chirp/integration` is the orchestrator's integration branch.
- Each worker works on `chirp/<track>` stacked on `chirp/integration`.
- There is no remote, so no pushes and no PRs. The orchestrator reviews `git diff chirp/integration...chirp/<track>` and merges into integration. Merging into `main` waits for the operator's approval.
