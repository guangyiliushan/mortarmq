/// The lease that decides when a follower stops following, and the
/// static preference that decides who tries next.
///
/// Raft's own observation applies here: safety never depends on timing,
/// only liveness does. A clock running fast can make a follower give up
/// on a leader that is perfectly healthy, which costs an election and
/// nothing else; it cannot make two leaders agree on the same term,
/// because the term is fenced by the promise recorded in the epoch log,
/// not by the lease. The lease is therefore allowed to be wrong about
/// *when* to fail over and never about *whether* one has happened.
///
/// # The tick is the caller's
///
/// The deadline is a difference between two readings of a monotonic
/// counter, never of wall clock. Wall time can step backwards, and a
/// lease whose remaining time grows when the clock rewinds would hand a
/// stale leader a lease it already lost. This module takes the tick as
/// an argument and never reads a clock itself, so the discipline lives
/// with whoever supplies the number -- and a test can supply any number
/// it likes.

///|
/// How often a healthy leader refreshes its followers' leases.
///
/// From the replication lease-timing table (`leader_heartbeat_ms`,
/// default 500, range 100..2000).
pub const LEADER_HEARTBEAT_MS : UInt64 = 500

///|
/// How long a follower keeps believing its leader after the last
/// refresh.
///
/// From the same table (`follower_lease_ms`, default 2000, range
/// 1000..10000). It has to be comfortably above
/// `LEADER_HEARTBEAT_MS`: a follower that expired on one lost heartbeat
/// would start an election every time the network hiccuped.
pub const FOLLOWER_LEASE_MS : UInt64 = 2000

///|
/// How long a candidate waits for the promises and installations it
/// needs before giving up on one round.
///
/// From the same table (`prepare_timeout_ms`, default 1000, range
/// 100..5000).
///
/// Milliseconds, as `Int`, because it is the deadline handed to the
/// same timeout every peer read is wrapped in. A member that goes quiet
/// inside it costs one round and is answered with `ElectionTimeout`:
/// the round can be run again, so the connection stays open and
/// nothing is written to it afterwards.
pub const PREPARE_TIMEOUT_MS : Int = 1000

///|
/// One follower's belief that its leader is still alive.
///
/// The deadline moves forward on every refresh and is read against a
/// caller-supplied tick; the struct never asks what time it is.
pub struct Lease {
  mut deadline_ms : UInt64
  lease_ms : UInt64
}

///|
/// Open a lease at `now_ms + lease_ms`.
///
/// # Example
///
/// ```mbt check
/// test {
///   let lease = @cluster.Lease::new(1000UL, 2000UL)
///   assert_eq(lease.expired(2999UL), false)
///   assert_eq(lease.expired(3000UL), true)
/// }
/// ```
pub fn Lease::new(now_ms : UInt64, lease_ms : UInt64) -> Lease {
  { deadline_ms: now_ms + lease_ms, lease_ms, }
}

///|
/// Push the deadline forward from `now_ms`, not from the old deadline.
///
/// Refreshing from the old deadline would let a follower that missed a
/// heartbeat catch up on one that arrived late and never notice the
/// gap; anchoring on arrival time measures what the lease is actually
/// for -- how long since a heartbeat was last seen.
pub fn Lease::refresh(self : Lease, now_ms : UInt64) -> Unit {
  self.deadline_ms = now_ms + self.lease_ms
}

///|
/// Whether the lease has run out at `now_ms`.
///
/// Expiry is inclusive: at the deadline the lease is gone, so a follower
/// does not hold on through the exact instant it was promised until.
///
/// # Example
///
/// ```mbt check
/// test {
///   let lease = @cluster.Lease::new(0UL, @cluster.FOLLOWER_LEASE_MS)
///   assert_eq(lease.expired(@cluster.FOLLOWER_LEASE_MS), true)
///   assert_eq(lease.expired(@cluster.FOLLOWER_LEASE_MS - 1UL), false)
/// }
/// ```
pub fn Lease::expired(self : Lease, now_ms : UInt64) -> Bool {
  now_ms >= self.deadline_ms
}

///|
/// How much of the lease is left at `now_ms`, floored at zero.
///
/// Zero means expired, and there is no negative remaining time: a
/// lease either has time on it or it does not, and a caller deciding
/// whether to warn about a leader needs that to be a one-sided number.
pub fn Lease::remaining_ms(self : Lease, now_ms : UInt64) -> UInt64 {
  if now_ms >= self.deadline_ms {
    return 0UL
  }
  self.deadline_ms - now_ms
}

///|
/// The member this node would stand for next, once `leader` can no
/// longer be followed.
///
/// Static preference rather than a contest: the order was fixed before
/// anything failed, so two followers that lose the same leader at the
/// same moment name the same candidate without first having to agree on
/// anything. The preference says who *tries*, not who *is* -- whoever
/// tries still has to collect the promises and the installations, and a
/// candidate that cannot is simply not the leader.
///
/// Returns `None` when nobody is left to try: with the failed leader
/// excluded, a cluster that has run out of members has no election to
/// hold.
///
/// # Example
///
/// ```mbt check
/// test {
///   let secret = match @cluster.PeerSecret::new(b"0123456789abcdef") {
///     Ok(secret) => secret
///     Err(_) => fail("sixteen bytes is the floor and must be accepted")
///   }
///   let peers : Array[@cluster.PeerEntry] = [
///     { node_id: 1U.to_uint16(), host: "127.0.0.1", port: 7191, },
///     { node_id: 2U.to_uint16(), host: "127.0.0.1", port: 7192, },
///     { node_id: 3U.to_uint16(), host: "127.0.0.1", port: 7193, },
///   ]
///   let config = match
///     @cluster.ClusterConfig::new(
///       1U.to_uint16(),
///       peers,
///       [1U, 2U, 3U].map(id => id.to_uint16()),
///       "127.0.0.1",
///       7191,
///       secret,
///     ) {
///     Ok(config) => config
///     Err(_) => fail("the fixture must be a valid static table")
///   }
///   // The first choice is gone, so the preference falls to the second.
///   assert_eq(config.candidate_after(1U.to_uint16()), Some(2U.to_uint16()))
///   assert_eq(config.candidate_after(2U.to_uint16()), Some(1U.to_uint16()))
///   // The failed leader is never a candidate, however it ranks.
///   let absent = match config.candidate_after(3U.to_uint16()) {
///     None => fail("two members remain after the third fails")
///     Some(node_id) => node_id
///   }
///   assert_eq(absent == 3U.to_uint16(), false)
/// }
/// ```
pub fn ClusterConfig::candidate_after(
  self : ClusterConfig,
  leader : UInt16,
) -> UInt16? {
  for node_id in self.leader_priority() {
    if node_id != leader {
      return Some(node_id)
    }
  }
  None
}
