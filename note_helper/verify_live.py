#!/usr/bin/env python3
"""verify_live.py -- live smoke test for note-helper over skillbridge.

Run this with Virtuoso up and its skillbridge server responding. It:
  1. loads note_helper.il into the running Virtuoso,
  2. exercises nhParseText + nh_buildIR (pure-logic path, no cellview needed),
  3. if a schematic edit cellview is open, emits a sample table into it and
     reports the primitive count.

Usage:
    python3 note_helper/verify_live.py

If the bridge is wedged (calls hang), re-load skillbridge/sbStart.il in the
CIW first, or restart pyStartServer. See REQUIREMENTS.md §14.
"""

import os
import sys

NOTE_HELPER_IL = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                              "note_helper.il")

SAMPLE = "|Net|Val|Unit|\n|:--|--:|:-:|\n|Vdd|3.3|V|\n|Gnd|0|V|"


def main():
    try:
        from skillbridge import Workspace
    except Exception as e:
        sys.exit("skillbridge not importable: %s" % e)

    ws = Workspace.open()

    # 0. liveness
    print("plus(1,1) =", ws["plus"](1, 1))

    # 1. load the plugin
    print("loading note_helper.il ...")
    ws["load"](NOTE_HELPER_IL)

    # 2. parse + layout (no cellview required)
    table = ws["nhParseText"](SAMPLE)
    print("parsed table ->", table)
    ir = ws["nh_buildIR"](table, None)
    print("IR element count =", len(ir) if ir else 0)

    # 3. emit into the current edit cellview if one is open
    cv = ws["geGetEditCellView"]()
    if cv:
        cvtype = ws["dbGet"](cv, "cellViewType")
        print("edit cellview:", ws["dbGet"](cv, "cellName"), "type", cvtype)
        if cvtype in ("schematic", "schematicSymbol", "symbol"):
            n = ws["nhEmitTableAt"](SAMPLE, cv, [0, 0], None)
            print("emitted", n, "note primitives at origin. Check the canvas.")
        else:
            print("edit cellview is not a schematic/symbol; skipping emit.")
    else:
        print("no edit cellview open; skipping the emit test. "
              "Open a schematic and re-run to test placement.")

    print("OK")


if __name__ == "__main__":
    main()
