/* Compare with the frozen Guard6 callback. Only already permitted short
 * samples in [8%,25%) may differ; all remaining state must still match. */
#include <assert.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static unsigned int rng = 0x6a09e667;
static unsigned int changed;
static unsigned int next(void)
{
    rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5;
    return rng;
}

static void compare_callback(struct sock *sk, const struct rate_sample *rs)
{
    struct sock old = *sk, hot = *sk;
    bool old_loss = true, hot_loss = false;
    bool a, b;

    /* Also test the loss callback without a preceding gate update. */
    a = reference_bbrguard_cc_is_inflight_too_high(&old, rs, &old_loss);
    b = bbrguard_cc_is_inflight_too_high(&hot, rs, &hot_loss);
    if (bbrguard_recovery_allowed(sk) && rs->tx_in_flight >= 32 &&
        rs->tx_in_flight < 128 && rs->lost > 0 &&
        (u64)rs->lost * 100 >= (u64)rs->tx_in_flight * 8 &&
        (u64)rs->lost * 100 < (u64)rs->tx_in_flight * 25) {
        assert(a && old_loss && !b && !hot_loss);
        assert(!old.bbr.guard_good_rounds && hot.bbr.guard_good_rounds == 3);
        old.bbr.guard_good_rounds = hot.bbr.guard_good_rounds;
        changed++;
    } else {
        assert(a == b && old_loss == hot_loss);
    }
    assert(memcmp(&old, &hot, sizeof(old)) == 0);
    *sk = hot;
}

static void compare(struct sock *sk, const struct rate_sample *rs)
{
    struct sock post = *sk;
    compare_callback(sk, rs);
    bbrguard_update_gate(&post, rs);
    compare_callback(&post, rs);
    *sk = post;
}

int main(void)
{
    static const u32 minima[] = {0, 49999, 50000, 100000, 200000, ~0U};
    static const u32 flight[] = {0, 1, 16, 31, 32, 33, 100, 127, 128, 129, 1000, ~0U};
    static const int losses[] = {-1, 0, 1, 3, 4, 5, 7, 8, 9, INT_MAX};
    unsigned int cases = 0;
    struct sock sk;
    struct rate_sample rs;

    for (unsigned int i = 0; i < 2000000; i++) {
        if (i % 64 == 0) {
            memset(&sk, 0, sizeof(sk));
            sk.bbr.mode = BBR_PROBE_BW;
            sk.bbr.full_bw_reached = 1;
            sk.bbr.loss_gate.delivered_stamp = next();
            sk.bbr.loss_gate.lost_stamp = next();
            sk.tp.delivered = sk.bbr.loss_gate.delivered_stamp;
            sk.tp.lost = sk.bbr.loss_gate.lost_stamp;
        }
        memset(&rs, 0, sizeof(rs));
        sk.bbr.min_rtt_us = minima[next() % 6];
        if (i % 4) sk.bbr.min_rtt_us = 100000;
        sk.bbr.guard_good_rounds = next() % 4;
        sk.bbr.guard_bad_rtt = next() % 2;
        sk.bbr.round_start = next() % 2;
        sk.tp.srtt_us = (sk.bbr.min_rtt_us + next() % 10001 - 1) << 3;
        sk.tp.delivered += next() % 65;
        sk.tp.lost += next() % 6;
        tcp_jiffies32 = next();
        sk.bbr.min_rtt_stamp = tcp_jiffies32 - next() % (6 * HZ);
        sk.bbr.loss_gate.sample_stamp = tcp_jiffies32 - (HZ - 1 + next() % 3);
        sk.tp.ecn = i % 13 == 0;
        sk.icsk.icsk_ca_state = i % 11 == 0 ? TCP_CA_Loss : next() % 4;
        sk.bbr.mode = i % 7 == 0 ? next() % 4 : BBR_PROBE_BW;
        sk.bbr.full_bw_reached = i % 17 != 0;
        rs.is_app_limited = i % 19 == 0;
        rs.is_ack_delayed = i % 5 == 0;
        rs.rtt_us = (i % 23 == 0) ? -1 : (long)sk.bbr.min_rtt_us + next() % 4002 - 1;
        rs.tx_in_flight = flight[next() % (sizeof(flight)/sizeof(flight[0]))];
        rs.lost = losses[next() % 10];
        compare(&sk, &rs);
        cases++;
    }
    /* Sustained eligible windows, small-window accumulation, no-loss rounds,
     * queue/ECN/RTO exits, and delivered/lost counter wrap across a sequence. */
    memset(&sk, 0, sizeof(sk)); memset(&rs, 0, sizeof(rs));
    sk.bbr.mode = BBR_PROBE_BW; sk.bbr.full_bw_reached = 1;
    sk.bbr.min_rtt_us = 100000; sk.tp.srtt_us = 100001 << 3;
    sk.bbr.loss_gate.delivered_stamp = sk.tp.delivered = ~0U - 20;
    sk.bbr.loss_gate.lost_stamp = sk.tp.lost = ~0U - 2;
    for (unsigned int i = 0; i < 10000; i++) {
        tcp_jiffies32++;
        sk.bbr.min_rtt_stamp = tcp_jiffies32;
        sk.bbr.round_start = i % 2 == 0;
        sk.tp.delivered += 15; sk.tp.lost += i % 10 == 0;
        sk.tp.ecn = i % 41 == 0;
        sk.icsk.icsk_ca_state = i % 59 == 0 ? TCP_CA_Loss : 0;
        rs.rtt_us = i % 37 == 0 ? 102001 : 100001;
        rs.tx_in_flight = 16; rs.lost = i % 10 == 0;
        compare(&sk, &rs); cases++;
    }
    assert(changed > 0); /* The exception itself must actually be exercised. */
    printf("%u differential states passed, %u declared short-sample changes (HZ=%d)\n", cases, changed, HZ);
    return 0;
}
