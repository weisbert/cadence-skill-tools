#!/usr/bin/env bash
# sync_vm.sh -- mirror relkit/ from this (Windows) clone to the dev VM's
# skill_tools checkout, and make sure the VM's skill_tools.il loads relkit.
#
#   bash relkit/tools/sync_vm.sh            # sync + patch umbrella line
#   bash relkit/tools/sync_vm.sh --no-patch # sync only
#
# Environment overrides:
#   RELKIT_VM_HOST  ssh host alias            (default: ewave-vm)
#   RELKIT_VM_DIR   skill_tools dir on the VM (default: the dev workarea's skill_tools)
#
# What it touches on the VM -- and nothing else:
#   * $RELKIT_VM_DIR/relkit/   replaced wholesale (staged as relkit.sync_new, then swapped)
#   * $RELKIT_VM_DIR/skill_tools.il  only the one relkit load line is inserted
#     (idempotent; the file is left alone when the line is already there)
# It never runs git on the VM.
set -euo pipefail

HOST="${RELKIT_VM_HOST:-ewave-vm}"
VM_DIR="${RELKIT_VM_DIR:-/home/yusheng/cadence_work/Test/workarea/skill_tools}"
PATCH=1
[ "${1:-}" = "--no-patch" ] && PATCH=0

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
[ -f "$REPO/relkit/relkit.il" ] || { echo "sync_vm: $REPO/relkit/relkit.il not found" >&2; exit 1; }

echo "sync_vm: $REPO/relkit -> $HOST:$VM_DIR/relkit"
tar -C "$REPO" --exclude=__pycache__ --exclude=.git -cf - relkit \
  | ssh "$HOST" "set -e
      cd '$VM_DIR'
      rm -rf relkit.sync_new && mkdir relkit.sync_new
      tar -C relkit.sync_new -xf -
      rm -rf relkit.sync_old
      if [ -d relkit ]; then mv relkit relkit.sync_old; fi
      mv relkit.sync_new/relkit relkit
      rm -rf relkit.sync_new relkit.sync_old
      find relkit -type f \\( -name '*.sh' -o -path '*/fake_tools/*' -o -path '*/fake_relstudio/*' -o -name 'relkit.py' \\) -exec chmod +x {} +"

if [ "$PATCH" = 1 ]; then
  ssh "$HOST" "python3 - '$VM_DIR/skill_tools.il'" <<'PYEOF'
import io, sys
p = sys.argv[1]
s = io.open(p, encoding="utf-8", newline="").read()
if 'relkit/relkit.il' in s:
    print("sync_vm: skill_tools.il already loads relkit (unchanged)")
    sys.exit(0)
old = '  (load (strcat r "verilog_helper/verilog_helper.il"))) ; plugin (calls mtRegister at end)'
new = ('  (load (strcat r "verilog_helper/verilog_helper.il"))  ; plugin (calls mtRegister at end)\n'
       '  (load (strcat r "relkit/relkit.il")))                 ; plugin (calls mtRegister at end)')
if s.count(old) != 1:
    sys.stderr.write("sync_vm: cannot find the verilog_helper load line in %s; add the relkit line by hand\n" % p)
    sys.exit(1)
io.open(p, "w", encoding="utf-8", newline="").write(s.replace(old, new))
print("sync_vm: added relkit load line to skill_tools.il")
PYEOF
fi
echo "sync_vm: done"
