"""rk_yaml -- minimal YAML emitter + subset loader (stdlib has no yaml).

The emitter writes the block style RelStudio's GUI writes (plan 4.2):

    Simulation:
      Corners:
        KEY:
          - Aged_1:
              Mode_Type: Aged
              Mode_Name: !!str FF125
              Model_File:
                - $MODEL_ROOT/alps/toplevel.scs
          Parameter_Groups: ~

Rules:
  * dict -> "key: value" in insertion order; nested dict/list on the next
    lines indented by 2; empty dict/list -> {} / [].
  * list items -> "- item"; a dict item starts on the dash line and its other
    keys line up 2 columns right of the dash.
  * None -> ~, bool -> true/false, int as is, float always with a '.' (YAML 1.1
    needs it to resolve as float).
  * Tagged(s) -> "!!str s" (the GUI tags Mode_Name, Test_Name, Project_Name,
    Cell_Name, IP_Name, aging Life_Time and every Parameters value).
  * str -> plain when that reads back as the same string under YAML 1.1,
    else double-quoted with escapes (same choice the GUI makes for e.g.
    Simulation_Cmd with a trailing blank).

The loader understands what the emitter writes plus the GUI files in the
probes: block maps / sequences, plain / single / double-quoted scalars,
"!!str", "~", true/false, ints, floats, [] and {} (and simple flow lists).
It is used by the fake RelStudio, the tests and the golden diff -- relkit
itself never needs to read yml.

Python 3.8+, stdlib only.
"""

import re

__all__ = ["Tagged", "dump", "load", "YamlError"]


class YamlError(ValueError):
    pass


class Tagged(object):
    """A scalar written with an explicit tag (default !!str)."""

    __slots__ = ("value", "tag")

    def __init__(self, value, tag="!!str"):
        self.value = "" if value is None else str(value)
        self.tag = tag

    def __eq__(self, other):
        if isinstance(other, Tagged):
            return self.value == other.value and self.tag == other.tag
        return self.value == other

    def __ne__(self, other):
        return not self.__eq__(other)

    def __hash__(self):
        return hash(self.value)

    def __repr__(self):
        return "Tagged(%r)" % self.value

    def __str__(self):
        return self.value


# --------------------------------------------------------------------------
# YAML 1.1 implicit resolvers (what PyYAML's SafeLoader would turn a plain
# scalar into). A plain str must not match any of these.
_BOOL_RE = re.compile(r"^(?:yes|Yes|YES|no|No|NO|true|True|TRUE|false|False|FALSE"
                      r"|on|On|ON|off|Off|OFF|y|Y|n|N)$")
_NULL_RE = re.compile(r"^(?:~|null|Null|NULL|)$")
_INT_RE = re.compile(r"^(?:[-+]?0b[0-1_]+|[-+]?0[0-7_]+|[-+]?(?:0|[1-9][0-9_]*)"
                     r"|[-+]?0x[0-9a-fA-F_]+|[-+]?[1-9][0-9_]*(?::[0-5]?[0-9])+)$")
_FLOAT_RE = re.compile(r"^(?:[-+]?(?:[0-9][0-9_]*)\.[0-9_]*(?:[eE][-+][0-9]+)?"
                       r"|\.[0-9_]+(?:[eE][-+][0-9]+)?"
                       r"|[-+]?[0-9][0-9_]*(?::[0-5]?[0-9])+\.[0-9_]*"
                       r"|[-+]?\.(?:inf|Inf|INF)|\.(?:nan|NaN|NAN))$")
_SPECIAL_RE = re.compile(r"^(?:=|<<)$")
_INDICATOR_FIRST = set(",[]{}#&*!|>'\"%@`")
_FLOW_INDICATOR = set("?:-")


def _resolves_to_non_str(s):
    return bool(_BOOL_RE.match(s) or _NULL_RE.match(s) or _INT_RE.match(s)
                or _FLOAT_RE.match(s) or _SPECIAL_RE.match(s))


def plain_ok(s, check_resolve=True):
    """True if `s` can be written as a plain scalar and read back as str.

    check_resolve=False: only the syntax rules (used after an explicit tag,
    where "!!str 10" is fine although "10" alone would read as an int).
    """
    if not s or s != s.strip():
        return False
    if check_resolve and _resolves_to_non_str(s):
        return False
    c = s[0]
    if c in _INDICATOR_FIRST:
        return False
    if c in _FLOW_INDICATOR and (len(s) == 1 or s[1] in " 	"):
        return False
    if ": " in s or " #" in s or s.endswith(":") or "	" in s:
        return False
    for ch in s:
        o = ord(ch)
        if o < 0x20 or o == 0x7f or ch in "\u0085\u2028\u2029\ufeff":
            return False
    return True


def _dq(s):
    out = ['"']
    for ch in s:
        o = ord(ch)
        if ch == "\\":
            out.append("\\\\")
        elif ch == '"':
            out.append('\\"')
        elif ch == "\n":
            out.append("\\n")
        elif ch == "\t":
            out.append("\\t")
        elif ch == "\r":
            out.append("\\r")
        elif o < 0x20 or o == 0x7f:
            out.append("\\x%02X" % o)
        else:
            out.append(ch)
    out.append('"')
    return "".join(out)


def _fmt_float(f):
    if f != f:
        return ".nan"
    if f in (float("inf"), float("-inf")):
        return ".inf" if f > 0 else "-.inf"
    s = repr(float(f))
    if "e" in s or "E" in s:
        mant, exp = s.lower().split("e")
        if "." not in mant:
            mant += ".0"
        if exp[0] not in "+-":
            exp = "+" + exp
        return mant + "e" + exp
    if "." not in s:
        s += ".0"
    return s


def scalar(v):
    """Text of a scalar value."""
    if v is None:
        return "~"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, int):
        return str(v)
    if isinstance(v, float):
        return _fmt_float(v)
    if isinstance(v, Tagged):
        if plain_ok(v.value, check_resolve=False):
            return "%s %s" % (v.tag, v.value)
        return "%s %s" % (v.tag, _dq(v.value))
    s = str(v)
    if plain_ok(s):
        return s
    return _dq(s)


def _key(k):
    s = str(k)
    if plain_ok(s):
        return s
    return _dq(s)


def _is_container(v):
    return isinstance(v, (dict, list, tuple))


def _emit(v, indent, out):
    pad = " " * indent
    if isinstance(v, dict):
        for k, x in v.items():
            if _is_container(x) and len(x) > 0:
                out.append("%s%s:" % (pad, _key(k)))
                _emit(x, indent + 2, out)
            elif isinstance(x, dict):
                out.append("%s%s: {}" % (pad, _key(k)))
            elif isinstance(x, (list, tuple)):
                out.append("%s%s: []" % (pad, _key(k)))
            else:
                out.append("%s%s: %s" % (pad, _key(k), scalar(x)))
    elif isinstance(v, (list, tuple)):
        for x in v:
            if isinstance(x, dict) and len(x) > 0:
                sub = []
                _emit(x, indent + 2, sub)
                first = sub[0][indent + 2:]
                out.append("%s- %s" % (pad, first))
                out.extend(sub[1:])
            elif isinstance(x, (list, tuple)) and len(x) > 0:
                sub = []
                _emit(x, indent + 2, sub)
                out.append("%s- %s" % (pad, sub[0][indent + 2:]))
                out.extend(sub[1:])
            elif isinstance(x, dict):
                out.append("%s- {}" % pad)
            elif isinstance(x, (list, tuple)):
                out.append("%s- []" % pad)
            else:
                out.append("%s- %s" % (pad, scalar(x)))
    else:
        out.append(pad + scalar(v))


def dump(obj):
    """Serialize obj (dict / list / scalars / Tagged) to YAML text (LF, final newline)."""
    out = []
    if _is_container(obj) and len(obj) == 0:
        return ("{}" if isinstance(obj, dict) else "[]") + "\n"
    _emit(obj, 0, out)
    return "\n".join(out) + "\n"


# --------------------------------------------------------------------------
# Loader (subset)

def _strip_comment(line):
    """Remove a trailing ' #...' comment outside quotes."""
    if "#" not in line:
        return line
    q = None
    i = 0
    n = len(line)
    while i < n:
        c = line[i]
        if q:
            if q == '"' and c == "\\":
                i += 2
                continue
            if c == q:
                if q == "'" and i + 1 < n and line[i + 1] == "'":
                    i += 2
                    continue
                q = None
        else:
            if c in "\"'" and (i == 0 or line[i - 1] in " :-[{,"):
                q = c
            elif c == "#" and (i == 0 or line[i - 1] in " \t"):
                return line[:i].rstrip()
        i += 1
    return line


def _unescape_dq(s):
    out = []
    i = 0
    n = len(s)
    esc = {"n": "\n", "t": "\t", "r": "\r", "\\": "\\", '"': '"', "/": "/",
           "0": "\0", " ": " ", "a": "\a", "b": "\b", "e": "\x1b", "f": "\f",
           "v": "\v", "N": "\u0085", "_": "\u00a0", "L": "\u2028", "P": "\u2029"}
    while i < n:
        c = s[i]
        if c == "\\" and i + 1 < n:
            d = s[i + 1]
            if d in esc:
                out.append(esc[d])
                i += 2
                continue
            if d in "xuU":
                width = {"x": 2, "u": 4, "U": 8}[d]
                out.append(chr(int(s[i + 2:i + 2 + width], 16)))
                i += 2 + width
                continue
        out.append(c)
        i += 1
    return "".join(out)


def _split_flow(s):
    items, depth, cur, q = [], 0, [], None
    for c in s:
        if q:
            cur.append(c)
            if c == q:
                q = None
            continue
        if c in "\"'":
            q = c
        elif c in "[{":
            depth += 1
        elif c in "]}":
            depth -= 1
        elif c == "," and depth == 0:
            items.append("".join(cur).strip())
            cur = []
            continue
        cur.append(c)
    if "".join(cur).strip():
        items.append("".join(cur).strip())
    return items


def parse_scalar(s, keep_tags=False):
    s = s.strip()
    if s.startswith("!!str"):
        rest = s[5:].strip()
        if rest.startswith('"') or rest.startswith("'"):
            rest = parse_scalar(rest)
        return Tagged(rest) if keep_tags else rest
    if s.startswith('"'):
        if not s.endswith('"') or len(s) < 2:
            raise YamlError("unterminated double-quoted scalar: %s" % s)
        return _unescape_dq(s[1:-1])
    if s.startswith("'"):
        if not s.endswith("'") or len(s) < 2:
            raise YamlError("unterminated single-quoted scalar: %s" % s)
        return s[1:-1].replace("''", "'")
    if s == "[]":
        return []
    if s == "{}":
        return {}
    if s.startswith("[") and s.endswith("]"):
        return [parse_scalar(x) for x in _split_flow(s[1:-1])]
    if s.startswith("{") and s.endswith("}"):
        d = {}
        for item in _split_flow(s[1:-1]):
            k, _, v = item.partition(":")
            d[parse_scalar(k)] = parse_scalar(v)
        return d
    if _NULL_RE.match(s):
        return None
    if s in ("true", "True", "TRUE", "yes", "Yes", "YES", "on", "On", "ON"):
        return True
    if s in ("false", "False", "FALSE", "no", "No", "NO", "off", "Off", "OFF"):
        return False
    if re.match(r"^[-+]?(?:0|[1-9][0-9_]*)$", s):
        return int(s.replace("_", ""))
    if _FLOAT_RE.match(s) and ":" not in s:
        t = s.replace("_", "").lower()
        if t in (".inf", "+.inf"):
            return float("inf")
        if t == "-.inf":
            return float("-inf")
        if t == ".nan":
            return float("nan")
        return float(t)
    return s


def _find_colon(s):
    """Index of the mapping ':' in a line (outside quotes), or -1."""
    q = None
    for i, c in enumerate(s):
        if q:
            if c == q:
                q = None
            continue
        if c in "\"'" and i == 0:
            q = c
            continue
        if c == ":" and (i + 1 == len(s) or s[i + 1] in " \t"):
            return i
    return -1


class _Lines(object):
    def __init__(self, text, keep_tags=False):
        self.keep_tags = keep_tags
        self.items = []
        for raw in text.splitlines():
            line = _strip_comment(raw.rstrip("\r"))
            if not line.strip() or line.strip() in ("---", "..."):
                continue
            if line.lstrip().startswith("#"):
                continue
            ind = len(line) - len(line.lstrip(" "))
            self.items.append((ind, line.strip()))
        self.pos = 0

    def peek(self):
        if self.pos < len(self.items):
            return self.items[self.pos]
        return None


def _parse_node(L, indent):
    """Parse the block starting at the current line whose indent == indent."""
    first = L.peek()
    if first is None:
        return None
    if first[1].startswith("- ") or first[1] == "-":
        return _parse_seq(L, first[0])
    return _parse_map(L, first[0])


def _parse_map(L, indent):
    d = {}
    while True:
        cur = L.peek()
        if cur is None or cur[0] < indent:
            break
        if cur[0] > indent:
            raise YamlError("bad indentation at: %s" % cur[1])
        text = cur[1]
        if text.startswith("- "):
            break
        ci = _find_colon(text)
        if ci < 0:
            raise YamlError("expected 'key: value' at: %s" % text)
        key = parse_scalar(text[:ci])
        rest = text[ci + 1:].strip()
        L.pos += 1
        if rest:
            d[key] = parse_scalar(rest, L.keep_tags)
        else:
            nxt = L.peek()
            if nxt is not None and (nxt[0] > indent or
                                    (nxt[0] == indent and (nxt[1].startswith("- ") or nxt[1] == "-"))):
                d[key] = _parse_node(L, nxt[0])
            else:
                d[key] = None
    return d


def _parse_seq(L, indent):
    out = []
    while True:
        cur = L.peek()
        if cur is None or cur[0] < indent:
            break
        if cur[0] > indent:
            raise YamlError("bad indentation at: %s" % cur[1])
        text = cur[1]
        if not (text.startswith("- ") or text == "-"):
            break
        body = text[1:].strip()
        if not body:
            L.pos += 1
            nxt = L.peek()
            if nxt is not None and nxt[0] > indent:
                out.append(_parse_node(L, nxt[0]))
            else:
                out.append(None)
            continue
        item_indent = indent + (len(text) - len(body))
        if body.startswith("- ") or (_find_colon(body) >= 0 and not body.startswith(("'", '"', "[", "{", "!!"))):
            # inline mapping/sequence item: re-feed the body as a line at item_indent
            L.items[L.pos] = (item_indent, body)
            out.append(_parse_node(L, item_indent))
        else:
            L.pos += 1
            out.append(parse_scalar(body, L.keep_tags))
    return out


def load(text, keep_tags=False):
    """Parse YAML text (subset, see module doc). keep_tags=True returns
    "!!str x" scalars as Tagged("x") instead of plain str."""
    L = _Lines(text, keep_tags)
    if L.peek() is None:
        return None
    if len(L.items) == 1 and _find_colon(L.items[0][1]) < 0 and not L.items[0][1].startswith("- "):
        return parse_scalar(L.items[0][1], keep_tags)
    v = _parse_node(L, L.peek()[0])
    if L.peek() is not None:
        raise YamlError("unexpected content at: %s" % L.peek()[1])
    return v


def load_file(path, keep_tags=False):
    with open(path, "r", encoding="utf-8") as f:
        return load(f.read(), keep_tags)
