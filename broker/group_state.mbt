/// The durable face of one consumer group: what a `GroupUpdate` record in
/// the metadata log carries, so a coordinator reloads after failover
/// without the clients rebuilding their subscriptions.
///
/// The metadata log is the truth source (its envelope carries the record
/// type and a CRC over the bytes). Each `GroupUpdate` payload is the
/// COMPLETE group state -- members with their installed assignment
/// epochs, the ownership records, the subscription bindings, the wholesale
/// generations, the epoch counters and the id allocators -- so the newest
/// payload that decodes is the state to restore. A payload that does not
/// decode is simply not the state: the caller walks back to the previous
/// record, and the log decides.
///
/// # Stability
///
/// * Reload is continuity, not a new generation: the restored
///   `membership_epoch` and `assignment_epoch` are exactly what the log
///   recorded (a failover never re-increments them), the ownership epochs
///   carry over unchanged, and the id allocators resume so no member id,
///   subscription id or notice id is ever reused.
/// * A member whose request predates the failover is fenced exactly as
///   before it: generation checks answer StaleGeneration and a superseded
///   ownership epoch answers StaleOwner.
/// * The ownership-change ports start unregistered after a restore; the
///   wiring layer re-registers them.
/// * The binding and wholesale tables encode in ascending key order, so
///   one state has exactly one encoding.

///|
/// The group-state payload format version.
const GROUP_STATE_FORMAT_VER : Byte = 0x01

///|
/// Encode the complete group state as one `GroupUpdate` payload.
///
/// Layout: `ver:u8 || group_id u16be || membership_epoch u32be ||
/// assignment_epoch u32be || next_member_id u64be || next_notice_id
/// u64be || next_subscription_id u16be || members || ownership ||
/// bindings || wholesale`, each list a `u16be` count followed by its
/// entries (member: id u64be, connection u64be, installed_assignment_epoch
/// u32be, topic_count u16be, topics u16be*; topics list: topic_id u16be,
/// partition_count u16be; ownership: topic u16be, partition u16be, member
/// u64be, epoch u64be; binding: member u64be, topic u16be, subscription
/// u16be; wholesale: member u64be, topic u16be, generation u64be).
///
/// Example:
///
/// ```mbt check
/// test {
///   let coordinator = @broker.GroupCoordinator::new(3)
///   let bytes = @broker.GroupCoordinator::encode_state(coordinator)
///   assert_eq(bytes.length() > 0, true)
/// }
/// ```
pub fn GroupCoordinator::encode_state(self : GroupCoordinator) -> Bytes {
  let buf = Buffer()
  buf.write_byte(GROUP_STATE_FORMAT_VER)
  buf.write_uint16_be(self.group_id)
  buf.write_uint_be(self.membership_epoch)
  buf.write_uint_be(self.assignment_epoch)
  buf.write_uint64_be(self.next_member_id)
  buf.write_uint64_be(self.next_notice_id)
  buf.write_uint16_be(self.next_subscription_id)
  buf.write_uint16_be(self.members.length().to_uint16())
  for m in self.members {
    buf.write_uint64_be(m.member_id)
    buf.write_uint64_be(m.connection_id)
    buf.write_uint_be(m.installed_assignment_epoch)
    buf.write_uint16_be(m.topics.length().to_uint16())
    for t in m.topics {
      buf.write_uint16_be(t)
    }
  }
  buf.write_uint16_be(self.topic_partitions.length().to_uint16())
  let topic_keys = sorted_topic_keys(self.topic_partitions)
  for t in topic_keys {
    buf.write_uint16_be(t)
    buf.write_uint16_be(self.topic_partitions[t])
  }
  buf.write_uint16_be(self.ownership.length().to_uint16())
  for rec in self.ownership {
    buf.write_uint16_be(rec.topic_id)
    buf.write_uint16_be(rec.partition)
    buf.write_uint64_be(rec.member_id)
    buf.write_uint64_be(rec.ownership_epoch)
  }
  let binding_keys = sorted_keys(self.subscription_ids)
  buf.write_uint16_be(binding_keys.length().to_uint16())
  for key in binding_keys {
    buf.write_uint64_be((key / 65536).to_uint64())
    buf.write_uint16_be((key % 65536).to_uint16())
    buf.write_uint16_be(self.subscription_ids[key])
  }
  let wholesale_keys = sorted_keys(self.wholesale_epochs)
  buf.write_uint16_be(wholesale_keys.length().to_uint16())
  for key in wholesale_keys {
    buf.write_uint64_be((key / 65536).to_uint64())
    buf.write_uint16_be((key % 65536).to_uint16())
    buf.write_uint64_be(self.wholesale_epochs[key])
  }
  buf.contents()
}

///|
/// The map keys in ascending order, so one state encodes one way.
fn[V] sorted_keys(map : Map[Int, V]) -> Array[Int] {
  let keys : Array[Int] = []
  for key, _value in map {
    keys.push(key)
  }
  for i in 0..<keys.length() {
    let mut least = i
    let start = i + 1
    for j in start..<keys.length() {
      if keys[j] < keys[least] {
        least = j
      }
    }
    if least != i {
      let saved = keys[i]
      keys[i] = keys[least]
      keys[least] = saved
    }
  }
  keys
}

///|
fn state_read_uint16(data : BytesView, offset : Int) -> UInt16? {
  if offset + 2 > data.length() {
    return None
  }
  Some(((data[offset].to_uint() << 8) | data[offset + 1].to_uint()).to_uint16())
}

///|
fn state_read_uint32(data : BytesView, offset : Int) -> UInt? {
  if offset + 4 > data.length() {
    return None
  }
  let value = (data[offset].to_uint() << 24) +
    (data[offset + 1].to_uint() << 16) +
    (data[offset + 2].to_uint() << 8) +
    data[offset + 3].to_uint()
  Some(value)
}

///|
fn state_read_uint64(data : BytesView, offset : Int) -> UInt64? {
  if offset + 8 > data.length() {
    return None
  }
  let mut value = 0UL
  for i in 0..<8 {
    value = (value << 8) | data[offset + i].to_uint64()
  }
  Some(value)
}

///|
/// The topic table keys in ascending order.
fn sorted_topic_keys(map : Map[UInt16, UInt16]) -> Array[UInt16] {
  let keys : Array[UInt16] = []
  for key, _value in map {
    ignore(_value)
    keys.push(key)
  }
  for i in 0..<keys.length() {
    let mut least = i
    let start = i + 1
    for j in start..<keys.length() {
      if keys[j] < keys[least] {
        least = j
      }
    }
    if least != i {
      let saved = keys[i]
      keys[i] = keys[least]
      keys[least] = saved
    }
  }
  keys
}

///|
/// Rebuild one coordinator from a `GroupUpdate` payload: the log's state,
/// continuity included. `None` means this payload is not a decodable
/// state -- the caller walks back to the previous record.
pub fn GroupCoordinator::restore(payload : BytesView) -> GroupCoordinator? {
  if payload.length() < 23 {
    return None
  }
  if payload[0] != GROUP_STATE_FORMAT_VER {
    return None
  }
  let mut offset = 1
  let group_id = match state_read_uint16(payload, offset) {
    Some(value) => value
    None => return None
  }
  offset = offset + 2
  let membership_epoch = match state_read_uint32(payload, offset) {
    Some(value) => value
    None => return None
  }
  offset = offset + 4
  let assignment_epoch = match state_read_uint32(payload, offset) {
    Some(value) => value
    None => return None
  }
  offset = offset + 4
  let next_member_id = match state_read_uint64(payload, offset) {
    Some(value) => value
    None => return None
  }
  offset = offset + 8
  let next_notice_id = match state_read_uint64(payload, offset) {
    Some(value) => value
    None => return None
  }
  offset = offset + 8
  let next_subscription_id = match state_read_uint16(payload, offset) {
    Some(value) => value
    None => return None
  }
  offset = offset + 2
  let member_count = match state_read_uint16(payload, offset) {
    Some(value) => value.to_int()
    None => return None
  }
  offset = offset + 2
  let members : Array[GroupMember] = []
  for _ in 0..<member_count {
    let member_id = match state_read_uint64(payload, offset) {
      Some(value) => value
      None => return None
    }
    offset = offset + 8
    let connection_id = match state_read_uint64(payload, offset) {
      Some(value) => value
      None => return None
    }
    offset = offset + 8
    let installed = match state_read_uint32(payload, offset) {
      Some(value) => value
      None => return None
    }
    offset = offset + 4
    let topic_count = match state_read_uint16(payload, offset) {
      Some(value) => value.to_int()
      None => return None
    }
    offset = offset + 2
    let topics : Array[UInt16] = []
    for _ in 0..<topic_count {
      let topic_id = match state_read_uint16(payload, offset) {
        Some(value) => value
        None => return None
      }
      offset = offset + 2
      topics.push(topic_id)
    }
    members.push({
      member_id,
      connection_id,
      topics,
      installed_assignment_epoch: installed,
    })
  }
  let topic_count = match state_read_uint16(payload, offset) {
    Some(value) => value.to_int()
    None => return None
  }
  offset = offset + 2
  let topic_partitions : Map[UInt16, UInt16] = Map([])
  for _ in 0..<topic_count {
    let topic_id = match state_read_uint16(payload, offset) {
      Some(value) => value
      None => return None
    }
    offset = offset + 2
    let partition_count = match state_read_uint16(payload, offset) {
      Some(value) => value
      None => return None
    }
    offset = offset + 2
    topic_partitions[topic_id] = partition_count
  }
  let ownership_count = match state_read_uint16(payload, offset) {
    Some(value) => value.to_int()
    None => return None
  }
  offset = offset + 2
  let ownership : Array[OwnedPartition] = []
  for _ in 0..<ownership_count {
    let topic_id = match state_read_uint16(payload, offset) {
      Some(value) => value
      None => return None
    }
    offset = offset + 2
    let partition = match state_read_uint16(payload, offset) {
      Some(value) => value
      None => return None
    }
    offset = offset + 2
    let member_id = match state_read_uint64(payload, offset) {
      Some(value) => value
      None => return None
    }
    offset = offset + 8
    let ownership_epoch = match state_read_uint64(payload, offset) {
      Some(value) => value
      None => return None
    }
    offset = offset + 8
    ownership.push({ topic_id, partition, member_id, ownership_epoch, })
  }
  let binding_count = match state_read_uint16(payload, offset) {
    Some(value) => value.to_int()
    None => return None
  }
  offset = offset + 2
  let subscription_ids : Map[Int, UInt16] = Map([])
  for _ in 0..<binding_count {
    let member_id = match state_read_uint64(payload, offset) {
      Some(value) => value
      None => return None
    }
    offset = offset + 8
    let topic_id = match state_read_uint16(payload, offset) {
      Some(value) => value
      None => return None
    }
    offset = offset + 2
    let subscription_id = match state_read_uint16(payload, offset) {
      Some(value) => value
      None => return None
    }
    offset = offset + 2
    subscription_ids.set(binding_key(member_id, topic_id), subscription_id)
  }
  let wholesale_count = match state_read_uint16(payload, offset) {
    Some(value) => value.to_int()
    None => return None
  }
  offset = offset + 2
  let wholesale_epochs : Map[Int, UInt64] = Map([])
  for _ in 0..<wholesale_count {
    let member_id = match state_read_uint64(payload, offset) {
      Some(value) => value
      None => return None
    }
    offset = offset + 8
    let topic_id = match state_read_uint16(payload, offset) {
      Some(value) => value
      None => return None
    }
    offset = offset + 2
    let generation = match state_read_uint64(payload, offset) {
      Some(value) => value
      None => return None
    }
    offset = offset + 8
    wholesale_epochs.set(binding_key(member_id, topic_id), generation)
  }
  if offset != payload.length() {
    return None
  }
  Some({
    group_id,
    members,
    ownership,
    topic_partitions,
    subscription_ids,
    wholesale_epochs,
    membership_epoch,
    assignment_epoch,
    next_member_id,
    next_notice_id,
    next_subscription_id,
    on_fence: ownership_changed_noop,
    on_release: ownership_changed_noop,
    on_waiters: ownership_changed_noop,
  })
}

///|
/// Restore from the newest decodable record of a durable sequence: the
/// caller read the `GroupUpdate` payloads in log order and a record that
/// does not decode is stepped over (a torn tail loses only itself). The
/// last decodable payload is the state, so the log always decides.
pub fn GroupCoordinator::restore_latest(
  payloads : Array[BytesView],
) -> GroupCoordinator? {
  let mut index = payloads.length()
  while index > 0 {
    index = index - 1
    match GroupCoordinator::restore(payloads[index]) {
      Some(coordinator) => return Some(coordinator)
      None => ()
    }
  }
  None
}
