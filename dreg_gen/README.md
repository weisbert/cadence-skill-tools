# Dreg Generator

A SKILL tool that auto-generates a "driver register" cell for a DUT. The
engineer selects a TOP DUT in schematic, picks which DUT pins to drive,
and a Dreg cell is generated. Each enabled pin becomes a CDF parameter on
the Dreg instance; user fills 1/0 (digital), output voltage = value × DVDD.
Bus pins (`D<7:0>`) collapse to one integer CDF param, bit-decomposed
internally to drive each bit.

**Status:** Step 1 (data layer) complete and validated on IC6.1.8.
Step 2 (Verilog-A generator) and later steps are in development.

## Files

- **dgenPinScan.il** — `dgenScanPins` opens the source cellview and
  returns a list of pin descriptor plists. `dgenParseBusName` parses
  Cadence bus syntax (`D<7:0>`, `D<7>`, `D`).
- **dgenStore.il** — `dgenSpecToString` / `dgenStringToSpec`,
  `dgenSavePropOnCell` / `dgenLoadPropFromCell` (cellview property
  `dgenConfig`), `dgenSaveLastState` / `dgenLoadLastState` (file at
  `~/.skill_tools/dreg_gen.last`).

## Bus terminal handling

Cadence schematic terminals usually return as a single bus terminal whose
`term~>name` is `"D<7:0>"`. The parser also tolerates the bit-decomposed
case where the terminal list contains separate `D<0>`...`D<7>` entries:
after parsing each name it groups same-base-name bus descriptors into one
covering descriptor (`busHi = max`, `busLo = min`). Scalar terminals
(`EN`) pass through untouched.

Citation for opening / closing the cellview and reading terminals:
`skdfref.pdf` p.900 (`dbOpenCellViewByType`), p.873 (`dbClose`). The
`cv~>terminals` and `term~>name` / `term~>direction` property notation
are standard `dbObject` accessors documented in the same reference.

**Page-number convention:** all `; Ref:` citations use *physical PDF
page* numbers (matching
`~/.claude/skills/virtuoso-skill/assets/function_index.tsv` and the
Read-tool `pages:` argument). For PDFs with front-matter (like
`skdfref.pdf`, +2 pages of cover/ToC) the physical page differs from the
printed footer page; for PDFs without front-matter (like `sklangref.pdf`)
they coincide.

## Loading and testing in CIW

```skill
load("<path-to-repo>/dreg_gen/dgenPinScan.il")
load("<path-to-repo>/dreg_gen/dgenStore.il")
```

### dgenParseBusName

```skill
dgenParseBusName("D<7:0>")   ; => (nil name "D" isBus t busHi 7 busLo 0)
dgenParseBusName("D<3>")     ; => (nil name "D" isBus t busHi 3 busLo 3)
dgenParseBusName("EN")       ; => (nil name "EN" isBus nil)
```

### dgenScanPins

Replace the lib/cell with one that exists in your environment.

```skill
pins = dgenScanPins("myLib" "myDUT" "symbol")
foreach(p pins printf("%L\n" p))
```

### Round-trip serialization (acceptance test)

```skill
spec = list(nil 'source list(nil 'lib "L" 'cell "C" 'view "symbol")
                'pins list(list(nil 'name "D" 'isBus t 'busHi 7 'busLo 0
                                    'enabled t 'default "DVDD")))
str   = dgenSpecToString(spec)
spec2 = dgenStringToSpec(str)
equal(spec spec2)            ; => t
```

### Cell property save / load

```skill
dgenSavePropOnCell("myDregLib" "dreg_myDUT" "symbol" spec)
dgenLoadPropFromCell("myDregLib" "dreg_myDUT" "symbol")
```

### Last-state save / load

```skill
dgenSaveLastState(list(nil 'lastLib "myDregLib" 'lastPrefix "dreg_"))
dgenLoadLastState()
```

The file lives at `$HOME/.skill_tools/dreg_gen.last`; the directory is
created on first save.
