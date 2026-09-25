import Darwin
import Foundation

/// Process-local liveness and resource samples independent of Flutter/RPC.
final class NativeResourceHeartbeat {
  private var timer: DispatchSourceTimer?
  private let startedAt = ProcessInfo.processInfo.systemUptime
  private var warnReported = false
  private var lastReclaimUptime: TimeInterval = 0

  /// iOS terminates a packet-tunnel provider near a ~50 MB phys_footprint.
  /// The 2026-08-29 22:46 traces pinned the real death line: four consecutive
  /// tunnel lives each logged a final heartbeat of 43, 48, 47 and 47 MB and were
  /// killed on the very next tick, so the effective ceiling is around 48 MB, not
  /// 50. Warning and reclaim thresholds sit low enough to leave a reaction
  /// window before that line.
  ///
  /// Reclaiming is only a backstop. Those traces also showed
  /// `memory_pressure_reclaimed` reporting the same or a higher footprint,
  /// because the pages in question were live probe and provider buffers rather
  /// than garbage. The primary defense is admission control before those
  /// allocations: iOS profile sanitization caps pre-connect and probe cadence,
  /// while the low-memory core defers and bounds rule-provider work.
  private static let footprintWarningMB = 30
  private static let footprintReclaimMB = 38
  /// Reclaiming walks the whole Go heap. Throttle it so a sustained plateau
  /// above the threshold cannot turn into a per-second stall.
  private static let reclaimCooldown: TimeInterval = 15

  // MARK: - Adaptive reclaim
  //
  // The 2026-09-01 tester trace (759 s of tunnel uptime) measured the cost of
  // treating `footprintReclaimMB` as an unconditional trigger: footprint sat at
  // a p50 of exactly 38 MB, so 50.9% of samples were at or above the threshold
  // and the cooldown fired 32 whole-heap `FreeOSMemory()` passes. Only 2 of
  // those recovered anything (42->35 MB and a life-saving 48->23 MB); the other
  // 30 logged an unchanged footprint because the pages were live. That is a
  // periodic full-heap walk, forever, for nothing — the battery cost the user
  // asked about.
  //
  // So the trigger adapts. A reclaim that frees real memory keeps the base
  // threshold and cooldown. A reclaim that frees nothing counts towards a
  // streak, and after `ineffectiveStreakLimit` consecutive misses the effective
  // threshold escalates towards the death line and the cooldown backs off
  // exponentially. The backstop survives (48 MB still reclaims promptly once
  // escalated, which is what saved the tunnel in the trace) while a healthy
  // plateau stops paying for pointless GC.
  private static let minEffectiveYieldMB = 2
  private static let ineffectiveStreakLimit = 3
  private static let escalatedReclaimMB = 44
  private static let maxReclaimCooldown: TimeInterval = 120

  /// Live reclaim tuning. Kept as a value type so the escalation rule is a pure
  /// function that can be unit-tested without a running extension.
  struct ReclaimPolicy: Equatable {
    var thresholdMB: Int
    var cooldown: TimeInterval
    var ineffectiveStreak: Int
  }

  static let baseReclaimPolicy = ReclaimPolicy(
    thresholdMB: footprintReclaimMB,
    cooldown: reclaimCooldown,
    ineffectiveStreak: 0
  )

  private var reclaimPolicy = NativeResourceHeartbeat.baseReclaimPolicy

  /// Escalation rule. `yieldMB` is `before - after`, so a negative value (the
  /// footprint grew across the reclaim) counts as ineffective just like zero.
  static func nextReclaimPolicy(
    current: ReclaimPolicy,
    yieldMB: Int
  ) -> ReclaimPolicy {
    guard yieldMB < minEffectiveYieldMB else {
      // Real memory came back: this plateau is collectable, stay aggressive.
      return baseReclaimPolicy
    }
    let streak = current.ineffectiveStreak + 1
    guard streak >= ineffectiveStreakLimit else {
      return ReclaimPolicy(
        thresholdMB: current.thresholdMB,
        cooldown: current.cooldown,
        ineffectiveStreak: streak
      )
    }
    return ReclaimPolicy(
      thresholdMB: max(current.thresholdMB, escalatedReclaimMB),
      cooldown: min(current.cooldown * 2, maxReclaimCooldown),
      ineffectiveStreak: streak
    )
  }

  // MARK: - Log throttling
  //
  // The same trace wrote 763 heartbeat lines in 759 s: one App Group file
  // append per second, for the whole life of the tunnel. The two `task_info`
  // calls that produce a sample are microseconds of pure counter reads and are
  // not worth touching, but the file write behind every sample is real I/O.
  //
  // Detail only matters near the death line, so that is where the per-second
  // cadence is kept. In a healthy steady state one line every
  // `logIntervalSeconds` is enough to prove liveness, plus any sample that
  // moved the footprint materially — which preserves every ramp into danger.
  private static let logIntervalSeconds: TimeInterval = 10
  private static let logDeltaMB = 3
  private var lastLoggedUptime: TimeInterval = -.greatestFiniteMagnitude
  private var lastLoggedFootprintMB = Int.min

  /// Pure decision so the throttle can be tested without a timer.
  static func shouldLogHeartbeat(
    uptimeSeconds: TimeInterval,
    footprintMB: Int,
    lastLoggedUptime: TimeInterval,
    lastLoggedFootprintMB: Int
  ) -> Bool {
    // Never throttle inside the reaction window. That window is keyed off the
    // *escalated* threshold, not the warning one: the trace put the steady-state
    // median at 38 MB, so exempting everything above the 30 MB warning line
    // exempted 96.5% of samples and threw the throttle away. p90 was 42 and p99
    // 43, so 44 MB and up is genuinely the run-up to the 48 MB kill.
    if footprintMB >= escalatedReclaimMB { return true }
    if abs(footprintMB - lastLoggedFootprintMB) >= logDeltaMB { return true }
    return uptimeSeconds - lastLoggedUptime >= logIntervalSeconds
  }

  /// Injected so the heartbeat stays unit-testable and never hard-depends on
  /// the ObjC bridge being linked into a test target.
  private let reclaim: () -> Void

  init(reclaim: @escaping () -> Void = { NECoreBridge.releaseMemory() }) {
    self.reclaim = reclaim
  }

  func start() {
    stop()
    warnReported = false
    lastReclaimUptime = 0
    reclaimPolicy = Self.baseReclaimPolicy
    lastLoggedUptime = -.greatestFiniteMagnitude
    lastLoggedFootprintMB = Int.min
    let timer = DispatchSource.makeTimerSource(
      queue: DispatchQueue(label: "com.follow.clash.necore-heartbeat")
    )
    timer.schedule(deadline: .now(), repeating: .seconds(1), leeway: .milliseconds(200))
    timer.setEventHandler { [weak self] in
      guard let self else { return }
      let usage = Self.resourceUsage()
      let uptimeSeconds = ProcessInfo.processInfo.systemUptime - self.startedAt
      let uptime = Int(uptimeSeconds * 1000)
      if Self.shouldLogHeartbeat(
        uptimeSeconds: uptimeSeconds,
        footprintMB: usage.footprintMB,
        lastLoggedUptime: self.lastLoggedUptime,
        lastLoggedFootprintMB: self.lastLoggedFootprintMB
      ) {
        self.lastLoggedUptime = uptimeSeconds
        self.lastLoggedFootprintMB = usage.footprintMB
        NativeDiagnosticLog.shared.append(
          "heartbeat uptime_ms=\(uptime) resident_mb=\(usage.residentMB) footprint_mb=\(usage.footprintMB) virtual_mb=\(usage.virtualMB)"
        )
      }
      if usage.footprintMB >= Self.footprintWarningMB, !self.warnReported {
        self.warnReported = true
        NativeDiagnosticLog.shared.append(
          "memory_pressure_warning footprint_mb=\(usage.footprintMB) threshold_mb=\(Self.footprintWarningMB)"
        )
      }
      guard usage.footprintMB >= self.reclaimPolicy.thresholdMB else { return }
      guard Self.shouldReclaim(
        uptimeSeconds: uptimeSeconds,
        lastReclaimUptime: self.lastReclaimUptime,
        cooldown: self.reclaimPolicy.cooldown
      ) else { return }
      self.lastReclaimUptime = uptimeSeconds
      NativeDiagnosticLog.shared.append(
        "memory_pressure_reclaim footprint_mb=\(usage.footprintMB) threshold_mb=\(self.reclaimPolicy.thresholdMB)"
      )
      self.reclaim()
      let after = Self.resourceUsage()
      let yieldMB = usage.footprintMB - after.footprintMB
      self.reclaimPolicy = Self.nextReclaimPolicy(
        current: self.reclaimPolicy,
        yieldMB: yieldMB
      )
      NativeDiagnosticLog.shared.append(
        "memory_pressure_reclaimed footprint_mb=\(after.footprintMB) yield_mb=\(yieldMB) streak=\(self.reclaimPolicy.ineffectiveStreak) next_threshold_mb=\(self.reclaimPolicy.thresholdMB) next_cooldown_s=\(Int(self.reclaimPolicy.cooldown))"
      )
    }
    self.timer = timer
    timer.resume()
  }

  /// First crossing always reclaims; later crossings wait out the cooldown,
  /// which the escalation rule can widen when reclaiming stops paying off.
  static func shouldReclaim(
    uptimeSeconds: TimeInterval,
    lastReclaimUptime: TimeInterval,
    cooldown: TimeInterval = reclaimCooldown
  ) -> Bool {
    if lastReclaimUptime == 0 { return true }
    return uptimeSeconds - lastReclaimUptime >= cooldown
  }

  func stop() {
    timer?.setEventHandler {}
    timer?.cancel()
    timer = nil
  }

  private static func resourceUsage() -> (
    residentMB: Int,
    footprintMB: Int,
    virtualMB: Int
  ) {
    var basic = mach_task_basic_info_data_t()
    var basicCount = mach_msg_type_number_t(
      MemoryLayout<mach_task_basic_info_data_t>.size /
        MemoryLayout<natural_t>.size
    )
    let basicResult = withUnsafeMutablePointer(to: &basic) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(basicCount)) {
        task_info(
          mach_task_self_,
          task_flavor_t(MACH_TASK_BASIC_INFO),
          $0,
          &basicCount
        )
      }
    }

    var vm = task_vm_info_data_t()
    var vmCount = mach_msg_type_number_t(
      MemoryLayout<task_vm_info_data_t>.size /
        MemoryLayout<natural_t>.size
    )
    let vmResult = withUnsafeMutablePointer(to: &vm) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) {
        task_info(
          mach_task_self_,
          task_flavor_t(TASK_VM_INFO),
          $0,
          &vmCount
        )
      }
    }

    let divisor: UInt64 = 1024 * 1024
    return (
      basicResult == KERN_SUCCESS ? Int(UInt64(basic.resident_size) / divisor) : -1,
      vmResult == KERN_SUCCESS ? Int(UInt64(vm.phys_footprint) / divisor) : -1,
      basicResult == KERN_SUCCESS ? Int(UInt64(basic.virtual_size) / divisor) : -1
    )
  }
}
