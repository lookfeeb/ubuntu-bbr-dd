/* Minimal socket types for compiled policy/callback regressions. */
#include <stdbool.h>
#include <stdint.h>
typedef uint32_t u32;
typedef uint64_t u64;
typedef int32_t s32;
#define BBR_SCALE 8
#define BBR_UNIT 256
#define BBR_PROBE_BW 2
#define BBR_BW_PROBE_UP 0
#define TCP_CA_Loss 4
#define before(a, b) ((s32)((u32)(a) - (u32)(b)) < 0)
#define bbrguard_param(sk, name) (BBR_UNIT * 2 / 100)
static volatile u32 tcp_jiffies32;
#include "tcp_bbr_guard_policy.h"
#include "tcp_bbr_wan_policy.h"
struct bbrguard {
    u32 guard_large_sample, inflight_hi, cycle_idx, min_rtt_us, min_rtt_stamp;
    unsigned int guard_good_rounds:2, guard_bad_rtt:1, mode:2,
                 full_bw_reached:1, round_start:1;
    struct bbrguard_gate loss_gate;
};
struct tcp_sock { u32 srtt_us, delivered, lost; bool ecn; };
struct inet_connection_sock { unsigned char icsk_ca_state; };
struct sock { struct bbrguard bbr; struct tcp_sock tp; struct inet_connection_sock icsk; };
struct rate_sample { long interval_us, rtt_us; int delivered; u32 tx_in_flight; int lost; bool is_ack_delayed, is_app_limited; };
#define inet_csk_ca(sk) (&(sk)->bbr)
#define tcp_sk(sk) (&(sk)->tp)
#define inet_csk(sk) (&(sk)->icsk)
#define tcp_ecn_mode_any(tp) ((tp)->ecn)
