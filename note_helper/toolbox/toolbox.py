#!/usr/bin/env python3
"""note-helper toolbox -- one Tkinter GUI for the Python data-prep front-ends.

Logically both companions are the same thing: clean/convert raw data on the
Python side so it can be dropped into a Cadence schematic. This bundles them as
tabs in a single window:

  * Image  -> SVG       (img2svg)  -> note-helper "Import SVG..."
  * Table  -> Markdown  (tsv2md)   -> paste into the note-helper form

The heavy lifting is imported from the sibling modules (img2svg.py, tsv2md.py);
this file only builds the shared UI. Standard library + Pillow + numpy.

    python3 toolbox.py            # the unified GUI
    python3 toolbox.py --selftest # headless build+exercise check (used in CI)
"""

import os
import sys

# make the sibling tool modules importable regardless of CWD
_HERE = os.path.dirname(os.path.abspath(__file__))
_ROOT = os.path.dirname(_HERE)
for _d in ("img2svg", "tsv2md"):
    _p = os.path.join(_ROOT, _d)
    if _p not in sys.path:
        sys.path.insert(0, _p)

import img2svg  # noqa: E402
import tsv2md   # noqa: E402


# --------------------------------------------------------------------------
# Tab 1: Image -> SVG  (wraps img2svg core)
# --------------------------------------------------------------------------
def build_image_tab(parent):
    import tkinter as tk
    from tkinter import ttk, filedialog
    img2svg._require_libs()

    state = {"in": None, "polys": None, "W": 0, "H": 0}
    main = ttk.Frame(parent, padding=8)
    main.pack(fill="both", expand=True)

    ctl = ttk.Frame(main)
    ctl.pack(fill="x", pady=(0, 6))
    in_var = tk.StringVar(value="")
    mode_var = tk.StringVar(value="threshold")
    ttk.Button(ctl, text="Open image...", command=lambda: pick_in()).pack(side="left")
    ttk.Label(ctl, textvariable=in_var, width=34).pack(side="left", padx=6)
    ttk.Label(ctl, text="Mode:").pack(side="left", padx=(10, 2))
    ttk.Radiobutton(ctl, text="line-art", variable=mode_var, value="threshold").pack(side="left")
    ttk.Radiobutton(ctl, text="edge (photo)", variable=mode_var, value="edge").pack(side="left")

    sl = ttk.Frame(main)
    sl.pack(fill="x", pady=(0, 6))
    thr_var = tk.IntVar(value=0)
    levels_var = tk.IntVar(value=1)
    simp_var = tk.DoubleVar(value=1.5)
    minlen_var = tk.DoubleVar(value=8.0)
    maxdim_var = tk.IntVar(value=1000)
    invert_var = tk.BooleanVar(value=False)
    rmbg_var = tk.BooleanVar(value=False)

    def labeled(parent_, text, var, frm, to, width=110):
        f = ttk.Frame(parent_)
        ttk.Label(f, text=text).pack(anchor="w")
        ttk.Scale(f, from_=frm, to=to, variable=var, orient="horizontal", length=width).pack()
        f.pack(side="left", padx=5)

    labeled(sl, "Threshold (0=auto)", thr_var, 0, 255)
    labeled(sl, "Levels (detail)", levels_var, 1, 8)
    labeled(sl, "Simplify (px)", simp_var, 0, 8)
    labeled(sl, "Min length (px)", minlen_var, 0, 60)
    labeled(sl, "Max dim", maxdim_var, 200, 2000)
    ttk.Checkbutton(sl, text="invert", variable=invert_var).pack(side="left", padx=6)
    ttk.Checkbutton(sl, text="rm bg", variable=rmbg_var).pack(side="left")

    btns = ttk.Frame(main)
    btns.pack(fill="x", pady=4)
    status = ttk.Label(btns, text="Open an image, then Trace.")
    ttk.Button(btns, text="Trace", command=lambda: do_trace()).pack(side="left")
    ttk.Button(btns, text="Save SVG...", command=lambda: do_save()).pack(side="left", padx=6)
    status.pack(side="left", padx=12)

    canvas = tk.Canvas(main, bg="white", highlightthickness=1, highlightbackground="#999")
    canvas.pack(fill="both", expand=True, pady=(6, 0))

    def pick_in():
        p = filedialog.askopenfilename(
            filetypes=[("Images", "*.png *.jpg *.jpeg *.bmp *.gif *.tif *.tiff"),
                       ("All files", "*.*")])
        if p:
            load(p)

    def load(p):
        state["in"] = p
        in_var.set(os.path.basename(p))
        status.config(text="Loaded %s" % in_var.get())

    def do_trace():
        if not state["in"]:
            status.config(text="Open an image first.")
            return
        gray = img2svg.load_gray(state["in"], max_dim=int(maxdim_var.get()))
        H, W = gray.shape
        thr = int(thr_var.get()) or None
        polys = img2svg.trace(gray, mode=mode_var.get(), threshold=thr,
                              invert=invert_var.get(), simplify=float(simp_var.get()),
                              min_len=float(minlen_var.get()), levels=int(levels_var.get()),
                              rmbg=rmbg_var.get())
        state.update(polys=polys, W=W, H=H)
        status.config(text="%d contours (%dx%d). Save SVG when happy." % (len(polys), W, H))
        draw_preview()

    def draw_preview():
        canvas.delete("all")
        polys, W, H = state["polys"], state["W"], state["H"]
        if not polys:
            return
        cw = canvas.winfo_width()
        ch = canvas.winfo_height()
        if cw < 50:
            cw = 880
        if ch < 50:
            ch = 320
        s = min((cw - 20) / float(W), (ch - 20) / float(H))
        for poly in polys:
            flat = []
            for (x, y) in poly:
                flat += [10 + x * s, 10 + y * s]
            if len(flat) >= 4:
                canvas.create_line(*flat, fill="black")

    def do_save(path=None):
        if not state["polys"]:
            status.config(text="Trace first.")
            return None
        if path is None:
            path = filedialog.asksaveasfilename(defaultextension=".svg",
                                                filetypes=[("SVG", "*.svg")])
        if not path:
            return None
        with open(path, "w") as f:
            f.write(img2svg.to_svg(state["polys"], state["W"], state["H"]))
        status.config(text="Saved %s  (import it with note-helper)" % os.path.basename(path))
        return path

    return {"load": load, "trace": do_trace, "save": do_save, "state": state,
            "set_levels": lambda n: levels_var.set(int(n)),
            "set_mode": lambda m: mode_var.set(m)}


# --------------------------------------------------------------------------
# Tab 2: Table -> Markdown  (wraps tsv2md core)
# --------------------------------------------------------------------------
def build_table_tab(parent, root):
    import tkinter as tk
    from tkinter import ttk, filedialog

    main = ttk.Frame(parent, padding=8)
    main.pack(fill="both", expand=True)

    opts = ttk.Frame(main)
    opts.pack(fill="x", pady=(0, 6))
    has_header = tk.BooleanVar(value=True)
    do_pad = tk.BooleanVar(value=True)
    align_var = tk.StringVar(value="")
    ttk.Checkbutton(opts, text="First row is header", variable=has_header).pack(side="left")
    ttk.Checkbutton(opts, text="Pad source", variable=do_pad).pack(side="left", padx=(10, 0))
    ttk.Label(opts, text="Align (l/r/c per col):").pack(side="left", padx=(14, 2))
    ttk.Entry(opts, textvariable=align_var, width=14).pack(side="left")

    ttk.Label(main, text="Paste TSV (from Excel):").pack(anchor="w")
    in_txt = tk.Text(main, height=9, wrap="none", undo=True)
    in_txt.pack(fill="both", expand=True)

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
        status.config(text="Pasted %d chars." % len(data))

    def do_convert():
        tsv = in_txt.get("1.0", "end")
        md = tsv2md.tsv_to_md(tsv, has_header=has_header.get(),
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
        return md

    def do_copy():
        md = out_txt.get("1.0", "end").rstrip("\n")
        if md:
            root.clipboard_clear()
            root.clipboard_append(md)
            status.config(text="Output copied to clipboard.")

    def do_open(path=None):
        if path is None:
            path = filedialog.askopenfilename(
                filetypes=[("Table / text", "*.tsv *.txt *.md *.csv *.markdown"),
                           ("All files", "*.*")])
        if not path:
            return None
        with open(path) as f:
            set_input(f.read())
        status.config(text="Loaded %s" % os.path.basename(path))
        return path

    def do_save(path=None):
        md = out_txt.get("1.0", "end").rstrip("\n")
        if not md:
            status.config(text="Convert first.")
            return None
        if path is None:
            path = filedialog.asksaveasfilename(defaultextension=".md",
                                                filetypes=[("Markdown", "*.md")])
        if not path:
            return None
        with open(path, "w") as f:
            f.write(md + "\n")
        status.config(text="Saved %s" % os.path.basename(path))
        return path

    ttk.Button(btns, text="Open file...", command=do_open).pack(side="left")
    ttk.Button(btns, text="Paste", command=do_paste).pack(side="left", padx=6)
    ttk.Button(btns, text="Convert  →", command=do_convert).pack(side="left")
    ttk.Button(btns, text="Copy", command=do_copy).pack(side="left", padx=6)
    ttk.Button(btns, text="Save .md...", command=do_save).pack(side="left")
    status.pack(side="left", padx=12)

    ttk.Label(main, text="Markdown:").pack(anchor="w")
    out_txt = tk.Text(main, height=9, wrap="none", state="disabled")
    out_txt.pack(fill="both", expand=True)

    def set_input(t):
        in_txt.delete("1.0", "end")
        in_txt.insert("1.0", t)

    return {"set_input": set_input, "convert": do_convert,
            "open_file": do_open, "save_md": do_save,
            "get_output": lambda: out_txt.get("1.0", "end").rstrip("\n")}


# --------------------------------------------------------------------------
def build_window():
    import tkinter as tk
    from tkinter import ttk
    root = tk.Tk()
    root.title("note-helper toolbox")
    root.geometry("940x700")
    nb = ttk.Notebook(root)
    f_img = ttk.Frame(nb)
    f_tab = ttk.Frame(nb)
    api = {"image": build_image_tab(f_img),
           "table": build_table_tab(f_tab, root)}
    nb.add(f_img, text="Image → SVG")
    nb.add(f_tab, text="Table → Markdown")
    nb.pack(fill="both", expand=True)
    return root, api


def run_gui():
    root, _ = build_window()
    root.mainloop()
    return 0


def selftest():
    """Headless build + exercise both tabs (run under xvfb-run)."""
    root, api = build_window()
    root.update_idletasks()
    # table tab: type-convert, then file open -> convert -> save round-trip
    api["table"]["set_input"]("Net\tVal\tUnit\nVdd\t3.3\tV\nGnd\t0\tV")
    out = (api["table"]["convert"]() or "")
    assert "|" in out and "Net" in out, "table tab produced no markdown"
    with open("/tmp/toolbox_in.tsv", "w") as f:
        f.write("A\tB\n1\t2\n")
    assert api["table"]["open_file"]("/tmp/toolbox_in.tsv"), "table open_file failed"
    api["table"]["convert"]()
    saved = api["table"]["save_md"]("/tmp/toolbox_out.md")
    assert saved and os.path.isfile(saved), "table save_md failed"
    assert "|" in open(saved).read(), "saved .md has no table"
    # image tab
    sample = os.path.join(_ROOT, "img2svg", "samples", "shapes.png")
    if os.path.isfile(sample):
        api["image"]["load"](sample)
        api["image"]["trace"]()
        n = len(api["image"]["state"]["polys"] or [])
        assert n > 0, "image tab produced no contours"
        svg = api["image"]["save"]("/tmp/toolbox_selftest.svg")
        assert svg and os.path.isfile(svg), "image tab did not save SVG"
        print("selftest OK: table md=%d chars, image contours=%d, svg=%s" % (len(out), n, svg))
    else:
        print("selftest OK (table only): md=%d chars; image sample missing" % len(out))
    root.destroy()
    return 0


def main():
    if "--selftest" in sys.argv[1:]:
        return selftest()
    try:
        import tkinter  # noqa: F401
    except Exception:
        sys.stderr.write(
            "tkinter unavailable for this Python. On Rocky/RHEL 8 with python3.11:\n"
            "  sudo dnf install python3.11-tkinter\n"
            "Then run:  python3 toolbox.py\n")
        return 2
    return run_gui()


if __name__ == "__main__":
    raise SystemExit(main())
