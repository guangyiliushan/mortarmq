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
/// The membership, assignment and ownership epochs carried here are the
/// mechanical counters the NOTICE fields need; the four-epoch model,
/// `installed_assignment_epoch` naming and fencing land with T035.

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
/// The result of admitting one member: its identity, the current epoch
/// versions, and the NOTICE payloads to send in order.
pub(all) struct JoinResult {
  member_id : UInt64
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
priv struct GroupMember {
  member_id : UInt64
  connection_id : UInt64
  topics : Array[UInt16]
} derive(Debug)

///|
/// Store one partition ownership record.
priv struct OwnedPartition {
  topic_id : UInt16
  partition : UInt16
  member_id : UInt64
  ownership_epoch : UInt64
} derive(Debug)

///|
/// Own the membership and partition assignment of one consumer group.
///
/// Reachable only through `join`, `leave`, and `owner_of`; the ownership
/// map is rebuilt from the recomputation diff, so a partition record only
/// ever changes through an assignment pass.
pub struct GroupCoordinator {
  priv group_id : UInt16
  priv members : Array[GroupMember]
  priv mut ownership : Array[OwnedPartition]
  priv topic_partitions : Map[UInt16, UInt16]
  priv mut membership_epoch : UInt
  priv mut assignment_epoch : UInt
  priv mut next_member_id : UInt64
  priv mut next_notice_id : UInt64
} derive(Debug)

///|
pub extend GroupCoordinator with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Create an empty coordinator for one group.
///
/// The first join allocates member id 1 and the first notice carries
/// notice id 1; counters are per coordinator, so two coordinators never
/// share members or notice ids.
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
    membership_epoch: 0U,
    assignment_epoch: 0U,
    next_member_id: 1UL,
    next_notice_id: 1UL,
  }
}

///|
/// Identify one partition ownership record.
fn owner_key(topic_id : UInt16, partition : Int) -> Int {
  topic_id.to_int() * 65536 + partition
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
/// Append one NOTICE payload carrying the current epoch versions.
fn GroupCoordinator::push_notice(
  self : GroupCoordinator,
  notices : Array[@protocol.NoticePayload],
  kind : Byte,
  ownership_epoch : UInt64,
  topic_id : UInt16,
  partition : UInt16,
  member_id : UInt64,
) -> Unit {
  notices.push({
    notice_id: self.next_notice_id,
    kind,
    group_id: self.group_id,
    membership_epoch: self.membership_epoch,
    assignment_epoch: self.assignment_epoch,
    ownership_epoch,
    topic_id,
    partition,
    member_id,
  })
  self.next_notice_id = self.next_notice_id + 1UL
}

///|
/// Install a target assignment and return the NOTICE payloads it produced.
///
/// Records whose owner does not change keep their ownership epoch; a moved
/// partition increments its epoch and emits REVOKE (old epoch) before
/// ASSIGN (new epoch); a partition leaving the universe revokes its live
/// owner and drops. Stragglers (records the new universe no longer covers)
/// are processed first, then the universe in (topic_id, partition) order.
fn GroupCoordinator::apply_target(
  self : GroupCoordinator,
  target : Map[Int, UInt64],
) -> Array[@protocol.NoticePayload] {
  let notices : Array[@protocol.NoticePayload] = []
  let next : Array[OwnedPartition] = []
  for rec in self.ownership {
    if target.get(owner_key(rec.topic_id, rec.partition.to_int())) is None {
      if self.is_live(rec.member_id) {
        self.push_notice(
          notices,
          NOTICE_KIND_REVOKE,
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
                    old.ownership_epoch,
                    t,
                    p.to_uint16(),
                    old.member_id,
                  )
                }
                self.push_notice(
                  notices,
                  NOTICE_KIND_ASSIGN,
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
/// Admit one connection as a group member and assign its partitions.
///
/// The first join of a connection creates a member and allocates its
/// `member_id`; a later join of the same connection adds a topic to that
/// member. Re-joining a topic already subscribed is idempotent: the
/// current epochs come back with no notices and nothing changes. A
/// membership or subscription change recomputes the assignment and bumps
/// both epoch counters once.
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
///   assert_eq(
///     @broker.GroupCoordinator::join(coordinator, 100UL, 1, 2),
///     Ok({
///       member_id: 1UL,
///       membership_epoch: 1U,
///       assignment_epoch: 1U,
///       notices: [
///         {
///           notice_id: 1UL,
///           kind: @broker.NOTICE_KIND_ASSIGN,
///           group_id: 1,
///           membership_epoch: 1U,
///           assignment_epoch: 1U,
///           ownership_epoch: 1UL,
///           topic_id: 1,
///           partition: 0,
///           member_id: 1UL,
///         },
///         {
///           notice_id: 2UL,
///           kind: @broker.NOTICE_KIND_ASSIGN,
///           group_id: 1,
///           membership_epoch: 1U,
///           assignment_epoch: 1U,
///           ownership_epoch: 1UL,
///           topic_id: 1,
///           partition: 1,
///           member_id: 1UL,
///         },
///       ],
///     }),
///   )
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
        membership_epoch: self.membership_epoch,
        assignment_epoch: self.assignment_epoch,
        notices: [],
      })
    }
  }
  let mut topic_known = self.topic_partitions.get(topic_id) is Some(_)
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
    topic_known = true
  }
  if is_new {
    let member_id = self.next_member_id
    self.next_member_id = self.next_member_id + 1UL
    self.members.push({ member_id, connection_id, topics: [topic_id], })
    member_index = self.members.length() - 1
  } else {
    self.members[member_index].topics.push(topic_id)
  }
  self.membership_epoch = self.membership_epoch + 1U
  self.assignment_epoch = self.assignment_epoch + 1U
  let target = self.compute_target()
  let notices = self.apply_target(target)
  Ok({
    member_id: self.members[member_index].member_id,
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
/// and no REVOKE notice is sent to the member that left. The membership
/// and assignment epochs both advance once.
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
  ignore(self.members.remove(member_index))
  self.membership_epoch = self.membership_epoch + 1U
  self.assignment_epoch = self.assignment_epoch + 1U
  let target = self.compute_target()
  let notices = self.apply_target(target)
  Ok({
    membership_epoch: self.membership_epoch,
    assignment_epoch: self.assignment_epoch,
    notices,
  })
}
