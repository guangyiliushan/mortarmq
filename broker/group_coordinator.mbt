/// Assign topic partitions to the members of one consumer group.
///
/// The coordinator is the only assignment authority (REQ-CON-001): members
/// join with the topics they subscribe and leave explicitly, and every
/// recomputation is deterministic, so the same join and leave sequence
/// always produces the same assignment (L1 "assignment results are
/// determined"). Assignment changes leave as NOTICE payloads in
/// (topic_id, partition) order with REVOKE before ASSIGN per moved
/// partition: the shape the incremental-rebalance protocol consumes.
///
/// # Stability
///
/// * A recomputation keeps every partition with its current owner while
///   that owner still subscribes the topic (sticky retention), assigns
///   unowned partitions first, and only then moves the minimum necessary
///   from members holding above their per-topic quota -- the largest
///   partition ids move first, so low partitions stay put.
/// * Every choice is ordered: partitions by (topic_id, partition), quota
///   extras and fills by (owned_count, member_id). Same-seed runs replay
///   identically.
/// * Group size is explicit (REQ-CON-006): at most `MAX_GROUP_MEMBERS`
///   members and `MAX_GROUP_ASSIGNMENTS` assigned partitions; a join past
///   either cap is refused with the registered code and changes nothing.
/// * An explicit leave releases the leaver partitions at once (the
///   graceful-release choreography of REQ-CON-003 layers on later); no
///   REVOKE notice is sent to a member that already left.
///
/// # Epochs (the four-epoch model, glossary 2)
///
/// Counters advance only after the state they version is installed
/// (persist-then-increment): the target assignment and its ownership
/// records are written first, then `membership_epoch` and
/// `assignment_epoch` advance, so a reader never sees an epoch ahead of
/// the state it names. Unchanged partitions keep their `ownership_epoch`.
/// `installed_assignment_epoch` lives on the member (R12a naming; the wire
/// field stays `assignment_epoch`). The wholesale generation
/// (`wholesale_ownership_epoch`) advances only when a subscription's
/// ownership set is replaced whole -- never on a partial migration.
///
/// Ownership changes between live members emit the eight-parameter
/// `OwnershipChangedHandler` callback (Q29: flat parameters, no shared
/// record) to the three registered ports in fixed order: fence (ledger
/// FENCED durable first, Q27), release (credit window), then waiter sink
/// (long-poll wake). A leave takes the wholesale path and emits nothing
/// per partition.

///|
/// Cap the live members of one group at 10 (v0 hard limit).
pub const MAX_GROUP_MEMBERS : Int = 10

///|
/// Cap the assigned partitions of one group at 4096.
pub const MAX_GROUP_ASSIGNMENTS : Int = 4096

///|
/// NOTICE kind: the member is assigned the partition.
pub const NOTICE_KIND_ASSIGN : Byte = 0x00

///|
/// NOTICE kind: the member loses the partition.
pub const NOTICE_KIND_REVOKE : Byte = 0x01

///|
/// The result of admitting one member: its identity, its subscription id,
/// the current epoch versions, and the NOTICE payloads to send in order.
pub(all) struct JoinResult {
  member_id : UInt64
  subscription_id : UInt16
  membership_epoch : UInt
  assignment_epoch : UInt
  notices : Array[@protocol.NoticePayload]
} derive(Eq, Debug)

///|
pub extend JoinResult with Eq::{not_equal, equal}

///|
pub extend JoinResult with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// The result of releasing one member: the current epoch versions and the
/// NOTICE payloads to send in order.
pub(all) struct LeaveResult {
  membership_epoch : UInt
  assignment_epoch : UInt
  notices : Array[@protocol.NoticePayload]
} derive(Eq, Debug)

///|
pub extend LeaveResult with Eq::{not_equal, equal}

///|
pub extend LeaveResult with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Store one member as the coordinator knows it.
///
/// `installed_assignment_epoch` is the R12a name of the assignment epoch
/// this member has loaded (glossary 2; the wire field stays
/// `assignment_epoch`).
priv struct GroupMember {
  member_id : UInt64
  connection_id : UInt64
  topics : Array[UInt16]
  installed_assignment_epoch : UInt
}

///|
/// Store one partition ownership record.
priv struct OwnedPartition {
  topic_id : UInt16
  partition : UInt16
  member_id : UInt64
  ownership_epoch : UInt64
}

///|
/// Own the membership and partition assignment of one consumer group.
///
/// Reachable only through `join`, `leave`, `mark_installed` and the
/// read-only queries; the ownership array is rebuilt from the
/// recomputation diff, so a partition record only ever changes through an
/// assignment pass.
pub struct GroupCoordinator {
  priv group_id : UInt16
  priv members : Array[GroupMember]
  priv mut ownership : Array[OwnedPartition]
  priv topic_partitions : Map[UInt16, UInt16]
  priv subscription_ids : Map[Int, UInt16]
  priv wholesale_epochs : Map[Int, UInt64]
  priv mut membership_epoch : UInt
  priv mut assignment_epoch : UInt
  priv mut next_member_id : UInt64
  priv mut next_notice_id : UInt64
  priv mut next_subscription_id : UInt16
  priv mut on_fence : OwnershipChangedHandler
  priv mut on_release : OwnershipChangedHandler
  priv mut on_waiters : OwnershipChangedHandler
}

///|
/// Create an empty coordinator for one group.
///
/// The first join allocates member id 1, subscription id 1 and notice id
/// 1; counters are per coordinator, so two coordinators never share
/// members, subscriptions or notices. The ownership-change ports start
/// unregistered (a no-op handler each).
///
/// Example:
///
/// ```mbt check
/// test {
///   let coordinator = @broker.GroupCoordinator::new(1)
///   assert_eq(@broker.GroupCoordinator::owner_of(coordinator, 1, 0), None)
/// }
/// ```
pub fn GroupCoordinator::new(group_id : UInt16) -> GroupCoordinator {
  {
    group_id,
    members: [],
    ownership: [],
    topic_partitions: Map([]),
    subscription_ids: Map([]),
    wholesale_epochs: Map([]),
    membership_epoch: 0U,
    assignment_epoch: 0U,
    next_member_id: 1UL,
    next_notice_id: 1UL,
    next_subscription_id: 1,
    on_fence: ownership_changed_noop,
    on_release: ownership_changed_noop,
    on_waiters: ownership_changed_noop,
  }
}

///|
/// Identify one partition ownership record.
fn owner_key(topic_id : UInt16, partition : Int) -> Int {
  topic_id.to_int() * 65536 + partition
}

///|
/// Identify one member topic subscription binding.
fn binding_key(member_id : UInt64, topic_id : UInt16) -> Int {
  member_id.to_int() * 65536 + topic_id.to_int()
}

///|
/// Find the ownership record of one partition, if any.
fn find_owned(
  records : Array[OwnedPartition],
  topic_id : UInt16,
  partition : Int,
) -> OwnedPartition? {
  for rec in records {
    if rec.topic_id == topic_id && rec.partition.to_int() == partition {
      return Some(rec)
    }
  }
  None
}

///|
/// Report whether a value is present in a small array.
fn contains_topic(topics : Array[UInt16], topic_id : UInt16) -> Bool {
  for t in topics {
    if t == topic_id {
      return true
    }
  }
  false
}

///|
/// Sort topic identifiers ascending in place (selection sort).
fn sort_topics_asc(topics : Array[UInt16]) -> Unit {
  for i in 0..<topics.length() {
    let mut least = i
    let start = i + 1
    for j in start..<topics.length() {
      if topics[j] < topics[least] {
        least = j
      }
    }
    if least != i {
      let saved = topics[i]
      topics[i] = topics[least]
      topics[least] = saved
    }
  }
}

///|
/// Order member slots by per-topic count desc then slot asc (selection sort,
/// strict compare keeps join order on ties).
fn order_slots_by_count_desc(count : Array[Int], order : Array[Int]) -> Unit {
  for i in 0..<order.length() {
    let mut most = i
    let start = i + 1
    for j in start..<order.length() {
      if count[order[j]] > count[order[most]] {
        most = j
      }
    }
    if most != i {
      let saved = order[i]
      order[i] = order[most]
      order[most] = saved
    }
  }
}

///|
/// Report whether a member id is still a live group member.
fn GroupCoordinator::is_live(
  self : GroupCoordinator,
  member_id : UInt64,
) -> Bool {
  for m in self.members {
    if m.member_id == member_id {
      return true
    }
  }
  false
}

///|
/// Collect the group subscribed topics, ascending and deduplicated.
fn GroupCoordinator::subscribed_topics(
  self : GroupCoordinator,
) -> Array[UInt16] {
  let topics : Array[UInt16] = []
  for m in self.members {
    for t in m.topics {
      if !contains_topic(topics, t) {
        topics.push(t)
      }
    }
  }
  sort_topics_asc(topics)
  topics
}

///|
/// Compute the target assignment for the current membership.
///
/// Per topic, in ascending topic order: sticky retention first (a partition
/// stays while its owner still subscribes), then quotas (base share plus
/// one for the first members of the remainder in (owned_count, member_id)
/// order), then the minimum necessary release from members above quota --
/// the largest partition ids leave first -- and finally every free
/// partition (never owned, lost, or just released) fills the deficits in
/// ascending partition order, each to the member with the lowest
/// (owned_count, member_id). The result is fully determined by the join
/// and leave history.
fn GroupCoordinator::compute_target(
  self : GroupCoordinator,
) -> Map[Int, UInt64] {
  let target : Map[Int, UInt64] = Map([])
  let total : Array[Int] = Array::make(self.members.length(), 0)
  for t in self.subscribed_topics() {
    let partition_count = match self.topic_partitions.get(t) {
      Some(count) => count.to_int()
      None => 0
    }
    let subs : Array[Int] = []
    for i in 0..<self.members.length() {
      if contains_topic(self.members[i].topics, t) {
        subs.push(i)
      }
    }
    if subs.length() == 0 {
      continue
    }
    let held : Array[Array[Int]] = []
    for _ in subs {
      held.push([])
    }
    for p in 0..<partition_count {
      match find_owned(self.ownership, t, p) {
        Some(rec) => {
          let mut slot = -1
          for j in 0..<subs.length() {
            if self.members[subs[j]].member_id == rec.member_id {
              slot = j
              break
            }
          }
          if slot >= 0 {
            target.set(owner_key(t, p), rec.member_id)
            held[slot].push(p)
            total[subs[slot]] = total[subs[slot]] + 1
          }
        }
        None => ()
      }
    }
    let count : Array[Int] = []
    for j in 0..<subs.length() {
      count.push(held[j].length())
    }
    let base = partition_count / subs.length()
    let rem = partition_count % subs.length()
    let quota : Array[Int] = Array::make(subs.length(), base)
    let order : Array[Int] = []
    for j in 0..<subs.length() {
      order.push(j)
    }
    order_slots_by_count_desc(count, order)
    for k in 0..<rem {
      quota[order[k]] = quota[order[k]] + 1
    }
    for j in 0..<subs.length() {
      while count[j] > quota[j] {
        let mut largest = 0
        for k in 1..<held[j].length() {
          if held[j][k] > held[j][largest] {
            largest = k
          }
        }
        let released = held[j][largest]
        ignore(held[j].remove(largest))
        ignore(target.remove(owner_key(t, released)))
        count[j] = count[j] - 1
        total[subs[j]] = total[subs[j]] - 1
      }
    }
    for p in 0..<partition_count {
      if target.get(owner_key(t, p)) is Some(_) {
        continue
      }
      let mut pick = -1
      for j in 0..<subs.length() {
        if count[j] < quota[j] {
          if pick < 0 {
            pick = j
          } else {
            let a = total[subs[j]]
            let b = total[subs[pick]]
            if a < b || (a == b && subs[j] < subs[pick]) {
              pick = j
            }
          }
        }
      }
      if pick < 0 {
        break
      }
      target.set(owner_key(t, p), self.members[subs[pick]].member_id)
      count[pick] = count[pick] + 1
      total[subs[pick]] = total[subs[pick]] + 1
    }
  }
  target
}

///|
/// Append one NOTICE payload carrying the given epoch versions.
fn GroupCoordinator::push_notice(
  self : GroupCoordinator,
  notices : Array[@protocol.NoticePayload],
  kind : Byte,
  membership_epoch : UInt,
  assignment_epoch : UInt,
  ownership_epoch : UInt64,
  topic_id : UInt16,
  partition : UInt16,
  member_id : UInt64,
) -> Unit {
  notices.push({
    notice_id: self.next_notice_id,
    kind,
    group_id: self.group_id,
    membership_epoch,
    assignment_epoch,
    ownership_epoch,
    topic_id,
    partition,
    member_id,
  })
  self.next_notice_id = self.next_notice_id + 1UL
}

///|
/// Fan one live ownership change out to the registered ports.
///
/// The three ports run in fixed order -- fence (ledger FENCED durable),
/// release (credit window), waiter sink (long-poll wake) -- so a crash
/// between them leaves only memory state to rebuild from the ledger
/// (Q27 consumption order). Only moves between live members emit; a leave
/// takes the wholesale path and emits nothing per partition. The fence
/// slot returns only once the FENCED write is durable (its adapter awaits
/// the ledger sync, ruling v1.1 #1): only then do the release and waiter
/// slots run, so a crash between them leaves nothing but memory state to
/// rebuild from the log.
fn GroupCoordinator::emit_ownership_changed(
  self : GroupCoordinator,
  topic_id : UInt16,
  partition : Int,
  subscription_id : UInt16,
  old_owner : UInt64,
  new_owner : UInt64,
  old_epoch : UInt64,
  new_epoch : UInt64,
) -> Unit {
  let group_id = self.group_id
  let part = partition.to_uint16()
  let fence = self.on_fence
  let release = self.on_release
  let waiters = self.on_waiters
  fence(
    group_id, topic_id, part, subscription_id, old_owner, new_owner, old_epoch, new_epoch,
  )
  release(
    group_id, topic_id, part, subscription_id, old_owner, new_owner, old_epoch, new_epoch,
  )
  waiters(
    group_id, topic_id, part, subscription_id, old_owner, new_owner, old_epoch, new_epoch,
  )
}

///|
/// Install a target assignment and return the NOTICE payloads it produced.
///
/// Records whose owner does not change keep their ownership epoch; a moved
/// partition increments its epoch and emits REVOKE (old epoch) before
/// ASSIGN (new epoch) plus one ownership-change callback to the ports; a
/// partition leaving the universe revokes its live owner and drops without
/// a callback (wholesale path). Stragglers (records the new universe no
/// longer covers) are processed first, then the universe in (topic_id,
/// partition) order. The epoch values the notices carry are passed in by
/// the caller, which advances its counters only after this call returns
/// (persist-then-increment).
fn GroupCoordinator::apply_target(
  self : GroupCoordinator,
  target : Map[Int, UInt64],
  membership_epoch : UInt,
  assignment_epoch : UInt,
) -> Array[@protocol.NoticePayload] {
  let notices : Array[@protocol.NoticePayload] = []
  let next : Array[OwnedPartition] = []
  for rec in self.ownership {
    if target.get(owner_key(rec.topic_id, rec.partition.to_int())) is None {
      if self.is_live(rec.member_id) {
        self.push_notice(
          notices,
          NOTICE_KIND_REVOKE,
          membership_epoch,
          assignment_epoch,
          rec.ownership_epoch,
          rec.topic_id,
          rec.partition,
          rec.member_id,
        )
      }
    }
  }
  for t in self.subscribed_topics() {
    let partition_count = match self.topic_partitions.get(t) {
      Some(count) => count.to_int()
      None => 0
    }
    for p in 0..<partition_count {
      match target.get(owner_key(t, p)) {
        None => ()
        Some(new_owner) =>
          match find_owned(self.ownership, t, p) {
            Some(old) =>
              if old.member_id == new_owner {
                next.push(old)
              } else {
                let new_epoch = old.ownership_epoch + 1UL
                if self.is_live(old.member_id) {
                  self.push_notice(
                    notices,
                    NOTICE_KIND_REVOKE,
                    membership_epoch,
                    assignment_epoch,
                    old.ownership_epoch,
                    t,
                    p.to_uint16(),
                    old.member_id,
                  )
                  match
                    self.subscription_ids.get(binding_key(old.member_id, t)) {
                    Some(sub) =>
                      self.emit_ownership_changed(
                        t,
                        p,
                        sub,
                        old.member_id,
                        new_owner,
                        old.ownership_epoch,
                        new_epoch,
                      )
                    None => ()
                  }
                }
                self.push_notice(
                  notices,
                  NOTICE_KIND_ASSIGN,
                  membership_epoch,
                  assignment_epoch,
                  new_epoch,
                  t,
                  p.to_uint16(),
                  new_owner,
                )
                next.push({
                  topic_id: t,
                  partition: p.to_uint16(),
                  member_id: new_owner,
                  ownership_epoch: new_epoch,
                })
              }
            None => {
              self.push_notice(
                notices,
                NOTICE_KIND_ASSIGN,
                membership_epoch,
                assignment_epoch,
                1UL,
                t,
                p.to_uint16(),
                new_owner,
              )
              next.push({
                topic_id: t,
                partition: p.to_uint16(),
                member_id: new_owner,
                ownership_epoch: 1UL,
              })
            }
          }
      }
    }
  }
  self.ownership = next
  notices
}

///|
/// Read the current owner of one partition, if assigned.
///
/// Returns the owning member id; `None` means the partition is unassigned
/// or the topic is unknown to the group.
///
/// Example:
///
/// ```mbt check
/// test {
///   let coordinator = @broker.GroupCoordinator::new(1)
///   ignore(@broker.GroupCoordinator::join(coordinator, 100UL, 1, 2))
///   assert_eq(@broker.GroupCoordinator::owner_of(coordinator, 1, 0), Some(1UL))
/// }
/// ```
pub fn GroupCoordinator::owner_of(
  self : GroupCoordinator,
  topic_id : UInt16,
  partition : UInt16,
) -> UInt64? {
  match find_owned(self.ownership, topic_id, partition.to_int()) {
    Some(rec) => Some(rec.member_id)
    None => None
  }
}

///|
/// Read the current ownership epoch of one partition, if assigned.
pub fn GroupCoordinator::ownership_epoch_of(
  self : GroupCoordinator,
  topic_id : UInt16,
  partition : UInt16,
) -> UInt64? {
  match find_owned(self.ownership, topic_id, partition.to_int()) {
    Some(rec) => Some(rec.ownership_epoch)
    None => None
  }
}

///|
/// Read the subscription id bound to one member topic, if bound.
pub fn GroupCoordinator::subscription_id_of(
  self : GroupCoordinator,
  member_id : UInt64,
  topic_id : UInt16,
) -> UInt16? {
  self.subscription_ids.get(binding_key(member_id, topic_id))
}

///|
/// Read the wholesale ownership generation of one subscription, if any.
///
/// The value `CREDIT.ownership_epoch` carries (Q28): `None` before the
/// first wholesale change, then the bump count. Bindings outlive their
/// member here (tombstones), so a stale credit window stays refutable.
pub fn GroupCoordinator::wholesale_epoch_of(
  self : GroupCoordinator,
  member_id : UInt64,
  topic_id : UInt16,
) -> UInt64? {
  self.wholesale_epochs.get(binding_key(member_id, topic_id))
}

///|
/// Read the installed assignment epoch of one member (R12a name).
pub fn GroupCoordinator::installed_assignment_epoch_of(
  self : GroupCoordinator,
  member_id : UInt64,
) -> UInt? {
  for m in self.members {
    if m.member_id == member_id {
      return Some(m.installed_assignment_epoch)
    }
  }
  None
}

///|
/// Admit one connection as a group member and assign its partitions.
///
/// The first join of a connection creates a member, allocates its
/// `member_id` and binds one subscription id to (member, topic); a later
/// join of the same connection adds a topic (and a new subscription id) to
/// that member. Re-joining a topic already subscribed is idempotent: the
/// current epochs and the existing subscription id come back with no
/// notices and nothing changes. A membership or subscription change
/// recomputes the assignment and advances both epoch counters once, only
/// after the new state is installed.
///
/// Parameters:
///
/// * `connection_id` : The requesting connection; one member per
///   connection. Reconnect-with-member identity is fenced later.
/// * `topic_id` : The topic being subscribed. Its partition count is
///   recorded at first sight and stays (partition counts are immutable).
/// * `partition_count` : The topic partition count the caller resolved.
///
/// # Errors
///
/// * `GroupMemberLimit` -- the group already holds `MAX_GROUP_MEMBERS`
///   members; shrink the group first.
/// * `GroupAssignmentLimit` -- the subscription would push the group past
///   `MAX_GROUP_ASSIGNMENTS` assigned partitions; shrink the subscription
///   set first.
///
/// Example:
///
/// ```mbt check
/// test {
///   let coordinator = @broker.GroupCoordinator::new(1)
///   let joined = @broker.GroupCoordinator::join(coordinator, 100UL, 1, 2)
///   assert_eq(joined is Ok(_), true)
/// }
/// ```
pub fn GroupCoordinator::join(
  self : GroupCoordinator,
  connection_id : UInt64,
  topic_id : UInt16,
  partition_count : UInt16,
) -> Result[JoinResult, @protocol.ErrCode] {
  let mut member_index = -1
  for i in 0..<self.members.length() {
    if self.members[i].connection_id == connection_id {
      member_index = i
      break
    }
  }
  let is_new = member_index < 0
  if is_new && self.members.length() >= MAX_GROUP_MEMBERS {
    return Err(@protocol.GroupMemberLimit)
  }
  if !is_new {
    let found = self.members[member_index]
    if contains_topic(found.topics, topic_id) {
      return Ok({
        member_id: found.member_id,
        subscription_id: self
        .subscription_id_of(found.member_id, topic_id)
        .unwrap(),
        membership_epoch: self.membership_epoch,
        assignment_epoch: self.assignment_epoch,
        notices: [],
      })
    }
  }
  let topic_known = self.topic_partitions.get(topic_id) is Some(_)
  let mut universe = 0
  for t in self.subscribed_topics() {
    match self.topic_partitions.get(t) {
      Some(count) => universe = universe + count.to_int()
      None => ()
    }
  }
  if !topic_known {
    universe = universe + partition_count.to_int()
  }
  if universe > MAX_GROUP_ASSIGNMENTS {
    return Err(@protocol.GroupAssignmentLimit)
  }
  if !topic_known {
    self.topic_partitions.set(topic_id, partition_count)
  }
  if is_new {
    let member_id = self.next_member_id
    self.next_member_id = self.next_member_id + 1UL
    self.members.push({
      member_id,
      connection_id,
      topics: [topic_id],
      installed_assignment_epoch: 0U,
    })
    member_index = self.members.length() - 1
  } else {
    self.members[member_index].topics.push(topic_id)
  }
  let member_id = self.members[member_index].member_id
  let sub_key = binding_key(member_id, topic_id)
  let subscription_id = match self.subscription_ids.get(sub_key) {
    Some(existing) => existing
    None => {
      let fresh = self.next_subscription_id
      self.next_subscription_id = self.next_subscription_id + 1
      self.subscription_ids.set(sub_key, fresh)
      fresh
    }
  }
  let membership_next = self.membership_epoch + 1U
  let assignment_next = self.assignment_epoch + 1U
  let target = self.compute_target()
  let notices = self.apply_target(target, membership_next, assignment_next)
  self.membership_epoch = membership_next
  self.assignment_epoch = assignment_next
  Ok({
    member_id,
    subscription_id,
    membership_epoch: self.membership_epoch,
    assignment_epoch: self.assignment_epoch,
    notices,
  })
}

///|
/// Release one member and reassign its partitions to the rest.
///
/// The leaver is removed at once (the graceful-release choreography of
/// REQ-CON-003 layers on later); only partitions the leaver owned move,
/// and no REVOKE notice is sent to the member that left. The leaver
/// subscriptions take the wholesale path: their wholesale generations
/// advance and no ownership-change callback fires per partition. The
/// membership and assignment epochs advance once, after the new state is
/// installed.
///
/// # Errors
///
/// * `UnknownMember` -- no member holds the id; rejoin with a fresh id.
///
/// Example:
///
/// ```mbt check
/// test {
///   let coordinator = @broker.GroupCoordinator::new(1)
///   ignore(@broker.GroupCoordinator::join(coordinator, 100UL, 1, 2))
///   assert_eq(@broker.GroupCoordinator::leave(coordinator, 1UL) is Ok(_), true)
///   assert_eq(@broker.GroupCoordinator::leave(coordinator, 1UL) is Err(_), true)
/// }
/// ```
pub fn GroupCoordinator::leave(
  self : GroupCoordinator,
  member_id : UInt64,
) -> Result[LeaveResult, @protocol.ErrCode] {
  let mut member_index = -1
  for i in 0..<self.members.length() {
    if self.members[i].member_id == member_id {
      member_index = i
      break
    }
  }
  if member_index < 0 {
    return Err(@protocol.UnknownMember)
  }
  let leaver_topics = self.members[member_index].topics
  ignore(self.members.remove(member_index))
  for t in leaver_topics {
    self.bump_wholesale(member_id, t)
  }
  let membership_next = self.membership_epoch + 1U
  let assignment_next = self.assignment_epoch + 1U
  let target = self.compute_target()
  let notices = self.apply_target(target, membership_next, assignment_next)
  self.membership_epoch = membership_next
  self.assignment_epoch = assignment_next
  Ok({
    membership_epoch: self.membership_epoch,
    assignment_epoch: self.assignment_epoch,
    notices,
  })
}

///|
/// Record that a member installed one assignment epoch (R12a name).
///
/// The coordinator is the only writer of `installed_assignment_epoch`.
/// Installing an epoch the coordinator has not produced yet, or replaying
/// an epoch older than the one already installed, is refused with
/// `StaleGeneration`.
///
/// # Errors
///
/// * `UnknownMember` -- no member holds the id.
/// * `StaleGeneration` -- the epoch is in the future or a replay.
pub fn GroupCoordinator::mark_installed(
  self : GroupCoordinator,
  member_id : UInt64,
  assignment_epoch : UInt,
) -> Result[Unit, @protocol.ErrCode] {
  for i in 0..<self.members.length() {
    if self.members[i].member_id == member_id {
      let current = self.members[i]
      if assignment_epoch > self.assignment_epoch ||
        assignment_epoch < current.installed_assignment_epoch {
        return Err(@protocol.StaleGeneration)
      }
      self.members[i] = {
        member_id: current.member_id,
        connection_id: current.connection_id,
        topics: current.topics,
        installed_assignment_epoch: assignment_epoch,
      }
      return Ok(())
    }
  }
  Err(@protocol.UnknownMember)
}

///|
/// Advance the wholesale ownership generation of one subscription.
///
/// The wholesale path (Q28): call on revoke-all, loss or rejoin of a
/// (member, topic) subscription. A partial partition migration must never
/// call this -- it emits ownership-change callbacks instead. Bindings
/// outlive their member (tombstones), so a stale `CREDIT.ownership_epoch`
/// stays refutable after the member is gone.
pub fn GroupCoordinator::bump_wholesale(
  self : GroupCoordinator,
  member_id : UInt64,
  topic_id : UInt16,
) -> Unit {
  let key = binding_key(member_id, topic_id)
  match self.wholesale_epochs.get(key) {
    Some(epoch) => self.wholesale_epochs.set(key, epoch + 1UL)
    None => self.wholesale_epochs.set(key, 1UL)
  }
}

///|
/// Register the ledger fence port (the first consumer of a live move).
///
/// The handler is called before the credit release port and the waiter
/// sink, so the FENCED write is durable before any memory effect (Q27).
pub fn GroupCoordinator::on_fence_port(
  self : GroupCoordinator,
  handler : OwnershipChangedHandler,
) -> Unit {
  self.on_fence = handler
}

///|
/// Register the credit release port (the second consumer of a live move).
pub fn GroupCoordinator::on_release_port(
  self : GroupCoordinator,
  handler : OwnershipChangedHandler,
) -> Unit {
  self.on_release = handler
}

///|
/// Register the long-poll waiter sink (the last consumer of a live move).
pub fn GroupCoordinator::on_waiter_sink(
  self : GroupCoordinator,
  handler : OwnershipChangedHandler,
) -> Unit {
  self.on_waiters = handler
}
