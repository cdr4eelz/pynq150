# 12 floorplan (implementation only): keep the cs150 CPU core next to its caches. The 50 MHz worst
# paths start at the D$ data BRAM and run through the CPU core (MemShift -> forward -> BranchCMP ->
# next-PC) to the I$ BRAM address; in the unconstrained placement the I$ data BRAMs sat ~40 rows
# below the core. MIPS.core + I$ + D$ go into clock region X1Y1 (60 BRAM sites); MemBank (BIOS /
# ISR / dmem / imem ROM BRAMs, UART, MMIO) and COP0 may use X1Y1..X1Y2 (all of the CPU together
# needs 66 BRAM sites, more than X1Y1 has).
create_pblock pb_cpu
add_cells_to_pblock [get_pblocks pb_cpu] [get_cells {u_core/CPU/MIPS.core u_core/icache u_core/dcache}]
resize_pblock [get_pblocks pb_cpu] -add {CLOCKREGION_X1Y1:CLOCKREGION_X1Y1}
create_pblock pb_bank
add_cells_to_pblock [get_pblocks pb_bank] [get_cells {u_core/CPU/MEMS.bank u_core/CPU/cop0}]
resize_pblock [get_pblocks pb_bank] -add {CLOCKREGION_X1Y1:CLOCKREGION_X1Y2}
