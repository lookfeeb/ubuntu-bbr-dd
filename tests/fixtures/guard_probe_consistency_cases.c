int main(void) {
 unsigned cases=0,continued=0;tcp_jiffies32=100*HZ;
 for(unsigned hi=1;hi<80;hi++)for(unsigned tx=0;tx<40;tx++)for(unsigned reason=0;reason<20;reason++) {
  struct sock s={0};struct rate_sample r={.rtt_us=100000,.lost=1,.acked_sacked=1,.tx_in_flight=tx};
  s.bbr.mode=BBR_PROBE_BW;s.bbr.full_bw_reached=1;s.bbr.guard_large_sample=1;
  s.bbr.inflight_hi=hi;s.bbr.prev_probe_too_high=1;s.bbr.min_rtt_us=100000;
  s.bbr.loss_gate.sample_stamp=tcp_jiffies32;s.tp.is_cwnd_limited=true;
  switch(reason) {
   case 1:r.losses=2;break;case 2:r.lost=2;break;case 3:r.acked_sacked=0;break;
   case 4:r.rtt_us=-1;break;case 5:r.rtt_us=102001;break;case 6:r.rtt_us=99999;break;
   case 7:r.is_app_limited=true;break;case 8:r.is_ack_delayed=true;break;
   case 9:s.tp.is_cwnd_limited=false;break;case 10:s.tp.ecn=true;break;
   case 11:s.icsk.icsk_ca_state=TCP_CA_Loss;break;case 12:s.bbr.guard_large_sample=0;break;
   case 13:s.bbr.guard_bad_rtt=1;break;case 14:s.bbr.loss_gate.sample_stamp-=HZ+1;break;
   case 15:s.bbr.full_bw_reached=0;break;case 16:s.bbr.mode=3;break;
   case 17:s.bbr.cycle_idx=1;break;case 18:r.losses=1;break;case 19:r.losses=-1;break;
  }
  struct sock before=s;
  bool stop=stop_probe(&s,&r,hi);
  bool allowed=(reason==0||reason==18)&&hi<64&&tx>=5&&tx<32;
  assert(stop==!allowed);
  assert(!memcmp(&before,&s,sizeof(s)));
  if(allowed)continued++;
  /* Existing heuristic still requires both a previous high probe and
   * reaching the old limit; neither path is newly made more restrictive. */
  assert(!stop_probe(&s,&r,hi-1));
  s.bbr.prev_probe_too_high=0;assert(!stop_probe(&s,&r,hi));
  cases++;
 }
 printf("PROBE_CONSISTENCY_PASS HZ=%u cases=%u continuations=%u\n",HZ,cases,continued);
}
