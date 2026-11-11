import AppKit

protocol DragNDropDelegate: AnyObject {
    func dragFinished(content: String, filePath: String?)
}

class DragNDropView: NSView {
    weak var dragDelegate: DragNDropDelegate?

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.string, .fileNames])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        return .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pboard = sender.draggingPasteboard

        if pboard.types?.contains(.string) == true,
           let str = pboard.string(forType: .string) {
            dragDelegate?.dragFinished(content: str, filePath: nil)
            return true
        }

        do {
            if pboard.types?.contains(.fileNames) == true,
               let files = pboard.propertyList(forType: .fileNames) as? [Any],
               let path = files.first as? String {
                let str = try String(contentsOf: URL(fileURLWithPath: path))
                dragDelegate?.dragFinished(content: str, filePath: path)
                return true
            } else {
                let errorInfo = [
                    NSLocalizedDescriptionKey: "Fail to import lyrics",
                    NSLocalizedFailureReasonErrorKey: "The file couldn’t be opened.",
                ]
                let error = NSError(domain: lyricsXErrorDomain, code: 0, userInfo: errorInfo)
                throw error
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
            return false
        }
    }
}

extension NSPasteboard.PasteboardType {
    static let fileNames = NSPasteboard.PasteboardType("NSFilenamesPboardType")
}
