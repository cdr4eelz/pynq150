# 0001: rc_axi_fifo_adapter address-conflict check (NOT applied)

`0001-rc_axi_fifo_adapter-address-conflict-check.patch` replaces the adapter's
read/write direction barrier with a per-line hazard check (RAW: AR waits for
the same line's BRESP; WAR: AW waits for the same line's RLAST). Made against
06 at commit d020508, paths `06_request_controller_arb_test/...`. It has
5 files: `rtl/rc_axi_fifo_adapter.v`, `Makefile`, `README.md`, new
`sim/axi4_slave_rand.v` and `sim/tb_adapter_mixed.v`.

Apply to 06 (from the repo root):

    git apply --check patches/0001-rc_axi_fifo_adapter-address-conflict-check.patch
    git apply         patches/0001-rc_axi_fifo_adapter-address-conflict-check.patch
    cd 06_request_controller_arb_test && make sim

Apply to 08 (or any other copy of the adapter), adapter file only. `-p2`
strips `a/06_request_controller_arb_test/`, `--directory` puts the project
dir back, `--include` skips the 06-only files:

    git apply --check -p2 --directory=08_hdmi_cs150_mode \
        --include='*/rtl/rc_axi_fifo_adapter.v' patches/0001-*.patch
    git apply         -p2 --directory=08_hdmi_cs150_mode \
        --include='*/rtl/rc_axi_fifo_adapter.v' patches/0001-*.patch

(Works on a byte-identical copy of 06's adapter, md5 0157b44b..., which 08's was
when checked. If 08's adapter has been edited since, use `git apply --3way` /
`patch -p2 --fuzz=3`, or copy 06's patched file over.) To also bring the
mixed test to 08, copy `sim/axi4_slave_rand.v`, `sim/tb_adapter_mixed.v` and
the `simmix` / `simthru` Makefile targets; the test needs the cs150
`RequestController.v` and the proj150 FIFO models in `sim/models/`.
