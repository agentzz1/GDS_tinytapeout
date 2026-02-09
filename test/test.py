import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge


async def reset_dut(dut):
    dut.rst_n.value = 0
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    dut.ena.value = 1
    await ClockCycles(dut.clk, 5)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 2)


async def run_alu_op(dut, a, b, op):
    """Run one ALU operation through the FSM: set inputs, pulse start, wait for result_valid."""
    # Set operands and operation, start=0
    dut.ui_in.value = (0 << 7) | (op << 4) | (a & 0xF)
    dut.uio_in.value = b & 0xF
    await ClockCycles(dut.clk, 1)

    # Assert start
    dut.ui_in.value = (1 << 7) | (op << 4) | (a & 0xF)
    await ClockCycles(dut.clk, 1)

    # Deassert start
    dut.ui_in.value = (0 << 7) | (op << 4) | (a & 0xF)

    # Wait for result_valid (uio_out[3])
    for _ in range(10):
        await ClockCycles(dut.clk, 1)
        if (dut.uio_out.value >> 3) & 1:
            break

    result = int(dut.uo_out.value)
    zero = int(dut.uio_out.value) & 1
    carry = (int(dut.uio_out.value) >> 1) & 1
    return result, zero, carry


@cocotb.test()
async def test_add(dut):
    clock = Clock(dut.clk, 20, units="ns")  # 50MHz
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    result, zero, carry = await run_alu_op(dut, 3, 5, 0b000)  # ADD
    assert result == 8, f"ADD 3+5 expected 8, got {result}"


@cocotb.test()
async def test_sub(dut):
    clock = Clock(dut.clk, 20, units="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    result, zero, carry = await run_alu_op(dut, 7, 3, 0b001)  # SUB
    assert result == 4, f"SUB 7-3 expected 4, got {result}"


@cocotb.test()
async def test_sub_zero(dut):
    clock = Clock(dut.clk, 20, units="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    result, zero, carry = await run_alu_op(dut, 5, 5, 0b001)  # SUB
    assert result == 0, f"SUB 5-5 expected 0, got {result}"
    assert zero == 1, f"Zero flag should be set"


@cocotb.test()
async def test_and(dut):
    clock = Clock(dut.clk, 20, units="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    result, zero, carry = await run_alu_op(dut, 0b1100, 0b1010, 0b010)  # AND
    assert result == 0b1000, f"AND expected 8, got {result}"


@cocotb.test()
async def test_or(dut):
    clock = Clock(dut.clk, 20, units="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    result, zero, carry = await run_alu_op(dut, 0b1100, 0b1010, 0b011)  # OR
    assert result == 0b1110, f"OR expected 14, got {result}"


@cocotb.test()
async def test_xor(dut):
    clock = Clock(dut.clk, 20, units="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    result, zero, carry = await run_alu_op(dut, 0b1100, 0b1010, 0b100)  # XOR
    assert result == 0b0110, f"XOR expected 6, got {result}"


@cocotb.test()
async def test_shl(dut):
    clock = Clock(dut.clk, 20, units="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    result, zero, carry = await run_alu_op(dut, 0b0101, 0, 0b101)  # SHL
    assert result == 0b1010, f"SHL expected 10, got {result}"


@cocotb.test()
async def test_shr(dut):
    clock = Clock(dut.clk, 20, units="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    result, zero, carry = await run_alu_op(dut, 0b1010, 0, 0b110)  # SHR
    assert result == 0b0101, f"SHR expected 5, got {result}"
