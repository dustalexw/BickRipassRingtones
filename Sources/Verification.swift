import Foundation

final class VerificationDefaults:UserDefaults {
    private var values:[String:Any]=[:]
    override func set(_ value:Any?,forKey key:String){values[key]=value}
    override func string(forKey key:String)->String?{values[key] as? String}
    override func data(forKey key:String)->Data?{values[key] as? Data}
    override func removeObject(forKey key:String){values.removeValue(forKey:key)}
}

@MainActor func verifyNativeLibrary() throws {
    guard let index=CommandLine.arguments.firstIndex(of:"--verify"),CommandLine.arguments.count>index+1 else{throw ToneError.message("Pass a scratch directory after --verify.")}
    let directory=URL(fileURLWithPath:CommandLine.arguments[index+1]);let fm=FileManager.default
    guard !fm.fileExists(atPath:directory.path) else{throw ToneError.message("Verification needs a new scratch directory.")}
    let library=try ToneLibrary(directory:directory)
    let fixture=directory.appendingPathComponent("verification.wav")
    try ToneLibrary.run(ToneLibrary.tool("ffmpeg"),["-v","error","-f","lavfi","-i","sine=frequency=440:duration=3","-c:a","pcm_s16le",fixture.path])
    let original=try Data(contentsOf:fixture)
    let id=try library.importFile(fixture)
    guard var tone=try library.tones().first,tone.id==id,try Data(contentsOf:library.originalURL(tone))==original else{throw ToneError.message("Original preservation failed.")}
    tone.start=0.5;tone.end=2;tone.fade=0.1;tone.favorite=true;tone.title="Native / verification";try library.save(tone)
    let cover=directory.appendingPathComponent("cover.png")
    try ToneLibrary.run(ToneLibrary.tool("ffmpeg"),["-v","error","-f","lavfi","-i","color=c=purple:s=64x64","-frames:v","1",cover.path])
    let firstCover=try library.setArtwork(toneID:id,source:cover)
    let replacement=try library.setArtwork(toneID:id,source:cover)
    guard firstCover != replacement else{throw ToneError.message("Artwork replacement failed.")}
    tone=try library.tones().first(where:{$0.id==id})!
    guard tone.artwork==replacement,let coverURL=library.artworkURL(tone) else{throw ToneError.message("Artwork persistence failed.")}
    let expectedCover=try Data(contentsOf:coverURL)
    let badImage=directory.appendingPathComponent("invalid.jpg");try Data("invalid image".utf8).write(to:badImage)
    do{try library.setArtwork(toneID:id,source:badImage);throw ToneError.message("Invalid image accepted.")}catch ToneError.message(let text){guard text != "Invalid image accepted." else{throw ToneError.message(text)}}
    for format in ["m4r","mp3","wav"]{
        let exported=try library.export([tone],format:format)
        let raw=try ToneLibrary.run(ToneLibrary.tool("ffprobe"),["-v","error","-show_format","-show_streams","-of","json",exported.file.path])
        let meta=try JSONSerialization.jsonObject(with:raw) as! [String:Any]
        let duration=Double((meta["format"] as! [String:Any])["duration"] as! String)!
        guard abs(duration-1.5)<0.1 else{throw ToneError.message("Export duration failed.")}
        if format=="m4r"{guard (meta["streams"] as! [[String:Any]])[0]["codec_name"] as? String=="aac" else{throw ToneError.message("M4R AAC encoding failed.")}}
        let streams=meta["streams"] as! [[String:Any]]
        let attached=streams.filter{($0["disposition"] as? [String:Any])?["attached_pic"] as? Int == 1}
        if format=="m4r" || format=="mp3" {
            guard attached.count==1 else{throw ToneError.message("Embedded artwork missing from \(format).")}
            let image=try ToneLibrary.run(ToneLibrary.tool("ffmpeg"),["-v","error","-i",exported.file.path,"-map","0:v:0","-c:v","copy","-frames:v","1","-f","image2pipe","pipe:1"])
            guard image==expectedCover else{throw ToneError.message("Embedded artwork does not match the chosen image.")}
            let imported=try library.importFile(exported.file)
            guard try library.tones().first(where:{$0.id==imported})?.artwork != nil else{throw ToneError.message("Artwork was not restored on re-import.")}
        }else{guard attached.isEmpty else{throw ToneError.message("Unexpected artwork stream in WAV.")}}

    }
    let unprocessed=try library.export([tone],format:"original")
    guard try Data(contentsOf:unprocessed.file)==original else{throw ToneError.message("Original export failed.")}
    var invalid=tone;invalid.end=9
    do {try library.save(invalid);throw ToneError.message("Invalid trim accepted.")}catch ToneError.message(let text){guard text != "Invalid trim accepted." else{throw ToneError.message(text)}}
    let second=try library.importFile(fixture)
    var other=try library.tones().first(where:{$0.id==second})!;other.title=tone.title;try library.save(other)
    let archive=try library.export([tone,other],format:"m4r")
    let names=String(data:try ToneLibrary.run(URL(fileURLWithPath:"/usr/bin/unzip"),["-Z1",archive.file.path]),encoding:.utf8)!.split(separator:"\n")
    guard names.count==2,Set(names).count==2 else{throw ToneError.message("Batch ZIP filename check failed.")}
    let model=LibraryModel(library:library)
    model.selection=[id]
    guard model.editing?.id==id else{throw ToneError.message("Inspector selection failed.")}
    if let covered=try library.tones().first(where:{$0.artwork != nil}) {
        model.selection=[covered.id]
        guard model.editing?.id==covered.id,model.editing?.artwork==covered.artwork else{throw ToneError.message("Artwork inspector did not follow selection.")}
    }else{throw ToneError.message("Missing covered tone for selection check.")}
    let reopened=try ToneLibrary(directory:directory)
    guard try reopened.tones().first(where:{$0.id==id})?.favorite==true else{throw ToneError.message("Persistence check failed.")}
    guard try reopened.tones().first(where:{$0.id==id})?.artwork==replacement else{throw ToneError.message("Artwork was lost when reopening the library.")}
    try library.removeArtwork(toneID:id)
    guard try library.tones().first(where:{$0.id==id})?.artwork==nil else{throw ToneError.message("Artwork removal failed.")}
    // Simulate another Mac and a translocated launch path; no local machine paths.
    let fakeBundle=directory.appendingPathComponent("private/AppTranslocation/random/d/BickRipassRingtones.app")
    let freshDefault=directory.appendingPathComponent("AnotherMac/Application Support/BickRipassRingtones")
    guard LibraryLocation.resolve(bundleURL:fakeBundle,portable:true,configured:nil,remembered:nil,defaultDirectory:freshDefault) == .needsRecovery else{throw ToneError.message("Missing adjacent library did not offer recovery.")}
    guard !fm.fileExists(atPath:freshDefault.path) else{throw ToneError.message("Recovery silently created an empty library.")}
    guard LibraryLocation.resolve(bundleURL:fakeBundle,portable:true,configured:nil,remembered:directory,defaultDirectory:freshDefault) == .ready(directory.standardizedFileURL) else{throw ToneError.message("Remembered library failed after simulated translocation.")}
    let enclosing=directory.appendingPathComponent("Unzipped release")
    let adjacent=enclosing.appendingPathComponent("Library")
    try fm.createDirectory(at:adjacent,withIntermediateDirectories:true)
    try fm.copyItem(at:directory.appendingPathComponent("library.sqlite3"),to:adjacent.appendingPathComponent("library.sqlite3"))
    guard LibraryLocation.existingLibrary(at:enclosing)?.path==adjacent.standardizedFileURL.path else{throw ToneError.message("Unzipped-folder selection was not recognized.")}
    guard LibraryLocation.resolve(bundleURL:enclosing.appendingPathComponent("BickRipassRingtones.app"),portable:true,configured:nil,remembered:nil,defaultDirectory:freshDefault) == .ready(adjacent.standardizedFileURL) else{throw ToneError.message("Adjacent portable library failed.")}
    let invalidDirectory=directory.appendingPathComponent("Not a library")
    try fm.createDirectory(at:invalidDirectory,withIntermediateDirectories:true)
    guard LibraryLocation.existingLibrary(at:invalidDirectory)==nil else{throw ToneError.message("Invalid library folder accepted.")}
    let prefs=VerificationDefaults()
    defer{prefs.removeObject(forKey:LibraryLocation.pathKey);prefs.removeObject(forKey:LibraryLocation.bookmarkKey)}
    LibraryLocation.remember(directory,defaults:prefs)
    guard LibraryLocation.remembered(defaults:prefs)?.path==directory.standardizedFileURL.path else{throw ToneError.message("Remembered folder did not persist.")}
    let usbClip=try library.export([tone],format:"m4r")
    try verifyPhoneTransfer(audio:Data(contentsOf:usbClip.file),directory:directory.appendingPathComponent("USB transfer checks"))
    print("PASS: portable library lookup, simulated app translocation, folder recovery, remembered location, and no silent empty-library creation.")
    print("PASS: artwork validation, replacement, persistence, exact embedded images in M4R and MP3, artwork re-import, removal, and original preservation.")
    print("PASS: native Swift import, preserved original, saved metadata, clip validation, M4R/AAC, MP3, WAV, original export, unique ZIP filenames, and persistence.")
}
