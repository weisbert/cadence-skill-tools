;; test_step1.il -- self-contained test harness for dreg_gen step 1.
;;
;; In CIW:
;;   load("/home/yusheng/cadence_work/Test/workarea/skill_tools/dreg_gen/test_step1.il")
;;   dgenTestStep1()
;;
;; After self-tests pass, optionally test against a real cell:
;;   dgenTestScanCell("yourLib" "yourCell" "symbol")
;;
;; And optionally test cell-property round-trip on a writable scratch cell:
;;   dgenTestPropOnCell("yourLib" "scratchCell" "symbol")

procedure( dgenT_assertEq(label expected actual stats)
  if( equal(expected actual) then
    printf("  PASS: %s\n" label)
    setarray(stats 0 stats[0]+1)
  else
    printf("  FAIL: %s\n        expected: %L\n        actual:   %L\n"
           label expected actual)
    setarray(stats 1 stats[1]+1)
  )
)

procedure( dgenTestStep1()
  let( (stats spec str spec2 base st loaded)
    base = "/home/yusheng/cadence_work/Test/workarea/skill_tools/dreg_gen/"

    printf("\n=== Loading dreg_gen step 1 modules ===\n")
    load(strcat(base "dgenPinScan.il"))
    load(strcat(base "dgenStore.il"))
    printf("Modules loaded.\n")

    stats = makeVector(2 0)

    printf("\n=== dgenParseBusName ===\n")
    dgenT_assertEq("D<7:0>"
      list(nil 'name "D" 'isBus t 'busHi 7 'busLo 0)
      dgenParseBusName("D<7:0>")
      stats)
    dgenT_assertEq("D<3>"
      list(nil 'name "D" 'isBus t 'busHi 3 'busLo 3)
      dgenParseBusName("D<3>")
      stats)
    dgenT_assertEq("EN"
      list(nil 'name "EN" 'isBus nil)
      dgenParseBusName("EN")
      stats)
    dgenT_assertEq("MODE<1:0>"
      list(nil 'name "MODE" 'isBus t 'busHi 1 'busLo 0)
      dgenParseBusName("MODE<1:0>")
      stats)

    printf("\n=== Spec serialization round-trip ===\n")
    spec = list(nil
      'source list(nil 'lib "L" 'cell "C" 'view "symbol")
      'target list(nil 'lib "TL" 'cell "TC" 'view "symbol")
      'dvddDefault "0.9"
      'pins list(
        list(nil 'name "D" 'isBus t 'busHi 7 'busLo 0 'enabled t 'default "DVDD")
        list(nil 'name "EN" 'isBus nil 'enabled t 'default "0")
        list(nil 'name "CLK" 'isBus nil 'enabled nil)
      ))
    str = dgenSpecToString(spec)
    spec2 = dgenStringToSpec(str)
    dgenT_assertEq("round-trip equal" spec spec2 stats)

    printf("\n=== last-state file (~/.skill_tools/dreg_gen.last) ===\n")
    st = list(nil 'lastLib "myDregLib" 'lastPrefix "dreg_")
    dgenSaveLastState(st)
    loaded = dgenLoadLastState()
    dgenT_assertEq("last-state round-trip" st loaded stats)

    printf("\n=== Summary: %d passed, %d failed ===\n" stats[0] stats[1])
    if( stats[1] == 0 then
      printf("Self-tests OK.\n")
      printf("Next: dgenTestScanCell(\"yourLib\" \"yourCell\" \"symbol\") on a real cell.\n")
    else
      printf("Failures detected. Copy this whole output back to project director.\n")
    )
    list('passed stats[0] 'failed stats[1])
  )
)

procedure( dgenTestScanCell(libName cellName viewName)
  let( (pins)
    printf("\n=== dgenScanPins(\"%s\" \"%s\" \"%s\") ===\n"
           libName cellName viewName)
    pins = dgenScanPins(libName cellName viewName)
    if( pins then
      printf("Found %d pin descriptor(s):\n" length(pins))
      foreach( p pins printf("  %L\n" p))
    else
      printf("Returned nil. Either cell has no terminals, or open failed.\n")
    )
    pins
  )
)

procedure( dgenTestPropOnCell(libName cellName viewName)
  let( (spec rt)
    printf("\n=== Property save/load on %s/%s/%s ===\n"
           libName cellName viewName)
    spec = list(nil 'note "dgen-test"
                    'pins list(list(nil 'name "T" 'isBus nil)))
    dgenSavePropOnCell(libName cellName viewName spec)
    rt = dgenLoadPropFromCell(libName cellName viewName)
    if( equal(spec rt) then
      printf("  PASS: prop round-trip on cell\n")
    else
      printf("  FAIL: prop round-trip on cell\n  saved:  %L\n  loaded: %L\n"
             spec rt)
    )
  )
)
