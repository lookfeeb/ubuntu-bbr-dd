/* HISTORY differential regression, with frozen R3 oracle. */

static struct sock init(u32 cw,u32 gate) {
 struct sock s;memset(&s,0,sizeof(s));tcp_jiffies32=100*HZ;
 s.b.guard_large_sample=1;s.b.mode=2;s.b.full_bw_reached=1;s.b.min_rtt_us=100000;
 s.b.loss_gate.sample_stamp=tcp_jiffies32;s.b.guard_good_rounds=gate;
 s.b.inflight_hi=cw;s.b.bw_probe_up_cnt=cw;s.b.try_fast_path=1;
 s.tp.snd_cwnd=cw;s.tp.is_cwnd_limited=true;
 s.b.cycle_mstamp=10000000;s.tp.tcp_mstamp=11000000;s.b.probe_wait_us=2000000;
 s.b.prev_probe_too_high=1;return s;
}
int main(void) {
 unsigned cases=0,differences=0;
 for(u32 history=0;history<2;history++)for(u32 gate=0;gate<=3;gate+=3)for(u32 why=0;why<20;why++)
 for(u32 cw=4;cw<=512;cw++)for(u32 ack=0;ack<=64;ack+=4) {
  struct sock a=init(cw,gate);a.b.guard_large_sample=history;struct rate_sample rs={.rtt_us=100000,.acked_sacked=ack};
  switch(why) {
   case 1:a.b.mode=3;break;
   case 2:a.b.full_bw_reached=0;break;
   case 3:a.icsk.icsk_ca_state=3;break;
   case 4:a.icsk.icsk_ca_state=4;break;
   case 5:a.tp.ecn=true;break;
   case 6:a.b.loss_gate.sample_stamp=tcp_jiffies32-HZ-1;break;
   case 7:rs.is_app_limited=true;break;
   case 8:rs.is_ack_delayed=true;break;
   case 9:rs.rtt_us=102001;break;
   case 10:rs.lost=1;break;
   case 11:rs.losses=1;break;
   case 12:a.tp.is_cwnd_limited=false;break;
   case 13:a.tp.snd_cwnd=cw-1;break;
   case 14:rs.rtt_us=-1;break;
   case 15:a.b.min_rtt_us=49999;break;
   case 16:a.b.guard_bad_rtt=1;break;
   case 17:a.b.loss_gate.sample_stamp=tcp_jiffies32-HZ;break;
   case 18:a.b.min_rtt_us=UINT32_MAX;break;
   case 19:rs.rtt_us=99999;break;
  }
  bool permitted=history&&cw<64 && ack && (why==0||why==3||why==13||why==17);
  assert(bbrguard_early_probe(&a,&rs)==permitted);
  struct sock b=a,c=a;
  bool before_stop=old_stop(&a,&rs,cw),after_stop=new_stop(&a,&rs,cw);
  assert(after_stop==(before_stop&&!permitted));
  bool oldtime=original_time(&b,&rs),newtime=bbrguard_cc_check_time_to_probe_bw(&c,&rs);
  assert(newtime==(oldtime||permitted));
  assert(c.refills==(newtime?1U:0U)&&b.refills==(oldtime?1U:0U));
  b=a;original_probe(&b,&rs);bbrguard_cc_probe_inflight_hi_upward(&a,&rs);
  if(permitted && why!=13) {
   assert(a.b.inflight_hi==cw+min(ack,64-cw));assert(a.b.inflight_hi<=64);
   assert(!a.b.bw_probe_up_acks && !a.b.try_fast_path);
   c=a;c.b.inflight_hi=b.b.inflight_hi;c.b.bw_probe_up_acks=b.b.bw_probe_up_acks;
   c.b.try_fast_path=b.b.try_fast_path;assert(!memcmp(&c,&b,sizeof(c)));
   differences++;
  } else assert(!memcmp(&a,&b,sizeof(a)));
  cases++;
 }
 for(u32 cw=4;cw<=512;cw+=4)for(u32 round=0;round<=30;round++) {
  struct sock s=init(cw,3);s.b.round_start=1;s.b.bw_probe_up_rounds=round;
  struct rate_sample rs={.rtt_us=100000,.acked_sacked=4};
  bbrguard_cc_probe_inflight_hi_upward(&s,&rs);
  assert(s.b.bw_probe_up_cnt==max(cw/(1U<<round),1U));
  assert(s.b.bw_probe_up_rounds==min(round+1,30U));cases++;
 }
 struct sock s=init(63,0);struct rate_sample rs={.rtt_us=100000,.acked_sacked=UINT32_MAX};
 bbrguard_cc_probe_inflight_hi_upward(&s,&rs);assert(s.b.inflight_hi==64);
 s=init(4,0);tcp_jiffies32=4;s.b.loss_gate.sample_stamp=UINT32_MAX-10;rs.acked_sacked=1;
 assert(bbrguard_early_probe(&s,&rs));
 s=init(4,0);s.tp.tcp_mstamp=s.b.cycle_mstamp+500000;
 assert(!bbrguard_cc_check_time_to_probe_bw(&s,&rs));
 s.tp.tcp_mstamp++;assert(bbrguard_cc_check_time_to_probe_bw(&s,&rs));
 s=init(4,0);s.tp.tcp_mstamp=s.b.cycle_mstamp-1;
 assert(!bbrguard_cc_check_time_to_probe_bw(&s,&rs));
 s=init(4,0);s.b.min_rtt_us=200000;rs.rtt_us=200000;
 s.tp.tcp_mstamp=s.b.cycle_mstamp+800000;assert(!bbrguard_cc_check_time_to_probe_bw(&s,&rs));
 s.tp.tcp_mstamp++;assert(bbrguard_cc_check_time_to_probe_bw(&s,&rs));
 printf("HISTORY_GROWTH_PASS HZ=%d cases=%u bounded_growth_cases=%u\n",HZ,cases,differences);
}
