# Load the 08 HDMI cs150-mode test-pattern overlay on the PYNQ-Z2 and keep the script
# alive until /home/xilinx/hdmi_cs150/stop exists (the bitstream stays
# configured after the script exits too; this just gives a visible status).
# Run on the board under sudo with the PYNQ environment sourced, see README.
import os, time
from pynq import Overlay, Clocks
d = '/home/xilinx/hdmi_cs150'
ol = Overlay(d + '/hdmi_cs150.bit')
print('OVERLAY_LOADED', flush=True)
print('FCLK0 MHz = %.3f (expect 100.000)' % Clocks.fclk0_mhz, flush=True)
print('Expect 800x600@60 colour bars on HDMI OUT. LD0 on (MMCM locked), LD1/LD3 blinking (~1 Hz).', flush=True)
stop = d + '/stop'
if os.path.exists(stop):
    os.remove(stop)
while not os.path.exists(stop):
    time.sleep(0.5)
print('STOP_SEEN', flush=True)
