import Cocoa

/// 剪贴板全保真快照（审计 H10）：备份所有 pasteboard item 的全部类型数据，
/// 恢复时逐类型写回 —— 旧实现仅存纯文本，图片/文件等格式在恢复时永久丢失。
///
/// 局限：延迟提供（promised）的类型无即时数据，无法快照；此类内容恢复时丢失。
struct PasteboardSnapshot {
    private let items: [[NSPasteboard.PasteboardType: Data]]

    init(_ pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    dict[type] = data
                }
            }
            return dict
        }
    }

    var isEmpty: Bool { items.allSatisfy(\.isEmpty) }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !isEmpty else { return }
        let pbItems = items.map { dict -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in dict {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(pbItems)
    }
}