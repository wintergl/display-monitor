import XCTest
@testable import DisplayMonitor

final class MenuBarTopologySnapshotTests: XCTestCase {
    func testHelperWithoutStatusItemsDoesNotChangeTopology() {
        let item = makeItem()
        let baseProvider = item.provider
        let helper = MenuBarTopologyProvider(
            bundleIdentifier: "example.helper",
            applicationName: "Helper",
            processIdentifier: 77
        )
        let before = MenuBarTopologySnapshot(
            items: [item],
            runningProviders: [baseProvider]
        )
        let after = MenuBarTopologySnapshot(
            items: [item],
            runningProviders: [baseProvider, helper]
        )

        XCTAssertTrue(MenuBarTopologyDelta.between(before, after).isEmpty)
        XCTAssertEqual(before.structuralRevision, after.structuralRevision)
    }

    func testStrongIdentityTitleChangeIsContentOnly() {
        let before = MenuBarTopologySnapshot(items: [makeItem(title: "同步 20%")])
        let after = MenuBarTopologySnapshot(items: [makeItem(title: "同步 21%")])

        let delta = MenuBarTopologyDelta.between(before, after)

        XCTAssertTrue(delta.added.isEmpty)
        XCTAssertTrue(delta.removed.isEmpty)
        XCTAssertEqual(delta.contentChanged.map(\.displayLabel), ["同步 21%"])
        XCTAssertTrue(delta.weakMetadataChanged.isEmpty)
    }

    func testWeakIdentityTitleRefreshIsFilteredFromPresentationCandidates() {
        let before = MenuBarTopologySnapshot(items: [
            makeItem(identity: "path:0", strength: .weak, identifier: nil, title: "12:00"),
        ])
        let after = MenuBarTopologySnapshot(items: [
            makeItem(identity: "path:0", strength: .weak, identifier: nil, title: "12:01"),
        ])

        let delta = MenuBarTopologyDelta.between(before, after)

        XCTAssertTrue(delta.contentChanged.isEmpty)
        XCTAssertEqual(delta.weakMetadataChanged.count, 1)
        XCTAssertTrue(delta.presentationCandidates.isEmpty)
        XCTAssertTrue(delta.isEmpty)
    }

    func testAddedRemovedAndRestartedProvidersStayDistinct() {
        let old = makeItem()
        let added = makeItem(identity: "identifier:second", identifier: "second", title: "Second")
        let restarted = makeItem(processIdentifier: 99)

        let addition = MenuBarTopologyDelta.between(
            MenuBarTopologySnapshot(items: [old]),
            MenuBarTopologySnapshot(items: [old, added])
        )
        XCTAssertEqual(addition.added.map(\.displayLabel), ["Second"])
        XCTAssertTrue(addition.removed.isEmpty)

        let removal = MenuBarTopologyDelta.between(
            MenuBarTopologySnapshot(items: [old, added]),
            MenuBarTopologySnapshot(items: [old])
        )
        XCTAssertEqual(removal.removed.map(\.displayLabel), ["Second"])
        XCTAssertTrue(removal.presentationCandidates.isEmpty)

        let restart = MenuBarTopologyDelta.between(
            MenuBarTopologySnapshot(items: [old]),
            MenuBarTopologySnapshot(items: [restarted])
        )
        XCTAssertEqual(restart.restartedBundleIdentifiers, ["example.target"])
        XCTAssertEqual(restart.added.count, 1)
        XCTAssertEqual(restart.removed.count, 1)
    }

    func testUnreadableProviderIsReportedWithoutInventingRemoval() {
        let item = makeItem()
        let current = MenuBarTopologySnapshot(
            items: [],
            runningProviders: [item.provider],
            unreadableProviders: [item.provider]
        )

        let delta = MenuBarTopologyDelta.between(
            MenuBarTopologySnapshot(items: [item]),
            current
        )

        XCTAssertEqual(delta.unreadableProviders, [item.provider])
        XCTAssertEqual(delta.removed.count, 1)
        // The coordinator treats unreadability as uncertain and does not accept
        // this apparent removal into its active baseline.
    }

    func testStatusItemIdentityNeverUsesDynamicTitle() {
        let first = MenuBarStatusItemIdentity.stableComponent(
            identifier: nil,
            structuralPath: [0, 2, 1]
        )
        let second = MenuBarStatusItemIdentity.stableComponent(
            identifier: nil,
            structuralPath: [0, 2, 1]
        )
        XCTAssertEqual(first, "path:0.2.1")
        XCTAssertEqual(first, second)
        XCTAssertEqual(
            MenuBarStatusItemIdentity.stableComponent(
                identifier: "sync.status",
                structuralPath: [99]
            ),
            "identifier:sync.status"
        )
    }

    func testDuplicateStrongIdentifiersFallBackToUniqueWeakStructuralPaths() {
        let provider = makeItem().provider
        let duplicated = [
            makeItem(
                identity: "identifier:duplicate",
                structuralIdentity: "path:0",
                identifier: "duplicate",
                title: "First"
            ),
            makeItem(
                identity: "identifier:duplicate",
                structuralIdentity: "path:1",
                identifier: "duplicate",
                title: "Second"
            ),
        ]

        let normalized = MenuBarTopologyRevisionReader.normalizeDuplicateIdentifiers(duplicated)
        let snapshot = MenuBarTopologySnapshot(
            items: normalized.items,
            ambiguousProviders: normalized.ambiguousProviders
        )
        let delta = MenuBarTopologyDelta.between(
            MenuBarTopologySnapshot(items: []),
            snapshot
        )

        XCTAssertEqual(Set(snapshot.items.map(\.key)).count, 2)
        XCTAssertTrue(snapshot.items.allSatisfy { $0.identityStrength == .weak })
        XCTAssertTrue(snapshot.items.allSatisfy { $0.accessibilityIdentifier == nil })
        XCTAssertEqual(snapshot.ambiguousProviders, [provider])
        XCTAssertEqual(delta.added.count, 2)
    }

    func testMalformedDuplicateKeysAreMarkedAmbiguousAndDoNotCrashDelta() {
        let item = makeItem()
        let snapshot = MenuBarTopologySnapshot(items: [item, item])

        let delta = MenuBarTopologyDelta.between(snapshot, snapshot)

        XCTAssertEqual(snapshot.ambiguousProviders, [item.provider])
        XCTAssertTrue(delta.isEmpty)
    }

    func testPersistentHealthStateAloneDoesNotBecomeARepeatedDelta() {
        let item = makeItem()
        let snapshot = MenuBarTopologySnapshot(
            items: [item],
            unreadableProviders: [item.provider],
            ambiguousProviders: [item.provider]
        )

        let delta = MenuBarTopologyDelta.between(snapshot, snapshot)

        XCTAssertEqual(delta.unreadableProviders, [item.provider])
        XCTAssertEqual(delta.ambiguousProviders, [item.provider])
        XCTAssertTrue(delta.isEmpty)
    }

    func testUnreadableKnownProviderKeepsOnlyItsLastConfirmedItems() {
        let previousItem = makeItem(title: "Confirmed")
        let partialCurrent = makeItem(title: "Partial")
        let current = MenuBarTopologySnapshot(
            items: [partialCurrent],
            runningProviders: [partialCurrent.provider],
            unreadableProviders: [partialCurrent.provider]
        )

        let accepted = current.preservingConfirmedItemsForUnreadableProviders(
            from: MenuBarTopologySnapshot(items: [previousItem])
        )

        XCTAssertEqual(accepted.items, [previousItem])
        XCTAssertEqual(accepted.unreadableProviders, [previousItem.provider])
    }

    func testUnreadableNewProviderCannotCommitPartialItems() {
        let confirmed = makeItem()
        let newProvider = MenuBarTopologyProvider(
            bundleIdentifier: "example.target",
            applicationName: "Target Helper",
            processIdentifier: 77
        )
        let partial = MenuBarTopologyItemSnapshot(
            provider: newProvider,
            identityKey: "identifier:partial",
            identityStrength: .strong,
            accessibilityIdentifier: "partial",
            title: "Partial",
            itemDescription: nil,
            value: nil
        )
        let current = MenuBarTopologySnapshot(
            items: [confirmed, partial],
            runningProviders: [confirmed.provider, newProvider],
            unreadableProviders: [newProvider]
        )

        let accepted = current.preservingConfirmedItemsForUnreadableProviders(
            from: MenuBarTopologySnapshot(items: [confirmed])
        )

        XCTAssertEqual(accepted.items, [confirmed])
    }

    func testUnreadableSiblingWithSameBundleDoesNotFreezeReadableInstance() {
        let before = makeItem(title: "Before")
        let changed = makeItem(title: "After")
        let helper = MenuBarTopologyProvider(
            bundleIdentifier: before.provider.bundleIdentifier,
            applicationName: "Target Helper",
            processIdentifier: 77
        )
        let current = MenuBarTopologySnapshot(
            items: [changed],
            runningProviders: [changed.provider, helper],
            unreadableProviders: [helper]
        ).preservingConfirmedItemsForUnreadableProviders(
            from: MenuBarTopologySnapshot(items: [before])
        )

        let delta = MenuBarTopologyDelta.between(
            MenuBarTopologySnapshot(items: [before]),
            current
        )

        XCTAssertEqual(delta.contentChanged.map(\.title), ["After"])
    }

    private func makeItem(
        identity: String = "identifier:target",
        structuralIdentity: String? = nil,
        strength: MenuBarTopologyIdentityStrength = .strong,
        identifier: String? = "target",
        title: String = "Target",
        processIdentifier: Int32 = 42
    ) -> MenuBarTopologyItemSnapshot {
        MenuBarTopologyItemSnapshot(
            provider: MenuBarTopologyProvider(
                bundleIdentifier: "example.target",
                applicationName: "Target",
                processIdentifier: processIdentifier
            ),
            identityKey: identity,
            structuralIdentityKey: structuralIdentity,
            identityStrength: strength,
            accessibilityIdentifier: identifier,
            title: title,
            itemDescription: nil,
            value: nil
        )
    }
}
