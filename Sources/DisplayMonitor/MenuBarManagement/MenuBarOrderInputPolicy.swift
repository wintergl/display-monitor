/// Input categories needed to stop a menu bar move, without storing key contents.
public enum MenuBarOrderInputKind: String, Sendable {
    case keyDown, modifierChanged, mouseMoved, mouseButton, mouseDragged, scroll
}

public enum MenuBarOrderInputPolicy {
    public static func cancellationReason(
        kind: MenuBarOrderInputKind,
        sourcePID: Int32?,
        userData: Int64?,
        keyCode: UInt16? = nil,
        ownPID: Int32,
        ownTag: Int64
    ) -> String? {
        // Some system-derived events retain only their source PID, not our tag.
        if userData == ownTag || sourcePID == ownPID { return nil }
        switch kind {
        case .modifierChanged:
            // Our Command drag can cause an untagged modifier notification.
            return nil
        case .keyDown:
            return keyCode == 53 ? "按下 Esc，已停止排序" : "检测到键盘输入，已停止排序"
        case .mouseMoved:
            return "检测到鼠标移动，已停止排序"
        case .mouseButton:
            return "检测到鼠标点击，已停止排序"
        case .mouseDragged:
            return "检测到鼠标拖动，已停止排序"
        case .scroll:
            return "检测到滚轮输入，已停止排序"
        }
    }
}
