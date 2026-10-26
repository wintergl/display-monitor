import ApplicationServices
import Foundation
import XCTest
@testable import DisplayMonitor

final class MenuBarAXAttributeBatchTests: XCTestCase {
    private let element = AXUIElementCreateApplication(42_424)

    func testSelfProcessAttributeReadsRequireMainThreadAndKnownOwner() {
        XCTAssertFalse(MenuBarAXAttributeBatch.permitsAttributeRead(ownerPID: 7, ownPID: 7, isMainThread: false))
        XCTAssertTrue(MenuBarAXAttributeBatch.permitsAttributeRead(ownerPID: 7, ownPID: 7, isMainThread: true))
        XCTAssertTrue(MenuBarAXAttributeBatch.permitsAttributeRead(ownerPID: 8, ownPID: 7, isMainThread: false))
        XCTAssertFalse(MenuBarAXAttributeBatch.permitsAttributeRead(ownerPID: nil, ownPID: 7, isMainThread: false))
        XCTAssertFalse(MenuBarAXAttributeBatch.permitsAttributeRead(ownerPID: 0, ownPID: 7, isMainThread: true))
    }

    func testRealSelfProcessAXHandleIsRejectedBeforeOffMainMenuReads() async {
        let rejected = await Task.detached {
            let own = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
            let batch = MenuBarAXAttributeBatch.read(element: own,
                attributes: [kAXRoleAttribute, kAXChildrenAttribute])
            let (singleError, value) = MenuBarAXAttributeBatch.copyAttributeValue(
                element: own, attribute: kAXChildrenAttribute)
            guard case .failed = batch.raw(kAXChildrenAttribute),
                  case .failed = batch.raw(kAXRoleAttribute) else { return false }
            return singleError == .cannotComplete && value == nil
        }.value
        XCTAssertTrue(rejected)
    }

    func testMixedBulkSlotsDecodeWithoutSingleReads() {
        let attributes = [
            "role",
            "blank",
            "null",
            "unsupported",
            "noValue",
            "busy",
            "otherError",
            "scalar",
            "geometry",
        ]
        var point = CGPoint(x: 10, y: 20)
        let geometry = AXValueCreate(.cgPoint, &point)!
        let values: [AnyObject] = [
            "  AXMenuBarItem  " as NSString,
            " \n " as NSString,
            kCFNull,
            boxedError(.attributeUnsupported),
            boxedError(.noValue),
            boxedError(.cannotComplete),
            boxedError(.failure),
            NSNumber(value: 42),
            geometry,
        ]
        var multipleCallCount = 0
        var singleCallCount = 0

        let batch = MenuBarAXAttributeBatch.read(
            element: element,
            attributes: attributes,
            copyMultiple: { _, receivedAttributes, options in
                multipleCallCount += 1
                XCTAssertEqual(receivedAttributes, attributes)
                XCTAssertEqual(options.rawValue, 0)
                return (.success, values as CFArray)
            },
            copySingle: { _, _ in
                singleCallCount += 1
                return (.failure, nil)
            }
        )

        XCTAssertEqual(multipleCallCount, 1)
        XCTAssertEqual(singleCallCount, 0)
        assertValue(batch.string("role"), equals: "AXMenuBarItem")
        assertAbsent(batch.string("blank"))
        assertAbsent(batch.raw("null"))
        assertAbsent(batch.raw("unsupported"))
        assertAbsent(batch.raw("noValue"))
        assertFailed(batch.raw("busy"))
        assertFailed(batch.raw("otherError"))
        assertValue(batch.scalarString("scalar"), equals: "42")
        assertFailed(batch.string("geometry"))
        XCTAssertNotNil(batch.optionalValue("geometry"))
        assertFailed(batch.raw("not-requested"))
    }

    func testGeometryAXValuesRemainOrdinaryRawValues() {
        var rect = CGRect(x: 1, y: 2, width: 30, height: 40)
        var point = CGPoint(x: 3, y: 4)
        var size = CGSize(width: 50, height: 60)
        let frame = AXValueCreate(.cgRect, &rect)!
        let position = AXValueCreate(.cgPoint, &point)!
        let dimensions = AXValueCreate(.cgSize, &size)!
        let batch = MenuBarAXAttributeBatch.read(
            element: element,
            attributes: ["frame", "position", "size"],
            copyMultiple: { _, _, _ in
                (.success, [frame, position, dimensions] as CFArray)
            },
            copySingle: { _, _ in (.failure, nil) }
        )

        assertAXValue(batch.optionalValue("frame"), type: .cgRect)
        assertAXValue(batch.optionalValue("position"), type: .cgPoint)
        assertAXValue(batch.optionalValue("size"), type: .cgSize)
    }

    func testBulkRequiresArrayAndMatchingSlotCount() {
        var singleCallCount = 0
        let nonArray = MenuBarAXAttributeBatch.read(
            element: element,
            attributes: ["role"],
            copyMultiple: { _, _, _ in (.success, "not-an-array" as NSString) },
            copySingle: { _, _ in
                singleCallCount += 1
                return (.success, "unused" as NSString)
            }
        )
        let wrongCount = MenuBarAXAttributeBatch.read(
            element: element,
            attributes: ["role", "children"],
            copyMultiple: { _, _, _ in (.success, ["AXMenuBarItem" as NSString] as CFArray) },
            copySingle: { _, _ in
                singleCallCount += 1
                return (.success, "unused" as NSString)
            }
        )

        assertFailed(nonArray.raw("role"))
        assertFailed(wrongCount.raw("role"))
        assertFailed(wrongCount.raw("children"))
        XCTAssertEqual(singleCallCount, 0)
    }

    func testCompatibilityGlobalErrorsFallBackPerAttribute() {
        let compatibilityErrors: [AXError] = [
            .notImplemented,
            .illegalArgument,
            .attributeUnsupported,
        ]

        for globalError in compatibilityErrors {
            var multipleCallCount = 0
            var singleAttributes: [String] = []
            let attributes = ["title", "unsupported", "missing", "busy", "nilValue"]
            let batch = MenuBarAXAttributeBatch.read(
                element: element,
                attributes: attributes,
                copyMultiple: { _, _, options in
                    multipleCallCount += 1
                    XCTAssertEqual(options.rawValue, 0)
                    return (globalError, nil)
                },
                copySingle: { _, attribute in
                    singleAttributes.append(attribute)
                    switch attribute {
                    case "title": return (.success, "Title" as NSString)
                    case "unsupported": return (.attributeUnsupported, nil)
                    case "missing": return (.noValue, nil)
                    case "busy": return (.cannotComplete, nil)
                    case "nilValue": return (.success, nil)
                    default: return (.failure, nil)
                    }
                }
            )

            XCTAssertEqual(multipleCallCount, 1)
            XCTAssertEqual(singleAttributes, attributes)
            assertValue(batch.string("title"), equals: "Title")
            assertAbsent(batch.raw("unsupported"))
            assertAbsent(batch.raw("missing"))
            assertFailed(batch.raw("busy"))
            assertAbsent(batch.raw("nilValue"))
        }
    }

    func testOtherGlobalErrorsFailWithoutFallback() {
        var singleCallCount = 0
        let batch = MenuBarAXAttributeBatch.read(
            element: element,
            attributes: ["role", "children"],
            copyMultiple: { _, _, _ in (.cannotComplete, nil) },
            copySingle: { _, _ in
                singleCallCount += 1
                return (.success, "must-not-be-read" as NSString)
            }
        )

        assertFailed(batch.raw("role"))
        assertFailed(batch.raw("children"))
        XCTAssertEqual(singleCallCount, 0)
    }

    func testCancellationBeforeBulkAvoidsAllReads() {
        var multipleCallCount = 0
        var singleCallCount = 0
        let batch = MenuBarAXAttributeBatch.read(
            element: element,
            attributes: ["role"],
            shouldContinue: { false },
            copyMultiple: { _, _, _ in
                multipleCallCount += 1
                return (.success, [] as CFArray)
            },
            copySingle: { _, _ in
                singleCallCount += 1
                return (.success, nil)
            }
        )

        assertFailed(batch.raw("role"))
        XCTAssertEqual(multipleCallCount, 0)
        XCTAssertEqual(singleCallCount, 0)
    }

    func testCancellationIsCheckedBeforeEveryFallbackRead() {
        var continuationChecks = 0
        var singleAttributes: [String] = []
        let attributes = ["first", "second", "third"]
        let batch = MenuBarAXAttributeBatch.read(
            element: element,
            attributes: attributes,
            shouldContinue: {
                defer { continuationChecks += 1 }
                return continuationChecks < 2
            },
            copyMultiple: { _, _, _ in (.notImplemented, nil) },
            copySingle: { _, attribute in
                singleAttributes.append(attribute)
                return (.success, attribute as NSString)
            }
        )

        XCTAssertEqual(singleAttributes, ["first"])
        assertValue(batch.string("first"), equals: "first")
        assertFailed(batch.raw("second"))
        assertFailed(batch.raw("third"))
        XCTAssertEqual(continuationChecks, 4)
    }

    func testElementsAcceptsOnlyAnEntireValidAXElementArray() {
        let first = AXUIElementCreateApplication(100)
        let second = AXUIElementCreateApplication(200)
        let validChildren: [AnyObject] = [first, second]
        let malformedChildren: [AnyObject] = [first, "not-an-element" as NSString, second]
        let batch = MenuBarAXAttributeBatch.read(
            element: element,
            attributes: ["valid", "malformed"],
            copyMultiple: { _, _, _ in
                (.success, [validChildren as CFArray, malformedChildren as CFArray] as CFArray)
            },
            copySingle: { _, _ in (.failure, nil) }
        )

        switch batch.elements("valid") {
        case .value(let elements):
            XCTAssertEqual(elements.count, 2)
            XCTAssertTrue(CFEqual(elements[0], first))
            XCTAssertTrue(CFEqual(elements[1], second))
        case .absent, .failed:
            XCTFail("A valid AX element array must be preserved.")
        }
        assertFailed(batch.elements("malformed"))
    }

    func testMandatoryStringUsesValidBatchSlotWithoutSingleRead() {
        var singleCallCount = 0
        let batch = makeBatch(role: "  AXButton  " as NSString)

        let result = batch.mandatoryString(
            element: element,
            attribute: kAXRoleAttribute,
            copySingle: { _, _ in
                singleCallCount += 1
                return (.success, "AXGroup" as NSString)
            }
        )

        XCTAssertEqual(result, .batch("AXButton"))
        XCTAssertEqual(singleCallCount, 0)
    }

    func testMandatoryStringFreshSingleReadRecoversUnavailableBatchSlots() {
        let unavailableBatchSlots: [AnyObject] = [
            kCFNull,
            boxedError(.cannotComplete),
            NSNumber(value: 7),
        ]

        for batchSlot in unavailableBatchSlots {
            var singleAttributes: [String] = []
            let batch = makeBatch(role: batchSlot)

            let result = batch.mandatoryString(
                element: element,
                attribute: kAXRoleAttribute,
                copySingle: { _, attribute in
                    singleAttributes.append(attribute)
                    return (.success, "  AXGroup  " as NSString)
                }
            )

            let expectedFailure: MenuBarAXMandatoryStringFailure
            if CFGetTypeID(batchSlot) == CFNullGetTypeID() {
                expectedFailure = .absent
            } else if CFGetTypeID(batchSlot) == AXValueGetTypeID() {
                expectedFailure = .failed
            } else {
                expectedFailure = .wrongType
            }
            XCTAssertEqual(
                result,
                .fallback("AXGroup", bulkFailure: expectedFailure)
            )
            XCTAssertEqual(singleAttributes, [kAXRoleAttribute])
        }
    }

    func testMandatoryStringRejectsUnavailableOrMalformedFallbackValues() {
        let fallbackResults: [(AXError, CFTypeRef?, MenuBarAXMandatoryStringFailure)] = [
            (.noValue, nil, .absent),
            (.cannotComplete, nil, .failed),
            (.success, NSNumber(value: 7), .wrongType),
            (.success, " \n " as NSString, .absent),
        ]

        for fallbackResult in fallbackResults {
            let batch = makeBatch(role: kCFNull)

            let result = batch.mandatoryString(
                element: element,
                attribute: kAXRoleAttribute,
                copySingle: { _, _ in (fallbackResult.0, fallbackResult.1) }
            )

            XCTAssertEqual(
                result,
                .failed(
                    bulkFailure: .absent,
                    fallbackFailure: fallbackResult.2
                )
            )
        }
    }

    func testMandatoryStringDoesNotReadPastDeadline() {
        var singleCallCount = 0
        let batch = makeBatch(role: boxedError(.cannotComplete))

        let result = batch.mandatoryString(
            element: element,
            attribute: kAXRoleAttribute,
            shouldContinue: { false },
            copySingle: { _, _ in
                singleCallCount += 1
                return (.success, "AXButton" as NSString)
            }
        )

        XCTAssertEqual(
            result,
            .failed(
                bulkFailure: .failed,
                fallbackFailure: .deadlineExceeded
            )
        )
        XCTAssertEqual(singleCallCount, 0)
    }

    func testMandatoryStringChecksDeadlineAroundFreshRead() {
        var continuationChecks = 0
        var events: [String] = []
        let batch = makeBatch(role: kCFNull)

        let result = batch.mandatoryString(
            element: element,
            attribute: kAXRoleAttribute,
            shouldContinue: {
                continuationChecks += 1
                events.append("check\(continuationChecks)")
                return continuationChecks < 3
            },
            beforeFallback: { events.append("configure") },
            copySingle: { _, _ in
                events.append("single")
                return (.success, "AXButton" as NSString)
            }
        )

        XCTAssertEqual(
            result,
            .failed(
                bulkFailure: .absent,
                fallbackFailure: .deadlineExceeded
            )
        )
        XCTAssertEqual(events, ["check1", "configure", "check2", "single", "check3"])
    }

    func testMandatoryStringFallbackDoesNotReplaceOtherBatchSlots() {
        let batch = MenuBarAXAttributeBatch.read(
            element: element,
            attributes: [kAXRoleAttribute, kAXChildrenAttribute],
            copyMultiple: { _, _, _ in
                (.success, [kCFNull, self.boxedError(.cannotComplete)] as CFArray)
            },
            copySingle: { _, _ in (.failure, nil) }
        )

        let result = batch.mandatoryString(
            element: element,
            attribute: kAXRoleAttribute,
            copySingle: { _, _ in (.success, "AXButton" as NSString) }
        )

        XCTAssertEqual(result, .fallback("AXButton", bulkFailure: .absent))
        assertFailed(batch.elements(kAXChildrenAttribute))
    }

    func testFreshElementsRequiresASuccessfulEntireAXElementArray() {
        let child = AXUIElementCreateApplication(123)
        let cases: [(AXError, CFTypeRef?, String)] = [
            (.success, [] as CFArray, "empty"),
            (.success, [child] as CFArray, "nonempty"),
            (.noValue, nil, "absent"),
            (.success, nil, "absent"),
            (.success, [child, "wrong" as NSString] as CFArray, "failed"),
            (.cannotComplete, nil, "failed"),
        ]

        for item in cases {
            let read = MenuBarAXAttributeBatch.freshElements(
                element: element,
                attribute: kAXChildrenAttribute,
                copySingle: { _, _ in (item.0, item.1) }
            )
            switch (item.2, read) {
            case ("empty", .value(let children)):
                XCTAssertTrue(children.isEmpty)
            case ("nonempty", .value(let children)):
                XCTAssertEqual(children.count, 1)
                XCTAssertTrue(CFEqual(children[0], child))
            case ("absent", .absent), ("failed", .failed):
                break
            default:
                XCTFail("Unexpected fresh children result for \(item.2).")
            }
        }
    }

    func testFreshElementsChecksDeadlineBeforeAndAfterSingleRead() {
        var checks = 0
        var events: [String] = []

        let read = MenuBarAXAttributeBatch.freshElements(
            element: element,
            attribute: kAXChildrenAttribute,
            shouldContinue: {
                checks += 1
                events.append("check\(checks)")
                return checks < 3
            },
            beforeRead: { events.append("configure") },
            copySingle: { _, _ in
                events.append("single")
                return (.success, [] as CFArray)
            }
        )

        assertFailed(read)
        XCTAssertEqual(events, ["check1", "configure", "check2", "single", "check3"])
    }

    func testGeometrySlotShapeDistinguishesAbsentPresentFailedAndWrongType() {
        var rect = CGRect(x: 0, y: 0, width: 10, height: 10)
        let frame = AXValueCreate(.cgRect, &rect)!
        let batch = MenuBarAXAttributeBatch.read(
            element: element,
            attributes: ["absent", "present", "failed", "wrong"],
            copyMultiple: { _, _, _ in
                (.success, [
                    kCFNull,
                    frame,
                    self.boxedError(.cannotComplete),
                    "not-geometry" as NSString,
                ] as CFArray)
            },
            copySingle: { _, _ in (.failure, nil) }
        )

        XCTAssertEqual(batch.geometrySlotShape("absent", expectedType: .cgRect), .absent)
        XCTAssertEqual(batch.geometrySlotShape("present", expectedType: .cgRect), .present)
        XCTAssertEqual(batch.geometrySlotShape("failed", expectedType: .cgRect), .failed)
        XCTAssertEqual(batch.geometrySlotShape("wrong", expectedType: .cgRect), .wrongType)
        XCTAssertEqual(batch.geometrySlotShape("present", expectedType: .cgPoint), .wrongType)
    }

    private func makeBatch(role: AnyObject) -> MenuBarAXAttributeBatch {
        MenuBarAXAttributeBatch.read(
            element: element,
            attributes: [kAXRoleAttribute],
            copyMultiple: { _, _, _ in (.success, [role] as CFArray) },
            copySingle: { _, _ in (.failure, nil) }
        )
    }

    private func boxedError(_ error: AXError) -> AXValue {
        var error = error
        return AXValueCreate(.axError, &error)!
    }

    private func assertAXValue(
        _ raw: CFTypeRef?,
        type expectedType: AXValueType,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let raw, CFGetTypeID(raw) == AXValueGetTypeID() else {
            XCTFail("Expected an AXValue.", file: file, line: line)
            return
        }
        XCTAssertEqual(
            AXValueGetType(unsafeDowncast(raw, to: AXValue.self)),
            expectedType,
            file: file,
            line: line
        )
    }

    private func assertValue<Value: Equatable>(
        _ read: MenuBarAXAttributeRead<Value>,
        equals expected: Value,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .value(let value) = read else {
            XCTFail("Expected a value.", file: file, line: line)
            return
        }
        XCTAssertEqual(value, expected, file: file, line: line)
    }

    private func assertAbsent<Value>(
        _ read: MenuBarAXAttributeRead<Value>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .absent = read else {
            XCTFail("Expected an absent read.", file: file, line: line)
            return
        }
    }

    private func assertFailed<Value>(
        _ read: MenuBarAXAttributeRead<Value>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .failed = read else {
            XCTFail("Expected a failed read.", file: file, line: line)
            return
        }
    }
}
