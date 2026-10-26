enum MenuBarQuickBarEscapePolicy {
    enum Source { case local, global }
    enum Decision: Equatable { case ignore, dismissAndConsume, dismissAndPassThrough }

    static func decision(keyCode: UInt16, source: Source) -> Decision {
        guard keyCode == 53 else { return .ignore }
        switch source {
        case .local: return .dismissAndConsume
        case .global: return .dismissAndPassThrough
        }
    }
}
