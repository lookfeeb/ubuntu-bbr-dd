/* Minimal socket state for the actual generated growth callbacks. */
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "tcp_bbr_guard_policy.h"
typedef uint32_t u32; typedef uint64_t u64; typedef int64_t s64;
#define max_t(t,a,b) max((t)(a),(t)(b))
#define BBR_PROBE_BW 2
#define BBR_BW_PROBE_UP 0
#define TCP_CA_Loss 4
#define min(a,b) ((a)<(b)?(a):(b))
#define max(a,b) ((a)>(b)?(a):(b))
static u32 tcp_jiffies32;
struct tcp_sock { u64 tcp_mstamp; u32 snd_cwnd; bool ecn, is_cwnd_limited; };
struct inet_connection_sock { u32 icsk_ca_state; };
struct bbrguard {
    u32 guard_large_sample, mode, full_bw_reached, guard_good_rounds, guard_bad_rtt, min_rtt_us;
    u64 cycle_mstamp;
    u32 probe_wait_us, prev_probe_too_high,
        round_start, cycle_idx, inflight_hi, bw_probe_up_cnt, bw_probe_up_acks;
    u32 bw_probe_up_rounds, try_fast_path;
    struct bbrguard_gate loss_gate;
};
struct sock { bool reno; u32 refills; struct tcp_sock tp; struct inet_connection_sock icsk; struct bbrguard b; };
struct rate_sample { long rtt_us; bool is_ack_delayed, is_app_limited; int lost, losses; u32 acked_sacked, tx_in_flight; };
#define tcp_sk(sk) (&(sk)->tp)
#define inet_csk_ca(sk) (&(sk)->b)
#define inet_csk(sk) (&(sk)->icsk)
#define tcp_ecn_mode_any(tp) ((tp)->ecn)
#define tcp_snd_cwnd(tp) ((tp)->snd_cwnd)

static bool bbrguard_cc_is_reno_coexistence_probe_time(struct sock *sk) { return sk->reno; }
static void bbrguard_cc_start_bw_probe_refill(struct sock *sk, u32 rounds) { (void)rounds; sk->refills++; }
static inline u32 tcp_stamp_us_delta(u64 t1, u64 t0)
{
	return max_t(s64, t1 - t0, 0);
}
