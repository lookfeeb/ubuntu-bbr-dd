/* HISTORY differential regression, with frozen R3 oracle. */

static struct sock init(u32 hi,u32 gate) {
 struct sock s;memset(&s,0,sizeof(s));tcp_jiffies32=100*HZ;
 s.bbr.guard_large_sample=1;s.bbr.mode=2;s.bbr.full_bw_reached=1;s.bbr.min_rtt_us=100000;
 s.bbr.min_rtt_stamp=tcp_jiffies32;s.bbr.loss_gate.sample_stamp=tcp_jiffies32;
 s.bbr.guard_good_rounds=gate;s.bbr.inflight_hi=hi;s.tp.srtt_us=800000;
 return s;
}
int main(void) {
 unsigned cases=0,differences=0;u32 bounds[]={4,16,31,32,63,64,128,UINT32_MAX};
 for(u32 history=0;history<2;history++)for(u32 gi=0;gi<2;gi++)for(u32 hi=0;hi<8;hi++)for(u32 why=0;why<20;why++)
 for(u32 tx=0;tx<=160;tx++)for(u32 lost=0;lost<=32;lost++) {
  struct sock a=init(bounds[hi],gi?3:0);a.bbr.guard_large_sample=history;struct rate_sample rs={.rtt_us=100000,.tx_in_flight=tx,.lost=lost};
  switch(why) {
   case 1:a.bbr.mode=0;break;
   case 2:a.bbr.mode=3;break;
   case 3:a.bbr.full_bw_reached=0;break;
   case 4:a.icsk.icsk_ca_state=3;break;
   case 5:a.icsk.icsk_ca_state=4;break;
   case 6:a.tp.ecn=true;break;
   case 7:a.bbr.guard_bad_rtt=1;break;
   case 8:rs.is_app_limited=true;break;
   case 9:rs.is_ack_delayed=true;break;
   case 10:a.bbr.cycle_idx=1;break;
   case 11:a.bbr.cycle_idx=2;break;
   case 12:a.bbr.cycle_idx=3;break;
   case 13:a.bbr.loss_gate.sample_stamp=tcp_jiffies32-HZ-1;break;
   case 14:a.bbr.loss_gate.sample_stamp=tcp_jiffies32-HZ;break;
   case 15:a.bbr.min_rtt_us=49999;break;
   case 16:a.bbr.min_rtt_us=UINT32_MAX;break;
   case 17:a.bbr.min_rtt_stamp=tcp_jiffies32-5*HZ;break; /* legacy threshold may be 2% */
   case 18:tcp_jiffies32=4;a.bbr.loss_gate.sample_stamp=UINT32_MAX-10;break;
   case 19:tcp_jiffies32=4;a.bbr.loss_gate.sample_stamp=UINT32_MAX-HZ;break;
  }
  bool domain=history&&lost==1&&tx>=5&&tx<32&&bounds[hi]<64&&
      (why==0||why==4||why==14||why==17||why==18);
  assert(bbrguard_tiny_single_loss(&a,&rs)==domain);
  struct sock b=a;bool ahigh=false,bhigh=false;
  bool old=original_loss(&b,&rs,&bhigh),now=bbrguard_cc_is_inflight_too_high(&a,&rs,&ahigh);
  assert(!memcmp(&a,&b,sizeof(a)));
  if(domain&&old) {assert(!now&&!ahigh&&bhigh);differences++;}
  else assert(now==old&&ahigh==bhigh);
  cases++;
 }
 struct sock s=init(28,0);struct rate_sample rs={.tx_in_flight=13,.lost=1};bool high;
 assert(original_loss(&s,&rs,&high)&&high);
 assert(!bbrguard_cc_is_inflight_too_high(&s,&rs,&high)&&!high);
 s=init(28,0);rs.tx_in_flight=4;assert(bbrguard_cc_is_inflight_too_high(&s,&rs,&high)&&high);
 s=init(28,0);rs.tx_in_flight=13;rs.lost=2;assert(bbrguard_cc_is_inflight_too_high(&s,&rs,&high)&&high);
 s=init(64,0);rs.lost=1;assert(bbrguard_cc_is_inflight_too_high(&s,&rs,&high)&&high);
 printf("HISTORY_LOSS_PASS HZ=%d cases=%u declared_differences=%u\n",HZ,cases,differences);
}
