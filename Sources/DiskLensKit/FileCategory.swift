import Foundation

/// A coarse file type, used for colors, symbols and the type filter.
public enum FileCategory: String, CaseIterable, Sendable, Identifiable {
    case video, audio, image, document, archive, diskImage, app, code, folder, other

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .video: "Video"
        case .audio: "Audio"
        case .image: "Images"
        case .document: "Documents"
        case .archive: "Archives & installers"
        case .diskImage: "Disk images & VMs"
        case .app: "Apps & packages"
        case .code: "Code & developer"
        case .folder: "Folders"
        case .other: "Other"
        }
    }

    public var symbol: String {
        switch self {
        case .video: "film"
        case .audio: "music.note"
        case .image: "photo"
        case .document: "doc.text"
        case .archive: "archivebox"
        case .diskImage: "externaldrive"
        case .app: "app.dashed"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .folder: "folder"
        case .other: "doc"
        }
    }

    private static let byExtension: [String: FileCategory] = {
        var map: [String: FileCategory] = [:]
        func add(_ category: FileCategory, _ list: String) {
            for ext in list.split(separator: " ") { map[String(ext)] = category }
        }
        add(.video, "mov mp4 m4v mkv avi wmv flv webm mpg mpeg mts m2ts 3gp braw r3d mxf prores")
        add(.audio, "mp3 m4a aac wav aif aiff flac alac ogg opus caf m4b m4p aax mid midi wma")
        add(.image, "jpg jpeg png gif heic heif tif tiff bmp raw cr2 cr3 nef arw dng raf orf rw2 psd psb webp svg ico icns exr hdr avif")
        add(.document, "pdf doc docx xls xlsx ppt pptx key pages numbers txt rtf rtfd md csv epub mobi azw3 odt ods odp")
        add(.archive, "zip tar gz tgz bz2 xz 7z rar zst lz4 dmg pkg mpkg xip ipa sit sitx cpgz")
        add(.diskImage, "iso img vmdk vdi vhd vhdx qcow2 hdd pvm utm sparseimage sparsebundle raw asif vmem nvram")
        add(.app, "app appex framework bundle plugin kext prefpane saver xpc photoslibrary musiclibrary tvlibrary fcpbundle logicx band")
        add(.code, "swift m h c cc cpp hpp js ts tsx jsx json py rb go rs java kt o a dylib so class jar xcarchive dsym xcodeproj xcworkspace sqlite db sqlite3 log")
        return map
    }()

    public static func of(name: String, kind: NodeKind) -> FileCategory {
        if kind == .directory { return .folder }
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else {
            return kind == .package ? .app : .other
        }
        let ext = name[name.index(after: dot)...].lowercased()
        return byExtension[ext] ?? (kind == .package ? .app : .other)
    }
}

extension FileTree {
    public func category(_ id: NodeID) -> FileCategory {
        FileCategory.of(name: name(id), kind: kind(id))
    }
}
