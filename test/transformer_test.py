import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, Timer


CMD_LOAD_QUERY = 0b00
CMD_LOAD_CONTEXT = 0b01
CMD_CONTROL = 0b10
CMD_READ_BANK = 0b11


def signed8(value):
    value &= 0xFF
    return value - 256 if value & 0x80 else value


def raw8(value):
    return value & 0xFF


def pack_uio(strobe, cmd, feature_idx=0, slot=0):
    return ((strobe & 0x1) << 7) | ((cmd & 0x3) << 5) | ((feature_idx & 0x7) << 2) | (slot & 0x3)


def sat8(value):
    if value > 127:
        return 127
    if value < -128:
        return -128
    return int(value)


def coeff4(seed, row_idx, col_idx):
    mix = (seed + row_idx * 3 + col_idx * 5 + row_idx * col_idx) % 7
    table = {
        0: -4,
        1: -3,
        2: -2,
        3: -1,
        4: 1,
        5: 2,
        6: 3,
    }
    return table[mix]


def sigmoid_q44(x):
    abs_x = abs(x)
    if abs_x >= 48:
        pos = 16
    elif abs_x >= 24:
        pos = (abs_x >> 4) + 10
    else:
        pos = (abs_x >> 3) + 8
    return 16 - pos if x < 0 else pos


def gelu_q44(x):
    scaled_x = sat8((x * 3) >> 1)
    sig_x = sigmoid_q44(scaled_x)
    return sat8((x * sig_x) >> 4)


def exp_weight(x):
    if x <= -48:
        return 2
    if x <= -24:
        return 4
    if x <= -8:
        return 8
    if x <= 8:
        return 16 + (0 if x < 0 else ((x & 0xF) >> 1))
    if x <= 24:
        return 28 + ((x & 0x1F) >> 1)
    return 48


def norm_shift(weight_sum):
    if weight_sum >= 160:
        return 6
    if weight_sum >= 96:
        return 5
    return 4


def transformer_reference(query_vec, context_vecs):
    q_proj = []
    keys = [[0] * 8 for _ in range(4)]
    values = [[0] * 8 for _ in range(4)]
    attn_weights = [0] * 8
    attn_mix = [0] * 8
    mix_vec = [0] * 8
    final_vec = [0] * 8

    for row in range(8):
        acc = 0
        for col in range(8):
            acc += query_vec[col] * coeff4(1, row, col)
        q_proj.append(sat8(acc >> 4))

    for token in range(4):
        for row in range(8):
            acc_k = 0
            acc_v = 0
            for col in range(8):
                acc_k += context_vecs[token][col] * coeff4(5, row, col)
                acc_v += context_vecs[token][col] * coeff4(9, row, col)
            keys[token][row] = sat8(acc_k >> 4)
            values[token][row] = sat8(acc_v >> 4)

    for head in range(2):
        base = head * 4
        weights = []
        for token in range(4):
            score_acc = 0
            for dim in range(4):
                score_acc += q_proj[base + dim] * keys[token][base + dim]
            weight = exp_weight(sat8(score_acc >> 8))
            attn_weights[base + token] = weight
            weights.append(weight)

        shift = norm_shift(sum(weights))
        for dim in range(4):
            acc = 0
            for token in range(4):
                acc += weights[token] * values[token][base + dim]
            attn_mix[base + dim] = sat8(acc >> shift)

    for row in range(8):
        acc = 0
        for col in range(8):
            acc += attn_mix[col] * coeff4(11, row, col)
        mix_vec[row] = sat8(query_vec[row] + (acc >> 4))

    hidden = []
    for hidden_idx in range(16):
        hidden_acc = 0
        for col in range(8):
            hidden_acc += mix_vec[col] * coeff4(13, hidden_idx, col)
        hidden.append(gelu_q44(sat8(hidden_acc >> 4)))

    for row in range(8):
        final_acc = 0
        for hidden_idx in range(16):
            final_acc += hidden[hidden_idx] * coeff4(3, row, hidden_idx)
        final_vec[row] = sat8(mix_vec[row] + (final_acc >> 5))

    return final_vec, mix_vec, q_proj, attn_weights


async def reset_dut(dut):
    dut.rst_n.value = 0
    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = pack_uio(0, CMD_CONTROL, 0, 0)
    await ClockCycles(dut.clk, 5)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 2)


async def write_query(dut, feature_idx, value):
    dut.ui_in.value = raw8(value)
    dut.uio_in.value = pack_uio(1, CMD_LOAD_QUERY, feature_idx, 0)
    await ClockCycles(dut.clk, 1)
    dut.uio_in.value = pack_uio(0, CMD_CONTROL, 0, 0)
    dut.ui_in.value = 0
    await ClockCycles(dut.clk, 1)


async def write_context(dut, slot, feature_idx, value):
    dut.ui_in.value = raw8(value)
    dut.uio_in.value = pack_uio(1, CMD_LOAD_CONTEXT, feature_idx, slot)
    await ClockCycles(dut.clk, 1)
    dut.uio_in.value = pack_uio(0, CMD_CONTROL, 0, 0)
    dut.ui_in.value = 0
    await ClockCycles(dut.clk, 1)


async def read_status(dut):
    dut.uio_in.value = pack_uio(0, CMD_CONTROL, 0, 0)
    await Timer(1, units="ns")
    return int(dut.uo_out.value)


async def execute(dut):
    dut.ui_in.value = 0
    dut.uio_in.value = pack_uio(1, CMD_CONTROL, 7, 0)
    await ClockCycles(dut.clk, 1)
    dut.uio_in.value = pack_uio(0, CMD_CONTROL, 0, 0)
    await ClockCycles(dut.clk, 1)


async def wait_done(dut, timeout_cycles=10):
    for _ in range(timeout_cycles):
        status = await read_status(dut)
        if (status >> 7) & 0x1:
            return status
        await ClockCycles(dut.clk, 1)
    raise AssertionError("transformer execution did not complete")


async def read_bank(dut, bank, feature_idx):
    dut.uio_in.value = pack_uio(0, CMD_READ_BANK, feature_idx, bank)
    await Timer(1, units="ns")
    return signed8(int(dut.uo_out.value))


async def load_vectors(dut, query_vec, context_vecs):
    for feature_idx, value in enumerate(query_vec):
        await write_query(dut, feature_idx, value)
    for slot, ctx in enumerate(context_vecs):
        for feature_idx, value in enumerate(ctx):
            await write_context(dut, slot, feature_idx, value)


@cocotb.test()
async def test_transformer_reference_match(dut):
    cocotb.start_soon(Clock(dut.clk, 100, units="ns").start())
    await reset_dut(dut)

    query = [16, -8, 20, 4, -12, 8, 24, -16]
    context = [
        [12, -4, 8, 0, -8, 16, 4, -12],
        [-16, 8, -4, 12, 20, -8, 0, 4],
        [4, 20, -12, 8, -4, 12, -16, 16],
        [8, 0, 16, -8, 12, -4, 20, -12],
    ]

    expected_final, expected_mix, expected_qproj, expected_weights = transformer_reference(query, context)

    await load_vectors(dut, query, context)
    await execute(dut)

    status = await read_status(dut)
    assert ((status >> 6) & 0x1) == 1, f"busy bit should assert after execute, got status=0x{status:02x}"

    final_status = await wait_done(dut)
    assert ((final_status >> 6) & 0x1) == 0, f"busy should clear after completion, got 0x{final_status:02x}"
    assert ((final_status >> 7) & 0x1) == 1, f"done should assert after completion, got 0x{final_status:02x}"

    observed_final = [await read_bank(dut, 0, i) for i in range(8)]
    observed_mix = [await read_bank(dut, 1, i) for i in range(8)]
    observed_qproj = [await read_bank(dut, 2, i) for i in range(8)]
    observed_weights = [raw8(await read_bank(dut, 3, i)) for i in range(8)]

    assert observed_final == expected_final, f"final mismatch: {observed_final} != {expected_final}"
    assert observed_mix == expected_mix, f"mix mismatch: {observed_mix} != {expected_mix}"
    assert observed_qproj == expected_qproj, f"q_proj mismatch: {observed_qproj} != {expected_qproj}"
    assert observed_weights == expected_weights, f"attn weights mismatch: {observed_weights} != {expected_weights}"


@cocotb.test()
async def test_transformer_reacts_to_context_updates(dut):
    cocotb.start_soon(Clock(dut.clk, 100, units="ns").start())
    await reset_dut(dut)

    query = [8, 12, -8, 16, -4, 20, 4, -12]
    context = [
        [4, 8, -12, 16, -8, 20, 0, -4],
        [-8, 16, 4, -12, 8, 0, 20, -16],
        [20, -4, 12, 8, -16, 4, -8, 16],
        [0, 12, -4, 20, 8, -8, 16, -12],
    ]

    await load_vectors(dut, query, context)
    await execute(dut)
    await wait_done(dut)
    baseline = [await read_bank(dut, 0, i) for i in range(8)]

    context[2][5] = -20
    await write_context(dut, 2, 5, context[2][5])
    await execute(dut)
    await wait_done(dut)

    expected_final, _, _, _ = transformer_reference(query, context)
    updated = [await read_bank(dut, 0, i) for i in range(8)]

    assert updated == expected_final, f"updated output mismatch: {updated} != {expected_final}"
    assert updated != baseline, "context update should change the transformer output"
