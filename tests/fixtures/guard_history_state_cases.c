/* HISTORY differential regression, with frozen R3 oracle. */

static struct sock init(void) {
 struct sock s;memset(&s,0,sizeof(s));tcp_jiffies32=100*HZ;
 s.bbr.mode=2;s.bbr.full_bw_reached=1;s.bbr.min_rtt_us=100000;
 s.bbr.min_rtt_stamp=tcp_jiffies32;s.bbr.loss_gate.sample_stamp=tcp_jiffies32;
 s.bbr.round_start=1;s.tp.delivered=124;s.tp.lost=4;
 return s;
}
int main(void) {
 unsigned cases=0;int counts[]={-1,0,1,127,128,129,2048,INT_MAX};
 long times[]={-1,0,1,100000,200000,200001,LONG_MAX};
 for(unsigned history=0;history<2;history++)for(unsigned di=0;di<8;di++)
 for(unsigned ti=0;ti<7;ti++)for(unsigned why=0;why<16;why++) {
  struct sock a=init();a.bbr.guard_large_sample=history;
  struct rate_sample rs={.rtt_us=100000,.interval_us=times[ti],.delivered=counts[di]};
  switch(why) {
   case 1:a.bbr.mode=0;break;
   case 2:a.bbr.mode=3;break;
   case 3:a.bbr.full_bw_reached=0;break;
   case 4:a.icsk.icsk_ca_state=4;break;
   case 5:a.tp.ecn=true;break;
   case 6:rs.is_app_limited=true;break;
   case 7:rs.is_ack_delayed=true;break;
   case 8:rs.rtt_us=-1;break;
   case 9:rs.rtt_us=102001;break;
   case 10:a.bbr.min_rtt_us=49999;break;
   case 11:a.bbr.min_rtt_us=UINT32_MAX;break;
   case 12:rs.rtt_us=99999;break;
   case 13:a.bbr.round_start=0;break;
   case 14:a.icsk.icsk_ca_state=3;break;
   case 15:a.bbr.guard_bad_rtt=1;break; /* current trustworthy RTT clears it */
  }
  bool observed=(why==0||why==13||why==14||why==15)&&di>=4&&ti>=2&&ti<=4;
  struct sock b=a;original_gate(&b,&rs);bbrguard_update_gate(&a,&rs);
  assert(a.bbr.guard_large_sample==(history||observed));
  a.bbr.guard_large_sample=b.bbr.guard_large_sample;
  assert(!memcmp(&a,&b,sizeof(a)));cases++;
 }
 printf("HISTORY_STATE_PASS HZ=%d cases=%u\n",HZ,cases);
}
