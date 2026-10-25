import Foundation
import SQLite3
import ImageIO
import UniformTypeIdentifiers

struct Tone: Identifiable, Hashable, Sendable {
    var id: String, title: String, artist: String, collection: String, category: String, color: String
    var favorite: Bool, duration: Double, start: Double, end: Double, fade: Double, normalize: Bool
    var created: Double, original: String, size: Int64, format: String, peaks: [Double]
    var artwork: String? = nil
    var length: Double { end-start }
}
enum ToneError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text)=self { return text }; return nil }
}
struct AudioExport: Sendable { let file: URL; let count: Int }
final class ToneLibrary: @unchecked Sendable {
    let directory: URL
    private let lock = NSRecursiveLock()
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private var database: OpaquePointer?
    static let extensions = Set(["wav","mp3","m4a","m4r","aac","aiff","aif","flac","ogg","opus","caf"])
    init(directory: URL) throws {
        self.directory=directory
        for folder in ["", "originals", "previews", "exports", "artwork"] { try FileManager.default.createDirectory(at:directory.appendingPathComponent(folder),withIntermediateDirectories:true) }
        guard sqlite3_open(directory.appendingPathComponent("library.sqlite3").path, &database)==SQLITE_OK else { throw ToneError.message("The library could not be opened.") }
        sqlite3_busy_timeout(database,20000)
        try execute("CREATE TABLE IF NOT EXISTS tones(id TEXT PRIMARY KEY,title TEXT,artist TEXT,collection TEXT,category TEXT,color TEXT,favorite INTEGER,duration REAL,start REAL,end REAL,fade REAL,normalize INTEGER,created REAL,original TEXT,size INTEGER,format TEXT,peaks TEXT)")
        try execute("CREATE TABLE IF NOT EXISTS collections(name TEXT PRIMARY KEY)")
        try execute("CREATE TABLE IF NOT EXISTS exports(id TEXT PRIMARY KEY,path TEXT,name TEXT)")
        try execute("CREATE TABLE IF NOT EXISTS artwork(tone_id TEXT PRIMARY KEY,filename TEXT NOT NULL)")
        for name in ["Everyday favorites","After hours","Little notifications"] { try addCollection(name) }
    }
    deinit { sqlite3_close(database) }
    private func statement(_ sql:String,_ values:[Any]=[]) throws -> OpaquePointer {
        var result:OpaquePointer?
        guard sqlite3_prepare_v2(database,sql,-1,&result,nil)==SQLITE_OK,let s=result else { throw ToneError.message("The library database could not complete this action.") }
        for (index,value) in values.enumerated() {
            let i=Int32(index+1)
            if let v=value as? String { sqlite3_bind_text(s,i,v,-1,transient) }
            else if let v=value as? Int { sqlite3_bind_int64(s,i,Int64(v)) }
            else if let v=value as? Int64 { sqlite3_bind_int64(s,i,v) }
            else if let v=value as? Double { sqlite3_bind_double(s,i,v) }
            else if let v=value as? Bool { sqlite3_bind_int(s,i,v ? 1:0) }
        }
        return s
    }
    private func execute(_ sql:String,_ values:[Any]=[]) throws {
        lock.lock();defer{lock.unlock()};let s=try statement(sql,values);defer{sqlite3_finalize(s)}
        guard sqlite3_step(s)==SQLITE_DONE else { throw ToneError.message("This change could not be saved to the library.") }
    }
    private func text(_ s:OpaquePointer,_ i:Int32)->String { guard let p=sqlite3_column_text(s,i) else{return ""};return String(cString:p) }
    func tones() throws -> [Tone] {
        lock.lock();defer{lock.unlock()};let s=try statement("SELECT tones.*,artwork.filename FROM tones LEFT JOIN artwork ON artwork.tone_id=tones.id ORDER BY created DESC");defer{sqlite3_finalize(s)};var result:[Tone]=[]
        while sqlite3_step(s)==SQLITE_ROW {
            let raw=text(s,16).data(using:.utf8) ?? Data();let peaks=(try? JSONDecoder().decode([Double].self,from:raw)) ?? []
            result.append(Tone(id:text(s,0),title:text(s,1),artist:text(s,2),collection:text(s,3),category:text(s,4),color:text(s,5),favorite:sqlite3_column_int(s,6) != 0,duration:sqlite3_column_double(s,7),start:sqlite3_column_double(s,8),end:sqlite3_column_double(s,9),fade:sqlite3_column_double(s,10),normalize:sqlite3_column_int(s,11) != 0,created:sqlite3_column_double(s,12),original:text(s,13),size:sqlite3_column_int64(s,14),format:text(s,15),peaks:peaks,artwork:sqlite3_column_type(s,17)==SQLITE_NULL ? nil:text(s,17)))
        };return result
    }
    func collections() throws -> [String] {
        lock.lock();defer{lock.unlock()};let s=try statement("SELECT name FROM collections ORDER BY name COLLATE NOCASE");defer{sqlite3_finalize(s)};var result:[String]=[]
        while sqlite3_step(s)==SQLITE_ROW { result.append(text(s,0)) };return result
    }
    func addCollection(_ name:String) throws {
        let name=name.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !name.isEmpty,name.count<=150 else {throw ToneError.message("Choose a collection name of 1–150 characters.")}
        try execute("INSERT OR IGNORE INTO collections VALUES(?)",[name])
    }
    func save(_ t:Tone) throws {
        guard [t.start,t.end,t.fade].allSatisfy({$0.isFinite}), t.start>=0,t.end>t.start,t.end<=t.duration+0.01,t.length<=30.001,t.fade>=0,t.fade<=min(3,t.length/2) else {throw ToneError.message("Choose a clip of up to 30 seconds. Fades must fit within half the clip, up to 3 seconds.")}
        guard [t.title,t.artist,t.collection,t.category].allSatisfy({!$0.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && $0.count<=150}) else {throw ToneError.message("Give your tone a title, source, and collection of 1–150 characters.")}
        try addCollection(t.collection)
        try execute("UPDATE tones SET title=?,artist=?,collection=?,category=?,favorite=?,start=?,end=?,fade=?,normalize=? WHERE id=?",[t.title,t.artist,t.collection,t.category,t.favorite,t.start,t.end,t.fade,t.normalize,t.id])
    }
    func originalURL(_ t:Tone)->URL {directory.appendingPathComponent("originals").appendingPathComponent(t.original)}
    func previewURL(_ t:Tone)->URL {directory.appendingPathComponent("previews").appendingPathComponent(t.id+".m4a")}
    func artworkURL(_ t:Tone)->URL? {
        guard let name=t.artwork,!name.isEmpty else{return nil}
        return directory.appendingPathComponent("artwork").appendingPathComponent(name)
    }
    @discardableResult func setArtwork(toneID:String,source:URL) throws -> String {
        guard try tones().contains(where:{$0.id==toneID}) else{throw ToneError.message("Select a tone before choosing artwork.")}
        let size=(try FileManager.default.attributesOfItem(atPath:source.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard size>0,size<=20*1024*1024 else{throw ToneError.message("Choose an image smaller than 20 MB.")}
        guard let input=CGImageSourceCreateWithURL(source as CFURL,nil),
              let properties=CGImageSourceCopyPropertiesAtIndex(input,0,nil) as? [CFString:Any],
              let width=properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height=properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue>0,height.doubleValue>0,width.doubleValue*height.doubleValue<=100_000_000,
              let image=CGImageSourceCreateThumbnailAtIndex(input,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:1024,kCGImageSourceCreateThumbnailWithTransform:true] as CFDictionary)
        else{throw ToneError.message("Choose a valid JPG, PNG, HEIC, TIFF, or another supported image up to 100 megapixels.")}
        let name=UUID().uuidString.lowercased()+".jpg",dest=directory.appendingPathComponent("artwork").appendingPathComponent(name)
        guard let output=CGImageDestinationCreateWithURL(dest as CFURL,UTType.jpeg.identifier as CFString,1,nil) else{throw ToneError.message("The artwork could not be saved.")}
        CGImageDestinationAddImage(output,image,[kCGImageDestinationLossyCompressionQuality:0.9] as CFDictionary)
        guard CGImageDestinationFinalize(output) else{try? FileManager.default.removeItem(at:dest);throw ToneError.message("The artwork could not be saved.")}
        do{try execute("INSERT INTO artwork(tone_id,filename) VALUES(?,?) ON CONFLICT(tone_id) DO UPDATE SET filename=excluded.filename",[toneID,name])}
        catch{try? FileManager.default.removeItem(at:dest);throw error}
        return name
    }
    func removeArtwork(toneID:String) throws {try execute("DELETE FROM artwork WHERE tone_id=?",[toneID])}
    static func tool(_ name:String) throws -> URL {
        for folder in ["/opt/homebrew/bin","/usr/local/bin","/usr/bin"] { let u=URL(fileURLWithPath:folder).appendingPathComponent(name);if FileManager.default.isExecutableFile(atPath:u.path){return u} }
        throw ToneError.message("\(name) is needed for audio conversion. Install FFmpeg with Homebrew, then reopen BickRipassRingtones.")
    }
    @discardableResult static func run(_ executable:URL,_ args:[String]) throws -> Data {
        let process=Process();process.executableURL=executable;process.arguments=args
        let output=Pipe();process.standardOutput=output;process.standardError=FileHandle.nullDevice;process.standardInput=FileHandle.nullDevice
        try process.run()
        let watchdog=DispatchWorkItem {if process.isRunning{process.terminate()}}
        DispatchQueue.global().asyncAfter(deadline:.now()+120,execute:watchdog)
        let data=output.fileHandleForReading.readDataToEndOfFile();process.waitUntilExit();watchdog.cancel()
        guard process.terminationStatus==0 else {throw ToneError.message("This audio could not be processed. Try an unprotected MP3, M4A, or WAV file.")};return data
    }
    @discardableResult func importFile(_ source:URL,collection:String="Everyday favorites") throws -> String {
        let ext=source.pathExtension.lowercased()
        guard Self.extensions.contains(ext) else {throw ToneError.message("Import MP3, M4A, M4R, WAV, AIFF, AAC, FLAC, OGG, OPUS, or CAF audio.")}
        let attributes=try FileManager.default.attributesOfItem(atPath:source.path)
        let size=(attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard size>0,size<=100*1024*1024 else {throw ToneError.message("Choose an audio file smaller than 100 MB.")}
        let id=UUID().uuidString.replacingOccurrences(of:"-",with:"").lowercased()
        let original=directory.appendingPathComponent("originals/\(id).\(ext)")
        let preview=directory.appendingPathComponent("previews/\(id).m4a")
        try FileManager.default.copyItem(at:source,to:original)
        do {
            let data=try Self.run(Self.tool("ffprobe"),["-v","error","-protocol_whitelist","file,pipe","-show_format","-show_streams","-of","json",original.path])
            guard let json=try JSONSerialization.jsonObject(with:data) as? [String:Any],let info=json["format"] as? [String:Any],let duration=Double(info["duration"] as? String ?? ""),duration.isFinite,duration>=0.1,duration<=1800,let streams=json["streams"] as? [[String:Any]],streams.contains(where:{$0["codec_type"] as? String == "audio"}) else {throw ToneError.message("Choose audio between 0.1 seconds and 30 minutes.")}
            let ffmpeg=try Self.tool("ffmpeg")
            try Self.run(ffmpeg,["-v","error","-nostdin","-y","-protocol_whitelist","file,pipe","-i",original.path,"-map","0:a:0","-vn","-c:a","aac","-b:a","128k","-movflags","+faststart",preview.path])
            let raw=try Self.run(ffmpeg,["-v","error","-nostdin","-protocol_whitelist","file,pipe","-i",original.path,"-map","0:a:0","-vn","-ac","1","-ar","2000","-f","s16le","pipe:1"])
            var samples=[Int16](repeating:0,count:raw.count/2);_ = samples.withUnsafeMutableBytes{raw.copyBytes(to:$0)}
            let bucket=max(1,samples.count/160)
            let peaks=stride(from:0,to:samples.count,by:bucket).prefix(160).map { index in Double(samples[index..<min(index+bucket,samples.count)].map{abs(Int($0))}.max() ?? 0)/32768 }
            let tags=info["tags"] as? [String:Any] ?? [:]
            let title=String((tags["title"] as? String ?? source.deletingPathExtension().lastPathComponent).prefix(150))
            let artist=String((tags["artist"] as? String ?? "Imported audio").prefix(150))
            let colors=["violet","coral","mint","blue","rose","amber","indigo","sage"]
            let color=colors[(Int(id.prefix(2),radix:16) ?? 0)%colors.count]
            try addCollection(collection)
            let encoded=String(data:try JSONEncoder().encode(peaks),encoding:.utf8) ?? "[]"
            try execute("INSERT INTO tones VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",[id,title,artist,collection,"Ringtone",color,false,duration,0.0,min(30,duration),min(0.3,duration/2),true,Date().timeIntervalSince1970,original.lastPathComponent,size,ext.uppercased(),encoded])
            // Existing attached cover art is optional; never reject otherwise valid audio.
            if streams.contains(where:{($0["disposition"] as? [String:Any])?["attached_pic"] as? Int == 1}) {
                let extracted=directory.appendingPathComponent("artwork/"+id+"-import.jpg")
                do {
                    if let cover=streams.first(where:{($0["disposition"] as? [String:Any])?["attached_pic"] as? Int == 1}),let stream=cover["index"] as? Int {
                        try Self.run(ffmpeg,["-v","error","-nostdin","-y","-protocol_whitelist","file,pipe","-i",original.path,"-map","0:\(stream)","-frames:v","1","-vf","scale='min(1024,iw)':-1",extracted.path])
                        try setArtwork(toneID:id,source:extracted)
                    }
                }catch{}
                try? FileManager.default.removeItem(at:extracted)
            }
            return id
        }catch{try? FileManager.default.removeItem(at:original);try? FileManager.default.removeItem(at:preview);throw error}
    }
    static func safeName(_ text:String)->String {
        let allowed=CharacterSet.alphanumerics.union(CharacterSet(charactersIn:" .()-_"))
        let result=String(text.unicodeScalars.filter{allowed.contains($0)}).trimmingCharacters(in:CharacterSet(charactersIn:" ."))
        return result.isEmpty ? "Untitled tone":String(result.prefix(100))
    }
    func export(_ tones:[Tone],format:String) throws -> AudioExport {
        guard ["m4r","mp3","wav","original"].contains(format), !tones.isEmpty,tones.count<=100 else {throw ToneError.message("Choose 1–100 tones and a supported export format.")}
        let id=UUID().uuidString.lowercased();let folder=directory.appendingPathComponent("exports/"+id)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        var files:[URL]=[]
        do {
            for (index,t) in tones.enumerated() {
                let ext=format == "original" ? URL(fileURLWithPath:t.original).pathExtension:format
                var name=Self.safeName(t.title)+"."+ext
                if files.contains(where:{$0.lastPathComponent==name}){name=Self.safeName(t.title)+" (\(index+1))."+ext}
                let dest=folder.appendingPathComponent(name)
                if format == "original" {try FileManager.default.copyItem(at:originalURL(t),to:dest)}
                else {
                    guard t.length>0,t.length<=30.001 else {throw ToneError.message("Save a clip of up to 30 seconds before exporting.")}
                    let cover=(format=="m4r" || format=="mp3") ? artworkURL(t):nil
                    var args=["-v","error","-nostdin","-y","-protocol_whitelist","file,pipe","-ss",String(t.start),"-i",originalURL(t).path]
                    if let cover=cover {
                        args += ["-i",cover.path,"-t",String(t.length),"-map","0:a:0","-map","1:v:0","-c:v","copy","-disposition:v:0","attached_pic","-metadata:s:v:0","title=Album cover","-metadata:s:v:0","comment=Cover (front)"]
                    }else{args += ["-t",String(t.length),"-map","0:a:0","-vn"]}
                    var filters:[String]=[]
                    if t.normalize{filters.append("loudnorm=I=-16:TP=-1.5:LRA=11")}
                    let fade=min(t.fade,t.length/2)
                    if fade>0{filters += ["afade=t=in:st=0:d=\(fade)","afade=t=out:st=\(max(0,t.length-fade)):d=\(fade)"]}
                    if !filters.isEmpty{args += ["-af",filters.joined(separator:",")]}
                    args += ["-ar","44100","-ac","2","-metadata","title="+t.title,"-metadata","artist="+t.artist]
                    switch format {case "m4r":args += ["-c:a","aac","-b:a","256k","-f","ipod"];case "mp3":args += ["-c:a","libmp3lame","-b:a","256k","-id3v2_version","3"];default:args += ["-c:a","pcm_s16le"]}
                    try Self.run(Self.tool("ffmpeg"),args+[dest.path])
                };files.append(dest)
            }
            let result:URL
            if files.count==1{result=files[0]}else{
                result=folder.appendingPathComponent("BickRipassRingtones collection.zip")
                try Self.run(URL(fileURLWithPath:"/usr/bin/zip"),["-j","-q",result.path]+files.map(\.path))
            }
            try execute("INSERT INTO exports VALUES(?,?,?)",[id,"exports/"+id+"/"+result.lastPathComponent,result.lastPathComponent])
            return AudioExport(file:result,count:files.count)
        }catch{try? FileManager.default.removeItem(at:folder);throw error}
    }
}
