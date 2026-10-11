/// Hold the per-subscription credit window that bounds un-returned deliveries.
///
/// One `CreditWindow` owns the dual message-and-byte budget of one
/// subscription: what the client may still receive (`granted`) and what
/// has been delivered but not yet returned through `CREDIT`
/// (`outstanding`). Every delivery attempt -- first delivery or the
/// redelivery of an unreturned message -- passes the `admit` gate and
/// consumes budget, so a slow consumer can never make the broker buffer
/// more than the window allows, and a redelivery pays for itself.
///
/// The window is keyed by `subscription_id`; `CreditRegistry` is the map
/// and the lookup surface that refuses an unknown key with
/// `UnknownSubscription` rather than inventing one.
///
/// # Stability
///
/// * `granted + outstanding` never exceeds the configured maximum on
///   either dimension. A `CREDIT` apply clamps the granted budget into
///   the room the maximum leaves above `outstanding`, so even a client
///   that sets or adds wildly cannot push the buffered (`outstanding`)
///   total past the cap -- the structural bound behind the slow-consumer
///   acceptance case.
/// * `outstanding` shrinks only when the client returns credit (a
///   `CREDIT` frame) or when an ownership change releases a fenced
///   partition tranche. An `ACK` never touches this module; ACK drives
///   the delivery ledger, `CREDIT` drives the window.
/// * Stale epochs are refused without any modification: a `CREDIT` carrying an old membership epoch or an old
///   subscription generation leaves every counter and `credit_epoch`
///   untouched.
/// * `credit_epoch` is a monotonic credit-change generation: every
///   successful apply and every release bumps it exactly once, so the `OK(CREDIT)` result the wire echoes back is
///   ordered evidence of which mutation a client is looking at.
/// * Nothing here is persisted. A connection drop or a reconnect discards
///   the window via `CreditRegistry::discard`; `SUB`/`PULL` rebuild it. Frames and sockets live elsewhere; this
///   module is pure state.

///|
/// Select how a `CREDIT` frame moves the granted budget.
///
/// `Set` replaces the granted dimensions (then clamps), `Add` returns the
/// carried amounts on top of the current grant (then clamps). The wire
/// carries the mode as a byte where 0 is `Set` and 1 is `Add`; the frame
/// decoder owns rejecting any other value.
pub(all) enum CreditMode {
  Set
  Add
} derive(Eq, Debug)

///|
pub extend CreditMode with Eq::{not_equal, equal}

///|
pub extend CreditMode with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Refuse a credit operation with the reason the caller must act on.
///
/// The window stays deliberately transport-neutral: these are the
/// mechanism-level reasons from the credit algorithm, and the
/// delivery layer maps them onto the registered wire codes (the wire-code mapping). `MessageExceedsCredit` and `NoCredit` correspond to the
/// 0x4005 / 0x4006 wire codes, `Backpressure` to 0x4001; overflow is not
/// an error here because applies clamp.
pub(all) enum CreditError {
  UnknownSubscription
  StaleGeneration
  MessageExceedsCredit
  NoCredit
  Backpressure
} derive(Eq, Debug)

///|
pub extend CreditError with Eq::{not_equal, equal}

///|
pub extend CreditError with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Report the authoritative window counters, matching the `OK(CREDIT)`
/// result fields so the connection layer can encode them unchanged.
///
/// `granted_*` is the remaining usable budget on the server; `outstanding_*`
/// is delivered-but-not-yet-returned; `credit_epoch` is the monotonic
/// change generation. The pairing is what keeps client and server views
/// from drifting.
pub(all) struct CreditReport {
  granted_count : UInt16
  granted_bytes : UInt
  outstanding_count : UInt16
  outstanding_bytes : UInt
  credit_epoch : UInt64
} derive(Eq, Debug)

///|
pub extend CreditReport with Eq::{not_equal, equal}

///|
pub extend CreditReport with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Book one partition's delivered-but-unreturned messages under the
/// ownership epoch they were delivered at, so a later ownership change
/// can release exactly that tranche once.
priv struct PartitionInFlight {
  msg_count : UInt16
  msg_bytes : UInt
  owner_epoch : UInt64
}

///|
/// The mutable counters of one window, held behind a `Ref` so a
/// `CreditWindow` value can be shared through the registry map the same
/// way `FakeClock` shares its state in the harness.
priv struct WindowCore {
  mut credit_count : UInt16
  mut credit_bytes : UInt
  mut outstanding_count : UInt16
  mut outstanding_bytes : UInt
  mut credit_epoch : UInt64
  in_flight : Map[UInt16, PartitionInFlight]
}

///|
/// Own the dual credit counters of one subscription.
///
/// Build with `CreditWindow::new` from the `SUB` credit fields plus the
/// configured maxima; nothing else can produce a window, so every window
/// starts from a clamped initial grant with zero outstanding and epoch 0.
pub struct CreditWindow {
  priv subscription_id : UInt16
  priv membership_epoch : UInt
  priv ownership_generation : UInt64
  priv max_count : UInt16
  priv max_bytes : UInt
  priv in_flight_cap : UInt16
  priv core : Ref[WindowCore]
}

///|
/// Open a window with the initial grant from `SUB`.
///
/// Parameters mirror the wire: `subscription_id` from the `SUB` result,
/// `membership_epoch` and `ownership_generation` the epochs the
/// subscription runs under (the generation is the subscription
/// full-change generation maintained by the coordinator), and
/// `initial_count` / `initial_bytes` the `SUB` credit fields (defaults
/// 256 messages / 2 MiB). `max_count` / `max_bytes` clamp every
/// later apply; `in_flight_cap` is the connection-level in-flight limit
/// the admission gate enforces. An initial grant above the maximum is
/// clamped at construction, and a zero initial grant is a legal stopped
/// window.
///
/// Example:
///
/// ```mbt check
/// test {
///   let window = @broker.CreditWindow::new(
///     1U.to_uint16(),
///     7U,
///     3UL,
///     1U.to_uint16(),
///     100U,
///     10U.to_uint16(),
///     1000U,
///     10U.to_uint16(),
///   )
///   assert_eq(
///     @broker.CreditWindow::admit(window, 0U.to_uint16(), 5UL, 3UL, 60U),
///     Ok(()),
///   )
///   assert_eq(@broker.CreditWindow::report(window).outstanding_bytes, 60U)
/// }
/// ```
pub fn CreditWindow::new(
  subscription_id : UInt16,
  membership_epoch : UInt,
  ownership_generation : UInt64,
  initial_count : UInt16,
  initial_bytes : UInt,
  max_count : UInt16,
  max_bytes : UInt,
  in_flight_cap : UInt16,
) -> CreditWindow {
  let count = if initial_count > max_count { max_count } else { initial_count }
  let bytes = if initial_bytes > max_bytes { max_bytes } else { initial_bytes }
  {
    subscription_id,
    membership_epoch,
    ownership_generation,
    max_count,
    max_bytes,
    in_flight_cap,
    core: Ref::Ref({
      credit_count: count,
      credit_bytes: bytes,
      outstanding_count: 0U.to_uint16(),
      outstanding_bytes: 0U,
      credit_epoch: 0UL,
      in_flight: Map([]),
    }),
  }
}

///|
/// Read the subscription this window is keyed by.
pub fn CreditWindow::id(self : CreditWindow) -> UInt16 {
  self.subscription_id
}

///|
/// Copy the authoritative counters for an `OK(CREDIT)` result or an
/// invariant check.
pub fn CreditWindow::report(self : CreditWindow) -> CreditReport {
  {
    granted_count: self.core.val.credit_count,
    granted_bytes: self.core.val.credit_bytes,
    outstanding_count: self.core.val.outstanding_count,
    outstanding_bytes: self.core.val.outstanding_bytes,
    credit_epoch: self.core.val.credit_epoch,
  }
}

///|
/// Run the pre-delivery gate once per delivery attempt and consume
/// budget on success.
///
/// `msg_bytes` is `key_len + value_len` of the message; the frame header
/// is never billed. A redelivery of an unreturned
/// message calls `admit` again and consumes again -- the rule that
/// every attempt pays for the buffer it occupies.
///
/// # Errors
///
/// * `StaleGeneration` -- the subscription generation is not the one this
///   window runs under (a full ownership change bumped it); nothing is
///   modified. The caller re-`SUB`s.
/// * `NoCredit` -- the message cannot go out now but could after the
///   client returns credit: the message dimension is exhausted, or the
///   byte budget left cannot cover this message while the window capacity
///   still could. The caller retains the message (no
///   partial delivery ever).
/// * `MessageExceedsCredit` -- the message is larger than the whole
///   window capacity (`granted_bytes + outstanding_bytes`), so no amount
///   of returning can ever fit it; the client must raise `credit_bytes`
///   (the 0x4005 action).
/// * `Backpressure` -- `outstanding_count` reached the connection-level
///   in-flight cap; the caller backs off (the 0x4001 action).
pub fn CreditWindow::admit(
  self : CreditWindow,
  partition : UInt16,
  owner_epoch : UInt64,
  ownership_generation : UInt64,
  msg_bytes : UInt,
) -> Result[Unit, CreditError] {
  if ownership_generation != self.ownership_generation {
    return Err(StaleGeneration)
  }
  if self.core.val.credit_count.to_uint() == 0U {
    return Err(NoCredit)
  }
  let capacity_bytes = self.core.val.credit_bytes +
    self.core.val.outstanding_bytes
  if msg_bytes > capacity_bytes {
    return Err(MessageExceedsCredit)
  }
  if msg_bytes > self.core.val.credit_bytes {
    return Err(NoCredit)
  }
  if self.core.val.outstanding_count.to_uint() >= self.in_flight_cap.to_uint() {
    return Err(Backpressure)
  }
  self.core.val.credit_count = (self.core.val.credit_count.to_uint() - 1U).to_uint16()
  self.core.val.credit_bytes = self.core.val.credit_bytes - msg_bytes
  self.core.val.outstanding_count = (self.core.val.outstanding_count.to_uint() +
  1U).to_uint16()
  self.core.val.outstanding_bytes = self.core.val.outstanding_bytes + msg_bytes
  // Fold the attempt into the partition tranche. A tranche left by an
  // earlier ownership epoch means its release event was missed; fold that
  // tranche back first so the ledger sum stays equal to `outstanding`.
  let prior = match self.core.val.in_flight.get(partition) {
    None => { msg_count: 0U.to_uint16(), msg_bytes: 0U, owner_epoch, }
    Some(entry) =>
      if entry.owner_epoch == owner_epoch {
        entry
      } else {
        self.fold_back(entry)
        { msg_count: 0U.to_uint16(), msg_bytes: 0U, owner_epoch, }
      }
  }
  self.core.val.in_flight[partition] = {
    msg_count: (prior.msg_count.to_uint() + 1U).to_uint16(),
    msg_bytes: prior.msg_bytes + msg_bytes,
    owner_epoch,
  }
  Ok(())
}

///|
/// Apply one `CREDIT` frame: `Set` replaces the granted budget, `Add`
/// returns the carried amounts on top of it, and the returned amounts
/// fold `outstanding` down on `Add` (outstanding
/// shrinks with client credit, never with ACKs).
///
/// The epochs must match the subscription this window runs under;
/// otherwise nothing is modified. Both modes clamp the granted budget
/// into the room the maximum leaves above `outstanding`, which is what
/// keeps `granted + outstanding` inside the cap no matter what a client
/// sends. A successful apply bumps
/// `credit_epoch` exactly once.
///
/// # Errors
///
/// * `StaleGeneration` -- a stale `membership_epoch` or subscription
///   generation; no counter and no `credit_epoch` moves.
pub fn CreditWindow::apply(
  self : CreditWindow,
  mode : CreditMode,
  count : UInt16,
  bytes : UInt,
  membership_epoch : UInt,
  ownership_generation : UInt64,
) -> Result[CreditReport, CreditError] {
  if membership_epoch != self.membership_epoch ||
    ownership_generation != self.ownership_generation {
    return Err(StaleGeneration)
  }
  match mode {
    Add => {
      let returned_count = if count.to_uint() >
        self.core.val.outstanding_count.to_uint() {
        self.core.val.outstanding_count.to_uint()
      } else {
        count.to_uint()
      }
      let returned_bytes = if bytes > self.core.val.outstanding_bytes {
        self.core.val.outstanding_bytes
      } else {
        bytes
      }
      self.core.val.outstanding_count = (self.core.val.outstanding_count.to_uint() -
      returned_count).to_uint16()
      self.core.val.outstanding_bytes = self.core.val.outstanding_bytes -
        returned_bytes
    }
    Set => ()
  }
  let room_count = self.max_count.to_uint() -
    self.core.val.outstanding_count.to_uint()
  let room_bytes = self.max_bytes - self.core.val.outstanding_bytes
  let target_count = match mode {
    Set => count.to_uint()
    Add => self.core.val.credit_count.to_uint() + count.to_uint()
  }
  let target_bytes = match mode {
    Set => bytes
    Add => self.core.val.credit_bytes + bytes
  }
  self.core.val.credit_count = (if target_count < room_count {
    target_count
  } else {
    room_count
  }).to_uint16()
  self.core.val.credit_bytes = if target_bytes < room_bytes {
    target_bytes
  } else {
    room_bytes
  }
  self.core.val.credit_epoch = self.core.val.credit_epoch + 1UL
  Ok(self.report())
}

///|
/// Release the in-flight tranche of one partition after an ownership
/// change, fenced by the epoch the tranche was delivered under.
///
/// The `Revoking` to `Released` transition is the trigger: by the
/// time the release runs the old owner has discarded the payloads, so
/// the freed budget reopens the window without overlapping the old
/// consumer's buffer. `old_epoch` is the replay fence -- a second call
/// with the same epoch, or any call naming an epoch the tranche was not
/// booked under, releases nothing. A successful release bumps
/// `credit_epoch` once. Returns whether anything was released.
pub fn CreditWindow::release_partition(
  self : CreditWindow,
  partition : UInt16,
  old_epoch : UInt64,
) -> Bool {
  match self.core.val.in_flight.get(partition) {
    None => false
    Some(entry) =>
      if entry.owner_epoch != old_epoch {
        false
      } else {
        ignore(self.core.val.in_flight.remove(partition))
        self.fold_back(entry)
        true
      }
  }
}

///|
/// Move one booked tranche of delivered-but-unreturned messages back
/// into the granted budget and out of `outstanding`, bumping
/// `credit_epoch`. The caller has already removed the tranche from the
/// ledger.
fn CreditWindow::fold_back(
  self : CreditWindow,
  entry : PartitionInFlight,
) -> Unit {
  self.core.val.outstanding_count = (self.core.val.outstanding_count.to_uint() -
  entry.msg_count.to_uint()).to_uint16()
  self.core.val.outstanding_bytes = self.core.val.outstanding_bytes -
    entry.msg_bytes
  self.core.val.credit_count = (self.core.val.credit_count.to_uint() +
  entry.msg_count.to_uint()).to_uint16()
  self.core.val.credit_bytes = self.core.val.credit_bytes + entry.msg_bytes
  self.core.val.credit_epoch = self.core.val.credit_epoch + 1UL
}

///|
/// Hold every live credit window of one broker, keyed by
/// `subscription_id`.
///
/// The registry is the only surface that can report
/// `UnknownSubscription`: a lookup that misses refuses rather than
/// creating, so a closed or never-opened subscription can never acquire
/// a window by asking for one.
pub struct CreditRegistry {
  priv windows : Map[UInt16, CreditWindow]
}

///|
/// Create an empty registry.
pub fn CreditRegistry::new() -> CreditRegistry {
  { windows: Map([]), }
}

///|
/// Insert or replace the window of its own subscription.
pub fn CreditRegistry::register(
  self : CreditRegistry,
  window : CreditWindow,
) -> Unit {
  self.windows[window.subscription_id] = window
}

///|
/// Drop the window of one subscription: a connection close, a stale
/// generation teardown, or a reconnect path. Later lookups report
/// `UnknownSubscription`, and nothing resurrects the counters.
pub fn CreditRegistry::discard(
  self : CreditRegistry,
  subscription_id : UInt16,
) -> Unit {
  ignore(self.windows.remove(subscription_id))
}

///|
/// Forward a delivery attempt to the subscription's window gate.
///
/// # Errors
///
/// * `UnknownSubscription` -- no live window for `subscription_id`; every
///   other refusal comes from `CreditWindow::admit`.
pub fn CreditRegistry::admit(
  self : CreditRegistry,
  subscription_id : UInt16,
  partition : UInt16,
  owner_epoch : UInt64,
  ownership_generation : UInt64,
  msg_bytes : UInt,
) -> Result[Unit, CreditError] {
  match self.windows.get(subscription_id) {
    None => Err(UnknownSubscription)
    Some(window) =>
      CreditWindow::admit(
        window, partition, owner_epoch, ownership_generation, msg_bytes,
      )
  }
}

///|
/// Forward a `CREDIT` apply to the subscription's window.
///
/// # Errors
///
/// * `UnknownSubscription` -- no live window for `subscription_id`.
pub fn CreditRegistry::apply(
  self : CreditRegistry,
  subscription_id : UInt16,
  mode : CreditMode,
  count : UInt16,
  bytes : UInt,
  membership_epoch : UInt,
  ownership_generation : UInt64,
) -> Result[CreditReport, CreditError] {
  match self.windows.get(subscription_id) {
    None => Err(UnknownSubscription)
    Some(window) =>
      CreditWindow::apply(
        window, mode, count, bytes, membership_epoch, ownership_generation,
      )
  }
}

///|
/// Copy the counters of one subscription's window.
///
/// # Errors
///
/// * `UnknownSubscription` -- no live window for `subscription_id`.
pub fn CreditRegistry::report(
  self : CreditRegistry,
  subscription_id : UInt16,
) -> Result[CreditReport, CreditError] {
  match self.windows.get(subscription_id) {
    None => Err(UnknownSubscription)
    Some(window) => Ok(CreditWindow::report(window))
  }
}

///|
/// Consume one `ownership_changed` event: release the fenced partition
/// tranche of the named subscription (the ownership-event port, the partial-migration
/// path).
///
/// This is the credit-side port of the ruled one-source-three-consumers
/// event. The coordinator calls it between the ledger's `FENCED` write
/// and the long-poll waiter wake-up; the eight parameters are the ruled
/// flat event shape, deliberately not a shared record. The group identity travels as `group_id : UInt16`, the same name and type as `NOTICE`/`CONTROL_ACK` (the `group` name stays out of the event). Full ownership
/// changes never arrive here -- they bump the subscription generation on
/// the coordinator side and the client re-`SUB`s, so only partial
/// migrations name a partition with an `old_epoch` to fence against. An
/// unknown subscription or an epoch that does not match the booked
/// tranche is a no-op: a replayed event can never release twice.
pub fn CreditRegistry::on_ownership_changed(
  self : CreditRegistry,
  _group_id : UInt16,
  _topic_id : UInt16,
  partition : UInt16,
  subscription_id : UInt16,
  _old_owner : UInt64,
  _new_owner : UInt64,
  old_epoch : UInt64,
  _new_epoch : UInt64,
) -> Unit {
  match self.windows.get(subscription_id) {
    None => ()
    Some(window) =>
      ignore(CreditWindow::release_partition(window, partition, old_epoch))
  }
}
