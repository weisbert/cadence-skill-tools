"""A synthetic PDK tree shaped like the one rk_pdk's rules expect (tests and
the VM panel smoke). Generic names only.

    <root>/setup/assura_tech.lib                       $SETUP_ROOT
    <root>/setup/tech/demo_tech/techfile.tf            $PDK_TECH_FILE  -> tech_name demo_tech
    <root>/setup/tech/demo_tech/layermap.txt           $PDK_LAYER_MAP_FILE
    <root>/verify/runset/Calibre_LVS/LVS/Ver_A/DEMO_LVS_R1/
        DEMO_LVS_R1.wodio.qcilvs  DEMO_LVS_R1.widio.qcilvs  empty.cdl
                                                       $calibre_source_added_place = .../empty.cdl
    <root>/verify/runset/Calibre_QRC/QRC/Ver_B/DEMO_QRC_R<n>/QCI_deck/
        query_cmd  preserveCellList.txt                $VERIFY_ROOT = <root>/verify

Usage: python fake_pdk.py <root> [--qrc-decks N] [--csh]
       prints the environment as JSON (or csh setenv lines with --csh).
"""

import json
import os
import sys


def _touch(path, text=""):
    d = os.path.dirname(path)
    if not os.path.isdir(d):
        os.makedirs(d)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)


def make_fake_pdk(root, qrc_decks=1, variants=("wodio", "widio")):
    root = root.replace("\\", "/").rstrip("/")
    setup = root + "/setup"
    tech = setup + "/tech/demo_tech"
    _touch(setup + "/assura_tech.lib", "; fake tech library\n")
    _touch(tech + "/techfile.tf", "; fake techfile\n")
    _touch(tech + "/layermap.txt", "# fake layer map\n")
    lvs = root + "/verify/runset/Calibre_LVS/LVS/Ver_A/DEMO_LVS_R1"
    for v in variants:
        _touch("%s/DEMO_LVS_R1.%s.qcilvs" % (lvs, v), "// fake rules %s\n" % v)
        _touch("%s/DEMO_LVS_R1.%s.lvs" % (lvs, v), "// fake rules %s\n" % v)
    _touch(lvs + "/empty.cdl", "* fake CDL prelude\n")
    for n in range(1, qrc_decks + 1):
        q = "%s/verify/runset/Calibre_QRC/QRC/Ver_B/DEMO_QRC_R%d/QCI_deck" % (root, n)
        _touch(q + "/query_cmd", "# fake query cmd\n")
        _touch(q + "/preserveCellList.txt", "")
    return {
        "SETUP_ROOT": setup,
        "VERIFY_ROOT": root + "/verify",
        "PDK_TECH_FILE": tech + "/techfile.tf",
        "PDK_LAYER_MAP_FILE": tech + "/layermap.txt",
        "calibre_source_added_place": lvs + "/empty.cdl",
    }


if __name__ == "__main__":
    args = sys.argv[1:]
    if not args:
        sys.exit(__doc__)
    n = 1
    if "--qrc-decks" in args:
        n = int(args[args.index("--qrc-decks") + 1])
    env = make_fake_pdk(os.path.abspath(args[0]), qrc_decks=n)
    if "--csh" in args:
        for k, v in env.items():
            print("setenv %s %s" % (k, v))
    else:
        print(json.dumps(env, indent=2))
