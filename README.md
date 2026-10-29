# crosstalk

Speech for Windows programs running under CrossOver/Wine on macOS, by
pretending to be NVDA running inside the bottle. Programs that talk directly to NVDA
(also tested with Prism and Tolk) work unmodified and speak with
macOS voices, as long as Crosstalk is running.

Crosstalk only mirrors the parts of NVDA that matter for programs and games that talk directly to it through the controller client or UIA messages. It doesn't do any work to actually read the screen.

## Why?

Quite simply, because I only have a Macbook and I want to be able to play games on Crossover. Unmodified NVDA will run and works with most games that talk to it, but it requires some setup if you don't want Espeak and likes to cause strange issues with focus. Games take forever to recover focus when cmd+tabbed into, if they use UIA they sometimes stop working entirely with no explanation, etc.

Crosstalk does nothing to let you access Windows UI controls, so games that show actual dialogs will still be an issue, but it does stand in for NVDA in the ways that matter to 99% of the use cases I needed to cover.

## Pieces

A Windows program reaches Crosstalk by one of two routes:

1. **NVDA controller:** the program, or a speech library it uses like Prism or Tolk, calls `nvdaControllerClient.dll`. The DLL talks over
   ncalrpc (`NvdaCtlr.*` endpoints) to `nvda.exe`, which passes the speech onward.
2. **UI Automation:** the program calls `UiaRaiseNotificationEvent`, which Crosstalk's
   `uiautomationcore.dll` proxy catches and passes on.

Both pass speech back to Mac OS over loopback TCP on 127.0.0.1:47655 to `Crosstalk.app`,
which speaks it with AVSpeechSynthesizer.

- **`Crosstalk.app`** (`app/`, `daemon/`): a menu-bar app holding the speech
  queue. It also gives the user a settings interface for language, voice, rate, volume and
  pitch and, if the accessibility permission is granted through Mac OS, stops speech when Control is pressed anywhere. It also shows speech history in a table for review.
  `build/crosstalkd` is the same server without UI.
- **`nvda.exe`** (`wine/nvda/`): stand-in NVDA, which is run in each Wine/CX bottle. Serves the
  NVDA controller RPC interfaces (1 to 3, so every controller client from
  2012 to 2026.3 works) on NVDA's endpoint names, owns a hidden
  `wxWindowClassNR` / `NVDA` window (Tolk and others check for it), and sets
  the system screen-reader flag.
- **`uiautomationcore.dll`** (`wine/uia/`): a proxy installed over Wine's,
  which forwards everything to Wine's own copy (installed as
  `crosstalk_wineuia.dll`) except:
  - `UiaRaiseNotificationEvent`, plus live-region and system-alert
    `UiaRaiseAutomationEvent`s, which pass text onto Crosstalk. Wine's own
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

## Install

Download `Crosstalk.zip` from the [latest release](https://github.com/guilevi/crosstalk/releases/latest), unzip it, put Crosstalk.app in Applications and open it. It runs on macOS 14 or later, on Apple Silicon and Intel. You'll have to go through the typical steps of running an unnotarized app.

The settings window will automatically find and list all the bottles that your install of Crossover knows about. You can switch Crosstalk on for each bottle you
want it in, or press **Choose Another Bottle** to browse for a non-Crossover bottle.

Every time there is a Crossover or Crosstalk update, you will need to update each bottle's version of the Crosstalk files. You'll see an update button next to a bottle's switch if it needs it.

Switching a bottle on sets up `C:\Program Files\Crosstalk\nvda.exe`, the
UIA proxy in `system32` and `syswow64` (Wine's originals backed up beside
nvda.exe), and a `uiautomationcore` native-then-builtin DLL override.
Switching it off puts everything back.

## Build

```sh
./build.sh                                   # needs Xcode or command line tools and mingw-w64
./install.sh /path/to/Bottle                 # optional: the same as Settings does, from a terminal
./install.sh --uninstall /path/to/Bottle
```

`build/Crosstalk.app` carries the Windows parts and `app/bottle-setup.sh`,
which does the bottle setup for both Settings and `install.sh`. `install.sh`
also copies the app to `~/Applications`.

Crosstalk registers itself to open at login, and starts `nvda.exe` in any
bottle that has it installed as soon as that bottle boots. It watches for the
bottle's wineserver, because CrossOver doesn't seem to reliably run a bottle's Run
keys. If a bottle boots first, its `nvda.exe` opens Crosstalk on the Mac in the
background. The bottle also gets a **Crosstalk** launcher in CrossOver, to
start `nvda.exe` by hand.

Make sure to grant the removable volume permissions through Mac OS system settings if your bottles are on an external drive! Granting accessibility permissions will also allow you to stop speech with Control while other apps are in
  front.

Don't run real NVDA in a bottle at the same time: both would claim the same
endpoint.

## Protocol

Line-based over 127.0.0.1:47655 (`CROSSTALK_PORT` overrides it on both
sides), documented at the top of `daemon/Server.swift`. For example:

```sh
printf 'HISTORY 20\n' | nc 127.0.0.1 47655
printf 'RATE 65\nVOICE\n' | nc 127.0.0.1 47655
printf 'BOTTLES\n' | nc 127.0.0.1 47655    # running bottles and whether Crosstalk can reach them
```

## Tests

```sh
python3 tests/daemon_test.py                         # queue semantics, Crosstalk running
python3 tests/run_tests.py /path/to/bottle # end to end tests in a bottle
```

`run_tests.py` drives real client libraries in the bottle through
`tests/ct_test.c`: NVDA 2026.3's controller client (x64 and x86), raw UIA
notifications (x64 and x86), and any NVDA controller clients, Tolk or Prism
builds you put in the bottle's `C:\crosstalk-test\clients` folder (layout at
the top of `run_tests.py`). It checks in
Crosstalk's history that queued lines finish in order, interrupts cut off,
and stops silence.

## License

MIT (see `LICENSE`), except that `wine/nvda/nvdaController.idl` comes from NVDA (LGPL 2.1), with the one
`[callback]` procedure removed because widl can't generate it; it is the
interface's last procedure, so the others keep their numbers.

## Thanks

Massive thanks to the [Prism](https://github.com/ethindp/prism) and [Tolk](https://github.com/dkager/tolk) abstraction libraries, which have been used by so many projects and I heavily relied on for testing Crosstalk.
