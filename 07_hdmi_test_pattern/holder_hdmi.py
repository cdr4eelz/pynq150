# Load the 07 HDMI test-pattern overlay on the PYNQ-Z2 and keep the script
# alive until /home/xilinx/hdmi_pattern/stop exists (the bitstream stays
# configured after the script exits too; this just gives a visible status).
# Run on the board under sudo with the PYNQ environment sourced, see README.
import os, time
from pynq import Overlay, Clocks
d = '/home/xilinx/hdmi_pattern'
ol = Overlay(d + '/hdmi_pattern.bit')
print('OVERLAY_LOADED', flush=True)
print('FCLK0 MHz = %.3f (expect 100.000)' % Clocks.fclk0_mhz, flush=True)
print('Expect 640x480 colour bars on HDMI OUT. LD0 on (MMCM locked), LD1/LD3 blinking.', flush=True)
stop = d + '/stop'
if os.path.exists(stop):
    os.remove(stop)
while not os.path.exists(stop):
    time.sleep(0.5)
print('STOP_SEEN', flush=True)
