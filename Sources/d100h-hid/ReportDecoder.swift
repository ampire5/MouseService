import MouseContract

/// D100H reports measured over Bluetooth. Keyboard and consumer controls have independent state.
struct ReportDecoder {
    let fourTurnTest: Bool
    private var topButton: D100HButton?
    private var pendingTurn: UInt16?
    private var upperLeftPressed = false
    private var leftPressed = false
    private var rightButton: D100HButton?

    init(fourTurnTest: Bool = false) { self.fourTurnTest = fourTurnTest }

    mutating func consumer(_ usage: UInt16) -> D100HInput? {
        let turn: D100HInput? = switch usage {
        case 0xea: .turn(.left, knobPressed: false)
        case 0xe9: .turn(.right, knobPressed: false)
        case 0x226 where fourTurnTest: .turn(.left, knobPressed: true)
        case 0x2a0 where fourTurnTest: .turn(.right, knobPressed: true)
        default: nil
        }
        if let turn {
            guard usage != pendingTurn else { return nil }
            pendingTurn = usage
            return turn
        }
        if usage == 0, pendingTurn != nil {
            pendingTurn = nil
            return nil
        }
        let button: D100HButton? = switch usage {
        case 0xb6: .topLeft
        case 0xcd: .topMiddle
        case 0xb5: .topRight
        default: nil
        }
        if let button, topButton == nil {
            topButton = button
            return .button(button, pressed: true)
        }
        if usage == 0, let topButton {
            self.topButton = nil
            return .button(topButton, pressed: false)
        }
        return nil
    }

    mutating func keyboard(modifiers: UInt8, keys: ArraySlice<UInt8>) -> [D100HInput] {
        let upperLeft = keys.contains(0x19) && (upperLeftPressed || modifiers == 0x08)
        let left = keys.contains(0x06) && (leftPressed || modifiers == 0x08)
        var events: [D100HInput] = []
        if upperLeft != upperLeftPressed { events.append(.button(.sideUpperLeft, pressed: upperLeft)) }
        if left != leftPressed { events.append(.button(.bottomLeft, pressed: left)) }
        upperLeftPressed = upperLeft
        leftPressed = left

        // Both right side buttons use the Z key. The firmware drops the modifiers before it drops Z.
        if keys.contains(0x1d) {
            if rightButton == nil, modifiers == 0x08 || modifiers == 0x0a {
                let button: D100HButton = modifiers == 0x0a ? .sideUpperRight : .bottomRight
                rightButton = button
                events.append(.button(button, pressed: true))
            }
        } else if let rightButton {
            self.rightButton = nil
            events.append(.button(rightButton, pressed: false))
        }
        return events
    }
}
