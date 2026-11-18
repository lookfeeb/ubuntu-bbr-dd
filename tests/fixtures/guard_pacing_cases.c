int main(void){
 unsigned cases=0;
 for(unsigned hi=1;hi<130;hi++)for(unsigned why=0;why<17;why++)for(unsigned phase=0;phase<4;phase++){
  struct sock a={0};struct rate_sample r={.rtt_us=100000,.acked_sacked=2};
  a.b.initialized=1;a.b.mode=2;a.b.cycle_idx=phase;a.b.guard_large_sample=1;a.b.inflight_hi=hi;
  a.b.full_bw_reached=1;a.b.min_rtt_us=100000;a.b.loss_gate.sample_stamp=tcp_jiffies32;
  a.tp.is_cwnd_limited=1;a.tp.snd_cwnd=hi;a.b.pacing_gain=phase==0?320:256;
  a.sk_max_pacing_rate=1000000000;
  bool eligible=hi<64&&phase==0;
  switch(why){
   case 1:a.b.guard_large_sample=0;eligible=0;break;
   case 2:a.b.guard_bad_rtt=1;eligible=0;break;
   case 3:a.icsk.icsk_ca_state=4;eligible=0;break;
   case 4:a.tp.ecn=1;eligible=0;break;
   case 5:r.is_app_limited=1;eligible=0;break;
   case 6:r.is_ack_delayed=1;eligible=0;break;
   case 7:r.acked_sacked=0;eligible=0;break;
   case 8:r.losses=1;eligible=0;break;
   case 9:r.lost=1;eligible=0;break;
   case 10:r.rtt_us=102001;eligible=0;break;
   case 11:a.b.loss_gate.sample_stamp=tcp_jiffies32-HZ-1;eligible=0;break;
   case 12:a.tp.is_cwnd_limited=0;break; /* pacing must not disable itself */
   case 13:a.b.full_bw_reached=0;eligible=0;break;
   case 14:r.rtt_us=0;eligible=0;break;
   case 15:r.rtt_us=-1;eligible=0;break;
   case 16:a.sk_max_pacing_rate=10000;break;
  }
  /* A preceding override must never survive loss of any safety condition,
   * even when the underlying fast path would otherwise skip controls. */
  a.b.guard_pacing_boost=1;a.sk_pacing_rate=9999999;
  bbrguard_cc_main(&a,0,0,&r);
  assert(a.calls==1);
  assert((a.b.guard_pacing_boost!=0)==eligible);
  assert(a.tp.snd_cwnd==hi&&a.b.inflight_hi==hi);
  assert(a.sk_pacing_rate<=a.sk_max_pacing_rate);
  if(eligible) assert(a.sk_pacing_rate<=(u64)hi*1500*10);
  else assert(a.sk_pacing_rate==bbrguard_cc_bw_to_pacing_rate(&a,10,a.b.pacing_gain));
  a.change_mode=1;a.b.guard_pacing_boost=1;
  bbrguard_cc_main(&a,0,0,&r);
  assert(a.b.mode==3&&!a.b.guard_pacing_boost);
  assert(a.sk_pacing_rate==bbrguard_cc_bw_to_pacing_rate(&a,10,256));
  cases++;
 }

 {
  struct sock a={0};struct rate_sample r={.rtt_us=200000,.interval_us=80000,.acked_sacked=2};
  a.b.initialized=1;a.b.mode=BBR_PROBE_BW;a.b.full_bw_reached=1;a.b.min_rtt_us=80000;
  a.b.inflight_hi=300;a.b.guard_large_sample=1;a.b.try_fast_path=1;
  a.tp.srtt_us=200000*8;a.tp.snd_cwnd=200;a.model_bw=30000;a.sample_bw=3000;
  a.sk_max_pacing_rate=1000000000;
  for(unsigned i=0;i<3;i++) {a.tp.tcp_mstamp+=80000;bbrguard_cc_main(&a,0,0,&r);}
  unsigned fast=a.fast_calls;
  unsigned long cap=bbrguard_cc_bw_to_pacing_rate(&a,3000,BBR_UNIT*7/8);
  assert(a.b.guard_drain_active&&a.sk_pacing_rate<=cap&&a.tp.snd_cwnd<=21);
  assert(!a.b.guard_pacing_boost);
  r.is_app_limited=1;a.tp.tcp_mstamp+=80000;
  bbrguard_cc_main(&a,0,0,&r);
  assert(a.b.guard_drain_active&&a.fast_calls==fast&&a.sk_pacing_rate<=cap);
  a.tp.ecn=1;a.b.try_fast_path=1;
  unsigned calls=a.calls;
  bbrguard_cc_main(&a,0,0,&r);
  assert(!a.b.guard_drain_active&&a.calls==calls+1&&a.sk_pacing_rate>cap);
 }
 printf("WINDOW_PACING_CONTROL_PASS HZ=%u cases=%u\n",HZ,cases);
}
