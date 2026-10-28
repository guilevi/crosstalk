#!/usr/bin/env python3
r"""End-to-end tests: real screen-reader client libraries, in a real bottle,
speaking through crosstalk.

    tests/run_tests.py <bottle dir> [name-filter]

Needs crosstalk installed in the bottle (install.sh) and Crosstalk running.
Each case runs build/<arch>/ct_test.exe in the bottle, then reads crosstalkd's
history to check that the script was spoken as it would be by NVDA: the two
queued lines both finish in order, the long line is cut off by the
interrupting one, and the last line is silenced by stop.

NVDA 2026.3's controller client is downloaded. Any other client libraries
to test go in C:\crosstalk-test\clients in the bottle, one folder each, named
<kind>-<arch>[-<label>], for example:

    clients\nvda-x86-legacy\nvdaControllerClient32.dll
    clients\tolk-x64\Tolk.dll (with the nvdaControllerClient it ships)
    clients\prism-x64-0.18.2\prism.dll

Prism folders are also tested without a window.
"""
import os
import shutil
import socket
import subprocess
import sys
import urllib.request
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CX = "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine"
PORT = int(os.environ.get("CROSSTALK_PORT", "47655"))
NVDA_CLIENT_URL = "https://download.nvaccess.org/releases/2026.3/nvda_2026.3_controllerClient.zip"
TEST = r"C:\crosstalk-test"
CLIENTS = TEST + r"\clients"


def daemon(*lines):
    with socket.create_connection(("127.0.0.1", PORT), timeout=10) as s:
        f = s.makefile("rwb")
        out = []
        for line in lines:
            f.write((line + "\n").encode())
            f.flush()
            reply = f.readline().decode().rstrip("\n")
            out.append(reply)
            if line.startswith("HISTORY"):
                out.extend(f.readline().decode().rstrip("\n") for _ in range(int(reply.split()[1])))
        return out


def last_id():
    # The newest line can be about an older utterance (a cancellation), so
    # take the highest id seen rather than the last one.
    return max((int(l.split("\t")[1]) for l in daemon("HISTORY 400")[1:]), default=0)


def events_since(mark, tag):
    """[(event, text)] for utterances newer than mark whose text starts with tag."""
    out = []
    for line in daemon("HISTORY 400")[1:]:
        ev, i, _src, text = line.split("\t", 3)
        if int(i) > mark and text.startswith(tag):
            out.append((ev, text[len(tag):].strip()))
    return out


def check_script(ev):
    """Problems with how the standard ct_test script was spoken, if any."""
    def outcome(word):
        for e, t in ev:
            if t.startswith(word) and e in ("done", "cancelled"):
                return e
        return None

    problems = []
    want = {"alpha": "done", "bravo": "done", "a long": "cancelled", "charlie": "done", "delta": "cancelled"}
    for word, expected in want.items():
        got = outcome(word)
        if got != expected:
            problems.append(f"{word!r} {got or 'never spoken'}, expected {expected}")
    starts = [t.split()[0] for e, t in ev if e == "start"]
    if starts[:2] != ["alpha", "bravo"]:
        problems.append(f"queue order {starts[:2]}")
    return problems


def win_path(bottle, path):
    c = os.path.join(bottle, "drive_c")
    return "C:\\" + os.path.relpath(path, c).replace("/", "\\")


def unix_path(bottle, win):
    return os.path.join(bottle, "drive_c", *win[3:].split("\\"))


def run(bottle, exe, args, env=None):
    e = dict(os.environ, CX_BOTTLE_PATH=os.path.dirname(bottle), **(env or {}))
    cmd = [CX, "--bottle", os.path.basename(bottle), "--wait-children", "--", exe, *args]
    p = subprocess.run(cmd, env=e, capture_output=True, text=True, timeout=180)
    return "\n".join(l for l in (p.stdout + p.stderr).splitlines() if ":fixme:" not in l and l.strip())


def prepare(bottle):
    test = unix_path(bottle, TEST)
    for arch in ("x64", "x86"):
        os.makedirs(os.path.join(test, arch), exist_ok=True)
        shutil.copy(os.path.join(ROOT, "build", arch, "ct_test.exe"), os.path.join(test, arch))
        # A stray proxy beside the exe would shadow the installed one.
        try:
            os.remove(os.path.join(test, arch, "uiautomationcore.dll"))
        except FileNotFoundError:
            pass
    if not os.path.exists(os.path.join(test, "cc64", "nvdaControllerClient.dll")):
        tmp = os.path.join(test, "cc.zip")
        urllib.request.urlretrieve(NVDA_CLIENT_URL, tmp)
        with zipfile.ZipFile(tmp) as z:
            for arch, d in (("x64", "cc64"), ("x86", "cc32")):
                os.makedirs(os.path.join(test, d), exist_ok=True)
                with open(os.path.join(test, d, "nvdaControllerClient.dll"), "wb") as f:
                    f.write(z.read(f"{arch}/nvdaControllerClient.dll"))
        os.remove(tmp)
    os.makedirs(unix_path(bottle, CLIENTS), exist_ok=True)


def client_cases(bottle):
    """Cases for the folders in CLIENTS (see the top of this file)."""
    cases = []
    root = unix_path(bottle, CLIENTS)
    for d in sorted(os.listdir(root)):
        kind, _, rest = d.partition("-")
        arch = rest.split("-")[0]
        if arch not in ("x64", "x86"):
            continue
        where = CLIENTS + "\\" + d
        if kind == "nvda":
            dlls = [f for f in os.listdir(os.path.join(root, d)) if f.lower().startswith("nvdacontrollerclient")]
            if dlls:
                cases.append((d, arch, ["nvda", where + "\\" + dlls[0]], "[nvda]", "testIfRunning -> 0", None))
        elif kind == "tolk":
            cases.append((d, arch, ["tolk", where], "[tolk]", "screen reader: NVDA", None))
        elif kind == "prism":
            cases.append((d, arch, ["prism", where], "[prism]", "backend: NVDA", None))
            cases.append((d + " windowless", arch, ["prism", where], "[prism]", "backend: NVDA", {"CT_NOWINDOW": "1"}))
    return cases


CASES = [
    # name, arch, args, tag, expected stdout fragment, extra env
    ("nvda 2026.3 x64", "x64", ["nvda", TEST + r"\cc64\nvdaControllerClient.dll"], "[nvda]", "testIfRunning -> 0", None),
    ("nvda 2026.3 x86", "x86", ["nvda", TEST + r"\cc32\nvdaControllerClient.dll"], "[nvda]", "testIfRunning -> 0", None),
    # Prism (after 0.18.2) also wants the screen-reader flag before it uses UIA.
    ("uia screen-reader flag", "x64", ["uia"], "[uia]", "SPI_GETSCREENREADER -> 1", None),
    ("uia x64", "x64", ["uia"], "[uia]", "UiaClientsAreListening -> 1", None),
    ("uia x86", "x86", ["uia"], "[uia]", "UiaClientsAreListening -> 1", None),
]


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    bottle = os.path.abspath(sys.argv[1])
    only = sys.argv[2] if len(sys.argv) > 2 else ""
    daemon("PING")
    prepare(bottle)
    failed = 0
    for name, arch, args, tag, expect, env in CASES + client_cases(bottle):
        if only not in name:
            continue
        dll = args[1] if len(args) > 1 else None
        if dll and not os.path.exists(unix_path(bottle, dll)):
            print(f"SKIP {name}: {dll} not found")
            continue
        daemon("STOP")
        mark = last_id()
        out = run(bottle, f"{TEST}\\{arch}\\ct_test.exe", args, env)
        problems = [] if expect in out else [f"stdout lacks {expect!r}"]
        problems += check_script(events_since(mark, tag))
        if problems:
            failed += 1
            print(f"FAIL {name}: " + "; ".join(problems))
            print("     " + out.replace("\n", "\n     "))
        else:
            print(f"PASS {name}")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
