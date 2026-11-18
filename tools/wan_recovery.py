"""Generate or integrate a low-queue, sampled-loss recovery TCP kernel module.

The standalone bbrguard module is generated from pinned upstream BBRv3.
Use a matching verified kernel build; do not load on production during trials.
"""
import argparse
import hashlib
from pathlib import Path
import re
import shutil
import tempfile
import sys

SOURCE_SHA256 = '7a8b7e6df08f6815b78b7c03ce48af5829215ab6f7227dadfd980c4f7a4538a9'
BASE_POLICY = r'''/* SPDX-License-Identifier: GPL-2.0-only OR BSD-2-Clause */
#ifndef BBR_WAN_POLICY_H
#define BBR_WAN_POLICY_H
/* Conservative eligibility gate; low queue delay does NOT prove random loss.
 * min RTT >= 50ms, valid fresh samples, steady state, ECN not negotiated.
 * Subtraction after ordering avoids overflow at large RTT values.
 */
static inline int bbrguard_relax_allowed(unsigned int min_us,
                                      unsigned int srtt_us,
                                      int ecn_seen, int steady, int fresh)
{
    return min_us >= 50000U && min_us != ~0U && srtt_us >= min_us &&
           srtt_us - min_us <= min_us / 8U && !ecn_seen && steady && fresh;
}
#endif
'''

BASE_HELPERS = r'''
#include "tcp_bbr_wan_policy.h"

/* This is an experimental low-queue/high-RTT loss response, not proof that
 * loss is non-congestive. Keep STARTUP, RTO and severe-loss cuts intact.
 * Upstream 2026 BBRv3 omits ECN support. Never relax on ECN-enabled sockets.
 */
static bool bbrguard_relaxed_loss(const struct sock *sk)
{
    const struct bbrguard *bbr = inet_csk_ca(sk);
    const struct tcp_sock *tp = tcp_sk(sk);

    return bbrguard_relax_allowed(bbr->min_rtt_us, tp->srtt_us >> 3,
        tcp_ecn_mode_any(tp),
        bbr->mode == BBR_PROBE_BW && bbr->full_bw_reached &&
            inet_csk(sk)->icsk_ca_state != TCP_CA_Loss,
        before(tcp_jiffies32, bbr->min_rtt_stamp + 5 * HZ));
}

static u32 bbrguard_loss_limit(const struct sock *sk)
{
    return bbrguard_relaxed_loss(sk) ? BBR_UNIT * 4 / 100 :
                                  bbrguard_param(sk, loss_thresh);
}

'''

def _base_transform(original):
    """Return the pinned base source used by the Guard generator."""
    if hashlib.sha256(original).hexdigest() != SOURCE_SHA256:
        raise ValueError('Expected pinned unmodified BBRv3 input')
    text = original.decode()
    # Rename every identifier containing bbr, including BTF ID set names.
    # Keep bbr3_* callbacks distinct from bbr_* parameters (fast_path and
    # loss_probe_recovery exist in both namespaces in the 2026 source).
    text = re.sub(r'\b[A-Za-z_]\w*\b', lambda m: m[0].replace('bbr3_', 'bbrguard_cc_').replace('bbr3', 'bbrguard').replace('bbr_', 'bbrguard_'), text)
    # These are kernel UAPI definitions, not private implementation names.
    text = text.replace('tcp_bbrguard_info', 'tcp_bbr_info').replace('tcp_bbrguard_phase', 'tcp_bbr_phase')
    text = re.sub(r'(->)bbrguard', r'\1bbr', text)
    marker = 'static bool bbrguard_cc_is_inflight_too_high('
    if text.count(marker) != 1 or text.count('bbrguard_param(sk, loss_thresh)') != 2:
        raise SystemExit('Unexpected BBRv3 loss-response layout')
    # Use one threshold consistently both when deciding excessive loss and
    # when reconstructing the in-flight level at that loss threshold.
    text = text.replace('bbrguard_param(sk, loss_thresh)', 'bbrguard_loss_limit(sk)')
    text = text.replace(marker, BASE_HELPERS + marker)
    old = 'u32 loss_cut = BBR_UNIT - bbrguard_param(sk, beta);'
    if text.count(old) != 1:
        raise SystemExit('Unexpected BBRv3 lower-bound response')
    text = text.replace(old, '''u32 beta = bbrguard_relaxed_loss(sk) ? BBR_UNIT * 15 / 100 :
                                              bbrguard_param(sk, beta);
\tu32 loss_cut = BBR_UNIT - beta;''')
    text = text.replace('MODULE_DESCRIPTION("TCP BBRv3 (Bottleneck Bandwidth and RTT)");',
                        'MODULE_DESCRIPTION("Experimental BBRv3 WAN loss response; A/B testing required");')
    text = text.replace('MODULE_VERSION(__stringify(BBR_VERSION));',
                        'MODULE_VERSION("3-guard7-r2-experimental");\nMODULE_ALIAS("tcp_bbrguard");')
    if '.name\t\t= "bbrguard"' not in text:
        raise SystemExit('Missing unique congestion-control name')
    return text

POLICY = r'''/* SPDX-License-Identifier: GPL-2.0-only OR BSD-2-Clause */
#ifndef BBR_GUARD_POLICY_H
#define BBR_GUARD_POLICY_H
struct bbrguard_gate {
    unsigned int delivered_stamp;
    unsigned int lost_stamp;
    unsigned int sample_stamp;
};
/* Tight absolute queue budget on long paths; use subtraction to avoid wrap. */
static inline int bbrguard_queue_ok(unsigned int min_us, unsigned int rtt,
                                    unsigned int divisor, unsigned int max_us)
{
    unsigned int budget = min_us / divisor;
    if (budget > max_us)
        budget = max_us;
    return min_us >= 50000U && min_us != ~0U && rtt >= min_us &&
           rtt - min_us <= budget;
}
/* Enter recovery after >=128 delivered/lost counter events and <=4% loss.
 * Once qualified, use >=128 events and >=8% loss to revoke the evidence.
 * Unqualified flows retain the >=32/8% early aggregate exit. Queue, ECN,
 * timeout and freshness checks independently control live permission.
 * Counter deltas do not overlap; they are not a claim of independent samples.
 * Unsigned subtraction handles counter wrap; products use 64-bit arithmetic.
 */
static inline unsigned int bbrguard_finish_round(struct bbrguard_gate *g,
        unsigned int delivered, unsigned int lost, unsigned int good_rounds,
        int eligible)
{
    unsigned int good = delivered - g->delivered_stamp;
    unsigned int bad = lost - g->lost_stamp;
    unsigned long long total = (unsigned long long)good + bad;
    int qualified = good_rounds == 3;
    if (eligible && total < 128 &&
        (qualified || total < 32 || (unsigned long long)bad * 100 < total * 8))
        return good_rounds;
    g->delivered_stamp = delivered;
    g->lost_stamp = lost;
    if (!eligible)
        return 0;
    /* Entry and revocation are different statistical questions.
     * The live RTT/ECN/Loss gate still controls permission every ACK.
     */
    if (qualified)
        return (unsigned long long)bad * 100 >= total * 8 ? 0 : 3;
    if ((unsigned long long)bad * 100 > total * 4)
        return 0;
    return bad ? 3 : good_rounds;
}
#endif
'''

HELPERS = r'''
static bool bbrguard_recovery_allowed(const struct sock *sk)
{
    const struct bbrguard *bbr = inet_csk_ca(sk);
    const struct tcp_sock *tp = tcp_sk(sk);
    const struct bbrguard_gate *gate = &bbr->loss_gate;

    return bbr->guard_good_rounds == 3 && !bbr->guard_bad_rtt &&
        bbr->mode == BBR_PROBE_BW &&
        bbr->full_bw_reached && inet_csk(sk)->icsk_ca_state != TCP_CA_Loss &&
        !tcp_ecn_mode_any(tp) &&
        tcp_jiffies32 - gate->sample_stamp <= HZ &&
        bbr->min_rtt_us >= 50000U && bbr->min_rtt_us != ~0U;
}

static void bbrguard_update_gate(struct sock *sk, const struct rate_sample *rs)
{
    struct bbrguard *bbr = inet_csk_ca(sk);
    const struct tcp_sock *tp = tcp_sk(sk);
    struct bbrguard_gate *gate = &bbr->loss_gate;
    bool valid = rs->rtt_us >= 0 && !rs->is_ack_delayed;
    bool bad_rtt = false;
    bool allowed = bbr->mode == BBR_PROBE_BW && bbr->full_bw_reached &&
        inet_csk(sk)->icsk_ca_state != TCP_CA_Loss && !tcp_ecn_mode_any(tp) &&
        !rs->is_app_limited;

    if (valid) {
        bad_rtt = !bbrguard_queue_ok(bbr->min_rtt_us, rs->rtt_us, 32, 2000);
        /* Keep loss evidence separate from current queue permission.
         * Bad RTT disables recovery immediately; only a trustworthy
         * good sample can clear it. Delayed/missing RTT changes neither. */
        if (!bad_rtt)
            gate->sample_stamp = tcp_jiffies32;
        bbr->guard_bad_rtt = bad_rtt;
    }
    /* Remember observed delivery, not an assumed capacity floor. A single
     * spare bit restricts early exploration to previously larger flows.
     * It never grants current loss/RTT permission or restores old bandwidth.
     */
    if (!bbr->guard_large_sample && allowed && valid && !bad_rtt &&
        rs->delivered >= 128 && rs->interval_us > 0 &&
        (u64)rs->interval_us <= (u64)bbr->min_rtt_us * 2)
        bbr->guard_large_sample = 1;
    if (!allowed || tcp_jiffies32 - gate->sample_stamp > HZ ||
        bbr->min_rtt_us < 50000U || bbr->min_rtt_us == ~0U) {
        bbr->guard_good_rounds = 0;
        gate->delivered_stamp = tp->delivered;
        gate->lost_stamp = tp->lost;
        /* Discard loss evidence on expired samples or excluded states. */
        return;
    }
    if (!bbr->round_start)
        return;
    bbr->guard_good_rounds = bbrguard_finish_round(gate, tp->delivered, tp->lost,
        bbr->guard_good_rounds,
        tcp_jiffies32 - gate->sample_stamp <= HZ);
}

'''


# Bounded early exploration requires observed larger delivery on this socket.
EARLY_GROWTH = r'''/* Small, ACK-funded exploration, without granting loss qualification. */
static bool bbrguard_early_probe(const struct sock *sk,
                                 const struct rate_sample *rs)
{
    const struct bbrguard *bbr = inet_csk_ca(sk);
    const struct tcp_sock *tp = tcp_sk(sk);

    return bbr->guard_large_sample && bbr->inflight_hi < 64 && tp->is_cwnd_limited &&
        bbr->mode == BBR_PROBE_BW && bbr->full_bw_reached &&
        !bbr->guard_bad_rtt && inet_csk(sk)->icsk_ca_state != TCP_CA_Loss &&
        !tcp_ecn_mode_any(tp) && !rs->is_app_limited && !rs->is_ack_delayed &&
        rs->acked_sacked && !rs->losses && !rs->lost && rs->rtt_us >= 0 &&
        bbrguard_queue_ok(bbr->min_rtt_us, rs->rtt_us, 32, 2000) &&
        tcp_jiffies32 - bbr->loss_gate.sample_stamp <= HZ;
}

static void bbrguard_cc_probe_inflight_hi_upward(struct sock *sk,
					  const struct rate_sample *rs)
{
	struct tcp_sock *tp = tcp_sk(sk);
	struct bbrguard *bbr = inet_csk_ca(sk);
	u32 delta;

	if (!tp->is_cwnd_limited || tcp_snd_cwnd(tp) < bbr->inflight_hi)
		return;  /* not fully using inflight_hi, so don't grow it */

    if (bbrguard_early_probe(sk, rs)) {
        delta = min(rs->acked_sacked, 64U - bbr->inflight_hi);
        bbr->inflight_hi += delta;
        bbr->bw_probe_up_acks = 0;
        if (delta)
            bbr->try_fast_path = 0;
        if (bbr->round_start)
            bbrguard_cc_raise_inflight_hi_slope(sk);
        return;
    }

	/* For each bw_probe_up_cnt packets ACKed, increase inflight_hi by 1. */
	bbr->bw_probe_up_acks += rs->acked_sacked;
	if (bbr->bw_probe_up_acks >=  bbr->bw_probe_up_cnt) {
		delta = bbr->bw_probe_up_acks / bbr->bw_probe_up_cnt;
		bbr->bw_probe_up_acks -= delta * bbr->bw_probe_up_cnt;
		bbr->inflight_hi += delta;
		bbr->try_fast_path = 0;  /* Need to update cwnd */
	}

	if (bbr->round_start)
		bbrguard_cc_raise_inflight_hi_slope(sk);
}
'''

WINDOW_PACING = r'''
/* Allow a currently allocated small window to be paced within its sampled
 * RTT. This does not restore historic bandwidth or increase cwnd/inflight_hi.
 * Keep ACK, queue, loss, ECN, timeout and freshness gates live on every ACK.
 */
static void bbrguard_pace_window(struct sock *sk, const struct rate_sample *rs)
{
    struct bbrguard *bbr = inet_csk_ca(sk);
    const struct tcp_sock *tp = tcp_sk(sk);
    u64 budget_bw;
    unsigned long rate;

    bbr->guard_pacing_boost = 0;
    if (!(bbr->guard_large_sample && bbr->inflight_hi < 64 &&
          bbr->mode == BBR_PROBE_BW && bbr->cycle_idx == BBR_BW_PROBE_UP &&
          bbr->full_bw_reached && !bbr->guard_bad_rtt &&
          inet_csk(sk)->icsk_ca_state != TCP_CA_Loss && !tcp_ecn_mode_any(tp) &&
          !rs->is_app_limited && !rs->is_ack_delayed && rs->acked_sacked &&
          !rs->losses && !rs->lost && rs->rtt_us >= 0 &&
          bbrguard_queue_ok(bbr->min_rtt_us, rs->rtt_us, 32, 2000) &&
          tcp_jiffies32 - bbr->loss_gate.sample_stamp <= HZ))
        return;
    budget_bw = (u64)min(tcp_snd_cwnd(tp), bbr->inflight_hi) * BW_UNIT;
    do_div(budget_bw, (u32)rs->rtt_us);
    rate = bbrguard_cc_bw_to_pacing_rate(sk, budget_bw, BBR_UNIT);
    if (rate > READ_ONCE(sk->sk_pacing_rate)) {
        WRITE_ONCE(sk->sk_pacing_rate, rate);
        bbr->guard_pacing_boost = 1;
    }
}

'''

TINY_LOSS = r'''/* One tiny overlapping loss sample is not full-window evidence.
 * Limit this exception to the explicit <=64-packet exploration budget.
 */
static bool bbrguard_tiny_single_loss(const struct sock *sk,
                                     const struct rate_sample *rs)
{
    const struct bbrguard *bbr = inet_csk_ca(sk);
    const struct tcp_sock *tp = tcp_sk(sk);

    return bbr->guard_large_sample && rs->lost == 1 &&
        rs->tx_in_flight >= 5 && rs->tx_in_flight < 32 &&
        bbr->inflight_hi < 64 && bbr->mode == BBR_PROBE_BW &&
        bbr->cycle_idx == BBR_BW_PROBE_UP && bbr->full_bw_reached &&
        !bbr->guard_bad_rtt && !tcp_ecn_mode_any(tp) &&
        inet_csk(sk)->icsk_ca_state != TCP_CA_Loss &&
        !rs->is_app_limited && !rs->is_ack_delayed &&
        bbr->min_rtt_us >= 50000U && bbr->min_rtt_us != ~0U &&
        tcp_jiffies32 - bbr->loss_gate.sample_stamp <= HZ;
}
'''


def once(text, old, new):
    if text.count(old) != 1:
        raise ValueError('Unexpected source anchor: ' + old[:90])
    return text.replace(old, new)


RECOVERY_CONTEXT = r'''static bool bbrguard_recovery_context(const struct sock *sk)
{
    const struct bbrguard *bbr = inet_csk_ca(sk);
    const struct tcp_sock *tp = tcp_sk(sk);

    /* Socket-local state cannot change within this decision. Freshness
     * remains a separate volatile clock read at each original boundary. */
    return bbr->guard_good_rounds == 3 && !bbr->guard_bad_rtt &&
        bbr->mode == BBR_PROBE_BW && bbr->full_bw_reached &&
        inet_csk(sk)->icsk_ca_state != TCP_CA_Loss && !tcp_ecn_mode_any(tp) &&
        bbr->min_rtt_us >= 50000U && bbr->min_rtt_us != ~0U;
}

'''


DRAIN_POLICY = r'''
/* Two min-RTT time windows avoid waiting for queue-inflated packet rounds.
 * The second window's maximum delivery rate becomes a frozen drain target.
 * Confirmation state and drain state share two u32 fields (8 bytes total).
 */
static void bbrguard_update_drain(struct sock *sk, const struct rate_sample *rs,
                                 const struct bbrguard_context *ctx)
{
    struct bbrguard *bbr = inet_csk_ca(sk);
    const struct tcp_sock *tp = tcp_sk(sk);
    u32 rtt = tp->srtt_us >> 3;
    u32 minimum = bbr->min_rtt_us;
    u32 now = (u32)tp->tcp_mstamp;
    bool valid = rs->acked_sacked && rs->rtt_us >= 0 &&
                 !rs->is_ack_delayed && rs->interval_us > 0 && ctx->sample_bw;

    if ((bbr->mode != BBR_PROBE_BW && bbr->mode != BBR_PROBE_RTT) ||
        inet_csk(sk)->icsk_ca_state == TCP_CA_Loss || tcp_ecn_mode_any(tp) ||
        (!bbr->guard_drain_active && rs->is_app_limited) || minimum < 50000U || minimum > 1000000U) {
        if (bbr->guard_drain_active)
            bbr->try_fast_path = 0;
        bbr->guard_stamp = bbr->guard_drain_bw = 0;
        bbr->guard_drop_rounds = bbr->guard_clear_rounds = 0;
        bbr->guard_drain_active = 0;
        return;
    }
    /* PROBE_RTT owns cwnd while active. Preserve our target for its return,
     * but never begin confirmation or apply a second cwnd policy there.
     * full_bw_reached is also reset by PROBE_UP, so mode is the startup gate.
     */
    if (bbr->mode == BBR_PROBE_RTT) {
        bbr->guard_drop_rounds = 0;
        if (!bbr->guard_drain_active)
            bbr->guard_drain_bw = 0;
        return;
    }
    if (!valid)
        return;
    if (bbr->guard_drain_active) {
        /* Once BBR's own maximum has caught up, its normal model owns pacing.
         * This also prevents a stale diagnostic/cap after queue-based exit
         * is prevented by BBR's normal two-BDP cwnd.
         */
        if (bbrguard_cc_max_bw(sk) <= bbr->guard_drain_bw) {
            bbr->guard_drain_active = 0;
            bbr->guard_drain_bw = 0;
            bbr->guard_clear_rounds = 0;
            bbr->try_fast_path = 0;
            return;
        }
        if (rtt >= minimum && rtt - minimum <= max(minimum / 8U, 5000U)) {
            if (!bbr->guard_clear_rounds) {
                bbr->guard_clear_rounds = 1;
                bbr->guard_stamp = now;
            } else if ((u32)(now - bbr->guard_stamp) >= minimum * 2U) {
                bbr->guard_drain_active = 0;
                bbr->guard_drain_bw = 0;
                bbr->guard_clear_rounds = 0;
                bbr->try_fast_path = 0;
            }
        } else {
            bbr->guard_clear_rounds = 0;
        }
        return;
    }
    if (ctx->sample_bw > bbrguard_cc_max_bw(sk) / 2U || rtt < minimum ||
        rtt - minimum < max(minimum / 4U, 10000U)) {
        bbr->guard_drop_rounds = 0;
        bbr->guard_drain_bw = 0;
        return;
    }
    if (!bbr->guard_drop_rounds || (u32)(now - bbr->guard_stamp) > minimum * 4U) {
        bbr->guard_stamp = now;
        bbr->guard_drain_bw = ctx->sample_bw;
        bbr->guard_drop_rounds = 1;
        return;
    }
    bbr->guard_drain_bw = max(bbr->guard_drain_bw, ctx->sample_bw);
    if ((u32)(now - bbr->guard_stamp) >= minimum) {
        if (bbr->guard_drop_rounds == 1) {
            bbr->guard_drop_rounds = 2;
            bbr->guard_stamp = now;
            bbr->guard_drain_bw = ctx->sample_bw;
        } else {
            bbr->guard_drop_rounds = 0;
            bbr->guard_drain_active = 1;
            bbr->guard_clear_rounds = 0;
            bbr->try_fast_path = 0;
        }
    }
}

static void bbrguard_apply_drain(struct sock *sk)
{
    struct bbrguard *bbr = inet_csk_ca(sk);
    struct tcp_sock *tp = tcp_sk(sk);
    u64 window;
    u32 cap;
    unsigned long rate;

    if (!bbr->guard_drain_active)
        return;
    if (bbr->mode != BBR_PROBE_BW)
        return;
    rate = bbrguard_cc_bw_to_pacing_rate(sk, bbr->guard_drain_bw,
                                       BBR_UNIT * 7 / 8);
    WRITE_ONCE(sk->sk_pacing_rate, min(READ_ONCE(sk->sk_pacing_rate), rate));
    window = (u64)bbr->guard_drain_bw * bbr->min_rtt_us;
    window = (window >> BW_SCALE) * 5 / 4 + 4;
    cap = max_t(u32, 4, min_t(u64, window, U32_MAX));
    tcp_snd_cwnd_set(tp, min(tcp_snd_cwnd(tp), cap));
    bbr->guard_pacing_boost = 0;
}

'''


def add_drain_policy(text):
    """Add a bounded drain without changing the original BBR bandwidth model."""
    text = once(text, '\t\tunused_4:6;\n',
                '\t\tguard_drop_rounds:2,\n\t\tguard_clear_rounds:2,\n'
                '\t\tguard_drain_active:1,\n\t\tunused_4:1;\n')
    text = once(text, '\tstruct bbrguard_gate loss_gate;\n',
                '\tstruct bbrguard_gate loss_gate;\n\tu32 guard_stamp;\n\tu32 guard_drain_bw;\n')
    text = once(text, '__bpf_kfunc static void bbrguard_cc_main(',
                DRAIN_POLICY + '__bpf_kfunc static void bbrguard_cc_main(')
    text = once(text, '\tbbrguard_cc_calculate_bw_sample(sk, rs, &ctx);',
                '\tbbrguard_cc_calculate_bw_sample(sk, rs, &ctx);\n\tbbrguard_update_drain(sk, rs, &ctx);')
    text = once(text, '\tif (!bbr->guard_pacing_boost &&',
                '\tif (!bbr->guard_pacing_boost && !bbr->guard_drain_active &&')
    text = once(text, '\tbbrguard_pace_window(sk, rs);',
                '\tbbrguard_pace_window(sk, rs);\n\tbbrguard_apply_drain(sk);')
    reset = ('\tbbr->guard_stamp = bbr->guard_drain_bw = 0;\n'
             '\tbbr->guard_drain_active = 0;\n'
             '\tbbr->guard_drop_rounds = bbr->guard_clear_rounds = 0;\n')
    text = once(text, '\tmemset(&bbr->loss_gate, 0, sizeof(bbr->loss_gate));',
                reset + '\tmemset(&bbr->loss_gate, 0, sizeof(bbr->loss_gate));')
    text = once(text, '\tif (new_state == TCP_CA_Loss) {',
                '\tif (new_state == TCP_CA_Loss) {\n' +
                ''.join('\t' + line + '\n' for line in reset.splitlines()).rstrip('\n'))
    text = once(text, '\tbbr->idle_restart = 1;', reset + '\tbbr->idle_restart = 1;')
    return once(text, '(bbr->guard_large_sample << 4);',
                '(bbr->guard_large_sample << 4) | (bbr->guard_drain_active ? 32 : 0);')


def generate(source, output):
    text = _base_transform(source.read_bytes())
    legacy = BASE_HELPERS
    text = once(text, legacy, HELPERS + legacy)
    text = once(text, '/* BBRv3 congestion control block */',
                '#include "tcp_bbr_guard_policy.h"\n\n/* BBRv3 congestion control block */')
    text = once(text, '\t\tunused_4:11;\n};',
                '\t\tguard_good_rounds:2,\n\t\tguard_bad_rtt:1,\n'
                '\t\tguard_large_sample:1,\n\t\tunused_4:7;\n\tstruct bbrguard_gate loss_gate;\n};')
    text = once(text, '\tbbrguard_cc_calculate_bw_sample(sk, rs, &ctx);',
                '\tbbrguard_update_gate(sk, rs);\n\tbbrguard_cc_calculate_bw_sample(sk, rs, &ctx);')
    text = once(text, '\tbbr->initialized = 1;',
                '\tmemset(&bbr->loss_gate, 0, sizeof(bbr->loss_gate));\n'
                '\tbbr->loss_gate.delivered_stamp = tp->delivered;\n'
                '\tbbr->loss_gate.lost_stamp = tp->lost;\n'
                '\tbbr->guard_good_rounds = 0;\n\tbbr->guard_bad_rtt = 0;\n\tbbr->guard_large_sample = 0;\n\tbbr->initialized = 1;')
    text = once(text, '\t*is_loss_too_high = 0;\n',
                '\t*is_loss_too_high = 0;\n'
                '\t/* No loss evidence: avoid all recovery eligibility checks. */\n'
                '\tif (rs->lost <= 0 || !rs->tx_in_flight)\n'
                '\t\treturn false;\n'
                '\t/* Qualified short samples overlap; revoke on a full observation,\n'
                '\t * or an immediate catastrophic short signal. Unqualified behavior is\n'
                '\t * unchanged, and queue/ECN/RTO permission is still checked below.\n'
                '\t */\n'
                '\tif ((rs->tx_in_flight >= 128 &&\n'
                '\t     (u64)rs->lost * 100 >= (u64)rs->tx_in_flight * 8) ||\n'
                '\t    (rs->tx_in_flight >= 32 &&\n'
                '\t     (u64)rs->lost * 100 >= (u64)rs->tx_in_flight * 25)) {\n'
                '\t\tstruct bbrguard *bbr = inet_csk_ca(sk);\n'
                '\t\tbbr->guard_good_rounds = 0;\n'
                '\t} else if (!bbrguard_recovery_context(sk)) {\n'
                '\t\tstruct bbrguard *bbr = inet_csk_ca(sk);\n'
                '\t\tif (rs->tx_in_flight >= 32 &&\n'
                '\t\t    (u64)rs->lost * 100 >= (u64)rs->tx_in_flight * 8)\n'
                '\t\t\tbbr->guard_good_rounds = 0;\n'
                '\t} else {\n'
                '\t\tstruct bbrguard *bbr = inet_csk_ca(sk);\n'
                '\t\tbool fresh = tcp_jiffies32 - bbr->loss_gate.sample_stamp <= HZ;\n'
                '\t\tif (!fresh && rs->tx_in_flight >= 32 &&\n'
                '\t\t    (u64)rs->lost * 100 >= (u64)rs->tx_in_flight * 8)\n'
                '\t\t\tbbr->guard_good_rounds = 0;\n'
                '\t\telse if (tcp_jiffies32 - bbr->loss_gate.sample_stamp <= HZ)\n'
                '\t\t\treturn false;\n'
                '\t}\n')
    text = once(text, '\t/* Loss response. */\n\tif (bbr->loss_in_round) {',
                '\t/* Repeated low-queue random loss must not repeatedly collapse\n'
                '\t * the short-term model. A guarded refill restores old bounds. */\n'
                '\tif (bbrguard_recovery_allowed(sk))\n\t\treturn;\n\n'
                '\t/* Loss response. */\n\tif (bbr->loss_in_round) {')
    text = once(text, '\tif (bbrguard_cc_has_elapsed_in_phase(sk, bbr->probe_wait_us) ||',
                '\tif ((bbrguard_recovery_allowed(sk) &&\n'
                '\t     bbrguard_cc_has_elapsed_in_phase(sk, max(500000U, min(bbr->min_rtt_us, 1000000U) * 4))) ||\n'
                '\t    bbrguard_cc_has_elapsed_in_phase(sk, bbr->probe_wait_us) ||')
    text = once(text, '\t\tif (bbr->prev_probe_too_high &&\n\t\t    inflight >= bbr->inflight_hi) {',
                '\t\tif (bbr->prev_probe_too_high && !bbrguard_recovery_allowed(sk) &&\n'
                '\t\t    inflight >= bbr->inflight_hi) {')
    text = once(text, '\tif (new_state == TCP_CA_Loss) {',
                '\tif (new_state == TCP_CA_Loss) {\n\t\tbbr->guard_good_rounds = 0;\n'
                '\t\tbbr->guard_bad_rtt = 1;')
    # Replace only the pinned growth body; large-window slope remains upstream.
    match = re.search(r'^static void bbrguard_cc_probe_inflight_hi_upward\([^;]+?\n\{', text, re.M)
    if match is None:
        raise ValueError('Missing inflight growth function')
    end = text.index('\n}\n', match.start()) + 3
    text = once(text, text[match.start():end], EARLY_GROWTH.rstrip() + '\n')
    text = once(text, 'static bool bbrguard_cc_is_inflight_too_high(',
                TINY_LOSS + '\n' + RECOVERY_CONTEXT + 'static bool bbrguard_cc_is_inflight_too_high(')
    text = once(text, '\n\tif (rs->lost > 0 && rs->tx_in_flight) {',
                '\n\tif (bbrguard_tiny_single_loss(sk, rs))\n\t\treturn false;\n'
                '\n\tif (rs->lost > 0 && rs->tx_in_flight) {')
    text = once(text, 'if ((bbrguard_recovery_allowed(sk) &&',
                'if (((bbrguard_recovery_allowed(sk) || bbrguard_early_probe(sk, rs)) &&')
    text = once(text, 'if (bbr->prev_probe_too_high && !bbrguard_recovery_allowed(sk) &&',
                'if (bbr->prev_probe_too_high && !bbrguard_recovery_allowed(sk) &&\n'
                '            !bbrguard_early_probe(sk, rs) &&')
    text = once(text, '\t\tbbrguard_info->bbr_version\t\t= (__u8)BBR_VERSION;',
                '\t\tbbrguard_info->bbr_version\t\t= (__u8)BBR_VERSION;\n'
                '\t\t/* Experimental diagnostic marker, only for bbrguard. */\n'
                '\t\tbbrguard_info->unused1 = 0x80 | bbr->guard_good_rounds |\n'
                '\t\t\t(bbr->guard_bad_rtt << 2) | (bbrguard_recovery_allowed(sk) << 3) |\n\t\t\t(bbr->guard_large_sample << 4);')
    # A stale small-window bandwidth estimate must not prevent using the
    # window already granted by ACK-funded growth. Keep the override ephemeral.
    text = once(text, '\t\tguard_large_sample:1,\n\t\tunused_4:7;',
                '\t\tguard_large_sample:1,\n\t\tguard_pacing_boost:1,\n\t\tunused_4:6;')
    text = once(text, '\tbbr->guard_large_sample = 0;\n',
                '\tbbr->guard_large_sample = 0;\n\tbbr->guard_pacing_boost = 0;\n')
    text = once(text, '__bpf_kfunc static void bbrguard_cc_main(',
                WINDOW_PACING + '__bpf_kfunc static void bbrguard_cc_main(')
    text = once(text, '\tif (bbrguard_cc_fast_path(sk, &update_model, rs, &ctx))',
                '\tif (!bbr->guard_pacing_boost &&\n'
                '\t    bbrguard_cc_fast_path(sk, &update_model, rs, &ctx))')
    text = once(text, '\tbbrguard_cc_bound_cwnd_for_inflight_model(sk);\n\nout:',
                '\tbbrguard_cc_bound_cwnd_for_inflight_model(sk);\n'
                '\tbbrguard_pace_window(sk, rs);\n\nout:')
    text = once(text, '            !bbrguard_early_probe(sk, rs) &&\n', '            !bbrguard_early_probe(sk, rs) &&\n            /* Preserve an already accepted bounded single-loss sample\n             * across the previous-limit heuristic. Loss classification and\n             * clean-ACK pacing remain unchanged. */\n            !(bbrguard_tiny_single_loss(sk, rs) && tp->is_cwnd_limited &&\n              rs->acked_sacked && rs->losses >= 0 && rs->losses <= 1 &&\n              rs->rtt_us >= 0 &&\n              bbrguard_queue_ok(bbr->min_rtt_us, rs->rtt_us, 32, 2000)) &&\n')
    if not re.search(r'\.name\s*= "bbrguard"', text):
        raise ValueError('Missing isolated algorithm name')
    text = add_drain_policy(text)
    output.mkdir(parents=True, exist_ok=False)
    (output / 'tcp_bbr_guard.c').write_text(text)
    (output / 'tcp_bbr_guard_policy.h').write_text(POLICY)
    (output / 'tcp_bbr_wan_policy.h').write_text(BASE_POLICY)
    (output / 'Makefile').write_text('obj-m += tcp_bbr_guard.o\n')


def apply_kernel_tree(root):
    """Add an opt-in module without changing old WAN sources or TCP ABI."""
    root = root.resolve()
    makefile = (root / 'Makefile').read_text()
    for name, value in [('VERSION', '7'), ('PATCHLEVEL', '3'), ('SUBLEVEL', '5')]:
        if not re.search(r'^' + name + r' = ' + value + r'$', makefile, re.M):
            raise ValueError('Expected Linux 7.3.5 kernel tree')
    ipv4 = root / 'net/ipv4'
    files = ['tcp_bbr_guard.c', 'tcp_bbr_guard_policy.h', 'tcp_bbr_guard_legacy.h']
    config, build = (ipv4 / 'Kconfig').read_text(), (ipv4 / 'Makefile').read_text()
    if any((ipv4 / name).exists() for name in files) or 'TCP_CONG_BBR_GUARD' in config + build:
        raise ValueError('Recovery module already present; use an unmodified tree')
    if config.count('config TCP_CONG_BBR3\n') != 1:
        raise ValueError('Missing unique BBRv3 Kconfig anchor')
    with tempfile.TemporaryDirectory(prefix='bbrguard-tree-') as temporary:
        output = Path(temporary) / 'module'
        generate(ipv4 / 'tcp_bbr3.c', output)
        source = (output / 'tcp_bbr_guard.c').read_text().replace(
            '"tcp_bbr_wan_policy.h"', '"tcp_bbr_guard_legacy.h"')
        (ipv4 / 'tcp_bbr_guard.c').write_text(source)
        shutil.copyfile(output / 'tcp_bbr_guard_policy.h', ipv4 / 'tcp_bbr_guard_policy.h')
        shutil.copyfile(output / 'tcp_bbr_wan_policy.h', ipv4 / 'tcp_bbr_guard_legacy.h')
    option = ('config TCP_CONG_BBR_GUARD\n'
              '\ttristate "Experimental BBRv3 guarded recovery"\n'
              '\tdepends on TCP_CONG_ADVANCED\n'
              '\thelp\n\t  Separate bbrguard module for controlled WAN recovery testing.\n\n')
    (ipv4 / 'Kconfig').write_text(config.replace('config TCP_CONG_BBR3\n', option + 'config TCP_CONG_BBR3\n'))
    (ipv4 / 'Makefile').write_text(build + '\nobj-$(CONFIG_TCP_CONG_BBR_GUARD) += tcp_bbr_guard.o\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--source', type=Path)
    mode.add_argument('--kernel-tree', type=Path)
    parser.add_argument('--out', type=Path)
    args = parser.parse_args()
    if args.kernel_tree:
        if args.out:
            parser.error('--out only applies to --source')
        apply_kernel_tree(args.kernel_tree)
    else:
        if not args.out:
            parser.error('--source requires --out')
        generate(args.source, args.out)
