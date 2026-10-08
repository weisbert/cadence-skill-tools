#!/usr/bin/env python3
"""Run relkit SKILL smoke tests in the live Virtuoso via skillbridge.

    python3 relkit/tests/run_skill_test.py relkit/tests/test_scaffold_smoke.il [...]

Loads relkit/relkit.il, tests/rk_testlib.il, then each test file, and prints
rkTestReport(). Exit 0 only if every report says PASS. Uses one-line
evalstring probes only (multi-line evalstring swallows errors). Never displays
forms (a displayed form blocks the bridge evaluator).

Bridge: the skillbridge server id in $SB_ID (default "default"), so a
private Virtuoso can be used.

Needs the skillbridge Python package: either importable already or found in
<skill_tools>/skillbridge (set SKILLBRIDGE_PATH to override).
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
RELKIT = os.path.dirname(HERE)
SKILL_TOOLS = os.path.dirname(RELKIT)

for p in (os.environ.get("SKILLBRIDGE_PATH"), os.path.join(SKILL_TOOLS, "skillbridge")):
    if p and os.path.isdir(p) and p not in sys.path:
        sys.path.insert(0, p)

from skillbridge import Workspace  # noqa: E402


def q(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


# skillbridge's server reports a call as failed whenever errset.errset is set
# afterwards -- and that property keeps the LAST error caught by ANY inner
# errset, even one the code handled on purpose. So every call clears it
# (putprop 'errset nil 'errset) before returning its value.
def load(ws, path):
    r = ws["evalstring"](
        '(let ((rkR (sprintf nil "%%L" (errset (load %s) t)))) (putprop (quote errset) nil (quote errset)) rkR)'
        % q(path))
    if r != "(t)":
        raise RuntimeError("load %s failed: %s" % (path, r))


def main(argv):
    if not argv:
        print(__doc__)
        return 2
    ws = Workspace.open(os.environ.get("SB_ID") or None)  # SB_ID: private bridge id
    load(ws, os.path.join(RELKIT, "relkit.il"))
    load(ws, os.path.join(HERE, "rk_testlib.il"))
    ok = True
    for t in argv:
        path = os.path.abspath(t)
        try:
            load(ws, path)
            rep = ws["evalstring"](
                "(let ((rkR (rkTestReport))) (putprop (quote errset) nil (quote errset)) rkR)")
        except Exception as e:  # noqa: BLE001
            rep = "%s: ERROR %s" % (os.path.basename(t), e)
        print(rep)
        ok = ok and (": PASS " in rep)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
