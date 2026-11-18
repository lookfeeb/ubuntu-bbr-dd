/* Advancing-clock, HZ edge and u32 wrap regression against frozen R5. */
int main(void)
{
    const u32 clocks[] = {0, HZ - 1, HZ, HZ + 1, UINT32_MAX - 1, UINT32_MAX};
    const u32 steps[] = {0, 1, HZ, UINT32_MAX};
    const u32 minima[] = {0, 49999, 50000, 100000, UINT32_MAX};
    const u32 flights[] = {0, 1, 4, 5, 16, 31, 32, 63, 64, 127, 128, 129, UINT32_MAX};
    const int losses[] = {-1, 0, 1, 2, 4, 8, 32, INT_MAX};
    unsigned cases = 0, mismatches = 0;

    for (unsigned ci = 0; ci < sizeof(clocks) / sizeof(clocks[0]); ci++)
    for (unsigned st = 0; st < sizeof(steps) / sizeof(steps[0]); st++)
    for (unsigned mi = 0; mi < sizeof(minima) / sizeof(minima[0]); mi++)
    for (unsigned fi = 0; fi < sizeof(flights) / sizeof(flights[0]); fi++)
    for (unsigned li = 0; li < sizeof(losses) / sizeof(losses[0]); li++)
    for (unsigned condition = 0; condition < 12; condition++) {
        struct sock initial = {0};
        struct rate_sample rs = {.lost = losses[li], .tx_in_flight = flights[fi]};
        initial.bbr.guard_good_rounds = 3;
        initial.bbr.full_bw_reached = 1;
        initial.bbr.mode = BBR_PROBE_BW;
        initial.bbr.min_rtt_us = minima[mi];
        initial.tp.srtt_us = 100000 << 3;
        initial.bbr.guard_large_sample = 1;
        initial.bbr.inflight_hi = 63;
        switch (condition) {
        case 1: initial.bbr.guard_good_rounds = 0; break;
        case 2: initial.bbr.guard_good_rounds = 1; break;
        case 3: initial.bbr.guard_good_rounds = 2; break;
        case 4: initial.bbr.guard_bad_rtt = 1; break;
        case 5: initial.bbr.mode = 0; break;
        case 6: initial.bbr.full_bw_reached = 0; break;
        case 7: initial.tp.ecn = 1; break;
        case 8: initial.icsk.icsk_ca_state = TCP_CA_Loss; break;
        case 9: rs.is_app_limited = 1; break;
        case 10: rs.is_ack_delayed = 1; break;
        case 11: initial.bbr.loss_gate.sample_stamp = UINT32_MAX - HZ; break;
        }
        struct sock reference = initial, current = initial;
        bool reference_loss = false, current_loss = true;
        tick = clocks[ci]; step = steps[st]; reads = 0;
        bool a = r5_reference_loss(&reference, &rs, &reference_loss);
        reads = 0;
        bool b = bbrguard_cc_is_inflight_too_high(&current, &rs, &current_loss);
        if (a != b || reference_loss != current_loss ||
            memcmp(&reference, &current, sizeof(reference)))
            mismatches++;
        cases++;
    }
    printf("clock_cases=%u mismatches=%u\n", cases, mismatches);
    return mismatches ? 1 : 0;
}
