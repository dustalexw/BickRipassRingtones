import Foundation
import SQLite3

/// Resolve only explicit, valid libraries. A missing portable folder requires recovery,
/// rather than silently making a new empty collection.
enum LibraryLocation {
    enum Resolution:Equatable {
        case ready(URL)
        case needsRecovery
        static func ==(lhs:Resolution,rhs:Resolution)->Bool {
            switch(lhs,rhs){
            case (.ready(let a),.ready(let b)):return a.standardizedFileURL.path==b.standardizedFileURL.path
            case (.needsRecovery,.needsRecovery):return true
            default:return false
            }
        }
    }
    static func existingLibrary(at url:URL?) -> URL? {
        guard let url=url else{return nil}
        let folder=url.pathExtension=="sqlite3" ? url.deletingLastPathComponent():url
        for candidate in [folder,folder.appendingPathComponent("Library",isDirectory:true)] {
            let db=candidate.appendingPathComponent("library.sqlite3")
            guard FileManager.default.fileExists(atPath:db.path) else{continue}
            var connection:OpaquePointer?
            guard sqlite3_open_v2(db.path,&connection,SQLITE_OPEN_READONLY,nil)==SQLITE_OK else{sqlite3_close(connection);continue}
            var statement:OpaquePointer?
            let prepared=sqlite3_prepare_v2(connection,"SELECT id FROM tones LIMIT 1",-1,&statement,nil)==SQLITE_OK
            sqlite3_finalize(statement);sqlite3_close(connection)
            if prepared{return candidate.standardizedFileURL}
        }
        return nil
    }
    static func resolve(bundleURL:URL,portable:Bool,configured:String?,remembered:URL?,defaultDirectory:URL)->Resolution {
        let adjacent=bundleURL.deletingLastPathComponent().appendingPathComponent("Library",isDirectory:true)
        let candidates=[remembered,portable ? adjacent:nil,configured.map{URL(fileURLWithPath:$0)},portable ? nil:defaultDirectory]
        for candidate in candidates {if let library=existingLibrary(at:candidate){return .ready(library)}}
        if portable || configured != nil{return .needsRecovery}
        return .ready(defaultDirectory)
    }
    static let bookmarkKey="SelectedLibraryBookmark"
    static let pathKey="SelectedLibraryDirectory"
    static func remember(_ url:URL,defaults:UserDefaults = .standard) {
        defaults.set(url.path,forKey:pathKey)
        if let bookmark=try? url.bookmarkData(options:.minimalBookmark,includingResourceValuesForKeys:nil,relativeTo:nil){defaults.set(bookmark,forKey:bookmarkKey)}
        else{defaults.removeObject(forKey:bookmarkKey)}
    }
    static func remembered(defaults:UserDefaults = .standard)->URL? {
        if let data=defaults.data(forKey:bookmarkKey) {
            var stale=false
            if let url=try? URL(resolvingBookmarkData:data,options:[.withoutUI,.withoutMounting],relativeTo:nil,bookmarkDataIsStale:&stale),let library=existingLibrary(at:url){if stale{remember(library,defaults:defaults)};return library}
        }
        return existingLibrary(at:defaults.string(forKey:pathKey).map{URL(fileURLWithPath:$0)})
    }
}
