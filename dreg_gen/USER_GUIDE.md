# Dreg Generator — Designer's Guide / 设计者使用手册

> 面向使用者的简明手册。开发者向的实现说明见 `README.md`。
> A short guide for designers. For implementation details see `README.md`.

---

## 1. 这是什么 / What it is

**中文.** 给定一个 DUT cellview，自动生成一个 "driver register" cell：每个 DUT 输入引脚变成一个 CDF 参数；testbench 里把这个 dreg 拖进来，给参数填 1/0，仿真时它就在对应引脚上输出 `value × DVDD`。Bus 引脚 (`D<7:0>`) 折叠成一个整型参数，仿真时自动按位拆分。

**EN.** Given a DUT cellview, auto-generates a "driver register" cell whose pins drive the DUT. Each DUT input becomes a CDF parameter; in the testbench you instantiate the dreg and fill 1/0, and at sim time it drives `value × DVDD` onto the matching pin. Bus pins (`D<7:0>`) collapse to one integer parameter and are bit-decomposed automatically.

**中文.** 除了直流值，每个信号还可以定义**时序**（在某个时间翻转/跳变、指定边沿时间），见 §6。时序直接写进生成的 dreg cell，别人拿这个 cell 仿真时自动带上同样的时序。

**EN.** Besides a DC value, every signal can carry **timing** (edges at given times with given edge times) — see §6. The timing is built into the generated dreg cell, so anyone who instantiates it simulates the same stimulus.

> **目的 / Why.** 省去手画 driver 符号、写 Verilog-A、配 CDF 的重复劳动。换 DUT 时一键重生成。
> Save the manual work of drawing a driver symbol, writing Verilog-A, and configuring CDF. Re-run when the DUT changes.

---

## 2. 打开方式 / How to open

**中文.** CIW 里直接：

**EN.** From the CIW:

```skill
dgenOpenGUI()
```

或在任意 schematic / Maestro / ADE-XL 窗口的菜单栏：**MyTool → Dreg Generator**。
Or use the menu on any schematic / Maestro / ADE-XL window: **MyTool → Dreg Generator**.

---

## 3. 三步工作流 / Three-step workflow

**中文.**
1. **选 DUT.** 在顶部填 Lib/Cell/View，或点 `[Select from Schematic]` / `[Browse Library...]`，再点 `[Load Pins]`。
2. **配置.** 设 Target Lib/Cell（生成物存放位置）、DVDD 默认值、默认值模式；勾选需要驱动的引脚，必要时改单个引脚的值。
3. **生成.** 点 **OK** 或 **Apply**。symbol、`veriloga/veriloga.va`、CDF 三件一起写出，可立即在 testbench 中实例化。

**EN.**
1. **Pick the DUT.** Fill Lib/Cell/View at the top, or click `[Select from Schematic]` / `[Browse Library...]`, then `[Load Pins]`.
2. **Configure.** Set Target Lib/Cell (where the dreg lands), DVDD default, default-value mode; tick the pins you want driven, override per-pin values as needed.
3. **Generate.** Click **OK** or **Apply**. Symbol, `veriloga/veriloga.va`, and CDF are written together; instantiate the cell in your testbench immediately.

---

## 4. GUI 字段说明 / GUI fields

### 顶部 — DUT source / Top — DUT source

| 字段 / Field | 说明 / Meaning |
|---|---|
| Source Lib / Cell / View | DUT 的位置 / Location of the DUT |
| `[Select from Schematic]` | 在 schematic 里点一个实例自动填入 / Click an instance in a schematic to fill in |
| `[Browse Library...]` | 弹出 Library Manager 选 / Pop the Library Manager |
| `[Load Pins]` | 扫描 DUT 引脚，铺出下方引脚列表 / Scan pins and render the pin list |

### 中部 — Target & defaults / Middle — Target & defaults

| 字段 / Field | 说明 / Meaning |
|---|---|
| Target Lib / Cell | 生成物落在哪里（cell 不存在会自动创建）/ Where to write (cell auto-created if missing) |
| `[Save As...]` | 另存为一个新 cell（原 cell 不动，可顺便把你选中的那个实例换成新 cell，见 §6.5），或同一个 cell 的新时序 view（见 §6.6）/ Write a new cell (the current one is untouched; optionally switch the selected instance to it — §6.5), or a new timing view of the same cell (§6.6) |
| DVDD default | `value × DVDD` 里的 DVDD 默认数值 / Default for DVDD in `value × DVDD` |
| Default values | 4 种默认值模式，见 §5 / 4 default-value modes — see §5 |
| Variable name | 仅当模式 = "Variable, custom pattern" 时启用 / Active only when mode = "Variable, custom pattern" |
| `[Timing Table...]` | 打开时序表，给信号加边沿；右边一行显示总数 / Open the timing table to add edges; the box next to it shows the total — see §6 |

### 引脚工具栏 / Pin toolbar

| 按钮 / Button | 效果 / Effect |
|---|---|
| All Pins | 全部勾上 / Enable every pin |
| No Pins | 全部取消 / Disable every pin |
| Only DREG | 仅勾选被识别为 `[DREG]` 的引脚 / Enable only `[DREG]`-classified pins |
| Auto Suggest | `[DREG]` 勾选、`[PWR]` 取消、其他按方向判断；`[PWR]` 引脚类型设为 Analog / `[DREG]` on, `[PWR]` off, others by direction; `[PWR]` pins set to Analog |
| Edit Patterns... | 编辑分类关键字（power / dreg）/ Edit classifier keywords (power / dreg) |

**中文.** 每一行引脚名前会标 `[PWR]` 或 `[DREG]` 前缀（其他不标），方便一眼区分电源轨和控制信号。前缀只是提示，分类规则可在 `[Edit Patterns...]` 里改。

**EN.** Each pin row is prefixed with `[PWR]` or `[DREG]` (or unprefixed) so you can scan supply rails vs. control inputs at a glance. The prefix is only a hint — edit the classifier under `[Edit Patterns...]`.

### 引脚列表 / Pin list

| 列 / Column | 说明 / Meaning |
|---|---|
| `[x]` 勾选框 / Tick box | 是否纳入 dreg / Whether to include this pin |
| value | 默认值（= 有时序时的**初始电平**）；模式非 literal 时变灰，显示解析后的变量名作为预览 / Default value (= the **initial level** when the signal has timing); greyed out under non-literal modes and shows the resolved variable name as preview |
| Digital / Analog | Digital：输出 `value × DVDD`；Analog：直接输出 value 伏（例如给 VDD 做上电斜坡）。Bus 引脚固定 Digital / Digital drives `value × DVDD`; Analog drives value volts (e.g. ramp a VDD). Bus pins are always Digital |
| 时序摘要 / Timing summary | `DC` 或 `3 edges 5n..120n`，只读 / `DC` or `3 edges 5n..120n`, read-only |

### Custom variables（可选）/ Custom variables (optional)

**中文.** `+ Digital` / `+ Analog` 按钮可以追加 DUT 引脚之外的额外驱动信号（比如外部 enable、模拟偏置）。Digital 用 `value × DVDD` 驱动；Analog 直接驱动设定的电压。

**EN.** `+ Digital` / `+ Analog` lets you add extra driven signals beyond the DUT's pins (e.g. an external enable, an analog bias). Digital drives `value × DVDD`; Analog drives the literal voltage.

---

## 5. 默认值模式 / Default-value modes

**中文.** 决定 CDF 上每个参数的"出厂默认值"是写死的数字、还是 testbench 里的变量名。生成的 dreg 实例的参数还是可以在 ADE 里手动覆盖——这里设的只是默认。

**EN.** Controls what gets written as the CDF default for each parameter — a hard-coded number, or a variable name that the testbench resolves. Per-instance values can always be overridden in ADE.

| 模式 / Mode | DVDD 默认 / DVDD default | 标量引脚 `EN` / Scalar pin `EN` | Bus 引脚 `D<3:0>` / Bus pin `D<3:0>` |
|---|---|---|---|
| Hard-coded number | `0.9`（你填的数）/ Your number | `0` | `0` |
| Leave empty | `""` | `""` | `""` |
| Variable = pin name | `DVDD` | `EN` | `D` |
| Variable, custom pattern (`d_*`) | `DVDD` | `d_EN` | `d_D` |

> **中文.** "Variable" 类模式要求 testbench / ADE-XL 的 design variables 表里有同名变量，否则仿真报 "undefined variable"。
> **EN.** "Variable" modes assume the testbench / ADE-XL design-variables table has matching names; otherwise sim fails with "undefined variable".

---

## 6. 时序信号 / Transient timing

### 6.1 定义时序 / Defining timing

**中文.** 点 `[Timing Table...]` 打开时序表。上面是表格（只读，点一行就能编辑它），下面一行是编辑区：选 Signal，填 Time、Edge，按 **Add**；选中某行后改完按 **Update**，或按 **Delete** 删除。按 **OK** 回到主界面（每个引脚右边会显示摘要），最后在主界面按 **OK / Apply** 生成。

- **Time** = 边沿**开始**的时刻；**Edge** = 边沿时间（从开始到结束线性变化，上升和下降都按这个算）。单位可写 `5n`、`5ns`、`50ps`、`1.2u`、`0`，也可以写变量，见 §6.2。
- **DC 值和瞬态是分开的（和 Cadence 的源一样，比如 vpulse 的 DC voltage 和波形）。** 主界面的 value 列，也就是 q 里的 `d_rx_en` 这些，是 **DC 值**：dc / ac / noise / stb 等分析用它。**tran** 从时序表里的 **init** 行开始，再按边沿走。
- **init 行**：每个有时序的信号的第一行。加第一个边沿时自动填 `0`，可以改成 0/1、一个数值、变量，或 `DC`（= 从 DC 值开始）。选中 init 行，改 Value，按 Update。
- **单比特数字信号**：Value 空着 = 翻转；也可以填 `0` / `1`、变量，或 `DC`（= 到达 DC 值）。表格的 **After** 列显示每行之后的电平。
- **Bus**：Value 填新的整数（如 `165`）或 `DC`。**Analog**：Value 填新的电压（如 `1.8`、`900m`）或 `DC`，Edge 就是斜坡时间。
- `View` 可切换"按信号"/"按时间"，按时间看能看清各信号的先后顺序。

例 1：EN 在 5ns 上升（50ps），50ns 下降（100ps），120ns 再上升（110ps）：

| Signal | Time | Edge | Value | After |
|---|---|---|---|---|
| EN | init | - | 0 | 0 |
| EN | 5n | 50p | | 1 |
| EN | 50n | 100p | | 0 |
| EN | 120n | 110p | | 1 |

例 2（"RX mode"）：DC 值是变量 `rx_en`（=1 表示 RX mode）。tran 里先 0、50ns 时到达它：

| Signal | Time | Edge | Value | After |
|---|---|---|---|---|
| EN | init | - | 0 | 0 |
| EN | 50n | 50p | DC | rx_en |

`rx_en=1`：DC 分析里 EN=1，tran 里先 0、50ns 变 1；`rx_en=0`：两边都是 0。

**EN.** Click `[Timing Table...]`. The table on top is read-only — click a row to edit it in the edit row below: pick a Signal, fill Time and Edge, press **Add**; or change a selected row and press **Update** / **Delete**. **OK** returns to the main form (each pin shows a summary); then generate with **OK / Apply** there.

- **Time** = when the edge **starts**; **Edge** = edge time (linear ramp, same for rising and falling). Units: `5n`, `5ns`, `50ps`, `1.2u`, `0` — or variables, see §6.2.
- **DC value and transient are separate (like Cadence sources, e.g. vpulse's DC voltage vs its waveform).** The main form's value column — `d_rx_en` etc. in q — is the **DC value**, used by dc / ac / noise / stb. **tran** starts at the table's **init** line and then follows the edges.
- **init line**: the first line of every timed signal. Filled with `0` when you add the first edge; change it to 0/1, a number, a variable, or `DC` (= start at the DC value): select it, edit Value, Update.
- **1-bit digital**: Value empty = toggle; or `0` / `1`, a variable, or `DC` (= go to the DC value). **After** shows the level after each row.
- **Bus**: Value = new integer (e.g. `165`) or `DC`. **Analog**: Value = new voltage (e.g. `1.8`, `900m`) or `DC`; Edge is the ramp time.
- `View` switches between by-signal and by-time order (by time shows the cross-signal sequence).

**检查 / Checks.** 非法时间/数值、同一信号两个边沿时间相同 → 不能生成，状态栏/对话框直接告诉你哪一行。前一个边沿还没走完下一个就开始 → 只是提醒（仿真会从当前电平折返）。没勾选的信号的时序行会保留但不生效。
Bad literals or two edges of one signal at the same time block generation and the message names the row. An edge starting while the previous one is still ramping is only a warning (the simulator reverses from the current level). Rows of signals that aren't enabled are kept but ignored.

**导入/导出 / Import / Export.** File 填路径后按 Import（替换当前表）/ Export。格式每行 `signal time edge [value]`，`#` 开头为注释，可直接用 Excel 整理：
Type a path in File, then Import (replaces the table) / Export. One row per line, `#` comments, easy to prepare in Excel:

```
# 可选：变量的排序值 / optional table value (ordering only)
T_1 = 5n
# signal  time     edge  [value]   (格子里不要有空格 / no blanks inside a cell)
EN        init     -     0
EN        T_1      50p
EN        T_1+45n  100p   DC
N_ctrl    30n     50p   10
VDD       0       10u   1.8
```

### 6.2 用变量和相对时间 / Variables and relative timing

**中文.** Time、Edge、Value 每个格子都可以**直接写变量或加减式**，不需要先定义：`T_1`、`T_1+70n`（比 T_1 晚 70ns）、`TR`、`VDDH-0.1`、bus 的 `BV+1`。

1. **格子里出现的名字就是变量。** 生成后，在 ADE L（Variables → Copy From Cellview）或 Maestro（test → Design Variables → 右键 Copy from Cellview）里，这些名字会自动出现在设计变量表中。**值是空的，需要自己填**（生成成功的对话框会列出所有变量），之后就能像普通变量一样扫描。
2. **View by signal** 下不用管变量的值。
3. **切到 View by time 时**，工具会找出 Time 格里还没给值的变量，弹窗让你填，用来排序；在 By time 视图下 Add / Update 带进来新的变量时也会问一次。可以不填，不填就当 0，排在最上面（同一个变量不会反复问）。之后想改，点 **Variable values...**。给了值的格子会显示成 `T_1+70n = 120n`。
4. 这些值**只影响界面里的排序**（同时作为 `.va` 里的备用默认值，不填就是 0）。仿真时用的永远是 ADE / Maestro 里设的设计变量。所以带变量的格子只检查写法，不检查时间先后和范围。

不能用作变量名：`time`、`temp`、`tnom`、`freq`、`scale`、`scalem`、`pi`、`dvdd`、`dc`、`init`。实例属性里能看到 `tv_T_1 = T_1` 这样的参数，也可以对某个实例单独填数字。

**EN.** Every Time / Edge / Value cell can hold a **variable or a sum directly** — no declaring first: `T_1`, `T_1+70n` (70 ns after T_1), `TR`, `VDDH-0.1`, `BV+1` for a bus.

1. **Any name typed in a cell is a variable.** After generating, ADE L (Variables → Copy From Cellview) or Maestro (test → Design Variables → right-click Copy from Cellview) lists them as design variables. **Values come in empty — fill them in** (the success dialog lists every variable); then sweep them like any other variable.
2. In **View by signal** you don't need values at all.
3. **Switching to View by time** asks for values for the Time-cell variables that have none, so the table can be ordered; in that view, Add / Update asks once more when a row brings in a new one. Leaving one blank counts as 0 — listed first (it isn't asked again). **Variable values...** reopens the dialog. Cells with values read like `T_1+70n = 120n`.
4. These values **only order the table** (and are the `.va` fallback, else 0). The simulation always uses the ADE / Maestro design variable, so cells with variables are checked for syntax only, not for order or range.

Not allowed as names: `time`, `temp`, `tnom`, `freq`, `scale`, `scalem`, `pi`, `dvdd`, `dc`, `init`. Instances show parameters like `tv_T_1 = T_1`; you can also type a number there for one instance.

### 6.3 时序保存在哪 / Where the timing lives

**中文.** 时序**写在生成的 dreg cell 里**（`.va` 里，开头还有一张注释表），同时整套设置（DUT、引脚勾选、Digital/Analog、Custom variables、时序）也存在这个 cell 上。所以：别人直接拿这个 cell 仿真，什么都不用配；复制 cell、打包进红区都会跟着走；以后再打开也能原样读回来继续改。

**EN.** The timing is **built into the generated dreg cell** (in the `.va`, which also starts with a comment table), and the full setup (DUT, enabled pins, Digital/Analog, custom variables, timing) is stored on the cell too. So anyone can simulate with the cell as-is, copies / red-zone packages carry it, and you can reopen it later to keep editing.

### 6.4 打开已有的 dreg 继续改 / Editing an existing dreg

**中文.** 最快的方法：在 schematic 里**选中 dreg 实例按 `q`**。属性表单里 DC 值（DVDD、d_xxx）下面是单独的时序区：标题行 **`==== Timing ====`**（右边是摘要，例如 `8 edges on 4 signals`，纯直流显示 `DC (no edges)`），紧接着是总开关 **`>> timing_en: 1 = ON, 0 = OFF`**（§6.7），再往下是时序变量，最后是 **[Edit timing...]** 按钮。点它：属性表单会按 OK 关掉（你在里面改的值会保留），Dreg Generator 打开这个 dreg，**时序表直接弹在最上面**。改完时序表按 OK，再在主界面按 OK（覆盖，会问一次 Yes/No）或 `[Save As...]`（另存，可以顺便把这个实例换成新 cell），见 §6.5。下次在 ADE / Maestro 里直接 Run 就是新时序。

- 这个按钮只在 `q` 属性表单里出现；放置实例时的 Add Instance 表单里没有（那时还没有实例）。
- 别人那边如果没有加载这个工具，按钮不显示，只是看不到而已，仿真照常。
- 用旧版本生成的 dreg 没有这个按钮：用下面任一方法打开、按 OK 重新生成一次就有了。

另外三种方式也会读回这个 dreg 的全部设置（Source 变成它原来的 DUT，Target 就是它自己），只是时序表要自己点 `[Timing Table...]` 打开：
1. 在 schematic 里**选中 dreg 实例**，再点 MyTool → Dreg Generator；
2. 打开界面后点 `[Select from Schematic]`，点 dreg 实例；
3. 把 dreg cell 填进 Source Lib/Cell，点 `[Load Pins]`。

另外，对一个 DUT 打开界面时，如果它的 Target dreg 已经存在，也会自动读回这个 dreg 的时序。

**EN.** Quickest: **select the dreg instance and press `q`**. Below the DC values (DVDD, d_xxx) the Properties form has a timing section: a header row **`==== Timing ====`** (its value is the summary, e.g. `8 edges on 4 signals`, or `DC (no edges)`), right under it the master switch **`>> timing_en: 1 = ON, 0 = OFF`** (§6.7), then the timing variables, then the **[Edit timing...]** button. Click it: the Properties form closes with OK (values you changed there are kept), the Dreg Generator opens on this dreg, and **the Timing Table pops up on top**. Edit, OK the table, then OK in the main form (overwrite — asks Yes/No once) or `[Save As...]` (new cell, optionally switching this instance), see §6.5. The next Run in ADE / Maestro uses the new timing.

- The button only shows in the `q` Properties form, not in Add Instance (no instance exists yet).
- Where the tool isn't loaded the button just doesn't show; simulation is unaffected.
- Dregs made by an older version don't have it: open one any way below and press OK once to regenerate it.

The three other ways reload the dreg's complete setup too (Source becomes its original DUT, Target the dreg itself); open the table yourself with `[Timing Table...]`:
1. **Select the dreg instance** in a schematic, then MyTool → Dreg Generator;
2. open the form, click `[Select from Schematic]`, click the dreg instance;
3. put the dreg cell into Source Lib/Cell and click `[Load Pins]`.

Also, opening the form on a DUT whose Target dreg already exists brings that dreg's timing back.

### 6.5 保存 / 另存为 / Save vs Save As

**中文.**
- **OK / Apply = 保存**：覆盖 Target cell。**注意：所有用到这个 cell 的 testbench 都会跟着变。** 如果这次会改变一个已有 dreg 的时序，会弹出确认框：Yes = 覆盖；No = 回到界面（什么都不写）。
- **`[Save As...]` = 另存为**：输入新 cell 名，原 cell 不动。如果你是从某个实例打开的，可以勾选"Switch instance … to the new cell"，工具会把这个实例换成新 cell（schematic 会变成已修改状态，记得保存）。想要一套不同的时序又不影响别人，就用 Save As。

**EN.**
- **OK / Apply = Save**: overwrites the Target cell. **Every testbench that uses this cell changes with it.** If this would change an existing dreg's timing you get a confirm: Yes = overwrite; No = back to the form (nothing written).
- **`[Save As...]`**: enter a new cell name; the current cell is untouched. If you opened the form from an instance, tick "Switch instance … to the new cell" and the tool re-points that instance (the schematic is left modified — save it). Use Save As for a different stimulus that must not affect others.

### 6.6 同一个 symbol 的多个时序版本 / One symbol, several timing views

**中文.** 想把同一个 dreg 给别人用、只是时序不同（例如 RX / TX 两种激励），不必另存成新 cell：`[Save As...]` 里把 **Save as** 选成 **New timing view of this cell**，名字填 `veriloga_RX`。这个 cell 下会多出一个 `veriloga_RX` view，symbol 不变。交给别人时只要说："用这个 symbol，view 选 `veriloga_RX`"。

- **对方怎么选：** ADE L 的 Setup → Environment → **Switch View List** 里把 `veriloga_RX` 放到 `veriloga` 前面（例如 `spectre cmos_sch cmos.sch schematic veriloga_RX veriloga`）；Maestro 在 test 的 Environment Options 里改同一项；用 config 的话，在 Hierarchy Editor 里把这个 cell 的 **View to Use** 设成 `veriloga_RX`。不改的话用的就是原来的 `veriloga`。
- **只有时序可以不同。** 引脚、Digital/Analog、DVDD 和直流值是所有版本共用的（symbol 和 CDF 只有一份）；要改这些，改主版本 `veriloga`，所有版本会一起更新。需要不同引脚，就另存成新 cell。
- **同一个 testbench 里只能用其中一个版本。** 所有版本的模块名相同，混用时仿真器会悄悄只用其中一个。要在一个 testbench 里同时用两套时序，另存成两个 cell。
- **修改：** 选中实例按 `q` → `[Edit timing...]`，有多个版本时会先问改哪个；窗口标题会显示 `[veriloga_RX]`。q 表单里 **Other timing views** 一行列出这个 cell 有哪些版本。
- **删除：** 在 Library Manager 里删掉那个 view 即可。

**EN.** To hand out the same dreg with a different stimulus (say RX / TX), you don't need a new cell: in `[Save As...]` set **Save as** to **New timing view of this cell** and name it `veriloga_RX`. The cell gets a `veriloga_RX` view; the symbol stays the same. Tell the user: "this symbol, view `veriloga_RX`".

- **How they pick it:** ADE L Setup → Environment → **Switch View List**: put `veriloga_RX` before `veriloga` (e.g. `spectre cmos_sch cmos.sch schematic veriloga_RX veriloga`); Maestro: the same field in the test's Environment Options; with a config: set the cell's **View to Use** to `veriloga_RX` in the Hierarchy Editor. Without that, `veriloga` is used.
- **Only the timing can differ.** Pins, Digital/Analog, DVDD and DC values are shared (one symbol, one CDF); change them in the main view `veriloga` and every timing view follows. Different pins → Save As a new cell.
- **One view per testbench.** All views define the same module, and mixing them silently uses just one. Two stimuli in one testbench → two cells.
- **Editing:** select the instance, `q` → `[Edit timing...]`; with several views it asks which one; titles show `[veriloga_RX]`. The q form's **Other timing views** line lists them.
- **Deleting:** delete the view in the Library Manager.

### 6.7 DC 值和瞬态 / DC value vs transient

**中文.**
- **DC 分析**（dc / dc 扫描 / ac / noise / stb）只用 DC 值（主界面 value 列 / q 里的 `d_xxx`，或它对应的设计变量），边沿不起作用。
- **tran** 从 init 行出发，按边沿走；值写 `DC` 的地方取 DC 值。所以像 "RX mode" 这种逻辑设定可以只用一个变量（如 `rx_en`）：init 写 0，边沿写 DC。
- **总开关 `timing_en`**：有时序的 dreg，q 里会多一个参数 `timing_en`（默认 1）。填 `0` = 关掉这个实例的全部时序，tran 里也保持 DC 值；填 `1` = 按时序表走。也可以填一个设计变量名（如 `tm_en`），然后在 Maestro 里设 0/1，或者在 corner 里把 0 和 1 各跑一次做对比。

**EN.**
- **DC analyses** (dc / dc sweep / ac / noise / stb) use only the DC value (main-form value / `d_xxx` in q, or its design variable); edges do nothing there.
- **tran** starts at the init line and follows the edges; cells that say `DC` take the DC value. So a logical setting such as "RX mode" stays one variable (`rx_en`): init 0, edge value DC.
- **Master switch `timing_en`**: a timed dreg shows an extra parameter `timing_en` in q (default 1). `0` = all timing of this instance off — tran stays at the DC values too; `1` = follow the table. You can also type a design variable (e.g. `tm_en`) and set it to 0/1 in Maestro, or run both in corners for a side-by-side comparison.

---

## 7. 仿真中使用 / Using it in simulation

**中文.**
1. 在 testbench schematic 里实例化生成的 dreg cell（Target Lib / Target Cell）。
2. 将 dreg 的输出引脚接到 DUT 对应输入。引脚名一一对应；bus 引脚保持原 bus 形态。
3. 打开 ADE / Maestro / ADE-XL，在实例参数表里给 `DVDD`、`d_EN`、`d_D` 等填值；bus 用十进制整数（0..2^N−1）。
4. 若用 Variable 类模式，需要在 Design Variables 表里建对应变量。Maestro 里点 "Copy from cellview" 会一次性把这些变量名抽到设计变量表中（无需手工添加）。
5. 仿真器：**Spectre**（含 OSS 网表器；spectreS 兼容入口已挂好）。

**EN.**
1. Instantiate the generated dreg in your testbench (Target Lib / Target Cell).
2. Wire dreg outputs to the DUT inputs — pin names line up one-for-one; buses stay as buses.
3. In ADE / Maestro / ADE-XL, fill values for `DVDD`, `d_EN`, `d_D` in the instance parameter table; buses take a decimal integer (0..2^N−1).
4. Variable-style modes require matching entries in the Design Variables table. In Maestro, **Copy from cellview** sweeps the variable names into the design-variables table in one click.
5. Simulator: **Spectre** (OSS netlister supported; spectreS entry is wired up too).

---

## 8. 常见问题 / Common pitfalls

**中文.**
- **生成的 dreg 没被网表化（仿真"成功"但 DUT 引脚悬空）.** 升级到最新版本——旧版漏配 `simInfo`，OSS 网表器会静默跳过 cell。
- **Bus 引脚填法.** 一个整数，不是 `4'b1010` 之类的 Verilog literal。例如 `D<3:0> = 10` 表示 `1010`。
- **改了 DUT 引脚后重新生成.** 直接再开 GUI、点 Load Pins、OK——会原地覆盖（symbol / .va / CDF 全部刷新）；testbench 中已实例化的 dreg 会自动跟着变。
- **value 字段灰色.** 说明当前不是 "Hard-coded number" 模式，显示的是变量名预览。切回 "Hard-coded number" 可重新编辑。
- **`[PWR]` 标错了.** 默认关键字偏保守。点 `[Edit Patterns...]` 在 power 关键字一行加入即可，分类立刻刷新。
- **改了时序但仿真没变.** 时序表按 OK 只是回到主界面，还要在主界面按 OK / Apply 生成。
- **时序行"not enabled".** 对应引脚没勾选（或 custom variable 改了名），这些行保留但不会生成。
- **t=0 的斜坡.** 在 0 时刻开始的边沿会正常从初始电平爬升（不会变成一开始就是终值）。
- **重新生成时弹出 "CDFParamDeleted".** 只有旧版本会弹（这次比上次少了引脚时），选 Yes 即可。新版本重新生成前会先清掉旧 CDF，不再弹。

**EN.**
- **Generated dreg isn't netlisted (sim "succeeds" but DUT inputs float).** Upgrade — older builds missed `simInfo`, causing the OSS netlister to skip the cell silently.
- **Bus values.** Pass an integer, not a Verilog literal. `D<3:0> = 10` means `1010`.
- **Re-running after a DUT pin change.** Reopen the GUI, click Load Pins, OK — it overwrites in place (symbol / .va / CDF refreshed). Existing testbench instances pick up the change automatically.
- **Greyed-out value field.** Means you're not in "Hard-coded number" mode — the field shows the resolved variable name as preview. Switch back to edit.
- **Wrong `[PWR]` tag.** Default keywords are conservative. Add the name under `[Edit Patterns...]` → power list; tags refresh immediately.
- **Changed the timing but the sim didn't.** OK in the timing table only returns to the main form — generate with OK / Apply there.
- **Timing rows marked "not enabled".** The pin isn't ticked (or the custom variable was renamed); the rows are kept but not generated.
- **Ramp at t=0.** An edge starting at 0 ramps from the initial level as expected (it does not start at the final value).
- **"CDFParamDeleted" prompt when regenerating.** Older versions only (when there were fewer pins than last time) — answer Yes. The current version clears the old CDF before regenerating, so it no longer appears.

---

## 9. 反馈 / Feedback

**中文.** Bug / 需求请直接联系工具作者（git blame 即可），或在使用现场打开 CIW 截图发过来。
**EN.** Bug reports / requests: ping the tool author (git blame), or screenshot the CIW and send it over.
