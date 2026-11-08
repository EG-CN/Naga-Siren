import SwiftUI

// 「深海」主题：深海军蓝画布 + 鲜亮宝蓝主色，全程不透明、无毛玻璃。
// 对齐 Stitch 设计稿（Nocturnal Control v2）：深邃底色、高对比白字、亮蓝点缀。
enum QuietWater{
    static let background=Color(red:0x0D/255,green:0x15/255,blue:0x26/255)
    static let sidebar=Color(red:0x0B/255,green:0x11/255,blue:0x1F/255)
    static let card=Color(red:0x16/255,green:0x21/255,blue:0x38/255)
    static let field=Color(red:0x0F/255,green:0x1A/255,blue:0x2E/255)
    static let hairline=Color(red:0x26/255,green:0x33/255,blue:0x4D/255)
    static let accent=Color(red:0x2E/255,green:0x7C/255,blue:0xE8/255)
    static let accentHover=Color(red:0x24/255,green:0x5F/255,blue:0xC4/255)
    static let accentSoft=Color(red:0xC7/255,green:0xDF/255,blue:0xF2/255)
    static let deep=Color(red:0x1B/255,green:0x3E/255,blue:0x6F/255)
    static let seafoam=Color(red:0x7F/255,green:0xB8/255,blue:0xA6/255)
    static let coral=Color(red:0xD9/255,green:0x8C/255,blue:0x8C/255)
    static let text=Color(red:0xF2/255,green:0xF6/255,blue:0xFB/255)
    static let textSecondary=Color(red:0x8F/255,green:0xA3/255,blue:0xBD/255)
    static let textMuted=Color(red:0x5E/255,green:0x72/255,blue:0x90/255)
    static let onAccent=Color(red:0xFF/255,green:0xFF/255,blue:0xFF/255)
}

// 主按钮：浅水蓝实色填充 + 深海军文字，8px 圆角。
struct WaterPrimaryButtonStyle:ButtonStyle{
    func makeBody(configuration:Configuration)->some View{
        configuration.label
            .font(.callout.weight(.semibold)).foregroundColor(QuietWater.onAccent)
            .padding(.horizontal,12).padding(.vertical,5)
            .background(RoundedRectangle(cornerRadius:8).fill(configuration.isPressed ? QuietWater.accentHover:QuietWater.accent))
    }
}

// 危险按钮：灰珊瑚实色（紧急停止/断开）。
struct WaterDestructiveButtonStyle:ButtonStyle{
    func makeBody(configuration:Configuration)->some View{
        configuration.label
            .font(.callout.weight(.semibold)).foregroundColor(QuietWater.onAccent)
            .padding(.horizontal,12).padding(.vertical,5)
            .background(RoundedRectangle(cornerRadius:8).fill(configuration.isPressed ? QuietWater.coral.opacity(0.8):QuietWater.coral))
    }
}
