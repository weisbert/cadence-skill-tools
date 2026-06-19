#!/usr/bin/env python3
"""tsv2md -- turn Excel-copied TSV into an aligned Markdown pipe table.

Companion to the note-helper SKILL tool, but completely Cadence-independent:
pure CPython standard library (Tkinter ships with CPython). Copy a range in
Excel (Ctrl+C yields TSV), paste here, get a clean aligned Markdown table on
the clipboard -- ready to paste into the note-helper form.

Usage
-----
GUI (default):
    python3 tsv2md.py

CLI (no window; reads TSV on stdin, writes Markdown on stdout):
    python3 tsv2md.py --cli [--no-header] [--align l,r,c] < table.tsv
    pbpaste | python3 tsv2md.py --cli            # or xclip -o, etc.

The GUI auto-falls back to CLI if Tkinter is unavailable (headless box).
"""

import sys
import argparse


# --------------------------------------------------------------------------
# Core conversion (no GUI dependency)
# --------------------------------------------------------------------------

ALIGN_CHARS = {"l": "left", "r": "right", "c": "center"}


def parse_aligns(spec, ncols):
    """Parse an alignment spec like 'l,r,c' or 'lrc' into a list of
    'left'/'right'/'center', padded/truncated to ncols (default left)."""
    out = []
    if spec:
        tokens = spec.replace(",", " ").split()
        if len(tokens) == 1 and len(tokens[0]) > 1:
            tokens = list(tokens[0])          # "lrc" -> ['l','r','c']
        for t in tokens:
            out.append(ALIGN_CHARS.get(t.strip().lower(), "left"))
    while len(out) < ncols:
        out.append("left")
    return out[:ncols]


def split_tsv(tsv_text):
    """TSV text -> list of rows (each a list of cell strings). Empty trailing
    lines are dropped; rows are padded to a common column count."""
    lines = tsv_text.replace("\r\n", "\n").replace("\r", "\n").split("\n")
    while lines and lines[-1].strip() == "":
        lines.pop()
    rows = [ln.split("\t") for ln in lines if ln.strip() != ""]
    ncols = max((len(r) for r in rows), default=0)
    for r in rows:
        r += [""] * (ncols - len(r))
    return rows, ncols


def _esc(cell):
    """Escape characters that would break a Markdown pipe table."""
    return cell.replace("|", "\\|").strip()


def _sep_cell(width, align):
    """Build a separator-row cell of the given visible width and alignment."""
    n = max(width, 3)
    if align == "center":
        return ":" + "-" * (n - 2) + ":"
    if align == "right":
        return "-" * (n - 1) + ":"
    if align == "left":
        return ":" + "-" * (n - 1)
    return "-" * n


def _pad(cell, width, align):
    """Pad a cell to width for a pretty-aligned source (display only;
    Markdown parsers ignore the padding)."""
    gap = width - len(cell)
    if gap <= 0:
        return cell
    if align == "right":
        return " " * gap + cell
    if align == "center":
        left = gap // 2
        return " " * left + cell + " " * (gap - left)
    return cell + " " * gap


def tsv_to_md(tsv_text, has_header=True, align_spec=None, pad=True):
    """Convert TSV text to a Markdown pipe table string."""
    rows, ncols = split_tsv(tsv_text)
    if ncols == 0:
        return ""
    rows = [[_esc(c) for c in r] for r in rows]
    aligns = parse_aligns(align_spec, ncols)

    if has_header:
        header, body = rows[0], rows[1:]
    else:
        header = ["Col%d" % (j + 1) for j in range(ncols)]
        body = rows

    # Column display widths (header + body cells; separators handled separately).
    widths = []
    for j in range(ncols):
        w = len(header[j])
        for r in body:
            w = max(w, len(r[j]))
        widths.append(max(w, 3))

    def fmt_row(cells):
        if pad:
            cells = [_pad(cells[j], widths[j], aligns[j]) for j in range(ncols)]
        return "| " + " | ".join(cells) + " |"

    sep = [_sep_cell(widths[j], aligns[j]) for j in range(ncols)]

    lines = [fmt_row(header), "| " + " | ".join(sep) + " |"]
    lines += [fmt_row(r) for r in body]
    return "\n".join(lines)


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------

def run_cli(argv):
    ap = argparse.ArgumentParser(prog="tsv2md", add_help=True,
                                 description="TSV (stdin) -> Markdown table (stdout).")
    ap.add_argument("--cli", action="store_true", help="force CLI mode")
    ap.add_argument("--no-header", action="store_true",
                    help="first row is data, not a header")
    ap.add_argument("--align", default=None,
                    help="per-column alignment, e.g. 'l,r,c' or 'lrc'")
    ap.add_argument("--no-pad", action="store_true",
                    help="do not space-pad cells in the output source")
    args = ap.parse_args(argv)
    tsv = sys.stdin.read()
    md = tsv_to_md(tsv, has_header=not args.no_header,
                   align_spec=args.align, pad=not args.no_pad)
    sys.stdout.write(md + ("\n" if md and not md.endswith("\n") else ""))
    return 0


# --------------------------------------------------------------------------
# GUI
# --------------------------------------------------------------------------

def run_gui():
    import tkinter as tk
    from tkinter import ttk

    root = tk.Tk()
    root.title("tsv2md  --  TSV to Markdown table")
    root.geometry("760x560")

    main = ttk.Frame(root, padding=8)
    main.pack(fill="both", expand=True)

    # Options row.
    opts = ttk.Frame(main)
    opts.pack(fill="x", pady=(0, 6))
    has_header = tk.BooleanVar(value=True)
    do_pad = tk.BooleanVar(value=True)
    ttk.Checkbutton(opts, text="First row is header", variable=has_header).pack(side="left")
    ttk.Checkbutton(opts, text="Pad source", variable=do_pad).pack(side="left", padx=(10, 0))
    ttk.Label(opts, text="Align (l/r/c per col):").pack(side="left", padx=(14, 2))
    align_var = tk.StringVar(value="")
    ttk.Entry(opts, textvariable=align_var, width=14).pack(side="left")

    # Input.
    ttk.Label(main, text="Paste TSV (from Excel):").pack(anchor="w")
    in_txt = tk.Text(main, height=10, wrap="none", undo=True)
    in_txt.pack(fill="both", expand=True)

    # Buttons.
    btns = ttk.Frame(main)
    btns.pack(fill="x", pady=6)
    status = ttk.Label(btns, text="Paste a TSV table, then Convert.")

    def do_paste():
        try:
            data = root.clipboard_get()
        except tk.TclError:
            status.config(text="Clipboard is empty or not text.")
            return
        in_txt.delete("1.0", "end")
        in_txt.insert("1.0", data)
        status.config(text="Pasted %d chars from clipboard." % len(data))

    def do_convert():
        tsv = in_txt.get("1.0", "end")
        md = tsv_to_md(tsv, has_header=has_header.get(),
                       align_spec=align_var.get(), pad=do_pad.get())
        out_txt.config(state="normal")
        out_txt.delete("1.0", "end")
        out_txt.insert("1.0", md)
        out_txt.config(state="disabled")
        if md:
            root.clipboard_clear()
            root.clipboard_append(md)
            status.config(text="Converted and copied to clipboard.")
        else:
            status.config(text="Nothing to convert.")

    def do_copy():
        md = out_txt.get("1.0", "end").rstrip("\n")
        if md:
            root.clipboard_clear()
            root.clipboard_append(md)
            status.config(text="Output copied to clipboard.")

    ttk.Button(btns, text="Paste from clipboard", command=do_paste).pack(side="left")
    ttk.Button(btns, text="Convert  →", command=do_convert).pack(side="left", padx=6)
    ttk.Button(btns, text="Copy output", command=do_copy).pack(side="left")
    status.pack(side="left", padx=12)

    # Output.
    ttk.Label(main, text="Markdown:").pack(anchor="w")
    out_txt = tk.Text(main, height=10, wrap="none", state="disabled")
    out_txt.pack(fill="both", expand=True)

    in_txt.focus_set()
    root.mainloop()
    return 0


# --------------------------------------------------------------------------

def main():
    argv = sys.argv[1:]
    if "--cli" in argv or not sys.stdin.isatty() and argv == []:
        # Piped stdin with no args -> behave as a filter.
        return run_cli([a for a in argv])
    if "--cli" in argv or "--no-header" in argv or "--align" in argv or "--no-pad" in argv:
        return run_cli(argv)
    try:
        import tkinter  # noqa: F401
    except Exception:
        sys.stderr.write("tkinter unavailable; falling back to CLI "
                         "(reads stdin, writes stdout).\n")
        return run_cli(["--cli"])
    return run_gui()


if __name__ == "__main__":
    raise SystemExit(main())
