/* Frozen Guard6 R5 oracle. Source SHA-256:
 * d2dc9c3054dbeb97eb88ceffade2cda5a7976d8c41a67288af98acbd4719fee7
 * Keep independent of the current generator. */
static bool r5_reference_recovery_allowed(const struct sock *sk)
{
    const struct bbrguard *bbr = inet_csk_ca(sk);
    const struct tcp_sock *tp = tcp_sk(sk);
    const struct bbrguard_gate *gate = &bbr->loss_gate;

    return bbr->guard_good_rounds == 3 && !bbr->guard_bad_rtt &&
        bbr->mode == BBR_PROBE_BW &&
        bbr->full_bw_reached && inet_csk(sk)->icsk_ca_state != TCP_CA_Loss &&
        !tcp_ecn_mode_any(tp) &&
        tcp_jiffies32 - gate->sample_stamp <= HZ &&
        bbr->min_rtt_us >= 50000U && bbr->min_rtt_us != ~0U;
}

static bool r5_reference_loss(struct sock *sk,
				      const struct rate_sample *rs,
				      bool *is_loss_too_high)
{
	u32 loss_thresh;

	*is_loss_too_high = 0;
	/* No loss evidence: avoid all recovery eligibility checks. */
	if (rs->lost <= 0 || !rs->tx_in_flight)
		return false;
	/* Qualified short samples overlap; revoke on a full observation,
	 * or an immediate catastrophic short signal. Unqualified behavior is
	 * unchanged, and queue/ECN/RTO permission is still checked below.
	 */
	if ((rs->tx_in_flight >= 128 &&
	     (u64)rs->lost * 100 >= (u64)rs->tx_in_flight * 8) ||
	    (rs->tx_in_flight >= 32 &&
	     (u64)rs->lost * 100 >= (u64)rs->tx_in_flight * 25) ||
	    (!r5_reference_recovery_allowed(sk) && rs->tx_in_flight >= 32 &&
	     (u64)rs->lost * 100 >= (u64)rs->tx_in_flight * 8)) {
		struct bbrguard *bbr = inet_csk_ca(sk);
		bbr->guard_good_rounds = 0;
	} else if (r5_reference_recovery_allowed(sk)) {
		/* Qualified aggregate evidence governs undersized samples.
		 * A severe sample above has already cleared eligibility. */
		return false;
	}

	if (bbrguard_tiny_single_loss(sk, rs))
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

