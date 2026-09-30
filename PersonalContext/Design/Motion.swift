import SwiftUI

enum Motion {
    static let snappy = Animation.snappy(duration: 0.28)
    static let quick = Animation.easeOut(duration: 0.16)
    static let smooth = Animation.smooth(duration: 0.35)
    static let hover = Animation.easeOut(duration: 0.12)
}
