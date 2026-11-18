/* Guard6 reference before hp1; source SHA-256:
 * abb9e0060beb709f32ad1553aef84275bc52f41b0a63e53833f83c63a966b3f0
 * Frozen oracle for state-transition equivalence, not production code.
 */
static void reference_bbrguard_update_gate(struct sock *sk, const struct rate_sample *rs)
{
    struct bbrguard *bbr = inet_csk_ca(sk);
    const struct tcp_sock *tp = tcp_sk(sk);
    struct bbrguard_gate *gate = &bbr->loss_gate;
    bool valid = rs->rtt_us >= 0 && !rs->is_ack_delayed;
    bool allowed = bbr->mode == BBR_PROBE_BW && bbr->full_bw_reached &&
        inet_csk(sk)->icsk_ca_state != TCP_CA_Loss && !tcp_ecn_mode_any(tp) &&
        !rs->is_app_limited;

    if (valid) {
        gate->sample_stamp = tcp_jiffies32;
        if (!bbrguard_queue_ok(bbr->min_rtt_us, rs->rtt_us, 32, 2000))
            bbr->guard_bad_rtt = 1;
    }
    if (!allowed || tcp_jiffies32 - gate->sample_stamp > HZ ||
        !bbrguard_queue_ok(bbr->min_rtt_us, tp->srtt_us >> 3, 16, 5000)) {
        bbr->guard_good_rounds = 0;
        gate->delivered_stamp = tp->delivered;
        gate->lost_stamp = tp->lost;
    }
    if (!bbr->round_start)
        return;
    bbr->guard_good_rounds = bbrguard_finish_round(gate, tp->delivered, tp->lost,
        bbr->guard_good_rounds,
        allowed && !bbr->guard_bad_rtt && tcp_jiffies32 - gate->sample_stamp <= HZ &&
        bbrguard_queue_ok(bbr->min_rtt_us, tp->srtt_us >> 3, 16, 5000));
    bbr->guard_bad_rtt = valid && !bbrguard_queue_ok(bbr->min_rtt_us, rs->rtt_us, 32, 2000);
}

static bool reference_bbrguard_cc_is_inflight_too_high(struct sock *sk,
				      const struct rate_sample *rs,
				      bool *is_loss_too_high)
{
	u32 loss_thresh;

	*is_loss_too_high = 0;
	if (rs->lost > 0 && rs->tx_in_flight >= 32 &&
	    (u64)rs->lost * 100 >= (u64)rs->tx_in_flight * 8) {
		struct bbrguard *bbr = inet_csk_ca(sk);
		bbr->guard_good_rounds = 0;
	}
	/* Qualified aggregate evidence governs undersized samples.
	 * Keep >=8% cuts when the instantaneous sample has >=32 packets. */
	if (bbrguard_recovery_allowed(sk) && rs->tx_in_flight && rs->lost > 0 &&
	    (rs->tx_in_flight < 32 || (u64)rs->lost * 100 < (u64)rs->tx_in_flight * 8))
		return false;

	if (rs->lost > 0 && rs->tx_in_flight) {
		loss_thresh = (u64)rs->tx_in_flight * bbrguard_loss_limit(sk) >>
				BBR_SCALE;
		if (rs->lost > loss_thresh) {
			*is_loss_too_high = true;
			return true;
		}
	}

	return false;
}
