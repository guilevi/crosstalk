# crosstalk

Speech for Windows programs running under CrossOver/Wine on macOS, by
pretending to be NVDA inside the bottle. Mods and games that talk to NVDA
(directly, through Tolk, or through Prism) work unmodified and speak with
macOS voices, as long as Crosstalk is running.

It copies only what such programs talk to, not NVDA itself: nothing here reads
the screen.

## Pieces

```
Windows program (game, mod)
  ├─ nvdaControllerClient.dll ── ncalrpc NvdaCtlr.* ──▶ nvda.exe ──┐
  │    (directly, via Tolk, or via Prism's NVDA backend)            │ loopback TCP
  └─ UiaRaiseNotificationEvent ──▶ uiautomationcore.dll proxy ──────┤ 127.0.0.1:47655
                                                                    ▼
                                                   Crosstalk.app (AVSpeechSynthesizer)
```

- **`Crosstalk.app`** (`app/`, `daemon/`): menu-bar app holding the one speech
  queue every bottle feeds. Settings for language, voice, rate, volume and
  pitch; stops speech when Control is pressed, in any app; shows recent speech.
  `build/crosstalkd` is the same server without UI.
- **`nvda.exe`** (`wine/nvda/`): stand-in NVDA, run in each bottle. Serves the
  NVDA controller RPC interfaces (1 to 3, so every controller client from
  2012 to 2026.3 works) on NVDA's endpoint names, owns a hidden
  `wxWindowClassNR` / `NVDA` window (Tolk and others check for it), and sets
  the system screen-reader flag, all as NVDA does.
- **`uiautomationcore.dll`** (`wine/uia/`): a proxy installed over Wine's,
  forwarding everything to Wine's own copy (installed as
  `crosstalk_wineuia.dll`) except:
  - `UiaRaiseNotificationEvent`, plus live-region and system-alert
    `UiaRaiseAutomationEvent`s: their text goes to Crosstalk. Wine's own
    version is a stub that drops them, with no path between processes;
  - `UiaClientsAreListening`: true while the stand-in NVDA runs;
  - in-process fixes for Wine's stubbed `RpcMgmtInqIfIds` and
    `RpcIfIdVectorFree`. Prism calls these before trusting NVDA, so without the
    fix its NVDA backend can never start under Wine. Prism imports
    uiautomationcore, so the proxy is already in every process that loads
    Prism.

## Why both routes

Under Wine, Prism (0.18.2 and current) rejects NVDA because of the RPC stubs
above, and falls back to UIA notifications. Those need a window owned by the
calling process, which windowless speech hosts don't have. With the RPC fix
Prism picks NVDA everywhere; the UIA route covers UIA-only programs, and Prism
if NVDA is ever unavailable.

## Speech semantics

| Caller does | Crosstalk does |
|---|---|
| `nvdaController_speakText` | queue, as NVDA does |
| `nvdaController_cancelSpeech` (Tolk/Prism interrupt = cancel, then speak) | stop and drop queue |
| `speakSsml` priority NORMAL / NEXT / NOW | queue / after current / interrupt, then resume what was cut off |
| `speakSsml` synchronous | returns when spoken (SSML marks are not reported) |
| `isSpeaking` | true while anything is speaking or queued |
| UIA `NotificationProcessing_All` / `ImportantAll` | queue |
| UIA `MostRecent` / `ImportantMostRecent` | interrupt (empty text: just stop) |
| UIA `CurrentThenMostRecent` | finish current, replace the rest |
| Control key, anywhere (Crosstalk setting) | stop |

## Build and install

```sh
./build.sh                                   # needs Xcode CLT and mingw-w64
./install.sh /path/to/Bottle       # per bottle
./install.sh --uninstall /path/to/Bottle
```

`install.sh` puts Crosstalk.app in `~/Applications` and sets up the bottle:
`C:\Program Files\Crosstalk\nvda.exe`, the proxy in `system32` and `syswow64`
(Wine's originals backed up beside nvda.exe), and a `uiautomationcore`
native-then-builtin DLL override.
**Re-run it after a CrossOver update**, so the copy of Wine's
uiautomationcore the proxy forwards to matches the new Wine.

Crosstalk registers itself to open at login, and starts `nvda.exe` in any
bottle that has it installed as soon as that bottle boots. It watches for the
bottle's wineserver, because CrossOver doesn't reliably run a bottle's Run
keys. If a bottle boots first, its `nvda.exe` opens Crosstalk in the
background.

macOS will ask, once each:
- **Removable volume access** for Crosstalk, when bottles live on an external
  drive. Without it the watcher can't see those bottles.
- **Accessibility**, for stopping speech with Control while other apps are in
  front.

Don't run real NVDA in a bottle at the same time: both would claim the same
endpoint.

## Protocol

Line-based over 127.0.0.1:47655 (`CROSSTALK_PORT` overrides it on both
sides), documented at the top of `daemon/Server.swift`. For example:

```sh
printf 'HISTORY 20\n' | nc 127.0.0.1 47655
printf 'RATE 65\nVOICE\n' | nc 127.0.0.1 47655
```

## Tests

```sh
python3 tests/daemon_test.py                         # queue semantics, Crosstalk running
python3 tests/run_tests.py /path/to/Bottle # end to end in a bottle
```

`run_tests.py` drives real client libraries in the bottle through
`tests/ct_test.c`: NVDA 2026.3's controller client (x64 and x86), raw UIA
notifications (x64 and x86), and any NVDA controller clients, Tolk or Prism
builds you put in the bottle's `C:\crosstalk-test\clients` folder (layout at
the top of `run_tests.py`). It checks in
Crosstalk's history that queued lines finish in order, interrupts cut off,
and stops silence.

## Licence

`wine/nvda/nvdaController.idl` comes from NVDA (LGPL 2.1), with the one
`[callback]` procedure removed because widl can't generate it; it is the
interface's last procedure, so the others keep their numbers.
