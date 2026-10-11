/// Pin the upgrade matrix: the exact green and blocked sets of the eight
/// cases, and same-seed reproducibility of the executable surface. The
/// expectations are hand-written literals, so a case cannot silently
/// change its outcome and a new block cannot appear unnoticed.

///|
async test "the matrix pins its green and blocked sets" {
  let env = @harness.SimEnv::new(42UL)
  let reports = @tools.run_upgrade_matrix(env)
  assert_eq(reports, [
    { id: "F1", status: @tools.Green, },
    { id: "F2", status: @tools.Green, },
    { id: "F3", status: @tools.Blocked("code-allocation"), },
    { id: "F4", status: @tools.Blocked("code-allocation"), },
    { id: "F5", status: @tools.Blocked("negotiation-mechanism"), },
    { id: "F6", status: @tools.Blocked("replica-version-field"), },
    { id: "downgrade_precheck", status: @tools.Blocked("mutation-tracking"), },
    { id: "rollback_explain", status: @tools.Blocked("mutation-tracking"), },
  ])
  // The case table itself is the frozen eight rows in table order.
  let cases = @tools.upgrade_cases()
  assert_eq(cases.length(), 8)
  assert_eq(cases[0].id, "F1")
  assert_eq(cases[7].id, "rollback_explain")
}

///|
async test "the matrix reruns identically across same-seed runs" {
  let run : async (@harness.SimEnv) -> Array[String] = env => {
    let reports = @tools.run_upgrade_matrix(env)
    let out : Array[String] = []
    for report in reports {
      let status = match report.status {
        @tools.Green => "green"
        @tools.Blocked(owner) => "blocked-by:" + owner
      }
      out.push(report.id + ":" + status)
    }
    out
  }
  assert_eq(@harness.reproducible(42UL, run), true)
}
