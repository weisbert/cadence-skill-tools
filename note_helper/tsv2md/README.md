# tsv2md

Standalone helper that turns **Excel-copied TSV** into an aligned **Markdown
pipe table** on your clipboard — ready to paste into the note-helper form.

Completely Cadence-independent: pure CPython standard library (Tkinter ships
with CPython). note-helper does **not** depend on it (the form ingests TSV
directly); this is just a convenience for prettier source.

## Use

GUI (default):

```bash
python3 tsv2md.py
```

1. Copy a range in Excel (`Ctrl+C` → TSV on the clipboard).
2. Click **Paste from clipboard** (or paste into the input box).
3. Set *First row is header* and optional per-column *Align* (`l/r/c`, e.g.
   `l,r,c` or `lrc`).
4. Click **Convert →** — the Markdown appears below and is copied to the
   clipboard automatically.

CLI (no window; reads TSV on stdin, writes Markdown on stdout):

```bash
python3 tsv2md.py --cli [--no-header] [--align l,r,c] [--no-pad] < table.tsv
xclip -o | python3 tsv2md.py --cli            # from the X clipboard
```

The GUI auto-falls back to CLI when Tkinter is unavailable (headless box).
Check availability with `python3 -m tkinter`.

## Notes

- Cells containing `|` are escaped (`\|`); empty cells are preserved.
- Without a header row, generic `Col1..ColN` headers are synthesized (GFM
  requires a header row).
- Source padding is cosmetic — Markdown parsers ignore it; turn it off with
  `--no-pad`.
