
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "tcp_bbr_guard_policy.h"
typedef uint32_t u32;typedef uint64_t u64;
#define BW_UNIT (1U << 24)
#define READ_ONCE(a) (a)
#define WRITE_ONCE(a,b) ((a)=(b))
#define do_div(a,b) ((a)/=(b))
#define min(a,b) ((a)<(b)?(a):(b))

#define BBR_PROBE_BW 2
#define BBR_PROBE_RTT 3
#define BW_SCALE 24
#define U32_MAX UINT32_MAX
#define max(a,b) ((a)>(b)?(a):(b))
#define max_t(t,a,b) max((t)(a),(t)(b))
#define BBR_BW_PROBE_UP 0
#define BBR_UNIT 256
#define TCP_CA_Loss 4
#define __bpf_kfunc
#define unlikely(x) (x)
#define min_t(t,a,b) ((a)<(b)?(a):(b))
static u32 tcp_jiffies32=100*HZ;
struct bbrguard { u32 guard_pacing_boost,initialized,round_start,rounds_since_probe,mode,cycle_idx,pacing_gain,cwnd_gain,prev_ca_state;
 u32 guard_drain_active,guard_stamp,guard_drain_bw,guard_drop_rounds,guard_clear_rounds,try_fast_path;
 u32 guard_large_sample,inflight_hi,full_bw_reached,guard_bad_rtt,min_rtt_us;struct bbrguard_gate loss_gate; };
struct tcp_sock { u64 tcp_mstamp; u32 srtt_us,snd_cwnd;bool ecn,is_cwnd_limited; };
struct inet_connection_sock {u32 icsk_ca_state;};
struct sock {struct bbrguard b;struct tcp_sock tp;struct inet_connection_sock icsk;unsigned long sk_pacing_rate,sk_max_pacing_rate;u32 applied_gain,calls,fast_calls,model_bw,sample_bw;bool change_mode;};
struct rate_sample {long rtt_us,interval_us;bool is_app_limited,is_ack_delayed;u32 acked_sacked;int losses,lost;};
struct bbrguard_context {u32 sample_bw;};
#define inet_csk_ca(sk) (&(sk)->b)
#define tcp_sk(sk) (&(sk)->tp)
#define inet_csk(sk) (&(sk)->icsk)
#define tcp_snd_cwnd(tp) ((tp)->snd_cwnd)
#define tcp_snd_cwnd_set(tp,v) ((tp)->snd_cwnd=(v))
#define tcp_ecn_mode_any(tp) ((tp)->ecn)
static u32 bbrguard_cc_update_round_start(struct sock*s,const struct rate_sample*r,struct bbrguard_context*c){return 1;}
static void bbrguard_update_gate(struct sock*s,const struct rate_sample*r){}
static void bbrguard_cc_calculate_bw_sample(struct sock*s,const struct rate_sample*r,struct bbrguard_context*c){c->sample_bw=s->sample_bw;}
static void bbrguard_cc_update_latest_delivery_signals(struct sock*s,const struct rate_sample*r,struct bbrguard_context*c){}
static bool bbrguard_cc_fast_path(struct sock*s,bool*u,const struct rate_sample*r,struct bbrguard_context*c){s->fast_calls++;return s->b.try_fast_path&&r->is_app_limited&&!s->change_mode;}
static void bbrguard_cc_update_model(struct sock*s,const struct rate_sample*r,struct bbrguard_context*c){if(s->change_mode)s->b.mode=3;}
static void bbrguard_cc_update_gains(struct sock*s){s->b.pacing_gain=s->b.mode==2&&s->b.cycle_idx==0?320:256;}
static u32 bbrguard_cc_max_bw(struct sock*s){return s->model_bw;}
static u32 bbrguard_cc_bw(struct sock*s){return s->model_bw?s->model_bw:10;}
static unsigned long bbrguard_cc_bw_to_pacing_rate(struct sock*s,u32 bw,int gain){
 u64 rate=(u64)bw*1500*1000000/BW_UNIT*gain/BBR_UNIT;return min(rate,s->sk_max_pacing_rate);
}
static void bbrguard_cc_set_pacing_rate(struct sock*s,u32 bw,u32 gain){s->applied_gain=gain;s->calls++;s->sk_pacing_rate=bbrguard_cc_bw_to_pacing_rate(s,bw,gain);}
static void bbrguard_cc_set_cwnd(struct sock*s,const struct rate_sample*r,u32 a,u32 bw,u32 gain,u32 cw,struct bbrguard_context*c){}
static void bbrguard_cc_bound_cwnd_for_inflight_model(struct sock*s){}
static void bbrguard_cc_advance_latest_delivery_signals(struct sock*s,const struct rate_sample*r,struct bbrguard_context*c){}
