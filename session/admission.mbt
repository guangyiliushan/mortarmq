/// Bound how many session establishments run at once, so an inbound
/// CONNECT storm is refused before any authentication work starts.
///
/// The connection-admission segment sits in front of authentication and
/// of every per-connection budget: establishing a session is the only
/// step that can queue an authentication pause, so the number of
/// establishments running at once bounds the pauses a storm can ever
/// buy. `admit` takes one establishment slot or refuses the work with
/// the registered rate code; `complete` returns the slot on every
/// finished path, success or failure.
///
/// # Stability
///
/// * The cap is caller-chosen and never moves under a live gate: a
///   refusal is explicit (the client keeps its work and backs off) and
///   nothing is queued inside.
/// * Slots are plain occupancy, not a timer: the gate answers with the
///   rate code whenever the cap is reached, whatever the arrival
///   pattern, so tests and operators see one deterministic rule.
/// * `complete` saturates at zero: a caller bug cannot make the gate
///   hand out phantom slots.

///|
priv struct AdmissionCore {
  mut in_flight : UInt16
}

///|
/// Hold the occupancy of one connection-admission gate.
pub struct ConnAdmission {
  priv max_in_flight : UInt16
  priv core : Ref[AdmissionCore]
}

///|
/// Open a gate that admits at most `max_in_flight` establishments at
/// once.
///
/// A cap of zero refuses every attempt and is a legal explicit stop;
/// the cap is chosen by the caller because no parameter-table default
/// exists for this gate.
///
/// Example:
///
/// ```mbt check
/// test {
///   let admission = @session.ConnAdmission::new(1U.to_uint16())
///   assert_eq(@session.ConnAdmission::admit(admission), Ok(()))
///   assert_eq(
///     @session.ConnAdmission::admit(admission),
///     Err(@session.AdmissionRefused),
///   )
///   @session.ConnAdmission::complete(admission)
///   assert_eq(@session.ConnAdmission::admit(admission), Ok(()))
/// }
/// ```
pub fn ConnAdmission::new(max_in_flight : UInt16) -> ConnAdmission {
  { max_in_flight, core: Ref::Ref({ in_flight: 0U.to_uint16(), }), }
}

///|
/// Take one establishment slot, or refuse the work with the rate code.
///
/// A refusal occupies nothing and starts no work: the caller answers
/// the client with `RateLimited` (0x4003, back off and retry) and the
/// authentication path is never touched.
///
/// Returns the taken slot, or `AdmissionRefused`.
///
/// Example:
///
/// ```mbt check
/// test {
///   let admission = @session.ConnAdmission::new(1U.to_uint16())
///   assert_eq(@session.ConnAdmission::admit(admission), Ok(()))
///   assert_eq(
///     @session.ConnAdmission::admit(admission),
///     Err(@session.AdmissionRefused),
///   )
/// }
/// ```
pub fn ConnAdmission::admit(self : ConnAdmission) -> Result[Unit, SessionFail] {
  if self.core.val.in_flight >= self.max_in_flight {
    return Err(AdmissionRefused)
  }
  self.core.val.in_flight = (self.core.val.in_flight.to_uint() + 1U).to_uint16()
  Ok(())
}

///|
/// Return one establishment slot to the gate.
///
/// Call it on every finished path of an admitted establishment. A call
/// that would drive the count below zero saturates at zero instead, so
/// a caller bug cannot corrupt the gate.
///
/// Example:
///
/// ```mbt check
/// test {
///   let admission = @session.ConnAdmission::new(1U.to_uint16())
///   let _ = @session.ConnAdmission::admit(admission)
///   @session.ConnAdmission::complete(admission)
///   @session.ConnAdmission::complete(admission)
///   assert_eq(@session.ConnAdmission::admit(admission), Ok(()))
/// }
/// ```
pub fn ConnAdmission::complete(self : ConnAdmission) -> Unit {
  if self.core.val.in_flight.to_uint() > 0U {
    self.core.val.in_flight = (self.core.val.in_flight.to_uint() - 1U).to_uint16()
  }
}
