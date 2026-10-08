# fake_tools

Fake `strmout` / `si` / `calibre` / `qrc` executables for testing the
extraction orchestration (plan section 4.8, `py/rk_extract.py`) on machines
without the real tools. Owner: extract & history role.

* `strmout`, `si`, `calibre`, `qrc` -- thin `#!/usr/bin/env python3` scripts
  (executable bit set in git) that call `fake_tool_impl.main(<tool>)`.
* `fake_tool_impl.py` -- the behaviour:
  * `strmout` writes `-strmFile` (fake GDS text).
  * `si` reads `si.env` from its cwd, writes `<simRunDir>/<hnlNetlistFileName>`
    and leaves a `.running` file behind like the real `si`.
  * `calibre ... -batch` reads the runset (`*lvsRunDir`, `*lvsReportFile`...),
    checks the layout/source inputs exist, writes a CORRECT or INCORRECT LVS
    report and, when the post trigger asks for the query, `query_output/`.
    Without `-batch` (the "open in Calibre GUI" command) it does nothing.
  * `qrc -cmd F` writes the `output_setup -file_name` DSPF, after checking the
    LVS query output exists.

Behaviour switch (JSON): `$RELKIT_FAKE_TOOLS_CONFIG`, else
`fake_tools/fake_config.json` (git-ignored), else defaults:

```json
{"lvs": "pass", "fail_step": null, "delay": 0, "lvs_no_banner": false}
```

`lvs: "fail"` gives an LVS mismatch report; `fail_step` (`strmout` / `si` /
`lvs` / `qrc`) makes that tool exit 1 without products; `delay` makes every
tool sleep (cancel tests). Each call is appended to `calls.log` next to the
config file.

Site config pointing at the fakes (VM dev site):

```json
"extract": {"tools": {"strmout": "${RELKIT_DIR}/py/tests/fake_tools/strmout",
                      "si": "${RELKIT_DIR}/py/tests/fake_tools/si",
                      "calibre": "${RELKIT_DIR}/py/tests/fake_tools/calibre",
                      "qrc": "${RELKIT_DIR}/py/tests/fake_tools/qrc"}}
```

On Windows (no shebang execution) a tool may be given as an argv list,
e.g. `["C:/Python/python.exe", ".../fake_tools/strmout"]`.
