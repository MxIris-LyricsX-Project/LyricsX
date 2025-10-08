import OpenCC

extension ChineseConverter {
    static var shared: ChineseConverter? {
        _ = ChineseConverter.observer
        return _shared
    }

    private static var _shared: ChineseConverter?

    private static let observer = defaults.observe(.chineseConversionIndex, options: [.new, .initial]) { _, change in
        switch change.newValue {
        case 1: ChineseConverter._shared = try? ChineseConverter(options: [.simplify])
        case 2: ChineseConverter._shared = try? ChineseConverter(options: [.traditionalize])
        case 3: ChineseConverter._shared = try? ChineseConverter(options: [.traditionalize, .twStandard])
        case 4: ChineseConverter._shared = try? ChineseConverter(options: [.traditionalize, .hkStandard])
        case 0,
             _: ChineseConverter._shared = nil
        }
    }
}
