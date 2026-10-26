import ApplicationServices
import Foundation

enum MenuBarAXAttributeRead<Value> {
    case value(Value)
    case absent
    case failed
}

enum MenuBarAXMandatoryStringFailure: Equatable {
    case absent
    case failed
    case wrongType
    case deadlineExceeded
}

enum MenuBarAXMandatoryStringRead: Equatable {
    case batch(String)
    case fallback(String, bulkFailure: MenuBarAXMandatoryStringFailure)
    case failed(
        bulkFailure: MenuBarAXMandatoryStringFailure,
        fallbackFailure: MenuBarAXMandatoryStringFailure
    )
}

struct MenuBarAXAttributeBatch {
    /// AX requests for our own PID can call AppKit directly on the calling
    /// thread (rather than remote IPC). Reading NSMenu children there invokes
    /// input-source validation and traps off-main on macOS 27. Do not dispatch
    /// synchronously to main: the main actor may be waiting for this scan.
    static func permitsAttributeRead(
        ownerPID: Int32?,
        ownPID: Int32 = ProcessInfo.processInfo.processIdentifier,
        isMainThread: Bool = Thread.isMainThread
    ) -> Bool {
        guard let ownerPID, ownerPID > 0 else { return false }
        return ownerPID != ownPID || isMainThread
    }

    private static func permitsAttributeRead(_ element: AXUIElement) -> Bool {
        var ownerPID: pid_t = 0
        guard AXUIElementGetPid(element, &ownerPID) == .success else { return false }
        return permitsAttributeRead(ownerPID: ownerPID)
    }
    typealias CopyMultiple = (
        _ element: AXUIElement,
        _ attributes: [String],
        _ options: AXCopyMultipleAttributeOptions
    ) -> (AXError, CFTypeRef?)

    typealias CopySingle = (
        _ element: AXUIElement,
        _ attribute: String
    ) -> (AXError, CFTypeRef?)

    private let reads: [String: MenuBarAXAttributeRead<CFTypeRef>]

    static func read(
        element: AXUIElement,
        attributes: [String],
        shouldContinue: () -> Bool = { !Task.isCancelled }
    ) -> Self {
        read(
            element: element,
            attributes: attributes,
            shouldContinue: shouldContinue,
            copyMultiple: systemCopyMultiple,
            copySingle: systemCopySingle
        )
    }

    static func read(
        element: AXUIElement,
        attributes: [String],
        shouldContinue: () -> Bool = { !Task.isCancelled },
        copyMultiple: CopyMultiple,
        copySingle: CopySingle
    ) -> Self {
        guard !attributes.isEmpty else { return Self(reads: [:]) }
        guard shouldContinue() else {
            return Self(reads: failedReads(for: attributes))
        }

        let options = AXCopyMultipleAttributeOptions(rawValue: 0)
        let (error, rawValues) = copyMultiple(element, attributes, options)
        if error == .success {
            return Self(reads: decodeMultiple(rawValues, attributes: attributes))
        }

        guard error == .notImplemented
                || error == .illegalArgument
                || error == .attributeUnsupported else {
            return Self(reads: failedReads(for: attributes))
        }

        var reads: [String: MenuBarAXAttributeRead<CFTypeRef>] = [:]
        reads.reserveCapacity(attributes.count)
        for attribute in attributes {
            guard shouldContinue() else {
                reads[attribute] = .failed
                continue
            }
            let (singleError, value) = copySingle(element, attribute)
            reads[attribute] = decodeSingle(error: singleError, value: value)
        }
        return Self(reads: reads)
    }

    func raw(_ attribute: String) -> MenuBarAXAttributeRead<CFTypeRef> {
        reads[attribute] ?? .failed
    }

    func optionalValue(_ attribute: String) -> CFTypeRef? {
        guard case .value(let value) = raw(attribute) else { return nil }
        return value
    }

    func string(_ attribute: String) -> MenuBarAXAttributeRead<String> {
        Self.string(from: raw(attribute)).read
    }

    func mandatoryString(
        element: AXUIElement,
        attribute: String,
        shouldContinue: () -> Bool = { !Task.isCancelled },
        beforeFallback: () -> Void = {}
    ) -> MenuBarAXMandatoryStringRead {
        mandatoryString(
            element: element,
            attribute: attribute,
            shouldContinue: shouldContinue,
            beforeFallback: beforeFallback,
            copySingle: Self.systemCopySingle
        )
    }

    func mandatoryString(
        element: AXUIElement,
        attribute: String,
        shouldContinue: () -> Bool = { !Task.isCancelled },
        beforeFallback: () -> Void = {},
        copySingle: CopySingle
    ) -> MenuBarAXMandatoryStringRead {
        let bulk = Self.string(from: raw(attribute))
        if case .value(let value) = bulk.read {
            return .batch(value)
        }
        let bulkFailure = bulk.failure ?? .failed
        guard shouldContinue() else {
            return .failed(
                bulkFailure: bulkFailure,
                fallbackFailure: .deadlineExceeded
            )
        }
        beforeFallback()
        guard shouldContinue() else {
            return .failed(
                bulkFailure: bulkFailure,
                fallbackFailure: .deadlineExceeded
            )
        }

        let (error, rawValue) = copySingle(element, attribute)
        guard shouldContinue() else {
            return .failed(
                bulkFailure: bulkFailure,
                fallbackFailure: .deadlineExceeded
            )
        }
        let fallback = Self.string(
            from: Self.decodeSingle(error: error, value: rawValue)
        )
        guard case .value(let value) = fallback.read else {
            return .failed(
                bulkFailure: bulkFailure,
                fallbackFailure: fallback.failure ?? .failed
            )
        }
        return .fallback(value, bulkFailure: bulkFailure)
    }

    func scalarString(_ attribute: String) -> MenuBarAXAttributeRead<String> {
        switch raw(attribute) {
        case .value(let raw):
            if let value = raw as? String {
                let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return clean.isEmpty ? .absent : .value(clean)
            }
            if let value = raw as? NSNumber { return .value(value.stringValue) }
            return .failed
        case .absent:
            return .absent
        case .failed:
            return .failed
        }
    }

    func elements(_ attribute: String) -> MenuBarAXAttributeRead<[AXUIElement]> {
        Self.elements(from: raw(attribute))
    }

    static func freshElements(
        element: AXUIElement,
        attribute: String,
        shouldContinue: () -> Bool = { !Task.isCancelled },
        beforeRead: () -> Void = {}
    ) -> MenuBarAXAttributeRead<[AXUIElement]> {
        freshElements(
            element: element,
            attribute: attribute,
            shouldContinue: shouldContinue,
            beforeRead: beforeRead,
            copySingle: systemCopySingle
        )
    }

    static func freshElements(
        element: AXUIElement,
        attribute: String,
        shouldContinue: () -> Bool = { !Task.isCancelled },
        beforeRead: () -> Void = {},
        copySingle: CopySingle
    ) -> MenuBarAXAttributeRead<[AXUIElement]> {
        guard shouldContinue() else { return .failed }
        beforeRead()
        guard shouldContinue() else { return .failed }
        let (error, rawValue) = copySingle(element, attribute)
        guard shouldContinue() else { return .failed }
        return elements(from: decodeSingle(error: error, value: rawValue))
    }

    private static func elements(
        from read: MenuBarAXAttributeRead<CFTypeRef>
    ) -> MenuBarAXAttributeRead<[AXUIElement]> {
        switch read {
        case .value(let raw):
            guard CFGetTypeID(raw) == CFArrayGetTypeID(),
                  let objects = raw as? [AnyObject] else { return .failed }
            var elements: [AXUIElement] = []
            elements.reserveCapacity(objects.count)
            for object in objects {
                guard CFGetTypeID(object) == AXUIElementGetTypeID() else { return .failed }
                elements.append(unsafeDowncast(object, to: AXUIElement.self))
            }
            return .value(elements)
        case .absent:
            return .absent
        case .failed:
            return .failed
        }
    }

    func geometrySlotShape(
        _ attribute: String,
        expectedType: AXValueType
    ) -> MenuBarContainerGeometrySlotShape {
        switch raw(attribute) {
        case .absent:
            return .absent
        case .failed:
            return .failed
        case .value(let raw):
            guard CFGetTypeID(raw) == AXValueGetTypeID() else { return .wrongType }
            let value = unsafeDowncast(raw, to: AXValue.self)
            return AXValueGetType(value) == expectedType ? .present : .wrongType
        }
    }

    private static func decodeMultiple(
        _ rawValues: CFTypeRef?,
        attributes: [String]
    ) -> [String: MenuBarAXAttributeRead<CFTypeRef>] {
        guard let rawValues,
              CFGetTypeID(rawValues) == CFArrayGetTypeID(),
              let values = rawValues as? [AnyObject],
              values.count == attributes.count else {
            return failedReads(for: attributes)
        }

        var reads: [String: MenuBarAXAttributeRead<CFTypeRef>] = [:]
        reads.reserveCapacity(attributes.count)
        for (attribute, value) in zip(attributes, values) {
            reads[attribute] = decodeSlot(value)
        }
        return reads
    }

    private static func decodeSingle(
        error: AXError,
        value: CFTypeRef?
    ) -> MenuBarAXAttributeRead<CFTypeRef> {
        if error == .attributeUnsupported || error == .noValue { return .absent }
        guard error == .success else { return .failed }
        guard let value else { return .absent }
        return decodeSlot(value)
    }

    private static func string(
        from read: MenuBarAXAttributeRead<CFTypeRef>
    ) -> (
        read: MenuBarAXAttributeRead<String>,
        failure: MenuBarAXMandatoryStringFailure?
    ) {
        switch read {
        case .value(let raw):
            guard let value = raw as? String else {
                return (.failed, .wrongType)
            }
            let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return clean.isEmpty ? (.absent, .absent) : (.value(clean), nil)
        case .absent:
            return (.absent, .absent)
        case .failed:
            return (.failed, .failed)
        }
    }

    private static func decodeSlot(
        _ value: CFTypeRef
    ) -> MenuBarAXAttributeRead<CFTypeRef> {
        if CFGetTypeID(value) == CFNullGetTypeID() { return .absent }
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return .value(value) }

        let axValue = unsafeDowncast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .axError else { return .value(value) }
        var error = AXError.success
        guard AXValueGetValue(axValue, .axError, &error) else { return .failed }
        if error == .attributeUnsupported || error == .noValue { return .absent }
        return .failed
    }

    private static func failedReads(
        for attributes: [String]
    ) -> [String: MenuBarAXAttributeRead<CFTypeRef>] {
        var reads: [String: MenuBarAXAttributeRead<CFTypeRef>] = [:]
        reads.reserveCapacity(attributes.count)
        for attribute in attributes {
            reads[attribute] = .failed
        }
        return reads
    }

    private static func systemCopyMultiple(
        element: AXUIElement,
        attributes: [String],
        options: AXCopyMultipleAttributeOptions
    ) -> (AXError, CFTypeRef?) {
        guard permitsAttributeRead(element) else { return (.cannotComplete, nil) }
        var values: CFArray?
        let error = AXUIElementCopyMultipleAttributeValues(
            element,
            attributes as CFArray,
            options,
            &values
        )
        return (error, values)
    }

    private static func systemCopySingle(
        element: AXUIElement,
        attribute: String
    ) -> (AXError, CFTypeRef?) {
        copyAttributeValue(element: element, attribute: attribute)
    }

    /// Use for direct reads too, so they cannot bypass the self-process fence.
    static func copyAttributeValue(
        element: AXUIElement,
        attribute: String
    ) -> (AXError, CFTypeRef?) {
        guard permitsAttributeRead(element) else { return (.cannotComplete, nil) }
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        )
        return (error, value)
    }
}
