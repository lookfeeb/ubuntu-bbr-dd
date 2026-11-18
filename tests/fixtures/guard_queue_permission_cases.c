/* Loss classification survives brief queue evidence; permission does not. */
#include <assert.h>
#include <stdio.h>
static struct sock qualified(void)
{
    struct sock sk={0};
    sk.bbr.mode=BBR_PROBE_BW;
    sk.bbr.full_bw_reached=1;
    sk.bbr.min_rtt_us=100000;
    sk.bbr.guard_good_rounds=3;
    sk.bbr.loss_gate.sample_stamp=tcp_jiffies32;
    return sk;
}
int main(void)
{
    struct sock sk;
    struct rate_sample rs={.rtt_us=102001};
    tcp_jiffies32=10000;
    sk=qualified();
    bbrguard_update_gate(&sk,&rs);
    assert(sk.bbr.guard_good_rounds==3 && !bbrguard_recovery_allowed(&sk));
    for (unsigned int i=0;i<3;i++) {
        sk.bbr.round_start=1;
        rs.rtt_us=i==0 ? -1 : 100000;
        rs.is_ack_delayed=i>0;
        bbrguard_update_gate(&sk,&rs);
        assert(!bbrguard_recovery_allowed(&sk));
    }
    rs.is_ack_delayed=false;
    rs.rtt_us=100100;
    bbrguard_update_gate(&sk,&rs);
    assert(bbrguard_recovery_allowed(&sk));

    /* Continued high queue expires the retained loss classification. */
    rs.rtt_us=102001;
    bbrguard_update_gate(&sk,&rs);
    tcp_jiffies32+=HZ+1;
    bbrguard_update_gate(&sk,&rs);
    assert(!sk.bbr.guard_good_rounds && !bbrguard_recovery_allowed(&sk));
    rs.rtt_us=100100;
    bbrguard_update_gate(&sk,&rs);
    assert(!bbrguard_recovery_allowed(&sk));

    /* Loss accumulation keeps running while queue permission is disabled. */
    sk=qualified();sk.bbr.round_start=1;rs.rtt_us=102001;
    sk.tp.delivered=122;sk.tp.lost=6;
    bbrguard_update_gate(&sk,&rs);
    assert(sk.bbr.guard_good_rounds==3 && !bbrguard_recovery_allowed(&sk));
    rs.rtt_us=100100;
    bbrguard_update_gate(&sk,&rs);
    assert(bbrguard_recovery_allowed(&sk)); /* fresh good RTT, retained 6/128 */
    sk=qualified();sk.bbr.round_start=1;rs.rtt_us=102001;
    sk.tp.delivered=29;sk.tp.lost=3;
    bbrguard_update_gate(&sk,&rs);
    assert(sk.bbr.guard_good_rounds==3 && !bbrguard_recovery_allowed(&sk));
    sk.tp.delivered+=88;sk.tp.lost+=8;
    bbrguard_update_gate(&sk,&rs);
    assert(!sk.bbr.guard_good_rounds); /* 11/128 exits even while queue is bad */

    for (unsigned int cause=0;cause<5;cause++) {
        sk=qualified();rs=(struct rate_sample){.rtt_us=100100};
        if(cause==0)sk.tp.ecn=true;
        if(cause==1)sk.icsk.icsk_ca_state=TCP_CA_Loss;
        if(cause==2)rs.is_app_limited=true;
        if(cause==3)sk.bbr.mode=0;
        if(cause==4)sk.bbr.min_rtt_us=49999;
        bbrguard_update_gate(&sk,&rs);
        assert(!sk.bbr.guard_good_rounds && !bbrguard_recovery_allowed(&sk));
    }
    tcp_jiffies32=~0U-HZ/2;
    sk=qualified();rs=(struct rate_sample){.rtt_us=102001};
    bbrguard_update_gate(&sk,&rs);
    tcp_jiffies32+=HZ;
    rs.rtt_us=-1;
    bbrguard_update_gate(&sk,&rs);
    assert(!bbrguard_recovery_allowed(&sk));
    tcp_jiffies32++;
    bbrguard_update_gate(&sk,&rs);
    assert(!sk.bbr.guard_good_rounds);
    /* Interleaved queue observations must not erase loss sample ownership.
     * Four 32-packet windows contain four losses; bad RTT denies permission
     * until the next trustworthy good sample, without recounting packets. */
    sk=qualified();sk.bbr.guard_good_rounds=0;
    const unsigned int losses[]={2,0,1,1};
    for(unsigned int i=0;i<4;i++) {
        sk.bbr.round_start=1;
        sk.tp.delivered+=32-losses[i];sk.tp.lost+=losses[i];
        rs.rtt_us=102001;
        bbrguard_update_gate(&sk,&rs);
        assert(!bbrguard_recovery_allowed(&sk));
        sk.bbr.round_start=0;rs.rtt_us=100100;
        bbrguard_update_gate(&sk,&rs);
        assert(bbrguard_recovery_allowed(&sk)==(i==3));
    }
    sk=qualified();rs=(struct rate_sample){.rtt_us=100100,.lost=3,.tx_in_flight=32};
    bool high=false;
    assert(!bbrguard_cc_is_inflight_too_high(&sk,&rs,&high) && !high);
    assert(sk.bbr.guard_good_rounds==3);
    sk.bbr.guard_bad_rtt=1;
    assert(bbrguard_cc_is_inflight_too_high(&sk,&rs,&high) && high);
    assert(!sk.bbr.guard_good_rounds); /* no live permission: original short exit */
    puts("split permission/evidence boundaries passed");
}
