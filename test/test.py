import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles

def q34_to_float(raw):
    if raw > 127:
        raw -= 256
    return raw / 16.0

def float_to_q34(f):
    v = int(round(f * 16))
    if v < -128: v = -128
    if v > 127: v = 127
    return v & 0xFF

async def reset_dut(dut):
    dut.rst_n.value = 0
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    dut.ena.value = 1
    await ClockCycles(dut.clk, 5)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 2)

async def run_alu_op(dut, a, b, op):
    dut.ui_in.value = (0 << 7) | (op << 4) | (a & 0xF)
    dut.uio_in.value = b & 0xF
    await ClockCycles(dut.clk, 1)
    dut.ui_in.value = (1 << 7) | (op << 4) | (a & 0xF)
    await ClockCycles(dut.clk, 1)
    dut.ui_in.value = (0 << 7) | (op << 4) | (a & 0xF)
    for _ in range(10):
        await ClockCycles(dut.clk, 1)
        if (dut.uio_out.value >> 3) & 1:
            break
    result = int(dut.uo_out.value)
    zero = int(dut.uio_out.value) & 1
    carry = (int(dut.uio_out.value) >> 1) & 1
    return result, zero, carry

def run_sfu(dut, x_float, func_sel):
    x_raw = float_to_q34(x_float)
    dut.ui_in.value = x_raw
    dut.uio_in.value = (1 << 4) | (func_sel & 0x7)

# ---- ALU Tests ----

@cocotb.test()
async def test_alu_add(dut):
    clock = Clock(dut.clk, 20, units="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)
    result, _, _ = await run_alu_op(dut, 3, 5, 0b000)
    assert result == 8, f"ADD 3+5 expected 8, got {result}"

@cocotb.test()
async def test_alu_sub(dut):
    clock = Clock(dut.clk, 20, units="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)
    result, _, _ = await run_alu_op(dut, 7, 3, 0b001)
    assert result == 4, f"SUB 7-3 expected 4, got {result}"

# ---- SFU Tests ----

@cocotb.test()
async def test_sfu_relu_positive(dut):
    clock = Clock(dut.clk, 20, units="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)
    run_sfu(dut, 2.5, 0b000)
    await ClockCycles(dut.clk, 1)
    y = q34_to_float(int(dut.uo_out.value))
    assert y == 2.5, f"ReLU(2.5) expected 2.5, got {y}"

@cocotb.test()
async def test_sfu_relu_negative(dut):
    clock = Clock(dut.clk, 20, units="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)
    run_sfu(dut, -1.5, 0b000)
    await ClockCycles(dut.clk, 1)
    y = q34_to_float(int(dut.uo_out.value))
    assert y == 0.0, f"ReLU(-1.5) expected 0, got {y}"

@cocotb.test()
async def test_sfu_sigmoid_zero(dut):
    clock = Clock(dut.clk, 20, units="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)
    run_sfu(dut, 0.0, 0b001)
    await ClockCycles(dut.clk, 1)
    y = q34_to_float(int(dut.uo_out.value))
    assert y == 0.5, f"Sigmoid(0) expected 0.5, got {y}"

@cocotb.test()
async def test_sfu_sigmoid_positive(dut):
    clock = Clock(dut.clk, 20, units="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)
    run_sfu(dut, 3.0, 0b001)
    await ClockCycles(dut.clk, 1)
    y = q34_to_float(int(dut.uo_out.value))
    assert y >= 0.875, f"Sigmoid(3.0) expected ~0.95, got {y}"

@cocotb.test()
async def test_sfu_gelu_positive(dut):
    clock = Clock(dut.clk, 20, units="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)
    run_sfu(dut, 1.0, 0b010)
    await ClockCycles(dut.clk, 1)
    y = q34_to_float(int(dut.uo_out.value))
    assert 0.5 <= y <= 1.2, f"GELU(1.0) expected ~0.84, got {y}"

@cocotb.test()
async def test_sfu_gelu_negative(dut):
    clock = Clock(dut.clk, 20, units="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)
    run_sfu(dut, -2.0, 0b010)
    await ClockCycles(dut.clk, 1)
    y = q34_to_float(int(dut.uo_out.value))
    assert -0.5 <= y <= 0.1, f"GELU(-2.0) expected ~-0.045, got {y}"

@cocotb.test()
async def test_sfu_exp_zero(dut):
    clock = Clock(dut.clk, 20, units="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)
    run_sfu(dut, 0.0, 0b100)
    await ClockCycles(dut.clk, 1)
    y = q34_to_float(int(dut.uo_out.value))
    assert y == 1.0, f"Exp(0) expected 1.0, got {y}"

@cocotb.test()
async def test_sfu_tanh_zero(dut):
    clock = Clock(dut.clk, 20, units="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)
    run_sfu(dut, 0.0, 0b011)
    await ClockCycles(dut.clk, 1)
    y = q34_to_float(int(dut.uo_out.value))
    assert y == 0.0, f"Tanh(0) expected 0, got {y}"

@cocotb.test()
async def test_sfu_identity(dut):
    clock = Clock(dut.clk, 20, units="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)
    run_sfu(dut, 3.25, 0b110)
    await ClockCycles(dut.clk, 1)
    y = q34_to_float(int(dut.uo_out.value))
    assert y == 3.25, f"Identity(3.25) expected 3.25, got {y}"
