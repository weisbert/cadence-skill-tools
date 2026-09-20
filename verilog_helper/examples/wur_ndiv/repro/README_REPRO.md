# WuR NDIV 红区复现手册 (repro kit)

一条命令跑完本周全部 WuR NDIV 仿真，输出一张 `SUMMARY.md`。

## 0. 什么东西过气隙

| 东西 | 怎么过去 |
|---|---|
| **工具**（`repro.sh` / `charac/*.vams` / `testbenches/*.vams` / `vh_delay.py` / `delays/*.json`） | 走 **skill_tools 常规 deploy**：yellow 上 `powershell -File deploy\pack.ps1` → 红区 `bash deploy/deploy.sh skill_tools_<hash>.tar.gz`。打包源是 **committed HEAD**。 |
| **设计**（`export/` struct 网表） | **已经在红区**：Stage-A `export/`（GUI 的 Extract A），或早先的 `<top>_pkg` / debug-dump build 目录（含 `export/` + `sim/run.sh` + `ext_libs.list`）。 |
| `_ref/`（本地私有网表） | **不过去**（`.gitignore`），所以 `--struct` 必须指红区自己的 build。 |

## 1. 步骤

```bash
cd /data/RFIC3/Hi1108V100_Pilot_C1Xplus/w84368867/workarea/skill_tools/verilog_helper/examples/wur_ndiv/repro

# 全量（推荐）
bash repro.sh --struct <build>            \   # 含 export/ 的目录
              --ext-libs <build>/ext_libs.list \   # 真 COT 库 -> RUN-KIND: FUNCTIONAL
              --out     <build>/repro_out

# 单项（可逗号组合）
bash repro.sh --struct <build> --ext-libs <build>/ext_libs.list --out <o> --only 32k
bash repro.sh ... --only sdm            # MASH-111：逐周期律 / 对齐 / 均值 / latency / setup / PSD
bash repro.sh ... --only modes          # committed 5-mode TB，4 个频点
bash repro.sh ... --only delay          # 延时倍率余量扫描（5.8 / 7.0 GHz）
bash repro.sh ... --only report         # vh_wur_report.py：report.md + SimVision PNG
# 常用裁剪
bash repro.sh ... --fvco 4800,7000 --scales 1,4,5 --models dly
```

- 红区登录 shell 是 **tcsh**，一律用 `bash repro.sh`，别 `./repro.sh`（上传可能丢执行位）。
- `ext_libs.list` 就是 AMS Options → Include Option Settings → **Library Files (-v)** 那张表，
  一行一条：裸路径 = `-v <path>`；`-y <dir>` / `+incdir+<dir>` 原样透传。
  见 `RED_ZONE.md` Step 4。没有它就临时用 `--ext-stub <dir>`（**只算 SMOKE，不作数**）。
- 脚本**不写** `--struct`：延时注入到副本 `<out>/export_dly`。真 COT cell **绝不注入**。
- 每次 xrun 独立 run 目录 + 独立 `-xmlibdirname` + 独立 log：`<out>/runs/<name>/{cmd.txt,xrun.log}`。

## 2. 看 SUMMARY.md

`<out>/SUMMARY.md` 头部是环境 + **RUN-KIND**，然后一张表：
`run | models | verdict | expect | kind | elapsed | key numbers`。

- **`RUN-KIND: FUNCTIONAL` + `=== TB PASS ===` 才是权威结果**（`RED_ZONE.md`）。
  用了 `--ext-stub` 只会显示 `SMOKE` —— 外部单元是理想 buffer，只证明连线和数字逻辑。
- `expect` 列：`PASS`/`FAIL` = **强制**（不符 → 整个 kit 退出码非 0，行尾打 ⚠）；
  `INFO` = 扫描点，只记录不判定（真实 cell 时序会挪断点）。
- `models`：`plain` = 原始 `export/`；`dly` = `export_dly/`（1× 延时表）。
- 退出码：0 = 全部强制项符合预期。

## 3. 期望数值（对照本地已验证结果）

| run | 期望 |
|---|---|
| `32k_*` | `TB PASS`，points=9 fails=0，45 checks；`per_out = per_dsm = (ndiv-1)` Tclk 精确；low=59 Tclk，duty 99.3–99.6 %；CLK2DSM lag 2.066–2.080 Tclk；整数 ndiv 误差 **4.8G +136 / 5.0G +78 / 5.8G +55 / 7.0G +27 ppm** |
| `sdm_w300_f7373_*` | `ALIGN best g=0` **8190/8190**；`AVG` mean **299.738110** vs 299.737280（err +8.3e-4，tol 3.2e-3）；HIST 8 个 y 值全出现 |
| `sdm_w32k_<band>_*` | **254/254**；mean err \|·\| ≤ 4.1e-2 Tclk → f_OUT_NDIV 对 32768 Hz 误差 ≤ **1.1 ppm**（静态是 27…139 ppm） |
| `sdm_lpbt51_*` | **510/510**；mean **50.735974** vs 50.737280 |
| `sdm_lat_lpbt_*` / `sdm_lat_w300_*` | last SAFE latency = **44 Tclk**（LPBT, M=50）/ **293 Tclk**（WuR, M=299）；保证边界 `M_min − 3.07` Tclk |
| `sdm_setup_w300_*` | smallest SAFE setup = **1.000 Tclk**（4.8G = 3.3333 ns；7.0G = 2.2857 ns）→ ndiv 字必须在 OUT_NDIV 上升沿前 ≥1 NDIVCKIN 稳定 |
| `sdm_psd` | `PSD PASS`；8192 周期记录 **+59.2 dB/dec**（order 2.96）；lpbt51 +62.6；254 周期的 32 kHz 点 +51…+56（记录短，仅定性） |
| `modes_*` | 每个频点 **30 checks PASS** → `=== TB PASS (top=NDIV_TOP_v7_svt_0p5W) ===`，4.8/5.0/5.8/7.0 GHz，plain 与 1× 延时均通过 |
| `dly_5.8G_wur/lpbt_*` | 0.5×–4× PASS；**LPBT 5× FAIL**（VCO/208，EOC→reload 迟到）；**6× 两模式 FAIL**（VCO/1600 / VCO/400，前级 ÷2 失效） |
| `dly_5.8G_pre_*` | `lpbt_en 1→0` 模式切换：0.5×–3× PASS，**4× 挂死**（edges=0，永不恢复；预分频 mux 非 glitch-free —— 最先坏的机制，留给设计方看） |
| `dly_7.0G_*` | 0.5×–4× PASS，**5× 两模式 FAIL**（T_VCO=142.9 ps，÷2 极限降到 ≈4.8×）；`pre` 模式切换仍是 **4× 挂死** |
| `dly_iso_*` | `tspc_pinned_6x` PASS（把 ÷2 钉回 5 ps，其余 6× → 证明是 ÷2 先坏）；`tspc_only_180ps` FAIL VCO/1600；`lpbt_reload_5x` FAIL VCO/208 |
| `report` | `report/report.md` + 6 张 SimVision PNG（需 Xvfb+PIL+simvision；缺了只出 md + `layout_*.tcl`） |

> 本周的**延时交叉核对**跑用过近似分数 F=0.3 / 0.6（4.8 / 5.8 GHz）。默认用的是 32.768 kHz
> 精确值（FNUM 286720/779264/652288/282600）。要完全复刻那次：
> `--fnum 314573,779264,629146,282600`。

## 4. 红区 vs 本地：哪些数会变，哪些不会

**结构性、不会变**（计数驱动，与 cell 延时无关）：
`M = ndiv − 1`（全 14 bit）· pwsel 律 `low = 2·floor(pwsel/2) − 3` · **ADCDIV 的 +62 offset**
（`adcdiv ≥ 2·floor(adcpwsel/2)+64` 才翻转）· SDM **z⁻¹ 对齐**（word 管下一个开始的周期）·
均值 `N_int−1+F` · PSD 3 阶整形 · M≈9k 时 50 % duty 不可达。

**会移动**（真 COT cell `INVD1/ND2D1/NR2D1/INVD8/DELAD1/DELBD1` 走 `-v`，带厂商时序，
且 **不随 `VH_TPD_SCALE` 缩放**）：
- EOC 的 `delay2` 路径时序 → ADCDIV 下降沿的**绝对**位置、duty 小数位（+62 的**计数**不变）；
- CLK2DSM lag 的小数（2.066–2.080 Tclk 这一档）；
- **延时余量断点**：本地 5.8 GHz 是 5×（LPBT reload）/ 6×（前级 ÷2）/ 4×（模式切换挂死）。
  红区只有 `export/` 被注入，COT cell 固定不变 → 断点会**往后挪**（分母变小）。
  所以 `dly_*` 全部标 `INFO`：看**谁先坏**，别抄倍数。

## 5. 不改文件重新调延时

```bash
# 整体缩放（1.0 = 表里的值）
bash repro.sh ... --only delay --scales 0.5,1,2,3
# 手工单跑，任意类单独给绝对 ps（仍乘 VH_TPD_SCALE）
xrun ... +define+VH_TPD_SCALE=2.0 +define+VH_TPD_TSPC_DIV2_PS=28
python3 ../../../vh_delay.py flags --table ../../../delays/wur_ndiv_delays.json   # 打印全部宏名
```
换真实 `.lib`/spectre 数字时，只改 `delays/wur_ndiv_delays.json`，重跑即可（`apply` 幂等）。

## 6. 已知坑

| 现象 | 说明 |
|---|---|
| `Spectre_AMS*_Lk ... checkout failed` | **良性**。纯数字 wreal 没有电学节点要解，不消耗 spectre license。 |
| `*E,FMUK: type of file could not be determined` | 少了 `-amsvlog_ext .vams,.va` —— `repro.sh` 已内置，别手敲 xrun。 |
| `RUN-KIND: SMOKE`（不该出现时） | 没给 `--ext-libs`，或表里少了某个真 `-v` 路径（`RED_ZONE.md` Step 4）。 |
| `./repro.sh: Permission denied` / `bad interpreter` | tcsh + 丢执行位：用 `bash repro.sh`。 |
| `numpy` 不存在 | 自动切到纯 stdlib Bluestein FFT（同样 +59.2 dB/dec，慢几秒）；preflight 会写明。`--backend py` 可强制。 |
| xrun license 被别人占 | 每个 run 自动重试 8 次 × 45 s（`VH_XRUN_RETRY` 可改）。 |
| 找不到 `_ref/build` | 正常，`_ref/` 从不入库。`--struct` 指红区自己的 Stage-A `export/` 所在目录。 |
| 想重跑单项 | run 目录互相独立，直接 `--only <item>` 重跑，不必清 `--out`。 |

参考：`../SDM_32K_RESULTS.md`（全量数字）· `../DELAYS.md`（延时表与余量）·
`../SPEC_CHECKLIST.md`（真值表/分频律）· `../../../RED_ZONE.md`（deploy + RUN-KIND 定义）。
