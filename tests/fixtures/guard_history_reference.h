/* Frozen R3 functions: extracted individually, not compiled together. */
static void original_probe(struct sock *sk,
					  const struct rate_sample *rs)
{
	struct tcp_sock *tp = tcp_sk(sk);
	struct bbrguard *bbr = inet_csk_ca(sk);
	u32 delta;

	if (!tp->is_cwnd_limited || tcp_snd_cwnd(tp) < bbr->inflight_hi)
		return;  /* not fully using inflight_hi, so don't grow it */

	/* For each bw_probe_up_cnt packets ACKed, increase inflight_hi by 1. */
	bbr->bw_probe_up_acks += rs->acked_sacked;
	if (bbr->bw_probe_up_acks >=  bbr->bw_probe_up_cnt) {
		delta = bbr->bw_probe_up_acks / bbr->bw_probe_up_cnt;
		bbr->bw_probe_up_acks -= delta * bbr->bw_probe_up_cnt;
		bbr->inflight_hi += delta;
		bbr->try_fast_path = 0;  /* Need to update cwnd */
	}

	if (bbr->round_start)
		bbrguard_cc_raise_inflight_hi_slope(sk);
}
static bool original_time(struct sock *sk,
					const struct rate_sample *rs)
{
    (void)rs;
	struct bbrguard *bbr = inet_csk_ca(sk);

	if ((bbrguard_recovery_allowed(sk) &&
	     bbrguard_cc_has_elapsed_in_phase(sk, max(500000U, min(bbr->min_rtt_us, 1000000U) * 4))) ||
	    bbrguard_cc_has_elapsed_in_phase(sk, bbr->probe_wait_us) ||
	    bbrguard_cc_is_reno_coexistence_probe_time(sk)) {
		bbrguard_cc_start_bw_probe_refill(sk, 0);
		return true;
	}
	return false;
}
static bool original_loss(struct sock *sk,
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
	    (!bbrguard_recovery_allowed(sk) && rs->tx_in_flight >= 32 &&
	     (u64)rs->lost * 100 >= (u64)rs->tx_in_flight * 8)) {
		struct bbrguard *bbr = inet_csk_ca(sk);
		bbr->guard_good_rounds = 0;
	} else if (bbrguard_recovery_allowed(sk)) {
		/* Qualified aggregate evidence governs undersized samples.
		 * A severe sample above has already cleared eligibility. */
		return false;
	}

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
static void original_gate(struct sock *sk, const struct rate_sample *rs)
{
    struct bbrguard *bbr = inet_csk_ca(sk);
    const struct tcp_sock *tp = tcp_sk(sk);
    struct bbrguard_gate *gate = &bbr->loss_gate;
    bool valid = rs->rtt_us >= 0 && !rs->is_ack_delayed;
    bool bad_rtt = false;
    bool allowed = bbr->mode == BBR_PROBE_BW && bbr->full_bw_reached &&
        inet_csk(sk)->icsk_ca_state != TCP_CA_Loss && !tcp_ecn_mode_any(tp) &&
        !rs->is_app_limited;

    if (valid) {
        bad_rtt = !bbrguard_queue_ok(bbr->min_rtt_us, rs->rtt_us, 32, 2000);
        /* Keep loss evidence separate from current queue permission.
         * Bad RTT disables recovery immediately; only a trustworthy
         * good sample can clear it. Delayed/missing RTT changes neither. */
        if (!bad_rtt)
            gate->sample_stamp = tcp_jiffies32;
        bbr->guard_bad_rtt = bad_rtt;
    }
    if (!allowed || tcp_jiffies32 - gate->sample_stamp > HZ ||
        bbr->min_rtt_us < 50000U || bbr->min_rtt_us == ~0U) {
        bbr->guard_good_rounds = 0;
        gate->delivered_stamp = tp->delivered;
        gate->lost_stamp = tp->lost;
        /* Discard loss evidence on expired samples or excluded states. */
        return;
    }
    if (!bbr->round_start)
        return;
    bbr->guard_good_rounds = bbrguard_finish_round(gate, tp->delivered, tp->lost,
        bbr->guard_good_rounds,
        tcp_jiffies32 - gate->sample_stamp <= HZ);
}
static void bbrguard_cc_update_cycle_phase(struct sock *sk,
				    const struct rate_sample *rs,
				    struct bbrguard_context *ctx)
{
	struct tcp_sock *tp = tcp_sk(sk);
	struct bbrguard *bbr = inet_csk_ca(sk);
	bool is_bw_probe_done = false;
	u32 inflight, bw;

	if (!bbrguard_cc_full_bw_reached(sk))
		return;

	/* In DRAIN, PROBE_BW, or PROBE_RTT, adjust upper bounds. */
	if (bbrguard_cc_adapt_upper_bounds(sk, rs, ctx))
		return;		/* already decided state transition */

	if (bbr->mode != BBR_PROBE_BW)
		return;

	inflight = bbrguard_cc_packets_in_net_at_edt(sk, rs->prior_in_flight);
	bw = bbrguard_cc_max_bw(sk);

	switch (bbr->cycle_idx) {
	/* First we spend most of our time cruising with a pacing_gain of 1.0,
	 * which paces at the estimated bw, to try to fully use the pipe
	 * without building queue. If we encounter loss, then we adapt
	 * by slowing down.
	 */
	case BBR_BW_PROBE_CRUISE:
		if (bbrguard_cc_check_time_to_probe_bw(sk, rs))
			return;		/* already decided state transition */
		break;

	/* After cruising, when it's time to probe, we first "refill": we send
	 * at the estimated bw to fill the pipe, before probing higher and
	 * knowingly risking overflowing the bottleneck buffer (causing loss).
	 */
	case BBR_BW_PROBE_REFILL:
		if (bbr->round_start) {
			/* After one full round trip of sending in REFILL, we
			 * start to see bw samples reflecting our REFILL, which
			 * may be putting too much data in flight.
			 */
			bbr->bw_probe_samples = 1;
			bbrguard_cc_start_bw_probe_up(sk, ctx);
		}
		break;

	/* After we refill the pipe, we probe by using a pacing_gain > 1.0, to
	 * probe for bw. If we have not seen high loss, we try to raise inflight
	 * to at least pacing_gain*BDP; note that this may take more than
	 * min_rtt if min_rtt is small (e.g. on a LAN).
	 *
	 * We terminate PROBE_UP bandwidth probing upon any of the following:
	 *
	 * (1) We've pushed inflight up to hit the inflight_hi target set in the
	 *     most recent previous bw probe phase. Thus we want to start
	 *     draining the queue immediately because it's very likely the most
	 *     recently sent packets will fill the queue and cause drops.
	 * (2) If inflight_hi has not limited bandwidth growth recently, and
	 *     yet delivered bandwidth has not increased much recently
	 *     (bbr->full_bw_now).
	 * (3) Loss filter says loss rate is "too high".
	 *
	 * (1) (2) checked here, (3) (4) checked in bbrguard_cc_is_inflight_too_high()
	 */
	case BBR_BW_PROBE_UP:
		if (bbr->prev_probe_too_high && !bbrguard_recovery_allowed(sk) &&
		    inflight >= bbr->inflight_hi) {
			bbr->stopped_risky_probe = 1;
			is_bw_probe_done = true;
		} else {
			if (tp->is_cwnd_limited &&
			    tcp_snd_cwnd(tp) >= bbr->inflight_hi) {
				/* inflight_hi is limiting bw growth */
				bbrguard_cc_reset_full_bw(sk);
				bbr->full_bw = ctx->sample_bw;
			} else if (bbr->full_bw_now) {
				/* Plateau in estimated bw. Pipe looks full. */
				is_bw_probe_done = true;
			}
		}
		if (is_bw_probe_done) {
			bbr->prev_probe_too_high = 0;  /* no high loss (yet) */
			bbrguard_cc_start_bw_probe_down(sk);  /* restart w/ down */
		}
		break;

	/* After probing in PROBE_UP, we have usually accumulated some data in
	 * the bottleneck buffer (if bw probing didn't find more bw). We next
	 * enter PROBE_DOWN to try to drain any excess data from the queue. To
	 * do this, we use a pacing_gain < 1.0. We hold this pacing gain until
	 * our inflight is less then that target cruising point, which is the
	 * minimum of (a) the amount needed to leave headroom, and (b) the
	 * estimated BDP. Once inflight falls to match the target, we estimate
	 * the queue is drained; persisting would underutilize the pipe.
	 */
	case BBR_BW_PROBE_DOWN:
		if (bbrguard_cc_check_time_to_probe_bw(sk, rs))
			return;		/* already decided state transition */
		if (bbrguard_cc_check_time_to_cruise(sk, inflight, bw))
			bbrguard_cc_start_bw_probe_cruise(sk);
		break;

	default:
		WARN_ONCE(1, "BBR invalid cycle index %u\n", bbr->cycle_idx);
	}
}
