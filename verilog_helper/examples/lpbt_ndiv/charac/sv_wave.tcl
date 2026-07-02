# SimVision command script: open the SHM, make a waveform, add signals, zoom to the data.
puts "SV: databases = [database list]"
set W [waveform new -name "LPBT_NDIV ndiv=51 (real struct)"]
puts "SV: wavewin = $W"
waveform using $W
set sigs [list \
    tb_wave.dut.NDIVCKIN \
    tb_wave.OUT_NDIV \
    tb_wave.CLK2DSM ]
foreach s $sigs {
    if {[catch {waveform add -signals $s} e]} { puts "SV: add FAIL $s -> $e" } else { puts "SV: added $s" }
}
# data window is ~259ns .. 365ns (after settle). Show ~1.2 OUT_NDIV periods.
catch {waveform xview limits 259ns 310ns} e ; puts "SV: xview -> $e"
puts "SV: script done"
