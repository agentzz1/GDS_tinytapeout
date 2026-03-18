# SPDX-License-Identifier: Apache-2.0

"""
Tiny Tapeout demoboard helper for tt_um_agentzz1_rtx8090.

Usage on the board REPL:

    import tt_um_agentzz1_rtx8090_demo as demo
    demo.run_all()

Or run individual steps:

    demo.run_smoke()
    demo.run_gold()
    demo.run_change()
"""

try:
    from ttboard.demoboard import DemoBoard
    from ttboard.mode import RPMode
    from machine import Pin
except ImportError:
    DemoBoard = None
    RPMode = None

    class Pin:
        OUT = 1


PROJECT_NAME = "tt_um_agentzz1_rtx8090"

CMD_LOAD_QUERY = 0b00
CMD_LOAD_CONTEXT = 0b01
CMD_CONTROL = 0b10
CMD_READ_BANK = 0b11

QUERY_VECTOR = [16, -8, 20, 4, -12, 8, 24, -16]
CONTEXT_VECTORS = [
    [12, -4, 8, 0, -8, 16, 4, -12],
    [-16, 8, -4, 12, 20, -8, 0, 4],
    [4, 20, -12, 8, -4, 12, -16, 16],
    [8, 0, 16, -8, 12, -4, 20, -12],
]
EXPECTED_FINAL = [21, -9, 25, 4, -7, 8, 27, -11]
UPDATED_CONTEXT_SLOT = 2
UPDATED_CONTEXT_FEATURE = 5
UPDATED_CONTEXT_VALUE = -20
EXPECTED_UPDATED_FINAL = [17, -3, 25, -3, -4, 5, 31, -15]


def raw8(value):
    return value & 0xFF


def signed8(value):
    value &= 0xFF
    return value - 256 if value & 0x80 else value


def pack_uio(strobe, cmd, feature_idx=0, slot=0):
    return (
        ((strobe & 0x1) << 7)
        | ((cmd & 0x3) << 5)
        | ((feature_idx & 0x7) << 2)
        | (slot & 0x3)
    )


def format_status(status):
    return "0x%02x (done=%d busy=%d)" % (
        status,
        (status >> 7) & 0x1,
        (status >> 6) & 0x1,
    )


class TinyTransformerDemo:
    def __init__(self, tt=None):
        if tt is None:
            if DemoBoard is None:
                raise RuntimeError(
                    "This script must run on the Tiny Tapeout demoboard MicroPython REPL."
                )
            tt = DemoBoard.get()
        self.tt = tt

    def setup(self):
        if RPMode is None:
            raise RuntimeError(
                "ttboard SDK not available. Run this on the Tiny Tapeout demoboard."
            )

        self.tt.mode = RPMode.ASIC_RP_CONTROL
        project = getattr(self.tt.shuttle, PROJECT_NAME, None)
        if project is None:
            raise RuntimeError("Project %s is not present on this shuttle." % PROJECT_NAME)

        project.enable()
        self.tt.bidir_mode = [Pin.OUT] * 8
        self.tt.clock_project_stop()
        self.tt.project_clk(False)
        self._drive_bus(0, pack_uio(0, CMD_CONTROL, 0, 0))
        self.tt.reset_project(True)
        self.tt.clock_project_once()
        self.tt.reset_project(False)
        self.tt.clock_project_once()
        return self.read_status()

    def _drive_bus(self, ui_byte, uio_byte):
        self.tt.input_byte = raw8(ui_byte)
        self.tt.bidir_byte = raw8(uio_byte)

    def write_query(self, feature_idx, value):
        self._drive_bus(value, pack_uio(1, CMD_LOAD_QUERY, feature_idx, 0))
        self.tt.clock_project_once()
        self._drive_bus(0, pack_uio(0, CMD_CONTROL, 0, 0))
        self.tt.clock_project_once()

    def write_context(self, slot, feature_idx, value):
        self._drive_bus(value, pack_uio(1, CMD_LOAD_CONTEXT, feature_idx, slot))
        self.tt.clock_project_once()
        self._drive_bus(0, pack_uio(0, CMD_CONTROL, 0, 0))
        self.tt.clock_project_once()

    def read_status(self):
        self._drive_bus(0, pack_uio(0, CMD_CONTROL, 0, 0))
        return raw8(self.tt.output_byte)

    def execute(self):
        self._drive_bus(0, pack_uio(1, CMD_CONTROL, 7, 0))
        self.tt.clock_project_once()
        self._drive_bus(0, pack_uio(0, CMD_CONTROL, 0, 0))
        self.tt.clock_project_once()
        return self.read_status()

    def wait_done(self, max_cycles=2000):
        for cycles in range(max_cycles):
            status = self.read_status()
            if (status >> 7) & 0x1:
                return status, cycles
            self.tt.clock_project_once()
        return self.read_status(), max_cycles

    def read_bank_value(self, bank, feature_idx, signed=True):
        self._drive_bus(0, pack_uio(0, CMD_READ_BANK, feature_idx, bank))
        value = raw8(self.tt.output_byte)
        return signed8(value) if signed else value

    def read_bank_vector(self, bank, signed=True):
        return [self.read_bank_value(bank, idx, signed=signed) for idx in range(8)]

    def load_vectors(self, query_vec, context_vecs):
        for feature_idx, value in enumerate(query_vec):
            self.write_query(feature_idx, value)
        for slot, ctx in enumerate(context_vecs):
            for feature_idx, value in enumerate(ctx):
                self.write_context(slot, feature_idx, value)


def _print_vector(label, values):
    print("%s: %s" % (label, values))


def run_smoke():
    demo = TinyTransformerDemo()
    idle_status = demo.setup()
    start_status = demo.execute()
    final_status, cycles = demo.wait_done()

    passed = (
        ((idle_status >> 6) & 0x1) == 0
        and ((start_status >> 6) & 0x1) == 1
        and ((final_status >> 6) & 0x1) == 0
        and ((final_status >> 7) & 0x1) == 1
    )

    print("== Smoke Test ==")
    print("Idle status  :", format_status(idle_status))
    print("Start status :", format_status(start_status))
    print("Final status :", format_status(final_status))
    print("Clock cycles :", cycles)
    print("Smoke result :", "PASS" if passed else "FAIL")
    return {
        "passed": passed,
        "idle_status": idle_status,
        "start_status": start_status,
        "final_status": final_status,
        "cycles": cycles,
    }


def run_gold():
    demo = TinyTransformerDemo()
    demo.setup()
    demo.load_vectors(QUERY_VECTOR, CONTEXT_VECTORS)
    start_status = demo.execute()
    final_status, cycles = demo.wait_done()
    first_output = demo.read_bank_vector(0)

    repeat_status = demo.execute()
    repeat_final_status, repeat_cycles = demo.wait_done()
    repeat_output = demo.read_bank_vector(0)

    passed = (
        ((start_status >> 6) & 0x1) == 1
        and ((final_status >> 7) & 0x1) == 1
        and first_output == EXPECTED_FINAL
        and ((repeat_status >> 6) & 0x1) == 1
        and ((repeat_final_status >> 7) & 0x1) == 1
        and repeat_output == EXPECTED_FINAL
    )

    print("== Gold Test ==")
    print("Final status       :", format_status(final_status))
    print("First run cycles   :", cycles)
    _print_vector("Observed output 1", first_output)
    _print_vector("Expected output  ", EXPECTED_FINAL)
    print("Repeat status      :", format_status(repeat_final_status))
    print("Repeat run cycles  :", repeat_cycles)
    _print_vector("Observed output 2", repeat_output)
    print("Gold result        :", "PASS" if passed else "FAIL")
    return {
        "passed": passed,
        "final_status": final_status,
        "cycles": cycles,
        "first_output": first_output,
        "repeat_output": repeat_output,
    }


def run_change():
    demo = TinyTransformerDemo()
    demo.setup()
    demo.load_vectors(QUERY_VECTOR, CONTEXT_VECTORS)
    demo.execute()
    demo.wait_done()
    baseline_output = demo.read_bank_vector(0)

    demo.write_context(UPDATED_CONTEXT_SLOT, UPDATED_CONTEXT_FEATURE, UPDATED_CONTEXT_VALUE)
    start_status = demo.execute()
    final_status, cycles = demo.wait_done()
    updated_output = demo.read_bank_vector(0)

    passed = (
        ((start_status >> 6) & 0x1) == 1
        and ((final_status >> 7) & 0x1) == 1
        and baseline_output == EXPECTED_FINAL
        and updated_output == EXPECTED_UPDATED_FINAL
        and updated_output != baseline_output
    )

    print("== Change Test ==")
    print(
        "Updated slot %d feature %d -> %d"
        % (UPDATED_CONTEXT_SLOT, UPDATED_CONTEXT_FEATURE, UPDATED_CONTEXT_VALUE)
    )
    print("Final status      :", format_status(final_status))
    print("Run cycles        :", cycles)
    _print_vector("Baseline output  ", baseline_output)
    _print_vector("Updated output   ", updated_output)
    _print_vector("Expected updated ", EXPECTED_UPDATED_FINAL)
    print("Change result     :", "PASS" if passed else "FAIL")
    return {
        "passed": passed,
        "final_status": final_status,
        "cycles": cycles,
        "baseline_output": baseline_output,
        "updated_output": updated_output,
    }


def run_all():
    smoke = run_smoke()
    if not smoke["passed"]:
        print("Bring-up worked enough to talk to the project, but the smoke test failed.")
        print("Use this as the fallback demo: project selection, reset, clock, and status reads.")
        return {"smoke": smoke, "gold": None, "change": None}

    gold = run_gold()
    change = run_change()
    overall = smoke["passed"] and gold["passed"] and change["passed"]
    print("== Overall Demo Result ==")
    print("Overall result:", "PASS" if overall else "PARTIAL / FAIL")
    return {"smoke": smoke, "gold": gold, "change": change, "passed": overall}
