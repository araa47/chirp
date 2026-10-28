#!/usr/bin/env python3
"""Disposable real-model server with content-free stop-order observations. Configurable throwaway port."""
import argparse
import asyncio
import json
import shutil
import time
from pathlib import Path
import uvicorn
from chirp_server import speakers_model
from chirp_server.speakers import SpeakerLabels
from chirp_server.app import create_app
from chirp_server.config import Settings

parser = argparse.ArgumentParser()
parser.add_argument('--model-dir', type=Path, required=True)
parser.add_argument('--metadata', type=Path, required=True)
parser.add_argument('--speaker-model', type=Path)
parser.add_argument('--speaker-model-gate', type=Path)
parser.add_argument('--cert')
parser.add_argument('--key')
parser.add_argument('--server-port', type=int, default=7899)
# Seconds each `ready` is held back: the Notes check makes it long enough that audio waits past 5 s before Ready.
parser.add_argument('--ready-delay', type=float, default=2)
args = parser.parse_args()
settings = Settings.read()
settings.model_dir = args.model_dir
# The notes flow asks for the model with its first note but only releases it in its last phase, minutes later;
# a shorter wait would leave the app on a failed download by then.
GATE_SECONDS = 3600


def install_speaker_model():
    # Exercise the authenticated automatic download, without network or the operator's model cache.
    target = speakers_model.path()
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(args.speaker_model, target)
    if not speakers_model.verify(target):
        speakers_model.remove()
        raise ValueError("Synthetic fixture model checksum mismatch")
    return target


def fetch_speaker_model():
    deadline = time.monotonic() + GATE_SECONDS
    while not args.speaker_model_gate.exists():
        if time.monotonic() >= deadline:
            raise TimeoutError("Speaker fixture was not released")
        time.sleep(.1)
    return install_speaker_model()


class FixtureSpeakerLabels(SpeakerLabels):
    async def _fetch_model(self):
        # New servers support cancellable fetches; retain that behavior in the offline fixture.
        deadline = time.monotonic() + GATE_SECONDS
        while not args.speaker_model_gate.exists():
            if time.monotonic() >= deadline:
                raise TimeoutError("Speaker fixture was not released")
            await asyncio.sleep(.1)
        install_speaker_model()


app = create_app(settings, speakers=FixtureSpeakerLabels(fetch=fetch_speaker_model) if args.speaker_model else None)

notes = {}


async def observed(scope, receive, send):
    if scope['type'] == 'http' and scope['path'].startswith(('/v1/notes/', '/v1/speakers/')):
        # Content-free: only the endpoint and its status, for the Notes check.
        voice_action = None
        async def read_model():
            nonlocal voice_action
            event = await receive()
            if scope['path'].endswith('/speakers/voices') and event.get('body'):
                try: action = json.loads(event['body']).get('action')
                except (ValueError, AttributeError): action = None
                if action in ('remember', 'rename', 'forget', 'forget_all', 'enable', 'disable'):
                    voice_action = action
            if scope['path'].endswith('/speakers/model') and event.get('body'):
                try: action = json.loads(event['body']).get('action')
                except (ValueError, AttributeError): action = None
                if action in ('download', 'cancel', 'remove'):
                    notes.setdefault('model_actions', []).append(action)
            return event

        async def answer(event):
            if event['type'] == 'http.response.start':
                notes.setdefault(scope['path'].rsplit('/', 1)[-1], []).append(event['status'])
                if voice_action:
                    notes.setdefault('voice_actions', []).append({'action': voice_action, 'status': event['status']})
            if scope['path'].endswith('/speakers/model') and event.get('body'):
                try: state = json.loads(event['body']).get('state')
                except (ValueError, AttributeError): state = None
                if state in ('ready', 'downloading', 'not_downloaded', 'failed'):
                    notes['model_state'] = state
            if scope['path'].endswith('/speakers/voices') and event.get('body'):
                try: body = json.loads(event['body'])
                except ValueError: body = {}
                if body.get('code') in ('too_short', 'gone', 'disabled', 'full', 'no_voice', 'bad_speakers'):
                    notes.setdefault('voice_errors', []).append(body['code'])
                if isinstance(body.get('voices'), list):
                    notes['voice_count'] = len(body['voices'])
                    notes['voices_enabled'] = body.get('enabled') is True
            args.metadata.with_name('notes.json').write_text(json.dumps(notes))
            await send(event)
        return await app(scope, read_model, answer)
    state = {'frames': 0, 'partials': 0, 'stop': False, 'empty': False, 'correcting': False, 'error': None,
             'learned_terms': 0, 'learned_applied': False, 'corrected': False, 'correction_requested': False, 'started': False, 'retired': False}
    learned_terms = []  # In memory only, never written to metadata or logs.
    def save():
        args.metadata.write_text(json.dumps(state))
    async def read():
        event = await receive()
        if event.get('bytes'): state['frames'] += 1
        if event.get('text'):
            control = json.loads(event['text'])
            if control.get('type') == 'start':
                learned_terms[:] = control.get('learned', {}).get('terms', [])
                state['learned_terms'] = len(learned_terms)
                state['started'] = True
                state['correction_requested'] = control.get('correction', False)
                state['notes_stream'] = control.get('correction_profile') == 'live_notes'
                save()
            if control.get('type') == 'stop': state['stop'] = True; save()
        return event
    async def write(event):
        if scope['type'] == 'websocket' and event.get('text'):
            frame = json.loads(event['text'])
            kind = frame.get('type')
            # Makes a native immediate double tap deterministically precede Ready.
            # Only Notes has the enlarged pre-ready buffer being stressed by the six-second fixture.
            if kind == 'ready': await asyncio.sleep(args.ready_delay if state.get('notes_stream') else min(args.ready_delay, 2))
            if kind == 'partial': state['partials'] += 1
            if kind == 'correcting': state['correcting'] = True
            # Keep the real managed correction transition observable on a slow AVD.
            if kind == 'final' and state['correcting']: await asyncio.sleep(2)
            if kind == 'final':
                state['empty'] = not frame.get('text', '').strip()
                state['corrected'] = frame.get('corrected', False)
                state['correction_error'] = frame.get('correction_error')
                state['learned_applied'] = any(
                    term['term'] in frame.get('text', '') and any(heard.lower() in frame.get('raw', '').lower() for heard in term.get('heard', []))
                    for term in learned_terms)

            if kind == 'final' and not state['empty']:
                notes['finals'] = notes.get('finals', 0) + 1
                # Speaker labels: how many finals were labelled and which slots spoke (numbers, never text).
                labels = frame.get('speakers')
                if isinstance(labels, dict) and labels.get('turns'):
                    notes['labelled'] = notes.get('labelled', 0) + 1
                    notes['slots'] = sorted(set(notes.get('slots', [])) | {t['speaker'] for t in labels['turns']})
                    notes['matched'] = notes.get('matched', 0) + len(labels.get('matches', []))
                elif isinstance(labels, dict) and labels.get('error'):
                    notes['label_errors'] = notes.get('label_errors', []) + [labels['error']]
                args.metadata.with_name('notes.json').write_text(json.dumps(notes))
            if kind == 'error': state['error'] = frame.get('code')
        # Only the stream that started an utterance is the check's: health calls and idle prewarm sockets
        # must not overwrite its metadata between its last frame and the check reading it (#344).
        if state['started']: save()
        await send(event)
    try:
        await app(scope, read, write)
    finally:
        if state['started']:
            state['retired'] = True
            save()

uvicorn.run(observed, host='127.0.0.1', port=args.server_port, access_log=False, log_level='critical',
            ssl_certfile=args.cert, ssl_keyfile=args.key)
