import os, sys, time, signal
from pynq import Overlay, allocate
ol = Overlay('/home/xilinx/ddrjtag/ddrjtag.bit')
buf = allocate(shape=(1024,), dtype='u4')
buf[:] = 0xDEADBEEF
buf.flush()
pa = buf.device_address
open('/home/xilinx/ddrjtag/addr.txt','w').write('0x%08X\n' % pa)
print('OVERLAY_LOADED PHYS=0x%08X' % pa, flush=True)
done = '/home/xilinx/ddrjtag/check'
stop = '/home/xilinx/ddrjtag/stop'
while not os.path.exists(stop):
    if os.path.exists(done):
        os.remove(done)
        buf.invalidate()
        exp = [0xA5000000 + i for i in range(256)]
        got = [int(x) for x in buf[:256]]
        bad = [i for i in range(256) if got[i] != exp[i]]
        print('CPU_CHECK first=%s last=0x%08X word256=0x%08X mismatches=%d %s' % (
            ['0x%08X' % v for v in got[:4]], got[255], int(buf[256]), len(bad), 'PASS' if not bad else 'FAIL'), flush=True)
    time.sleep(0.5)
buf.freebuffer()
print('FREED', flush=True)
