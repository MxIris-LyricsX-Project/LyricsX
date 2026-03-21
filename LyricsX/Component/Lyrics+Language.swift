import Foundation
import LyricsXFoundation

extension NSCountedSet {
    fileprivate var mostFrequentElement: Any? {
        var result: (Any?, Int) = (nil, 0)
        for element in self {
            let count = self.count(for: element)
            if count > result.1 {
                result = (element, count)
            }
        }
        return result.0
    }
}

extension Lyrics {
    func recognizeLanguage() {
        var lyricsContent = ""
        var translationContent = ""
        for line in lines {
            lyricsContent += line.content
            if let trans = line.attachments.translation() {
                translationContent += trans
            }
        }
        metadata.language = (lyricsContent as NSString).dominantLanguage
        if let transLan = (translationContent as NSString).dominantLanguage {
            let tag = LyricsLine.Attachments.Tag.translation(languageCode: transLan)
            guard !metadata.attachmentTags.contains(tag) else {
                return
            }
            for idx in lines.indices {
                if let trans = lines[idx].attachments.translation() {
                    lines[idx].attachments[.translation()] = nil
                    lines[idx].attachments[.translation(languageCode: transLan)] = trans
                }
            }
            metadata.attachmentTags.insert(tag)
        }
    }
}
