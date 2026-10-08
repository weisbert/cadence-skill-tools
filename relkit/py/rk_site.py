"""rk_site -- relkit site configuration lookup, merge and ${VAR} expansion.

Mirrors rkSite.il exactly (docs/CONTRACT.md section 1):

  lookup order : $RELKIT_SITE -> <workarea>/.relkit_site.json -> <relkit>/site.json
                 (none found -> built-in defaults only, with a warning)
  merge        : <relkit>/site_defaults.json deep-merged with the site file
                 (objects merge recursively; any other value, null included,
                 replaces the default)
  expansion    : "${NAME}" in every string value; NAME is looked up in
                 {WORKAREA, USER, RELKIT_DIR} first, then the environment.
                 Unknown names are left verbatim and reported as warnings.
                 A bare "$NAME" (no braces) is NEVER expanded -- RelStudio
                 needs literal "$MODEL_ROOT/..." in its yml.
  relstudio_home: null -> $RELSTUDIO_HOME of the calling process (D6);
                 the SKILL side passes Virtuoso's value in ctx.relstudio_home.

Python 3.8+, stdlib only.
"""

import copy
import getpass
import json
import os
import re

PY_DIR = os.path.dirname(os.path.abspath(__file__))
RELKIT_DIR = os.path.dirname(PY_DIR)
DEFAULTS_PATH = os.path.join(RELKIT_DIR, "site_defaults.json")

_VAR_RE = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}")


class SiteError(Exception):
    """Raised when an explicitly requested site file is missing or invalid."""


def read_json(path):
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def default_workarea(environ=None):
    env = os.environ if environ is None else environ
    wa = env.get("RELKIT_WORKAREA") or ""
    if not wa:
        wa = os.getcwd()
    return wa.rstrip("/\\") or wa


def default_user(environ=None):
    env = os.environ if environ is None else environ
    user = env.get("USER") or env.get("USERNAME") or ""
    if not user:
        try:
            user = getpass.getuser()
        except Exception:  # pragma: no cover - platform dependent
            user = "unknown"
    return user


def find_site_path(workarea, environ=None):
    """Return the site file path by the lookup order, or None (defaults only)."""
    env = os.environ if environ is None else environ
    explicit = env.get("RELKIT_SITE") or ""
    if explicit:
        if not os.path.isfile(explicit):
            raise SiteError("RELKIT_SITE=%s does not exist" % explicit)
        return explicit
    cand = os.path.join(workarea, ".relkit_site.json")
    if os.path.isfile(cand):
        return cand
    cand = os.path.join(RELKIT_DIR, "site.json")
    if os.path.isfile(cand):
        return cand
    return None


def deep_merge(base, over):
    """Return a new dict: `over` merged into `base` (objects recurse)."""
    out = copy.deepcopy(base)
    for k, v in over.items():
        if isinstance(v, dict) and isinstance(out.get(k), dict):
            out[k] = deep_merge(out[k], v)
        else:
            out[k] = copy.deepcopy(v)
    return out


def expand_vars(text, variables, environ=None, warnings=None):
    """Expand ${NAME} in `text`; see module doc for the rules."""
    env = os.environ if environ is None else environ

    def repl(m):
        name = m.group(1)
        if name in variables and variables[name] is not None:
            return str(variables[name])
        val = env.get(name)
        if val:
            return val
        if warnings is not None:
            warnings.append("unknown variable ${%s} left unexpanded" % name)
        return m.group(0)

    return _VAR_RE.sub(repl, text)


def expand_tree(obj, variables, environ=None, warnings=None):
    if isinstance(obj, str):
        return expand_vars(obj, variables, environ, warnings)
    if isinstance(obj, list):
        return [expand_tree(x, variables, environ, warnings) for x in obj]
    if isinstance(obj, dict):
        return {k: expand_tree(v, variables, environ, warnings) for k, v in obj.items()}
    return obj


def load_site(workarea=None, path=None, user=None, relstudio_home=None,
              environ=None, use_lookup=True):
    """Load the merged, expanded site config.

    workarea       : defaults to $RELKIT_WORKAREA or cwd
    path           : explicit site file (skips the lookup). Use ctx["site_path"].
    user           : defaults to $USER
    relstudio_home : value to use when the site says null (ctx["relstudio_home"]);
                     falls back to $RELSTUDIO_HOME
    use_lookup     : False -> when path is None use defaults only (do not search)

    Returns (site_dict, site_path_or_None, warnings_list).
    """
    env = os.environ if environ is None else environ
    warnings = []
    wa = (workarea or default_workarea(env)).rstrip("/\\") or workarea
    if path is None and use_lookup:
        path = find_site_path(wa, env)
    if path is not None and not os.path.isfile(path):
        raise SiteError("site file %s does not exist" % path)

    defaults = read_json(DEFAULTS_PATH)
    if path is None:
        warnings.append("no site file found; using built-in defaults only")
        site = {}
    else:
        try:
            site = read_json(path)
        except ValueError as e:
            raise SiteError("site file %s is not valid JSON: %s" % (path, e))
        if not isinstance(site, dict):
            raise SiteError("site file %s must contain a JSON object" % path)

    merged = deep_merge(defaults, site)
    variables = {
        "WORKAREA": wa,
        "USER": user or default_user(env),
        "RELKIT_DIR": RELKIT_DIR.replace("\\", "/"),
    }
    merged = expand_tree(merged, variables, env, warnings)

    if not merged.get("relstudio_home"):
        merged["relstudio_home"] = relstudio_home or env.get("RELSTUDIO_HOME") or None
    return merged, path, warnings


def site_from_ctx(ctx, environ=None):
    """Load the site the way every subcommand should: from the ctx.json fields.

    ctx["site_path"] is the file rkSite.il resolved (null = SKILL found none,
    so defaults only). If the key is absent (hand-written ctx), do the lookup.
    """
    return load_site(workarea=ctx.get("workarea"),
                     path=ctx.get("site_path"),
                     user=ctx.get("user"),
                     relstudio_home=ctx.get("relstudio_home"),
                     environ=environ,
                     use_lookup="site_path" not in ctx)


def get(site, dotted, default=None):
    """site_get(site, "emir.license_policy")."""
    cur = site
    for part in dotted.split("."):
        if not isinstance(cur, dict) or part not in cur:
            return default
        cur = cur[part]
    return cur
