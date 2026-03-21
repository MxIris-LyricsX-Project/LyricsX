import AppKit

class PreferenceFilterViewController: PreferenceViewController {
    @objc dynamic var directFilter = [FilterKey]()

    override func viewDidLoad() {
        super.viewDidLoad()

        loadFilter()
    }

    override func viewWillDisappear() {
        saveFilter()
    }

    func loadFilter() {
        directFilter = defaults[.lyricsFilterKeys].map {
            FilterKey(keyword: $0)
        }
    }

    func saveFilter() {
        defaults[.lyricsFilterKeys] = directFilter.map { $0.keyword }
    }

    @IBAction func resetFilterKey(_ sender: Any) {
        defaults.remove(.lyricsFilterKeys)
        loadFilter()
    }
}

@objc(FilterKey)
class FilterKey: NSObject, NSCoding {
    @objc var keyword = "keyword"

    override init() {
        super.init()
    }

    init(keyword: String) {
        self.keyword = keyword
        super.init()
    }

    required init?(coder aDecoder: NSCoder) {
        guard let decodeKey = aDecoder.decodeObject(forKey: "keyword") as? String else {
            return nil
        }
        self.keyword = decodeKey
        super.init()
    }

    func encode(with aCoder: NSCoder) {
        aCoder.encode(keyword, forKey: "keyword")
    }
}
