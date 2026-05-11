;; test_patterns.il -- self-tests for dgenPatterns.il (Phase 1 of pin
;; auto-categorization feature).
;;
;; In CIW:
;;   load("/home/yusheng/cadence_work/Test/workarea/skill_tools/dreg_gen/test_patterns.il")
;;   dgenTestPatterns()

procedure( dgenT_pAssertEq(label expected actual stats)
  if( equal(expected actual) then
    printf("  PASS: %s\n" label)
    setarray(stats 0 stats[0]+1)
  else
    printf("  FAIL: %s\n        expected: %L\n        actual:   %L\n"
           label expected actual)
    setarray(stats 1 stats[1]+1)
  )
)

;; Build a minimal pin plist with the fields dgenPatternsClassify reads.
procedure( dgenT_mkPin(name dir isBus)
  list(nil 'name name 'srcDirection dir 'isBus isBus)
)

procedure( dgenTestPatterns()
  let( (stats base pats path savedHome power dreg )
    base = "/home/yusheng/cadence_work/Test/workarea/skill_tools/dreg_gen/"

    printf("\n=== Loading dgenPatterns + deps ===\n")
    load(strcat(base "dgenStore.il"))     ;; for dgen_ensureLastDir
    load(strcat(base "dgenPinScan.il"))   ;; not strictly needed, but mirrors prod load order
    load(strcat(base "dgenPatterns.il"))
    printf("Modules loaded.\n")

    stats = makeVector(2 0)
    pats = dgenPatternsDefault()

    printf("\n=== dgenPat_escape (literal metachars) ===\n")
    ;; Alphanumeric -> no-op
    dgenT_pAssertEq("escape VDD" "VDD" dgenPat_escape("VDD") stats)
    dgenT_pAssertEq("escape EN_N" "EN_N" dgenPat_escape("EN_N") stats)
    ;; Metachars get a leading backslash
    dgenT_pAssertEq("escape ()" "\\(VDD\\)" dgenPat_escape("(VDD)") stats)
    dgenT_pAssertEq("escape ." "a\\.b" dgenPat_escape("a.b") stats)
    dgenT_pAssertEq("escape +" "x\\+y" dgenPat_escape("x+y") stats)

    printf("\n=== dgenPatternsMatchKw (prefix word-boundary, case-insensitive) ===\n")
    power = dgenPatternsDefaultPower()
    dreg  = dgenPatternsDefaultDreg()
    ;; Power true positives
    dgenT_pAssertEq("VDD hits power"     t   dgenPatternsMatchKw("VDD"      power) stats)
    dgenT_pAssertEq("VDDA hits power"    t   dgenPatternsMatchKw("VDDA"     power) stats)
    dgenT_pAssertEq("VDDIO_core hits"    t   dgenPatternsMatchKw("VDDIO_core" power) stats)
    dgenT_pAssertEq("core_VDD hits"      t   dgenPatternsMatchKw("core_VDD" power) stats)
    dgenT_pAssertEq("vss lowercase hits" t   dgenPatternsMatchKw("vss"      power) stats)
    dgenT_pAssertEq("GND hits power"     t   dgenPatternsMatchKw("GND"      power) stats)
    ;; Power true negatives -- the substring-vs-boundary trap
    dgenT_pAssertEq("XVDD no-hit"      nil   dgenPatternsMatchKw("XVDD"     power) stats)
    dgenT_pAssertEq("myVDD no-hit"     nil   dgenPatternsMatchKw("myVDD"    power) stats)
    dgenT_pAssertEq("DOUT no-hit pwr"  nil   dgenPatternsMatchKw("DOUT"     power) stats)
    dgenT_pAssertEq("EN no-hit pwr"    nil   dgenPatternsMatchKw("EN"       power) stats)
    ;; Dreg true positives
    dgenT_pAssertEq("EN hits dreg"       t   dgenPatternsMatchKw("EN"       dreg)  stats)
    dgenT_pAssertEq("ENABLE hits dreg"   t   dgenPatternsMatchKw("ENABLE"   dreg)  stats)
    dgenT_pAssertEq("RST_N hits dreg"    t   dgenPatternsMatchKw("RST_N"    dreg)  stats)
    dgenT_pAssertEq("rstn lowercase"     t   dgenPatternsMatchKw("rstn"     dreg)  stats)
    dgenT_pAssertEq("CLK hits dreg"      t   dgenPatternsMatchKw("CLK"      dreg)  stats)
    ;; Dreg true negatives -- substring traps
    dgenT_pAssertEq("DRAIN no-hit dreg" nil  dgenPatternsMatchKw("DRAIN"    dreg)  stats)
    dgenT_pAssertEq("OPEN no-hit dreg"  nil  dgenPatternsMatchKw("OPEN"     dreg)  stats)
    dgenT_pAssertEq("FIRST no-hit"      nil  dgenPatternsMatchKw("FIRST"    dreg)  stats)
    ;; Empty/blank keywords are ignored, not match-all
    dgenT_pAssertEq("blank-only no-hit" nil  dgenPatternsMatchKw("anything" list("" "  ")) stats)

    printf("\n=== dgenPatternsClassify (priority order) ===\n")
    ;; Pure power rails
    dgenT_pAssertEq("VDD input  -> power"   'power
      dgenPatternsClassify(dgenT_mkPin("VDD" "input" nil) pats) stats)
    dgenT_pAssertEq("VSS inout  -> power"   'power
      dgenPatternsClassify(dgenT_mkPin("VSS" "inputOutput" nil) pats) stats)
    dgenT_pAssertEq("GND no-dir -> power"   'power
      dgenPatternsClassify(dgenT_mkPin("GND" "input" nil) pats) stats)
    ;; Output pins always 'other, even if name matches power keyword
    dgenT_pAssertEq("vss_mon output -> other" 'other
      dgenPatternsClassify(dgenT_mkPin("vss_mon" "output" nil) pats) stats)
    dgenT_pAssertEq("DOUT output -> other"    'other
      dgenPatternsClassify(dgenT_mkPin("DOUT" "output" nil) pats) stats)
    ;; Bus pin -> dreg even if name doesn't match dreg keyword
    dgenT_pAssertEq("foo<3:0> bus -> dreg"    'dreg
      dgenPatternsClassify(dgenT_mkPin("foo" "input" t) pats) stats)
    ;; Name-matched dreg
    dgenT_pAssertEq("EN input -> dreg"        'dreg
      dgenPatternsClassify(dgenT_mkPin("EN" "input" nil) pats) stats)
    dgenT_pAssertEq("RSTN input -> dreg"      'dreg
      dgenPatternsClassify(dgenT_mkPin("RSTN" "input" nil) pats) stats)
    ;; inout w/o name match -> power (rail fallback)
    dgenT_pAssertEq("inout unknown -> power" 'power
      dgenPatternsClassify(dgenT_mkPin("foo_rail" "inputOutput" nil) pats) stats)
    ;; Plain unknown scalar input -> other
    dgenT_pAssertEq("scalar input -> other"  'other
      dgenPatternsClassify(dgenT_mkPin("VBG" "input" nil) pats) stats)
    ;; Bus on output stays 'other (output priority)
    dgenT_pAssertEq("bus output -> other"    'other
      dgenPatternsClassify(dgenT_mkPin("data" "output" t) pats) stats)
    ;; Power-keyword + bus: power wins (rare but explicit, per priority order)
    dgenT_pAssertEq("VDDA<1:0> -> power"     'power
      dgenPatternsClassify(dgenT_mkPin("VDDA" "input" t) pats) stats)

    printf("\n=== dgenPatternsSave / Load round-trip ===\n")
    ;; Field-by-field compare; sprintf %L doesn't preserve plist key order,
    ;; so whole-plist equal would fail on a perfectly valid round-trip.
    let( (custom rt)
      custom = list(nil 'schemaVersion 1
                        'power list("VDD" "VBG" "VREF")
                        'dreg  list("EN" "RST" "MYSIG"))
      dgenPatternsSave(custom)
      rt = dgenPatternsLoad()
      dgenT_pAssertEq("round-trip schemaVersion"
        get(custom 'schemaVersion) get(rt 'schemaVersion) stats)
      dgenT_pAssertEq("round-trip power list"
        get(custom 'power) get(rt 'power) stats)
      dgenT_pAssertEq("round-trip dreg list"
        get(custom 'dreg)  get(rt 'dreg)  stats)
      ;; Restore the default dictionary so leaving the test doesn't strand
      ;; the user's pattern file in test state.
      dgenPatternsSave(dgenPatternsDefault())
    )

    printf("\n=== Summary: %d passed, %d failed ===\n" stats[0] stats[1])
    if( stats[1] == 0 then
      printf("dgenPatterns self-tests OK.\n")
    else
      printf("Failures detected.\n")
    )
    list('passed stats[0] 'failed stats[1])
  )
)
