#!/usr/bin/env python3
"""Exercises crosstalkd's queue semantics over its socket protocol.

Run with the daemon already listening. Speech is audible; texts are short.
"""
import base64
import os
import socket
import sys
import time

PORT = int(os.environ.get("CROSSTALK_PORT", "47655"))


class Client:
    def __init__(self, source):
        self.s = socket.create_connection(("127.0.0.1", PORT), timeout=30)
        self.f = self.s.makefile("rwb")
        self.cmd(f"SOURCE {source}")

    def cmd(self, line):
        self.f.write((line + "\n").encode())
        self.f.flush()
        reply = self.f.readline().decode().rstrip("\n")
        if not reply.startswith("OK"):
            raise RuntimeError(f"{line!r} -> {reply!r}")
        return reply[3:]

    def lines(self, line):
        n = int(self.cmd(line))
        return [self.f.readline().decode().rstrip("\n") for _ in range(n)]

    def speak(self, text, mode=0):
        return int(self.cmd(f"SPEAK {mode} {base64.b64encode(text.encode()).decode()}"))


def events(c, ids):
    """(event, id) pairs from history for the given utterance ids, in order."""
    out = []
    for l in c.lines("HISTORY 200"):
        ev, i, _src, _text = l.split("\t", 3)
        if int(i) in ids:
            out.append((ev, int(i)))
    return out


def check(name, cond):
    print(("PASS " if cond else "FAIL ") + name)
    if not cond:
        global failed
        failed = True


failed = False
c = Client("daemon_test")
c.cmd("STOP")

# Queue: both spoken, in order.
a = c.speak("first")
b = c.speak("second")
check("wait returns done", c.cmd(f"WAIT {b} 15000") == "done")
ev = events(c, {a, b})
check("queue order", [e for e in ev if e[0] == "done"] == [("done", a), ("done", b)])

# Interrupt: the long one is cancelled, the short one finishes.
a = c.speak("this is a long sentence that should be cut off by the next one")
time.sleep(0.5)
b = c.speak("interrupted", 1)
check("interrupt: new finishes", c.cmd(f"WAIT {b} 15000") == "done")
check("interrupt: old cancelled", c.cmd(f"WAIT {a} 100") == "cancelled")
ev = events(c, {b})
check("interrupt: new actually started", ("start", b) in ev)

# Interrupt while several are queued: all queued are dropped.
ids = [c.speak(f"queued {i}") for i in range(3)]
b = c.speak("only this", 1)
c.cmd(f"WAIT {b} 15000")
check("interrupt drops queue", all(c.cmd(f"WAIT {i} 100") == "cancelled" for i in ids))

# NOW priority: speaks first, interrupted utterance resumes afterwards.
a = c.speak("normal priority speech that gets interrupted")
time.sleep(0.4)
n = c.speak("urgent", 2)
check("now: interrupted one still completes", c.cmd(f"WAIT {a} 20000") == "done")
ev = events(c, {a, n})
starts = [e for e in ev if e[0] == "start"]
check("now: order is a, urgent, a again", starts == [("start", a), ("start", n), ("start", a)])

# STOP and SPEAKING.
c.speak("stop me please, this is long enough to still be talking")
time.sleep(0.3)
check("speaking while talking", c.cmd("SPEAKING") == "1")
c.cmd("STOP")
check("not speaking after stop", c.cmd("SPEAKING") == "0")

# Empty interrupt utterance acts as a stop (UIA convention).
a = c.speak("another long sentence to be silenced by an empty notification")
time.sleep(0.3)
e = c.speak("", 1)
check("empty interrupt cancels", c.cmd(f"WAIT {a} 100") == "cancelled")
check("empty finishes", c.cmd(f"WAIT {e} 2000") == "done")

sys.exit(1 if failed else 0)
