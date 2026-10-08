; test_scaffold_smoke.il -- scaffold smoke test: plugin load, MyTool entry,
; JSON/TSV utilities, site lookup, IPC round trip, headless panel build.
;
; Run: python3 relkit/tests/run_skill_test.py relkit/tests/test_scaffold_smoke.il
; Needs <workarea>/.relkit_site.json (the VM dev site config) for the site checks;
; writes scratch files under <workarea>/relkit_dev/tmp/.

(rkTestBegin "scaffold_smoke")

(let (tmp obj s back site path p f form1 form2 nm1 nm2 tsv cmd pid out res wa)
  (setq wa (rkWorkarea))
  (setq tmp (rkPathJoin wa "relkit_dev/tmp"))
  (rkCheck "mkdirs tmp" (rkMkdirs tmp))

  ; --- plugin load + MyTool registration ------------------------------------
  (rkCheck "relkitDir is a dir" (and (stringp relkitDir) (isDir relkitDir)))
  (rkCheck "relkitDir trailing slash" (pcreMatchp "/$" relkitDir))
  (rkCheck "MyTool has RelStudio..."
    (exists e (mtListRegistered) (equal (car e) "RelStudio...")))
  (rkCheck "MyTool callback is rkOpenPanel"
    (exists e (mtListRegistered) (and (equal (car e) "RelStudio...") (eq (cadr e) 'rkOpenPanel))))
  (foreach fn (list 'rkSiteLoad 'rkMaeGetContext 'rkMaeExportNetlist 'rkResultsJumpToInstance
                    'rkResultsPickDut 'rkAgedCreateCorners 'rkIpcRun 'rkIpcRunSync 'rkOpenPanel
                    'rkGuiBuild 'rkJsonRead 'rkJsonWrite 'rkTsvRead)
    (rkCheck (sprintf nil "defined %s" fn) (getd fn)))

  ; --- JSON reader ----------------------------------------------------------
  (setq obj (rkJsonParse
    "{\"a\": [1, -2.5e1, \"x\\ny\\t\\\"q\\\"\", true, false, null], \"b\": {\"c\": \"d\", \"e\": {}}, \"u\": \"\\u0041\\u00e9\", \"empty\": \"\", \"arr0\": []}"))
  (rkCheck "object is table" (tablep obj))
  (rkCheckEqual "int" (rkGet obj "a.0") 1)
  (rkCheckEqual "float" (rkGet obj "a.1") -25.0)
  (rkCheckEqual "escapes" (rkGet obj "a.2") "x\ny\t\"q\"")
  (rkCheckEqual "true" (rkGet obj "a.3") t)
  (rkCheckEqual "false" (rkGet obj "a.4") nil)
  (rkCheckEqual "nested" (rkGet obj "b.c") "d")
  (rkCheck "empty object is table" (tablep (rkGet obj "b.e")))
  (rkCheckEqual "unicode ascii" (substring (rkGet obj "u") 1 1) "A")
  (rkCheckEqual "unicode utf8 len" (strlen (rkGet obj "u")) 3)
  (rkCheckEqual "empty string" (rkGet obj "empty") "")
  (rkCheckEqual "empty array" (rkGet obj "arr0") nil)
  (rkCheckEqual "missing key default" (rkGet obj "nope.x" "dflt") "dflt")
  (rkCheckEqual "keys sorted" (rkKeys obj) (list "a" "arr0" "b" "empty" "u"))
  (rkCheck "bad json errors" (null (errset (rkJsonParse "{\"a\": }") nil)))
  (rkCheck "trailing junk errors" (null (errset (rkJsonParse "[1] x") nil)))

  ; --- JSON writer round trip -------------------------------------------------
  (setq obj (rkMakeObj))
  (rkPut obj "s" "tab\there \"quoted\" back\\slash")
  (rkPut obj "n" 42)
  (rkPut obj "f" 0.5)
  (rkPut obj "l" (list 1 "two" t))
  (rkPut obj "nul" nil)
  (rkPut obj "fls" rkJsonFalse)
  (rkPut obj "ea" rkJsonEmptyArray)
  (rkPut obj "sub" (rkMakeObj))
  (setq s (rkJsonToString obj))
  (setq back (rkJsonParse s))
  (rkCheckEqual "rt string" (rkGet back "s") "tab\there \"quoted\" back\\slash")
  (rkCheckEqual "rt int" (rkGet back "n") 42)
  (rkCheckEqual "rt float" (rkGet back "f") 0.5)
  (rkCheckEqual "rt list" (rkGet back "l") (list 1 "two" t))
  (rkCheck "rt false text" (pcreMatchp "\"fls\": false" s))
  (rkCheck "rt null text" (pcreMatchp "\"nul\": null" s))
  (rkCheck "rt [] text" (pcreMatchp "\"ea\": \\[\\]" s))
  (rkCheck "rt {} text" (pcreMatchp "\"sub\": \\{\\}" s))
  (setq path (rkPathJoin tmp "rt.json"))
  (rkCheck "write file" (rkJsonWrite obj path))
  (rkCheckEqual "read file" (rkGet (rkJsonRead path) "s") "tab\there \"quoted\" back\\slash")

  ; --- TSV ------------------------------------------------------------------
  (setq path (rkPathJoin tmp "t.tsv"))
  (setq p (outfile path "w"))
  (fprintf p "_inst\tPass\tval\nI0.X1.M3\t\t1.5\n\tfail\t\n")
  (close p)
  (setq tsv (rkTsvRead path))
  (rkCheckEqual "tsv header" (car tsv) (list "_inst" "Pass" "val"))
  (rkCheckEqual "tsv row1 empty middle" (car (cadr tsv)) (list "I0.X1.M3" "" "1.5"))
  (rkCheckEqual "tsv row2 empty ends" (cadr (cadr tsv)) (list "" "fail" ""))

  ; --- misc utils -------------------------------------------------------------
  (rkCheck "timestamp shape" (pcreMatchp "^[0-9]{8}-[0-9]{6}$" (rkTimestamp)))
  (rkCheckEqual "expand USER" (rkExpandVars "${USER}/x") (strcat (rkUser) "/x"))
  (rkCheckEqual "bare $ literal" (rkExpandVars "$MODEL_ROOT/alps") "$MODEL_ROOT/alps")
  (rkCheckEqual "unknown kept" (rkExpandVars "a/${RK_NO_SUCH_VAR_X}/b") "a/${RK_NO_SUCH_VAR_X}/b")
  (rkCheckEqual "shell quote" (rk_shq "a'b") "'a'\\''b'")

  ; --- site ---------------------------------------------------------------------
  (setq site (rkSiteLoad nil t))
  (rkCheck "site is table" (tablep site))
  (rkCheckEqual "site path = workarea file" (rkSitePath) (rkPathJoin wa ".relkit_site.json"))
  (rkCheckEqual "site python" (rkSiteGet "python") "/usr/bin/python3")
  (rkCheckEqual "site merged default" (rkSiteGet "cluster.CPU") 8)
  (rkCheckEqual "site override" (rkSiteGet "cluster.Queue") "normal")
  (rkCheckEqual "site default policy" (rkSiteGet "emir.license_policy") "wait_forever")
  (rkCheckEqual "site defaults.aging" (rkSiteGet "defaults.aging.life_time") "10")
  (rkCheck "relstudio_home set" (stringp (rkRelstudioHome)))
  (rkCheck "model map literal $" (pcreMatchp "^\\$MODEL_ROOT/" (rkGet (car (rkSiteGet "model_file_map")) "replace")))

  ; --- IPC round trip: Python CLI reachable from Virtuoso, SKILL reads its JSON --
  (setq out (rkPathJoin tmp "version_out.json"))
  (when (isFile out) (deleteFile out))
  (setq cmd (rkIpcCommandLine "version" nil out))
  (setq pid (ipcBeginProcess (sprintf nil "/bin/sh -c %s" (rk_shq cmd))))
  (ipcWait pid 30)
  (rkCheckEqual "python exit 0" (ipcGetExitStatus pid) 0)
  (setq res (car (errset (rkJsonRead out) nil)))
  (rkCheckEqual "python ok" (rkGet res "ok") t)
  (rkCheckEqual "python cmd" (rkGet res "cmd") "version")

  ; --- headless panel (built, never displayed: display blocks the bridge) -------
  (setq form1 (rkGuiBuild))
  (setq nm1 (get form1 'hiFormSym))
  (setq form2 (rkGuiBuild))
  (setq nm2 (get form2 'hiFormSym))
  (rkCheck "form built" (and form1 form2))
  (rkCheck "fresh name per build" (and nm1 nm2 (neq nm1 nm2)))
  (rkCheck "not displayed" (null (hiIsFormDisplayed form2)))
  (rkCheckEqual "current form" (rkGuiCurrentForm) form2)
  (errset (hiFormCancel form1) nil)
  (errset (hiFormCancel form2) nil))

(rkTestReport)
