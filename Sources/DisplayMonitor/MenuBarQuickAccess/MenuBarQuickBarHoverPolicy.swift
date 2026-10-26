enum MenuBarQuickBarHoverPolicy {
    static func shouldPresent(
        enabled: Bool,
        quickBarMode: Bool,
        pointerInside: Bool,
        alreadyVisible: Bool,
        contextMenuOpen: Bool,
        mouseButtonPressed: Bool,
        suppressedUntilExit: Bool
    ) -> Bool {
        enabled && quickBarMode && pointerInside && !alreadyVisible
            && !contextMenuOpen && !mouseButtonPressed && !suppressedUntilExit
    }
}
