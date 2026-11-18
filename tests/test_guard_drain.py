"""Compile the product drain policy against temporal and safety transitions."""
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('drain_recovery', ROOT / 'tools/wan_recovery.py')
recovery = importlib.util.module_from_spec(spec)
spec.loader.exec_module(recovery)

STUB = r'''
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
typedef uint32_t u32;
typedef uint64_t u64;
#define BBR_PROBE_BW 2
#define TCP_CA_Loss 4
#define BBR_UNIT 256
#define BW_SCALE 24
#define U32_MAX UINT32_MAX
#define min(a,b) ((a)<(b)?(a):(b))
#define max(a,b) ((a)>(b)?(a):(b))
#define min_t(t,a,b) min((t)(a),(t)(b))
#define max_t(t,a,b) max((t)(a),(t)(b))
#define READ_ONCE(x) (x)
#define WRITE_ONCE(x,v) ((x)=(v))
struct bbrguard {
 u32 min_rtt_us, guard_stamp, guard_drain_bw, max_bw;
 unsigned mode:2, full_bw_reached:1, try_fast_path:1, guard_pacing_boost:1,
          guard_drop_rounds:2, guard_clear_rounds:2, round_start:1, guard_drain_active:1;
};
struct tcp_sock {u64 tcp_mstamp; u32 srtt_us, cwnd; bool ecn;};
struct inet_connection_sock {int icsk_ca_state;};
struct sock {struct bbrguard bbr; struct tcp_sock tp; struct inet_connection_sock icsk;
 unsigned long sk_pacing_rate;};
struct rate_sample {long interval_us, rtt_us; u32 acked_sacked; bool is_app_limited, is_ack_delayed;};
struct bbrguard_context {u32 sample_bw;};
#define inet_csk_ca(sk) (&(sk)->bbr)
#define tcp_sk(sk) (&(sk)->tp)
#define inet_csk(sk) (&(sk)->icsk)
#define tcp_ecn_mode_any(tp) ((tp)->ecn)
#define tcp_snd_cwnd(tp) ((tp)->cwnd)
#define tcp_snd_cwnd_set(tp,v) ((tp)->cwnd=(v))
#define bbrguard_cc_max_bw(sk) ((sk)->bbr.max_bw)
static unsigned long bbrguard_cc_bw_to_pacing_rate(struct sock *sk, u32 bw, int gain) {
 (void)sk; return (unsigned long)((u64)bw*gain/256);
}

#define BBR_PROBE_RTT 3
'''

CASES = r'''
static struct sock fresh(u32 time) {
 struct sock s={0}; s.bbr.min_rtt_us=80000; s.bbr.max_bw=2000000;
 s.bbr.mode=BBR_PROBE_BW; s.bbr.full_bw_reached=1; s.bbr.try_fast_path=1;
 s.tp.srtt_us=200000*8; s.tp.cwnd=10000; s.tp.tcp_mstamp=time;
 s.sk_pacing_rate=99999999; return s;
}
static void ack(struct sock *s, u32 delta, u32 bw) {
 struct rate_sample rs={.interval_us=80000,.rtt_us=200000,.acked_sacked=10};
 struct bbrguard_context ctx={.sample_bw=bw};
 s->tp.tcp_mstamp += delta; bbrguard_update_drain(s,&rs,&ctx);
}
int main(void) {
 for(unsigned wrap=0; wrap<2; wrap++) {
  struct sock s=fresh(wrap?U32_MAX-100000:0);
  ack(&s,0,400000); assert(!s.bbr.guard_drain_active);
  ack(&s,80000,200000); assert(!s.bbr.guard_drain_active);
  ack(&s,80000,180000); assert(s.bbr.guard_drain_active && s.bbr.guard_drain_bw==200000);
  assert(!s.bbr.try_fast_path); bbrguard_apply_drain(&s);
  assert(s.sk_pacing_rate==175000);
  ack(&s,80000,100000); assert(s.bbr.guard_drain_bw==200000);
  s.tp.srtt_us=85000*8; ack(&s,10000,100000);
  ack(&s,159999,100000); assert(s.bbr.guard_drain_active);
  ack(&s,1,100000); assert(!s.bbr.guard_drain_active && !s.bbr.guard_drain_bw);
 }
 for(unsigned gate=0; gate<8; gate++) {
  struct sock s=fresh(0); ack(&s,0,200000); ack(&s,80000,200000); ack(&s,80000,200000);
  struct rate_sample rs={.interval_us=80000,.rtt_us=200000,.acked_sacked=10};
  struct bbrguard_context ctx={.sample_bw=200000};
  if(gate==0)s.bbr.mode=0;
  if(gate==1)s.bbr.mode=1;
  if(gate==2)s.icsk.icsk_ca_state=TCP_CA_Loss;
  if(gate==3)s.tp.ecn=true;
  if(gate==4)rs.is_app_limited=true;
  if(gate==5)s.bbr.min_rtt_us=49999;
  if(gate==6)s.bbr.min_rtt_us=1000001;
  if(gate==7)s.bbr.min_rtt_us=U32_MAX;
  bbrguard_update_drain(&s,&rs,&ctx); assert(s.bbr.guard_drain_active == (gate==4));
 }
 struct sock s=fresh(0); ack(&s,0,200000); ack(&s,320001,200000);
 assert(!s.bbr.guard_drain_active && s.bbr.guard_drop_rounds==1);
 ack(&s,80000,200000); ack(&s,1,1000001); assert(!s.bbr.guard_drop_rounds);
 ack(&s,80000,200000); assert(!s.bbr.guard_drain_active);

 s=fresh(0); ack(&s,0,200000); ack(&s,80000,200000); ack(&s,80000,200000);
 s.bbr.full_bw_reached=0; ack(&s,80000,200000); assert(s.bbr.guard_drain_active);
 s.bbr.mode=BBR_PROBE_RTT; ack(&s,80000,200000);
 assert(s.bbr.guard_drain_active); s.tp.cwnd=9999; s.sk_pacing_rate=99999999;
 bbrguard_apply_drain(&s); assert(s.tp.cwnd==9999 && s.sk_pacing_rate==99999999);
 s.bbr.mode=BBR_PROBE_BW; ack(&s,80000,200000); bbrguard_apply_drain(&s);
 assert(s.bbr.guard_drain_active && s.sk_pacing_rate==175000);
 s.bbr.max_bw=200000; ack(&s,80000,200000); assert(!s.bbr.guard_drain_active);
 s=fresh(0); s.bbr.mode=BBR_PROBE_RTT;
 ack(&s,0,200000); ack(&s,80000,200000); ack(&s,80000,200000);
 assert(!s.bbr.guard_drain_active && !s.bbr.guard_drop_rounds);

 {
  s=fresh(0);
  struct rate_sample rs={.interval_us=80000,.rtt_us=200000,.acked_sacked=10,.is_app_limited=true};
  struct bbrguard_context ctx={.sample_bw=200000};
  for(unsigned i=0;i<5;i++) { s.tp.tcp_mstamp+=80000; bbrguard_update_drain(&s,&rs,&ctx); }
  assert(!s.bbr.guard_drain_active && !s.bbr.guard_drop_rounds);
 }
 s=fresh(0); s.bbr.guard_drain_active=1; s.bbr.guard_drain_bw=1;
 s.tp.cwnd=2; s.sk_pacing_rate=0; bbrguard_apply_drain(&s);
 assert(s.tp.cwnd==2 && s.sk_pacing_rate==0); /* Never raise an existing bound. */
 s=fresh(0); s.bbr.guard_drain_active=1; s.bbr.guard_drain_bw=U32_MAX;
 s.bbr.min_rtt_us=U32_MAX-1; bbrguard_apply_drain(&s); assert(s.tp.cwnd==10000);
 puts("PRODUCT_DRAIN_CLOCK_GATES_PROBE_AND_BOUNDS_PASS");


}
'''

class GuardDrainTests(unittest.TestCase):
    def test_clock_wrap_safety_gates_probe_ownership_and_bounds(self):
        with tempfile.TemporaryDirectory(prefix='guard-drain-policy-') as temporary:
            directory = Path(temporary)
            source = directory / 'check.c'
            source.write_text(STUB + recovery.DRAIN_POLICY + CASES)
            executable = directory / 'check'
            subprocess.run(['gcc', '-O2', '-std=c11', '-Wall', '-Wextra', '-Werror',
                            '-fsanitize=undefined', '-fno-sanitize-recover=all',
                            str(source), '-o', str(executable)], check=True, capture_output=True)
            result = subprocess.run([str(executable)], check=True, capture_output=True, text=True)
            self.assertIn('PRODUCT_DRAIN_CLOCK_GATES_PROBE_AND_BOUNDS_PASS', result.stdout)
