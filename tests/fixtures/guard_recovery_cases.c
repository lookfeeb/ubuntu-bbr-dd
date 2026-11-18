/* Regressions for recovery after sparse loss and delayed ACK pollution. */
#include <assert.h>
#include <stdio.h>

static struct sock qualified(void)
{
    struct sock sk = {0};
    sk.bbr.mode = BBR_PROBE_BW;
    sk.bbr.full_bw_reached = 1;
    sk.bbr.min_rtt_us = 100000;
    sk.bbr.min_rtt_stamp = tcp_jiffies32;
    sk.bbr.guard_good_rounds = 3;
    sk.bbr.loss_gate.sample_stamp = tcp_jiffies32;
    sk.tp.srtt_us = 106000 << 3; /* delayed ACK remains in the smoothed RTT */
    return sk;
}

int main(void)
{
    struct rate_sample rs = {.rtt_us=100100};
    struct sock sk;
    bool high = false;
    tcp_jiffies32 = 100000;
    sk = qualified();
    bbrguard_update_gate(&sk, &rs);
    assert(bbrguard_recovery_allowed(&sk)); /* trustworthy RTT is already clean */

    rs.rtt_us = 102001;
    bbrguard_update_gate(&sk, &rs);
    assert(sk.bbr.guard_good_rounds == 3 && !bbrguard_recovery_allowed(&sk));
    sk.bbr.guard_good_rounds = 3;
    sk.bbr.round_start = 1;
    rs.rtt_us = -1;
    bbrguard_update_gate(&sk, &rs);
    assert(!bbrguard_recovery_allowed(&sk)); /* missing samples must not revive bad RTT */

    sk = qualified();
    rs.rtt_us = 200000;
    rs.is_ack_delayed = true;
    bbrguard_update_gate(&sk, &rs);
    assert(bbrguard_recovery_allowed(&sk)); /* use the previous trustworthy sample */
    tcp_jiffies32 += HZ + 1;
    bbrguard_update_gate(&sk, &rs);
    assert(!bbrguard_recovery_allowed(&sk)); /* delayed ACK never refreshes it */

    rs = (struct rate_sample){.rtt_us=100100};
    for (unsigned int cause=0; cause<6; cause++) {
        sk = qualified();
        sk.bbr.round_start = 1;
        sk.tp.delivered = 1000;
        sk.tp.lost = 30;
        if (cause == 0) sk.tp.ecn = true;
        if (cause == 1) sk.icsk.icsk_ca_state = TCP_CA_Loss;
        if (cause == 2) rs.is_app_limited = true;
        if (cause == 3) sk.bbr.mode = 0;
        if (cause == 4) sk.bbr.full_bw_reached = 0;
        if (cause == 5) sk.bbr.min_rtt_us = 49999;
        bbrguard_update_gate(&sk, &rs);
        assert(!sk.bbr.guard_good_rounds && !bbrguard_recovery_allowed(&sk));
        assert(sk.bbr.loss_gate.delivered_stamp == 1000 && sk.bbr.loss_gate.lost_stamp == 30);
        rs.is_app_limited = false;
    }

    tcp_jiffies32 = ~0U - HZ/2;
    sk = qualified();
    bbrguard_update_gate(&sk, &rs);
    tcp_jiffies32 += HZ;
    assert(bbrguard_recovery_allowed(&sk));
    tcp_jiffies32++;
    assert(!bbrguard_recovery_allowed(&sk)); /* unsigned freshness across wrap */

    sk = qualified();
    rs.lost = 3;
    rs.tx_in_flight = 32;
    assert(!bbrguard_cc_is_inflight_too_high(&sk, &rs, &high) && !high);
    assert(sk.bbr.guard_good_rounds == 3); /* qualified short overlap */
    rs.lost = 8;
    assert(bbrguard_cc_is_inflight_too_high(&sk, &rs, &high) && high);
    assert(!sk.bbr.guard_good_rounds); /* >=25% catastrophic short sample */
    sk = qualified();
    rs.tx_in_flight = 128; rs.lost = 11;
    assert(bbrguard_cc_is_inflight_too_high(&sk, &rs, &high) && high);
    assert(!sk.bbr.guard_good_rounds); /* full >=8% observation */
    sk = qualified();
    rs.lost = 0;
    high = true;
    assert(!bbrguard_cc_is_inflight_too_high(&sk, &rs, &high) && !high);

    sk = qualified();
    sk.bbr.guard_good_rounds = 0;
    sk.bbr.round_start = 1;
    rs = (struct rate_sample){.rtt_us=100100};
    const unsigned int losses[] = {2, 0, 1, 1};
    for (unsigned int i=0; i<4; i++) {
        sk.tp.delivered += 32 - losses[i];
        sk.tp.lost += losses[i];
        bbrguard_update_gate(&sk, &rs);
        assert(sk.bbr.guard_good_rounds == (i == 3 ? 3 : 0));
    }
    assert(bbrguard_recovery_allowed(&sk)); /* 4/128, not isolated 2/32 */
    sk.tp.delivered += 29;
    sk.tp.lost += 3;
    bbrguard_update_gate(&sk, &rs);
    assert(sk.bbr.guard_good_rounds == 3);
    assert(sk.bbr.loss_gate.delivered_stamp == 124 && sk.bbr.loss_gate.lost_stamp == 4);
    sk.tp.delivered += 87; sk.tp.lost += 8;
    bbrguard_update_gate(&sk, &rs);
    assert(sk.bbr.guard_good_rounds == 3); /* cumulative 11/127 still pending */
    sk.tp.delivered++;
    bbrguard_update_gate(&sk, &rs);
    assert(!sk.bbr.guard_good_rounds); /* 11/128 revokes */
    puts("recovery RTT, loss, ECN/RTO and counter-wrap regressions passed");
    return 0;
}
