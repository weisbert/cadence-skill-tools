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
;
; 环境变量:
;   SKILLBRIDGE_PYTHON   - python 解释器, 默认 /usr/bin/python3
;                          (本机无裸 'python', 必须绝对路径)
;
; 幂等: pyStartServer 自身在已运行时打印 "server is already
; running" 并返回 nil; 重复 load 本文件不会重启 server.
; ============================================================

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

    ; Ref: sklangref.pdf p.627 (getShellEnvVar)
    _python = getShellEnvVar("SKILLBRIDGE_PYTHON")
    when( or( null(_python)  equal(_python "") )
        _python = "/usr/bin/python3"
    )

    pyStartServer( ?python _python )
    printf("[skillbridge] pyStartServer requested with python=%s\n" _python)
    printf("[skillbridge] socket: /tmp/skill-server-default.sock\n")
)
