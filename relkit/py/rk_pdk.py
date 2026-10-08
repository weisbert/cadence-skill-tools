"""rk_pdk -- derive the extraction parameters from the environment (plan 4.8).

The values the extraction chain needs (layer map, LVS deck, Quantus deck and
tech library, CDL prelude, tech name) change from project to project, but the
PDK setup script exports them as environment variables. Like Auto_ext
(github.com/weisbert/Auto_ext: auto_ext/core/env.py, model/pdk.py,
core/profile_discover.py SCAN_RULES R1-R8), relkit stores *rules* in the site
config and resolves them against the environment of the calling process
(Virtuoso's environment: the panel's Python child inherits it).

Expression syntax (port of Auto_ext resolve_path_expr / substitute_env):

    <head>[|filter]*
    head    text with $X, ${X} or $env(X) references; $$ is a literal $
    filter  parent  (PurePosixPath.parent; chains left to right)

A value without any reference is a literal, so pinning a value in the site
config is just writing the path. Unknown filters are an error; a reference to
an unset variable makes the value unresolved and is reported by name.

Rules (site `extract.*`, defaults in site_defaults.json = Auto_ext defaults):

    layer_map                "$PDK_LAYER_MAP_FILE"
    lvs_deck_dir             "$calibre_source_added_place|parent"         (R1)
    lvs_basename             null -> last segment of lvs_deck_dir         (R2)
    lvs_filename_pattern     "{basename}.{variant}.qcilvs"                 (R3)
    lvs_variant              null -> user choice; else lvs_default_variant if
                             present, else the only one found
    cdl_include_file         "$calibre_source_added_place"
    technology_library_file  "$SETUP_ROOT/assura_tech.lib"
    tech_name                null -> parent dir name of the first set variable
                             in tech_name_env_vars                         (R8)
    qrc_deck_dir             null -> qrc_deck_glob: one hit = automatic, several
                             = user choice, none = error                  (R5)
    qrc_query_cmd_name / qrc_preserve_cell_list_name   files in the QRC deck
    corners / default_corner  RC corner names -> Quantus -technology_corner
    power_names / ground_names  global LVS supply lists (PDK data; may be empty)

Python 3.8+, stdlib only.
"""

import glob
import os
import posixpath
import re

import rk_common

_RE_ENV_TCL = re.compile(r"(?<!\$)\$env\(([A-Za-z_][A-Za-z0-9_]*)\)")
_RE_ENV_BRACE = re.compile(r"(?<!\$)\$\{([A-Za-z_][A-Za-z0-9_]*)\}")
_RE_ENV_BARE = re.compile(r"(?<!\$)\$(?!env\()([A-Za-z_][A-Za-z0-9_]*)(?![A-Za-z0-9_])")
_ESC = "\x00"

DEFAULT_TECH_NAME_ENV_VARS = ["PDK_TECH_FILE", "PDK_LAYER_MAP_FILE", "PDK_DISPLAY_FILE"]

# Generic Quantus RuleSet corner names (Auto_ext profile). A PDK may offer a
# subset; the site `extract.corners` list is what the panel offers.
DEFAULT_CORNERS = [
    {"name": "typical", "technology_corner": "TYPICAL"},
    {"name": "cbest", "technology_corner": "CBEST"},
    {"name": "cbest_t", "technology_corner": "CBEST_T"},
    {"name": "cworst", "technology_corner": "CWORST"},
    {"name": "cworst_t", "technology_corner": "CWORST_T"},
    {"name": "rcbest", "technology_corner": "RCBEST"},
    {"name": "rcbest_t", "technology_corner": "RCBEST_T"},
    {"name": "rcworst", "technology_corner": "RCWORST"},
    {"name": "rcworst_t", "technology_corner": "RCWORST_T"},
]

# Site keys of relkit <= 0.1 (fixed values) -> the rule key that replaces them.
# Still honoured (as a literal override) with a warning.
LEGACY_KEYS = {
    "pdk_layer_map": "layer_map",
    "calibre_lvs_dir": "lvs_deck_dir",
    "calibre_lvs_basename": "lvs_basename",
    "technology_name": "tech_name",
    "power_nets": "power_names",
    "ground_nets": "ground_names",
}


# --------------------------------------------------------------------------
# expressions
# --------------------------------------------------------------------------

def env_refs(text):
    """Names referenced by $X / ${X} / $env(X) in text ($$ is an escape)."""
    if not isinstance(text, str) or not text:
        return []
    masked = text.replace("$$", _ESC + _ESC)
    found = []
    for rx in (_RE_ENV_TCL, _RE_ENV_BRACE, _RE_ENV_BARE):
        for m in rx.finditer(masked):
            if m.group(1) not in found:
                found.append(m.group(1))
    return found


def substitute(text, env):
    """Replace references with env values; unknown names pass through
    unchanged; $$ collapses to $ (Auto_ext substitute_env)."""
    if not text:
        return text
    text = text.replace("$$", _ESC)

    def rep(m):
        v = env.get(m.group(1))
        return m.group(0) if v is None else v

    text = _RE_ENV_TCL.sub(rep, text)
    text = _RE_ENV_BRACE.sub(rep, text)
    text = _RE_ENV_BARE.sub(rep, text)
    return text.replace(_ESC, "$")


def resolve_expr(expr, env):
    """-> (value or None, missing_vars). A value is None when any referenced
    variable is unset/empty. Raises RkError for an unknown filter."""
    if expr is None:
        return None, []
    if not isinstance(expr, str):
        return expr, []
    head, _sep, rest = expr.partition("|")
    filters = [f.strip() for f in rest.split("|")] if _sep else []
    for f in filters:
        if f != "parent":
            raise rk_common.RkError("unknown path filter %r in %r; supported: parent" % (f, expr))
    missing = [v for v in env_refs(head) if not env.get(v)]
    if missing:
        return None, missing
    val = substitute(head.strip(), env)
    for _f in filters:
        val = posixpath.dirname(val.rstrip("/")) or ("/" if val.startswith("/") else ".")
    return val, []


def tech_name_from_env(candidates, env):
    """Parent directory name of the first candidate variable that is set (R8)."""
    for var in candidates or []:
        v = env.get(var)
        if not v:
            continue
        name = posixpath.basename(posixpath.dirname(v.replace("\\", "/").rstrip("/")))
        if name:
            return name, var
    return None, None


def find_variants(deck_dir, basename, pattern):
    """Variants present in deck_dir for '<basename>.<variant>.qcilvs'-style
    patterns (R3: globbed, never assumed). Sorted; [] if the dir is unreadable."""
    try:
        names = os.listdir(deck_dir)
    except OSError:
        return []
    pre, _s, post = pattern.partition("{variant}")
    pre = pre.replace("{basename}", basename)
    post = post.replace("{basename}", basename)
    rx = re.compile("^" + re.escape(pre) + r"([^/]+?)" + re.escape(post) + "$")
    out = []
    for n in names:
        m = rx.match(n)
        if m and os.path.isfile(os.path.join(deck_dir, n)):
            out.append(m.group(1))
    return sorted(set(out))


def find_qrc_decks(pattern):
    """Directories matching the (already substituted) glob, sorted."""
    return sorted(p.replace("\\", "/") for p in glob.glob(pattern) if os.path.isdir(p))


def corner_list(ext):
    out = []
    for c in ext.get("corners") or DEFAULT_CORNERS:
        if isinstance(c, str):
            out.append({"name": c.lower(), "technology_corner": c.upper()})
        elif isinstance(c, dict) and c.get("name"):
            out.append({"name": c["name"],
                        "technology_corner": c.get("technology_corner") or c["name"].upper()})
    return out


def pick_corner(corners, want):
    """Match a corner by name or by its technology_corner (case-insensitive)."""
    if not want:
        return None
    w = str(want).lower()
    for c in corners:
        if c["name"].lower() == w or c["technology_corner"].lower() == w:
            return c
    return None


# --------------------------------------------------------------------------
# the resolver
# --------------------------------------------------------------------------

def _blank(v):
    return v is None or v == "" or v == []


def migrate_legacy(ext):
    """Copy relkit<=0.1 fixed-value keys onto the rule keys (explicit values
    win over the defaults). -> (ext copy, warnings)."""
    ext = dict(ext or {})
    warnings = []
    for old, new in LEGACY_KEYS.items():
        if not _blank(ext.get(old)):
            ext[new] = ext[old]
            warnings.append("site extract.%s is obsolete; use extract.%s (value used)" % (old, new))
    for old in ("qrc_query_cmd", "qrc_preserve_cell_list"):
        if not _blank(ext.get(old)):
            ext["qrc_deck_dir"] = ext.get("qrc_deck_dir") or posixpath.dirname(
                str(ext[old]).replace("\\", "/"))
            warnings.append("site extract.%s is obsolete; set extract.qrc_deck_dir "
                            "(its directory is used)" % old)
    return ext, warnings


def resolve(ext, env, choices=None, check_files=None):
    """Resolve the site `extract` rules against env (a dict) plus the user's
    choices {lvs_variant, qrc_deck, technology_corner, temperature,
    power_names, ground_names}.

    -> {"params": {key: value}, "resolved": {key: {value, source, expr, missing}},
        "choices": {variants, qrc_decks, corners}, "selected": {...},
        "missing_env": [...], "errors": [...], "warnings": [...], "ready": bool}
    source: rule (derived from env), literal (fixed in the site config),
    user (panel), default (built-in), derived (from another parameter).
    """
    ext, warnings = migrate_legacy(ext)
    choices = choices or {}
    if check_files is None:
        check_files = ext.get("check_files", True) is not False
    resolved, params, errors, missing_env = {}, {}, [], []

    def note_missing(names):
        for n in names:
            if n not in missing_env:
                missing_env.append(n)

    def put(key, value, source, expr=None, missing=None):
        resolved[key] = {"value": value, "source": source, "expr": expr,
                         "missing": list(missing or [])}
        params[key] = value
        return value

    def from_rule(key, label, required=True):
        expr = ext.get(key)
        if _blank(expr):
            if required:
                errors.append("extract.%s is not set (%s)" % (key, label))
            return put(key, None, "unset")
        try:
            val, miss = resolve_expr(expr, env)
        except rk_common.RkError as e:
            errors.append("extract.%s: %s" % (key, e))
            return put(key, None, "error", expr)
        if miss:
            note_missing(miss)
            if required:
                errors.append("%s: environment variable %s not set (rule extract.%s = %r)"
                              % (label, ", ".join("$" + m for m in miss), key, expr))
            return put(key, None, "rule", expr, miss)
        return put(key, val, "rule" if env_refs(expr) else "literal", expr)

    def must_exist(key, label, is_dir=False):
        v = params.get(key)
        if not v or not check_files:
            return
        ok = os.path.isdir(v) if is_dir else os.path.isfile(v)
        if not ok:
            errors.append("%s not found: %s (extract.%s)" % (label, v, key))

    # layer map, CDL prelude, tech library
    from_rule("layer_map", "strmout layer map")
    must_exist("layer_map", "layer map")
    from_rule("cdl_include_file", "si CDL include (incFILE)", required=False)
    if params.get("cdl_include_file") and check_files and not os.path.isfile(params["cdl_include_file"]):
        warnings.append("CDL include file not found: %s" % params["cdl_include_file"])
    from_rule("technology_library_file", "Quantus technology library")
    must_exist("technology_library_file", "Quantus technology library")

    # tech name (R8)
    if not _blank(ext.get("tech_name")):
        from_rule("tech_name", "Quantus technology name")
    else:
        cands = ext.get("tech_name_env_vars") or DEFAULT_TECH_NAME_ENV_VARS
        name, var = tech_name_from_env(cands, env)
        if name:
            put("tech_name", name, "rule", "parent dir name of $%s" % var)
        else:
            note_missing([c for c in cands if not env.get(c)][:1])
            errors.append("Quantus technology name: none of %s is set (rule R8)"
                          % ", ".join("$" + c for c in cands))
            put("tech_name", None, "rule", "parent dir name of $%s" % cands[0], cands[:1])

    # LVS deck (R1-R3)
    from_rule("lvs_deck_dir", "Calibre LVS deck directory")
    deck = params.get("lvs_deck_dir")
    if deck:
        deck = deck.rstrip("/")
        params["lvs_deck_dir"] = resolved["lvs_deck_dir"]["value"] = deck
        must_exist("lvs_deck_dir", "Calibre LVS deck directory", is_dir=True)
    if not _blank(ext.get("lvs_basename")):
        from_rule("lvs_basename", "LVS rules basename")
    else:
        put("lvs_basename", posixpath.basename(deck) if deck else None, "derived",
            "last segment of lvs_deck_dir")
    pattern = ext.get("lvs_filename_pattern") or "{basename}.{variant}.qcilvs"
    variants = find_variants(deck, params["lvs_basename"], pattern) if deck and params["lvs_basename"] else []
    want = choices.get("lvs_variant") or None
    src = "user"
    if not want and not _blank(ext.get("lvs_variant")):
        want, src = ext.get("lvs_variant"), "literal"
    if not want:
        dflt = ext.get("lvs_default_variant") or "wodio"
        if dflt in variants:
            want, src = dflt, "default"
        elif len(variants) == 1:
            want, src = variants[0], "derived"
    if want and variants and want not in variants:
        errors.append("LVS variant %r not found in %s (found: %s)" % (want, deck, ", ".join(variants)))
    elif want and not variants and deck and check_files:
        warnings.append("no '%s' rules files found in %s; using variant %r as given"
                        % (pattern, deck, want))
    if not want and deck:
        if variants:
            errors.append("choose the LVS variant (%s)" % ", ".join(variants))
        elif check_files:
            errors.append("no LVS rules files '%s' in %s (rule R3)" % (pattern, deck))
    put("lvs_variant", want, src if want else "unset")
    if deck and params["lvs_basename"] and want:
        put("lvs_rules_file", posixpath.join(deck, pattern.format(basename=params["lvs_basename"],
                                                                 variant=want)), "derived")
    else:
        put("lvs_rules_file", None, "derived")

    # QRC deck (R5)
    decks = []
    qwant = choices.get("qrc_deck") or None
    if not _blank(ext.get("qrc_deck_dir")):
        from_rule("qrc_deck_dir", "Quantus (QCI) deck directory")
        qdir = params.get("qrc_deck_dir")
        decks = [qdir] if qdir else []
    else:
        gexpr = ext.get("qrc_deck_glob") or "$VERIFY_ROOT/runset/Calibre_QRC/QRC/*/*/QCI_deck"
        miss = [v for v in env_refs(gexpr) if not env.get(v)]
        qdir, qsrc = None, "rule"
        if miss:
            note_missing(miss)
            errors.append("Quantus deck: environment variable %s not set (rule extract.qrc_deck_glob = %r)"
                          % (", ".join("$" + m for m in miss), gexpr))
        else:
            pat = substitute(gexpr, env)
            decks = find_qrc_decks(pat)
            if qwant:
                if qwant in decks or not check_files:
                    qdir, qsrc = qwant, "user"
                else:
                    errors.append("Quantus deck %s is not one of the %d found by %s"
                                  % (qwant, len(decks), pat))
            elif len(decks) == 1:
                qdir = decks[0]
            elif len(decks) > 1:
                base = params.get("lvs_basename") or ""
                narrow = [d for d in decks if base and posixpath.basename(posixpath.dirname(d)).startswith(base)]
                if len(narrow) == 1:
                    qdir, qsrc = narrow[0], "derived"
                else:
                    errors.append("choose the Quantus deck: %d match %s" % (len(decks), pat))
            else:
                errors.append("no Quantus deck matches %s (rule R5; set extract.qrc_deck_dir)" % pat)
        put("qrc_deck_dir", qdir, qsrc, gexpr)
    qdir = params.get("qrc_deck_dir")
    qcmd = posixpath.join(qdir, ext.get("qrc_query_cmd_name") or "query_cmd") if qdir else None
    plist = posixpath.join(qdir, ext.get("qrc_preserve_cell_list_name") or "preserveCellList.txt") if qdir else None
    put("qrc_query_cmd", qcmd, "derived")
    put("qrc_preserve_cell_list", plist, "derived")
    if qcmd and check_files and not os.path.isfile(qcmd):
        errors.append("Calibre query command file not found: %s" % qcmd)
    if plist and check_files and not os.path.isfile(plist):
        warnings.append("%s not found; -parasitic_blocking_device_cells_file left empty" % plist)
        params["qrc_preserve_cell_list"] = resolved["qrc_preserve_cell_list"]["value"] = None

    # RC corner + temperature (user choices)
    corners = corner_list(ext)
    cwant = choices.get("technology_corner") or ext.get("technology_corner") or ext.get("default_corner") or "typical"
    c = pick_corner(corners, cwant)
    if c is None:
        errors.append("RC corner %r is not in extract.corners (%s)"
                      % (cwant, ", ".join(x["name"] for x in corners)))
        put("technology_corner", None, "user")
    else:
        put("technology_corner", c["technology_corner"],
            "user" if choices.get("technology_corner") else "default", c["name"])
    temp = choices.get("temperature")
    put("temperature", temp if temp is not None else ext.get("temperature", 25),
        "user" if temp is not None else "default")

    # LVS supply names: the panel list if given, else the site lists
    for kind in ("power_names", "ground_names"):
        v = choices.get(kind)
        if v:
            put(kind, list(v), "user")
        else:
            put(kind, list(ext.get(kind) or []), "literal" if ext.get(kind) else "default")
    if not params["power_names"] or not params["ground_names"]:
        warnings.append("LVS power/ground names are empty: fill them in (DUT ports) or set "
                        "extract.power_names / ground_names")

    return {
        "params": params,
        "resolved": resolved,
        "choices": {"variants": variants, "qrc_decks": decks, "corners": corners},
        "selected": {"lvs_variant": params.get("lvs_variant"), "qrc_deck": params.get("qrc_deck_dir"),
                     "corner": c["name"] if c else None, "temperature": params.get("temperature")},
        "missing_env": missing_env,
        "errors": errors,
        "warnings": warnings,
        "ready": not errors,
    }
