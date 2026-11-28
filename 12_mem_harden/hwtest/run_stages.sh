#!/bin/bash
# run_stages.sh STAGE - GIOS command sequences (from proj150 hwtest) for 12_mem_harden on the PYNQ-Z2
# (UART log in hwtest/logs/). Port: gios_uart.py default (Pmod FT232R), override with PORT=.
#   banner | dcache | icache | pixfeed | pixfeed_stress | pixfeed_isolate | gpu | gpu_stress | elip | elipbig
#   (gs_check.py logs/X.log reports the PixelFeeder resync count, gs bits 23:16, per stage)
#   LOGPFX=after_ ./run_stages.sh gpu   writes logs/after_gpu.log
set -u; cd "$(dirname "$0")"; mkdir -p logs
G="python3 ./gios_uart.py ${PORT:+--port $PORT} --log logs/${LOGPFX:-}$1.log"
case "$1" in
  banner)  $G --wait-banner 3 help gs ;;
  dcache)
    $G --timeout 60 --file 10100000 data4k.hex \
       result "copy 10100000 0 1000" "copy 10100000 10180000 1000" "copy 10180000 0 1000" \
       "copy 10100000 10104000 1000" "copy 10104000 0 1000" \
       "dump 10100000" "dump 10180000" \
       "sw 18181818 18000040" "sw 10101010 10000040" "lw 10002040" "lw 18000040" "lw 10000040" \
       "sw c0ffee14 10001014" "lw 10003014" "lw 10001000" "lw 10001014" \
       "sw 11223344 10001100" "sb aa 10001101" "sh bbcc 10001106" "lw 10001100" "lw 10001104" "lhu 10001102" "lbu 10001103" \
       "copy 40000000 10200000 4000" "copy 40000000 0 4000" "copy 10200000 0 4000" ;;
  icache)
    # ISE map: 0x1 writes go to D$ only, 0x3 writes go to D$ and I$; fetch from 0x1 reads I$.
    $G --timeout 30 --file 30030000 icache_prog.hex "sw 0 10020000" result "jal 10030000" "lw 10020000" \
       "jal 10030000" "lw 10020000" ;;
  pixfeed)
    $G --timeout 30 gs "pf 1" "@sleep 1" gs "@sleep 2" gs "pf 0" "@sleep 1" gs "pf 1" "@sleep 1" gs ;;
  pixfeed_stress)
    # display (frame 1) while the CPU streams write-through stores (swfill) and the caches run:
    # the underrun flag (D in gs, '*' = pf_fault) must stay clear after everything.
    $G --timeout 60 --file 10110000 data4k.hex gs "pf 1" result "copy 10110000 0 1000" "copy 10110000 10190000 1000" \
       "copy 10190000 0 1000" "copy 40000000 10210000 4000" "copy 10210000 0 4000" "sf 1" "swcolor 00203040" "swfill" \
       "lw 10400000" "lw 10657c7c" gs "copy 10100000 0 1000" "copy 10200000 0 4000" gs ;;
  pixfeed_isolate)
    # PixelFeeder alone, then a copy burst, then a frame-2 software fill (CPU store stream only)
    $G --timeout 30 gs "pf 1" gs "copy 40000000 10210000 4000" "copy 10210000 10250000 4000" "copy 10250000 0 4000" gs \
       "sf 2" "swcolor 00ff0000" "swfill" gs ;;
  gpu)
    # PixelFeeder shows frame 1 while the GPU writes it; pf_fault ('*' in gs) must stay clear.
    # hwelip must finish: the later 'gs' show GF#..-ERLFG (all upper case = every unit ready).
    # GPU v2 FILL/LINE/ELIP write alpha ff: compare the low 24 bits of the lw replies.
    $G --timeout 60 gs "pf 1" "gf 1" "hwcolor 00ff8040" "hwfill" "@sleep 1" gs "lw 10400000" "lw 10400c7c" "lw 10657c7c" \
       "lw 10400c80" "hwcolor 000000ff" "hwline 0 0 799 599" "@sleep 1" gs "lw 10400000" "lw 1052c640" "lw 1052c644" \
       "hwcolor 0000ff00" "hwelip 400 300 200 150" "@sleep 3" gs "lw 10496640" "lw 105c2640" "@sleep 5" gs ;;
  gpu_stress)
    # 12: GPU draw stress while frame 1 is shown: ROUNDS x (fill, 4 rects, 8 lines, 2 ellipses) queued
    # to the GPU back to back, with CPU copy bursts (DDR reads+write-through stores) interleaved, so
    # PixelFeeder, GPU and CPU all compete in the RequestController. Pass = the PixelFeeder resync
    # count (gs bits 23:16) does not move and no fault '*' (checked by gs_check.py).
    # Ends on a fixed picture for the HDMI capture: blue fill, white border rect, red X, green ellipse.
    R=${ROUNDS:-8}; C=(gs "pf 1" "gf 1" "@sleep 1" gs)
    for ((i = 0; i < R; i++)); do
      C+=("hwcolor 00$(printf %02x $((i * 29 & 255)))8040" hwfill
          "hwcolor 00ffff00" "hwrect 10 10 789 589" "hwcolor 0000ffff" "hwrect 100 100 699 499"
          "hwcolor 00ff00ff" "hwrect 0 0 399 299" "hwcolor 00808080" "hwrect 400 300 799 599"
          "copy 40000000 10210000 4000"
          "hwcolor 00ffffff" "hwline 0 0 799 599" "hwline 799 0 0 599" "hwline 0 300 799 300" "hwline 400 0 400 599"
          "hwline 0 0 799 0" "hwline 0 599 799 599" "hwline 0 0 0 599" "hwline 799 0 799 599"
          "hwcolor 0000ff00" "hwelip 400 300 390 290" "hwcolor 00ff0000" "hwelip 400 300 150 100"
          "copy 10210000 0 4000" gs)
    done
    C+=("hwcolor 000000ff" hwfill "hwcolor 00ffffff" "hwrect 20 20 779 579" "hwcolor 000000ff" "hwrect 24 24 775 575"
        "hwcolor 00ff0000" "hwline 0 0 799 599" "hwline 799 0 0 599" "hwcolor 0000ff00" "hwelip 400 300 300 200"
        "@sleep 3" gs "lw 10400000" "lw 1052c640" "lw 10414050" "@sleep 2" gs)
    $G --timeout 180 "${C[@]}"
    python3 gs_check.py logs/${LOGPFX:-}$1.log ;;
  elip|elipbig)
    # GPU ellipses (frame 1, hwelip) against the CPU swelip reference (frame 2): pixel reads at model
    # points + band checksums; prints PASS/FAIL. elipbig = the 399x299 ellipse alone.
    BIGARG=""; [ "$1" = elipbig ] && BIGARG="--big"
    mapfile -t C < <(python3 elip_check.py cmds $BIGARG)
    $G --timeout 90 "${C[@]}"
    python3 elip_check.py check logs/${LOGPFX:-}$1.log $BIGARG ;;
  *) echo "usage: $0 banner|dcache|icache|pixfeed|pixfeed_stress|pixfeed_isolate|gpu|gpu_stress|elip|elipbig"; exit 2 ;;
esac
