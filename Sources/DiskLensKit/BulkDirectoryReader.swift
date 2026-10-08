import Darwin

/// One entry of a directory, as `getattrlistbulk(2)` reports it.
struct BulkEntry {
    enum Kind: UInt8 { case file, directory, symlink, other }

    var name: String
    var kind: Kind
    /// Bytes on disk (what `du` counts). Zero for directories and for iCloud files that
    /// aren't downloaded.
    var allocated: Int64
    /// The file's listed size.
    var logical: Int64
    var modified: UInt32
    var accessed: UInt32
    var inode: UInt64
    var linkCount: UInt32
    /// BSD file flags (`st_flags`): SF_RESTRICTED, SF_DATALESS, UF_IMMUTABLE…
    var bsdFlags: UInt32
    var isMountPoint: Bool
    /// Set by the scanner: another link to a file already counted.
    var isHardLinkDuplicate = false
}

/// Reads whole directories with `getattrlistbulk`, which returns every entry's
/// attributes in a few syscalls instead of one `stat` per file.
/// Not thread-safe: each scanning thread owns one.
final class BulkDirectoryReader {
    enum ReadError: Error { case open(Int32), read(Int32) }

    private let bufferSize = 256 * 1024
    private let buffer: UnsafeMutableRawPointer

    init() {
        buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
    }

    deinit { buffer.deallocate() }

    /// Calls `body` for each entry of the directory at `path`. Symlinks are reported, not followed.
    func read(_ path: String, _ body: (BulkEntry) -> Void) throws(ReadError) {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw .open(errno) }
        defer { close(fd) }

        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_NAME)
            | attrgroup_t(ATTR_CMN_ERROR) | attrgroup_t(ATTR_CMN_OBJTYPE)
            | attrgroup_t(ATTR_CMN_MODTIME) | attrgroup_t(ATTR_CMN_ACCTIME)
            | attrgroup_t(ATTR_CMN_FLAGS) | attrgroup_t(ATTR_CMN_FILEID)
        request.dirattr = attrgroup_t(ATTR_DIR_MOUNTSTATUS)
        request.fileattr = attrgroup_t(ATTR_FILE_LINKCOUNT) | attrgroup_t(ATTR_FILE_TOTALSIZE)
            | attrgroup_t(ATTR_FILE_ALLOCSIZE)

        while true {
            let count = getattrlistbulk(fd, &request, buffer, bufferSize, 0)
            if count == 0 { return }
            if count < 0 { throw .read(errno) }
            var entryStart = UnsafeRawPointer(buffer)
            for _ in 0..<Int(count) {
                let length = entryStart.loadUnaligned(as: UInt32.self)
                if let entry = Self.parse(entryStart) { body(entry) }
                entryStart += Int(length)
            }
        }
    }

    /// Attributes come back in bitmap order, and only those listed in the entry's
    /// returned-attributes set are present.
    private static func parse(_ start: UnsafeRawPointer) -> BulkEntry? {
        var p = start + 4
        let returned = p.loadUnaligned(as: attribute_set_t.self)
        p += MemoryLayout<attribute_set_t>.size
        let common = returned.commonattr

        if common & attrgroup_t(ATTR_CMN_ERROR) != 0 {
            let error = p.loadUnaligned(as: UInt32.self)
            p += 4
            if error != 0 { return nil }
        }
        guard common & attrgroup_t(ATTR_CMN_NAME) != 0 else { return nil }
        let nameRef = p.loadUnaligned(as: attrreference_t.self)
        let name = String(cString: (p + Int(nameRef.attr_dataoffset)).assumingMemoryBound(to: CChar.self))
        p += MemoryLayout<attrreference_t>.size

        var entry = BulkEntry(name: name, kind: .other, allocated: 0, logical: 0, modified: 0,
                              accessed: 0, inode: 0, linkCount: 1, bsdFlags: 0, isMountPoint: false)
        if common & attrgroup_t(ATTR_CMN_OBJTYPE) != 0 {
            switch p.loadUnaligned(as: UInt32.self) {
            case UInt32(VREG.rawValue): entry.kind = .file
            case UInt32(VDIR.rawValue): entry.kind = .directory
            case UInt32(VLNK.rawValue): entry.kind = .symlink
            default: entry.kind = .other
            }
            p += 4
        }
        if common & attrgroup_t(ATTR_CMN_MODTIME) != 0 {
            entry.modified = clampedSeconds(p.loadUnaligned(as: timespec.self))
            p += MemoryLayout<timespec>.size
        }
        if common & attrgroup_t(ATTR_CMN_ACCTIME) != 0 {
            entry.accessed = clampedSeconds(p.loadUnaligned(as: timespec.self))
            p += MemoryLayout<timespec>.size
        }
        if common & attrgroup_t(ATTR_CMN_FLAGS) != 0 {
            entry.bsdFlags = p.loadUnaligned(as: UInt32.self)
            p += 4
        }
        if common & attrgroup_t(ATTR_CMN_FILEID) != 0 {
            entry.inode = p.loadUnaligned(as: UInt64.self)
            p += 8
        }
        if returned.dirattr & attrgroup_t(ATTR_DIR_MOUNTSTATUS) != 0 {
            entry.isMountPoint = p.loadUnaligned(as: UInt32.self) & UInt32(DIR_MNTSTATUS_MNTPOINT) != 0
            p += 4
        }
        let file = returned.fileattr
        if file & attrgroup_t(ATTR_FILE_LINKCOUNT) != 0 {
            entry.linkCount = p.loadUnaligned(as: UInt32.self)
            p += 4
        }
        if file & attrgroup_t(ATTR_FILE_TOTALSIZE) != 0 {
            entry.logical = p.loadUnaligned(as: Int64.self)
            p += 8
        }
        if file & attrgroup_t(ATTR_FILE_ALLOCSIZE) != 0 {
            entry.allocated = p.loadUnaligned(as: Int64.self)
            p += 8
        }
        return entry
    }

    private static func clampedSeconds(_ ts: timespec) -> UInt32 {
        UInt32(clamping: max(0, ts.tv_sec))
    }
}
