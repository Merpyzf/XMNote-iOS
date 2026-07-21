import Foundation

/**
 * [INPUT]: 依赖 Foundation 基础值类型与 ReadCalendarMonthData 月度聚合模型
 * [OUTPUT]: 对外提供阅读日历分享类型、48 套 Android 同源模板与年度分享快照
 * [POS]: Domain 层阅读日历分享领域模型，供分享 ViewModel 与渲染视图共同消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/// 阅读日历分享卡类型，与 Android 的年度热力图、月活动和月封面三种成品一致。
nonisolated enum ReadCalendarShareType: String, CaseIterable, Identifiable, Hashable {
    case yearHeatmap
    case monthEvent
    case monthCover

    var id: String { rawValue }

    var title: String {
        switch self {
        case .yearHeatmap: "年度热力图"
        case .monthEvent: "月度活动"
        case .monthCover: "月度书单"
        }
    }
}

/// 分享卡配色；RGBA 使用 Android 端模板的原始色值，避免跨端视觉漂移。
nonisolated struct ReadCalendarSharePalette: Hashable {
    let backgroundARGB: UInt32
    let accentARGB: UInt32
}

/// Android 同源分享模板目录；免费模板固定为前五套基础色与“青磁纸”。
nonisolated enum ReadCalendarShareTemplate: String, CaseIterable, Identifiable, Hashable {
    case pureWhite = "PURE_WHITE"
    case gofun = "NIPPON_01_GOFUN"
    case shironezumi = "NIPPON_02_SHIRONEZUMI"
    case ginnezumi = "NIPPON_03_GINNEZUMI"
    case shirotsurubami = "NIPPON_04_SHIROTSURUBAMI"
    case rikyushiracha = "NIPPON_05_RIKYUSHIRACHA"
    case sunezumi = "NIPPON_08_SUNEZUMI"
    case shiracha = "NIPPON_13_SHIRACHA"
    case kuchiba = "NIPPON_16_KUCHIBA"
    case tamago = "NIPPON_20_TAMAGO"
    case hanaba = "NIPPON_21_HANABA"
    case yamabuki = "NIPPON_23_YAMABUKI"
    case karashi = "NIPPON_24_KARASHI"
    case sakura = "NIPPON_25_SAKURA"
    case haizakura = "NIPPON_26_HAIZAKURA"
    case toki = "NIPPON_27_TOKI"
    case benifuji = "NIPPON_28_BENIFUJI"
    case mizugaki = "NIPPON_29_MIZUGAKI"
    case urayanagi = "NIPPON_32_URAYANAGI"
    case byakuroku = "NIPPON_33_BYAKUROKU"
    case sabiseiji = "NIPPON_35_SABISEIJI"
    case matsuba = "NIPPON_36_MATSUBA"
    case aoni = "NIPPON_37_AONI"
    case rokusyoh = "NIPPON_39_ROKUSYOH"
    case kamenozoki = "NIPPON_40_KAMENOZOKI"
    case byakugun = "NIPPON_41_BYAKUGUN"
    case mizuasagi = "NIPPON_42_MIZUASAGI"
    case asagi = "NIPPON_43_ASAGI"
    case shinbashi = "NIPPON_44_SHINBASHI"
    case noshimehana = "NIPPON_45_NOSHIMEHANA"
    case hanada = "NIPPON_46_HANADA"
    case ai = "NIPPON_47_AI"
    case fujinezumi = "NIPPON_49_FUJINEZUMI"
    case fuji = "NIPPON_50_FUJI"
    case shion = "NIPPON_51_SHION"
    case kikyo = "NIPPON_52_KIKYO"
    case edomurasaki = "NIPPON_53_EDOMURASAKI"
    case sumi = "NIPPON_56_SUMI"
    case kon = "NIPPON_59_KON"
    case shironeriPaper = "SHIRONERI_PAPER"
    case torinokoPaper = "TORINOKO_PAPER"
    case usukohPaper = "USUKOH_PAPER"
    case seijiPaper = "SEIJI_PAPER"
    case mizuBluePaper = "MIZU_BLUE_PAPER"
    case wakakusaPaper = "WAKAKUSA_PAPER"
    case momoAozumi = "MOMO_AOZUMI"
    case gunjoShuin = "GUNJO_SHUIN"
    case seihekiShusha = "SEIHEKI_SHUSHA"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pureWhite: "纯白"
        case .gofun: "胡粉"
        case .shironezumi: "白鼠"
        case .ginnezumi: "银鼠"
        case .shirotsurubami: "白橡"
        case .rikyushiracha: "利休白茶"
        case .sunezumi: "素鼠"
        case .shiracha: "白茶"
        case .kuchiba: "朽叶"
        case .tamago: "玉子"
        case .hanaba: "花叶"
        case .yamabuki: "山吹"
        case .karashi: "芥子"
        case .sakura: "樱"
        case .haizakura: "灰樱"
        case .toki: "朱鹭"
        case .benifuji: "红藤"
        case .mizugaki: "水柿"
        case .urayanagi: "里柳"
        case .byakuroku: "白绿"
        case .sabiseiji: "锈青磁"
        case .matsuba: "松叶"
        case .aoni: "青丹"
        case .rokusyoh: "绿青"
        case .kamenozoki: "瓶窥"
        case .byakugun: "白群"
        case .mizuasagi: "水浅葱"
        case .asagi: "浅葱"
        case .shinbashi: "新桥"
        case .noshimehana: "熨斗目花"
        case .hanada: "缥"
        case .ai: "蓝"
        case .fujinezumi: "藤鼠"
        case .fuji: "藤"
        case .shion: "紫苑"
        case .kikyo: "桔梗"
        case .edomurasaki: "江户紫"
        case .sumi: "墨"
        case .kon: "绀"
        case .shironeriPaper: "白练纸"
        case .torinokoPaper: "鸟之子纸"
        case .usukohPaper: "薄香纸"
        case .seijiPaper: "青磁纸"
        case .mizuBluePaper: "水蓝纸"
        case .wakakusaPaper: "若草纸"
        case .momoAozumi: "桃青墨"
        case .gunjoShuin: "群青朱印"
        case .seihekiShusha: "青碧朱砂"
        }
    }

    var isFree: Bool {
        switch self {
        case .pureWhite, .gofun, .shironezumi, .ginnezumi, .shirotsurubami, .seijiPaper: true
        default: false
        }
    }

    var palette: ReadCalendarSharePalette {
        let colors: (UInt32, UInt32)
        switch self {
        case .pureWhite: colors = (0xFFFFFFFF, 0xFF376B6D)
        case .gofun: colors = (0xFFFFFFFB, 0xFF255359)
        case .shironezumi: colors = (0xFFF3F4F1, 0xFF7D8580)
        case .ginnezumi: colors = (0xFFECEFF1, 0xFF6F7881)
        case .shirotsurubami: colors = (0xFFF5E8CF, 0xFF8A6A2E)
        case .rikyushiracha: colors = (0xFFEFE7D7, 0xFF7E745B)
        case .sunezumi: colors = (0xFFDADDD9, 0xFF5F6864)
        case .shiracha: colors = (0xFFEFE3D2, 0xFF8C6F49)
        case .kuchiba: colors = (0xFFF1D1A3, 0xFFA86424)
        case .tamago: colors = (0xFFFFF1C7, 0xFFB77A16)
        case .hanaba: colors = (0xFFFFF0BA, 0xFFB48113)
        case .yamabuki: colors = (0xFFFFE6A3, 0xFFC98200)
        case .karashi: colors = (0xFFEFE2BA, 0xFF8A742E)
        case .sakura: colors = (0xFFFFF0F1, 0xFFC96F7E)
        case .haizakura: colors = (0xFFEDE0DA, 0xFF9C8178)
        case .toki: colors = (0xFFF8DAD7, 0xFFC66D6D)
        case .benifuji: colors = (0xFFEAD6EE, 0xFF8A5795)
        case .mizugaki: colors = (0xFFE8D0C8, 0xFF9B675B)
        case .urayanagi: colors = (0xFFEDF3E6, 0xFF7F9A6B)
        case .byakuroku: colors = (0xFFE6F6EC, 0xFF4F9E74)
        case .sabiseiji: colors = (0xFFD7E6E0, 0xFF688C7C)
        case .matsuba: colors = (0xFFD3DDC8, 0xFF42602D)
        case .aoni: colors = (0xFFDCE6D4, 0xFF516E41)
        case .rokusyoh: colors = (0xFFD6EFE5, 0xFF24936E)
        case .kamenozoki: colors = (0xFFE8F7F9, 0xFF4D9CAB)
        case .byakugun: colors = (0xFFDFF2F3, 0xFF3E9093)
        case .mizuasagi: colors = (0xFFD9F0EF, 0xFF3E918E)
        case .asagi: colors = (0xFFD8EEF2, 0xFF1887A0)
        case .shinbashi: colors = (0xFFD7EDF3, 0xFF0089A7)
        case .noshimehana: colors = (0xFF2B5F75, 0xFFA7D8E0)
        case .hanada: colors = (0xFF006284, 0xFFB5E3EF)
        case .ai: colors = (0xFF0D5661, 0xFFA8DCD8)
        case .fujinezumi: colors = (0xFFE3E5F1, 0xFF6E75A4)
        case .fuji: colors = (0xFFE9E5F6, 0xFF8B81C3)
        case .shion: colors = (0xFFE9E1F2, 0xFF8F77B5)
        case .kikyo: colors = (0xFFDED7EE, 0xFF6A4C9C)
        case .edomurasaki: colors = (0xFF77428D, 0xFFE2B8EA)
        case .sumi: colors = (0xFF1C1C1C, 0xFFD8C58F)
        case .kon: colors = (0xFF0F2540, 0xFF90B7D8)
        case .shironeriPaper: colors = (0xFFFCFAF2, 0xFF376B6D)
        case .torinokoPaper: colors = (0xFFF3E8CA, 0xFF255359)
        case .usukohPaper: colors = (0xFFF7D7AA, 0xFF376B6D)
        case .seijiPaper: colors = (0xFFE7F0EC, 0xFF376B6D)
        case .mizuBluePaper: colors = (0xFFEAF4F7, 0xFF2E5C6E)
        case .wakakusaPaper: colors = (0xFFEEF5D8, 0xFF465D4C)
        case .momoAozumi: colors = (0xFFFFE8DD, 0xFF0C4842)
        case .gunjoShuin: colors = (0xFFF6F0E6, 0xFFD84A36)
        case .seihekiShusha: colors = (0xFFDFF3F0, 0xFFD7543F)
        }
        return ReadCalendarSharePalette(backgroundARGB: colors.0, accentARGB: colors.1)
    }
}

/// 分享页加载快照，月卡与年度热力图均只依赖 Repository 产出的稳定数据。
nonisolated struct ReadCalendarShareSnapshot: Hashable {
    let selectedMonth: Date
    let monthData: ReadCalendarMonthData
    let yearMonths: [ReadCalendarMonthData]
}
