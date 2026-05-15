# Dreg Generator — Designer's Guide / 设计者使用手册

> 面向使用者的简明手册。开发者向的实现说明见 `README.md`。
> A short guide for designers. For implementation details see `README.md`.

---

## 1. 这是什么 / What it is

**中文.** 给定一个 DUT cellview，自动生成一个 "driver register" cell：每个 DUT 输入引脚变成一个 CDF 参数；testbench 里把这个 dreg 拖进来，给参数填 1/0，仿真时它就在对应引脚上输出 `value × DVDD`。Bus 引脚 (`D<7:0>`) 折叠成一个整型参数，仿真时自动按位拆分。

**EN.** Given a DUT cellview, auto-generates a "driver register" cell whose pins drive the DUT. Each DUT input becomes a CDF parameter; in the testbench you instantiate the dreg and fill 1/0, and at sim time it drives `value × DVDD` onto the matching pin. Bus pins (`D<7:0>`) collapse to one integer parameter and are bit-decomposed automatically.

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
| DVDD default | `value × DVDD` 里的 DVDD 默认数值 / Default for DVDD in `value × DVDD` |
| Default values | 4 种默认值模式，见 §5 / 4 default-value modes — see §5 |
| Variable name | 仅当模式 = "Variable, custom pattern" 时启用 / Active only when mode = "Variable, custom pattern" |

### 引脚工具栏 / Pin toolbar

| 按钮 / Button | 效果 / Effect |
|---|---|
| All Pins | 全部勾上 / Enable every pin |
| No Pins | 全部取消 / Disable every pin |
| Only DREG | 仅勾选被识别为 `[DREG]` 的引脚 / Enable only `[DREG]`-classified pins |
| Auto Suggest | `[DREG]` 勾选、`[PWR]` 取消、其他按方向判断 / `[DREG]` on, `[PWR]` off, others by direction |
| Edit Patterns... | 编辑分类关键字（power / dreg）/ Edit classifier keywords (power / dreg) |

**中文.** 每一行引脚名前会标 `[PWR]` 或 `[DREG]` 前缀（其他不标），方便一眼区分电源轨和控制信号。前缀只是提示，分类规则可在 `[Edit Patterns...]` 里改。

**EN.** Each pin row is prefixed with `[PWR]` or `[DREG]` (or unprefixed) so you can scan supply rails vs. control inputs at a glance. The prefix is only a hint — edit the classifier under `[Edit Patterns...]`.

### 引脚列表 / Pin list

| 列 / Column | 说明 / Meaning |
|---|---|
| `[x]` 勾选框 / Tick box | 是否纳入 dreg / Whether to include this pin |
| value | 默认值；模式非 literal 时变灰，显示解析后的变量名作为预览 / Default value; greyed out under non-literal modes and shows the resolved variable name as preview |

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

## 6. 仿真中使用 / Using it in simulation

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

## 7. 常见问题 / Common pitfalls

**中文.**
- **生成的 dreg 没被网表化（仿真"成功"但 DUT 引脚悬空）.** 升级到最新版本——旧版漏配 `simInfo`，OSS 网表器会静默跳过 cell。
- **Bus 引脚填法.** 一个整数，不是 `4'b1010` 之类的 Verilog literal。例如 `D<3:0> = 10` 表示 `1010`。
- **改了 DUT 引脚后重新生成.** 直接再开 GUI、点 Load Pins、OK——会原地覆盖（symbol / .va / CDF 全部刷新）；testbench 中已实例化的 dreg 会自动跟着变。
- **value 字段灰色.** 说明当前不是 "Hard-coded number" 模式，显示的是变量名预览。切回 "Hard-coded number" 可重新编辑。
- **`[PWR]` 标错了.** 默认关键字偏保守。点 `[Edit Patterns...]` 在 power 关键字一行加入即可，分类立刻刷新。

**EN.**
- **Generated dreg isn't netlisted (sim "succeeds" but DUT inputs float).** Upgrade — older builds missed `simInfo`, causing the OSS netlister to skip the cell silently.
- **Bus values.** Pass an integer, not a Verilog literal. `D<3:0> = 10` means `1010`.
- **Re-running after a DUT pin change.** Reopen the GUI, click Load Pins, OK — it overwrites in place (symbol / .va / CDF refreshed). Existing testbench instances pick up the change automatically.
- **Greyed-out value field.** Means you're not in "Hard-coded number" mode — the field shows the resolved variable name as preview. Switch back to edit.
- **Wrong `[PWR]` tag.** Default keywords are conservative. Add the name under `[Edit Patterns...]` → power list; tags refresh immediately.

---

## 8. 反馈 / Feedback

**中文.** Bug / 需求请直接联系工具作者（git blame 即可），或在使用现场打开 CIW 截图发过来。
**EN.** Bug reports / requests: ping the tool author (git blame), or screenshot the CIW and send it over.
