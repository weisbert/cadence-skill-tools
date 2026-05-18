; ============================================================
; sbStart.il -- generic skillbridge launcher (path-portable)
;
; 用法 (在 .cdsinit 或 CIW):
;   load("/abs/path/to/skill_tools/skillbridge/sbStart.il")
;
; 行为:
;   1. 从自身所在目录加载兄弟文件 python_server.il
;      (定义 pyStartServer / pyKillServer / pyShowLog ...)
;   2. 调用 pyStartServer, spawn Python 服务监听
;      /tmp/skill-server-default.sock
;   3. **如果检测到 axl worker VM (cdsinit 在子进程里执行), 跳过
;      第 2 步** -- 否则 worker 也会去抢同一个 socket, 把主 VM 的
;      server 顶掉, Python client 连过去就找不到 Maestro session.
;      Worker 检测: /proc/self/cmdline 含 "-axlChildIdFlag".
;      根因 + 修复历史见 simkit DECISIONS #60 (2026-05-18).
;
; 环境变量:
;   SKILLBRIDGE_PYTHON   - python 解释器, 默认 /usr/bin/python3
;                          (本机无裸 'python', 必须绝对路径)
;
; 幂等: pyStartServer 自身在已运行时打印 "server is already
; running" 并返回 nil; 重复 load 本文件不会重启 server.
; ============================================================

; -----------------------------------------------------------------
; sbIsAxlWorker -- t if THIS virtuoso process is an axl worker child
; spawned for sim dispatch (axlRunAllTests fan-out), nil otherwise.
;
; Workers are spawned by Maestro's axl framework with cmdline arg
; `-axlChildIdFlag <N>` (see runICRP<N> wrapper script). Main VM
; never has this flag.
;
; Implementation: shell out to grep — sidesteps SKILL `getc`'s broken
; EOF semantics (returns symbol `t` for both EOF AND character 't', so
; reading binary content char-by-char truncates at the first 't' byte).
; `grep -aq` treats /proc/<pid>/cmdline as text and handles embedded
; NULs without truncating; exit-code-style usage via && echo y. The
; spawned shell's $PPID resolves to virtuoso (we have no SKILL getpid).
; -----------------------------------------------------------------
procedure( sbIsAxlWorker()
    let( (proc out)
        proc = ipcBeginProcess(
            "sh -c 'grep -aq axlChildIdFlag /proc/$PPID/cmdline && echo y'"
        )
        ipcWait(proc)
        out = ipcReadProcess(proc)
        and(stringp(out) pcreMatchp("y" out))
    )
)

let( (_thisFile _thisDir _serverIl _python)

    ; self-locate: 同款写法见兄弟文件 python_server.il 第 3 行
    _thisFile = get_filename(piport)
    ; Ref: sklangref.pdf p.191 (pcreReplace)
    _thisFile = pcreReplace(pcreCompile("^ +| +$") _thisFile "" 0)

    ; 去掉末尾 "/<filename>" 得到目录
    _thisDir = pcreReplace(pcreCompile("/[^/]+$") _thisFile "" 1)

    _serverIl = strcat(_thisDir "/python_server.il")
    ; Ref: sklangref.pdf p.428 (isFile)
    unless( isFile(_serverIl)
        error("[skillbridge] python_server.il not found at %s -- must sit beside sbStart.il" _serverIl)
    )

    load(_serverIl)
    printf("[skillbridge] server defs loaded from %s\n" _serverIl)

    ; Skip pyStartServer in axl worker VMs (would steal main VM's
    ; socket binding and break every subsequent Python client call).
    ; Lisp-style if: 3 args, multi-stmt else wrapped in progn.
    if( sbIsAxlWorker()
        printf("[skillbridge] axl worker VM detected (cmdline has -axlChildIdFlag); skipping pyStartServer\n")
        progn(
            ; Ref: sklangref.pdf p.627 (getShellEnvVar)
            _python = getShellEnvVar("SKILLBRIDGE_PYTHON")
            when( or( null(_python)  equal(_python "") )
                _python = "/usr/bin/python3"
            )

            pyStartServer( ?python _python )
            printf("[skillbridge] pyStartServer requested with python=%s\n" _python)
            printf("[skillbridge] socket: /tmp/skill-server-default.sock\n")
        )
    )
)
