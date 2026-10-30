import ApplicationServices
import CoreGraphics
import Foundation

struct MenuBarReplicaCandidate: Equatable, Hashable, Sendable {
    let processIdentifier: Int32
    let frame: CGRect
    let identifier: String?

    func hash(into hasher: inout Hasher) {
        hasher.combine(processIdentifier)
        hasher.combine(frame.minX)
        hasher.combine(frame.minY)
        hasher.combine(frame.width)
        hasher.combine(frame.height)
        hasher.combine(identifier)
    }

    func matches(_ pid: Int32, _ frame: CGRect, _ identifier: String?) -> Bool {
        processIdentifier == pid && self.frame == frame && self.identifier == identifier
    }

    var samplePoints: [CGPoint] {
        [0.1, 0.5, 0.9].map { CGPoint(x: frame.minX + frame.width * $0, y: frame.midY) }
    }
}

struct MenuBarReplicaHit: Equatable, Sendable {
    let point: CGPoint
    let processIdentifier: Int32
    let role: String
    let frame: CGRect
}

/// An offscreen application status item can remain in one MenuBarAgent window
/// replica. Its SINGLE status item is verified independently before reconciling
/// that complete superset with the visible view. The normal ownership, boundary,
/// policy and two-fresh-plan checks still decide whether it may be hidden.
/// Evidence is tied to one raw graph and expires; no app name is special-cased.
struct MenuBarOffscreenReplicaEvidence: Equatable, Sendable {
    let rawRevision: String
    let candidate: MenuBarReplicaCandidate
    let bundleIdentifier: String
    let ownerItemFrames: [CGRect]
    let focusedProcessIdentifier: Int32
    let hits: [MenuBarReplicaHit]
    let sampledAtUptime: TimeInterval

    func isValid(for snapshot: MenuBarRawPhysicalStructureSnapshot) -> Bool {
        let age = ProcessInfo.processInfo.systemUptime - sampledAtUptime
        guard rawRevision == snapshot.revision, age >= 0, age < 2,
              case .value(let provider) = snapshot.model.providerProcessIdentifier,
              candidate.processIdentifier > 0, candidate.processIdentifier != provider,
              !bundleIdentifier.isEmpty, valid(candidate.frame),
              ownerItemFrames.count == 1,
              hits.count == candidate.samplePoints.count else { return false }
        let displays = snapshot.model.displays.compactMap { display -> CGRect? in
            guard case .value(let r) = display.bounds else { return nil }
            return CGRect(x: r.x, y: r.y, width: r.width, height: r.height)
        }
        guard !displays.isEmpty, displays.allSatisfy(valid),
              ownerItemFrames.allSatisfy({ frame in
                  valid(frame) && displays.allSatisfy { !$0.intersects(frame) }
              }) else { return false }
        for (hit, expectedPoint) in zip(hits, candidate.samplePoints) {
            guard hit.point == expectedPoint, hit.processIdentifier > 0,
                  hit.processIdentifier != candidate.processIdentifier,
                  valid(hit.frame), hit.frame.contains(hit.point) else { return false }
            if hit.role == kAXMenuBarRole, hit.processIdentifier == focusedProcessIdentifier {
                // The actual foreground application's menu bar covers this
                // point. A document/window/popover hit is never accepted.
                guard displays.contains(where: {
                    abs(hit.frame.minY - $0.minY) <= 1 && hit.frame.height <= 80
                        && hit.frame.width >= $0.width / 2
                }) else { return false }
            } else {
                // A system overflow/control button must itself be present in
                // the sampled physical graph at exactly the hit-test geometry.
                guard hit.processIdentifier == provider, hit.role == kAXButtonRole,
                      snapshot.model.nodes.contains(where: { node in
                          node.processIdentifier == .value(provider) && node.role == .value(kAXButtonRole)
                              && MenuBarReplicaVisibilityReader.frame(node) == hit.frame
                      }) else { return false }
            }
        }
        return true
    }

    private func valid(_ rect: CGRect) -> Bool {
        [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite)
            && rect.width > 0 && rect.height > 0
    }
}

enum MenuBarReplicaVisibilityReader {
    static func read(
        snapshot: MenuBarRawPhysicalStructureSnapshot,
        applications: [RunningAppSnapshot], deadline: TimeInterval,
        frontmostProcessIdentifier: Int32?
    ) -> [MenuBarOffscreenReplicaEvidence] {
        let candidates = MenuBarPhysicalInventoryEvidence.replicaDifferenceCandidates(snapshot: snapshot)
        guard !candidates.isEmpty, candidates.count <= 4,
              let focusedPID = frontmostProcessIdentifier, focusedPID > 0 else { return [] }
        let grouped = Dictionary(grouping: applications, by: \.processIdentifier)
        func available() -> Bool { !Task.isCancelled && ProcessInfo.processInfo.systemUptime < deadline }
        func value(_ node: AXUIElement, _ name: String) -> CFTypeRef? {
            guard available() else { return nil }
            AXUIElementSetMessagingTimeout(node, Float(min(0.02, deadline - ProcessInfo.processInfo.systemUptime)))
            var result: CFTypeRef?
            guard AXUIElementCopyAttributeValue(node, name as CFString, &result) == .success,
                  available() else { return nil }
            return result
        }
        func element(_ value: CFTypeRef?) -> AXUIElement? {
            guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return unsafeDowncast(value, to: AXUIElement.self)
        }
        func rect(_ node: AXUIElement) -> CGRect? {
            guard let p = value(node, kAXPositionAttribute), CFGetTypeID(p) == AXValueGetTypeID(),
                  let s = value(node, kAXSizeAttribute), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
            var point = CGPoint.zero
            var size = CGSize.zero
            guard AXValueGetValue(unsafeDowncast(p, to: AXValue.self), .cgPoint, &point),
                  AXValueGetValue(unsafeDowncast(s, to: AXValue.self), .cgSize, &size) else { return nil }
            return CGRect(origin: point, size: size)
        }
        let system = AXUIElementCreateSystemWide()
        var proofs: [MenuBarOffscreenReplicaEvidence] = []
        for candidate in candidates {
            guard available(), candidate.processIdentifier != getpid(),
                  let owners = grouped[candidate.processIdentifier], owners.count == 1,
                  let owner = owners.first, !owner.bundleIdentifier.isEmpty else { return [] }
            let application = AXUIElementCreateApplication(candidate.processIdentifier)
            // Read ONLY the explicit status-item bar, never AXChildren on an
            // application, a menu, a window, titles, documents or notification text.
            guard let bar = element(value(application, kAXExtrasMenuBarAttribute)),
                  value(bar, kAXRoleAttribute) as? String == kAXMenuBarRole,
                  let children = value(bar, kAXChildrenAttribute) as? [AXUIElement],
                  children.count == 1 else { return [] }
            var ownerFrames: [CGRect] = []
            for child in children {
                var pid: pid_t = 0
                guard AXUIElementGetPid(child, &pid) == .success, pid == candidate.processIdentifier,
                      value(child, kAXRoleAttribute) as? String == kAXMenuBarItemRole,
                      let frame = rect(child) else { return [] }
                if let identifier = candidate.identifier {
                    guard value(child, kAXIdentifierAttribute) as? String == identifier else { return [] }
                }
                ownerFrames.append(frame)
            }
            var hits: [MenuBarReplicaHit] = []
            for point in candidate.samplePoints {
                guard available() else { return [] }
                var hit: AXUIElement?
                guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success,
                      let hit, let role = value(hit, kAXRoleAttribute) as? String,
                      let frame = rect(hit) else { return [] }
                var pid: pid_t = 0
                guard AXUIElementGetPid(hit, &pid) == .success else { return [] }
                hits.append(.init(point: point, processIdentifier: pid, role: role, frame: frame))
            }
            let proof = MenuBarOffscreenReplicaEvidence(rawRevision: snapshot.revision,
                candidate: candidate, bundleIdentifier: owner.bundleIdentifier,
                ownerItemFrames: ownerFrames, focusedProcessIdentifier: focusedPID,
                hits: hits, sampledAtUptime: ProcessInfo.processInfo.systemUptime)
            guard available(), proof.isValid(for: snapshot) else { return [] }
            proofs.append(proof)
        }
        return proofs
    }

    static func frame(_ node: MenuBarRawPhysicalNode) -> CGRect? {
        if case .value(let r) = node.frame {
            return CGRect(x: r.x, y: r.y, width: r.width, height: r.height)
        }
        guard case .absent = node.frame, case .value(let p) = node.position,
              case .value(let s) = node.size else { return nil }
        return CGRect(x: p.x, y: p.y, width: s.width, height: s.height)
    }
}
