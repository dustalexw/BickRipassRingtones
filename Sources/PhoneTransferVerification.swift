import Foundation

private final class MemoryPhoneStore:RingtoneDeviceStore {
    enum Fault {case none,corruptAudio,changedIndex,ambiguousCommit}
    var files:[String:Data]
    var fault:Fault
    var indexReads=0
    var writes:[String]=[]
    var removed:[String]=[]
    init(index:Data,fault:Fault = .none){self.files=[IPhoneTransfer.indexPath:index,IPhoneTransfer.toneDirectory+"/OLD.m4r":Data("keep original ringtone".utf8)];self.fault=fault}
    func read(_ path:String)throws->Data? {
        if path==IPhoneTransfer.indexPath {
            indexReads+=1
            if fault == .changedIndex && indexReads==2{files[path]=try PropertyListSerialization.data(fromPropertyList:["Ringtones":["OLD.m4r":["Name":"Old"]],"ChangedByFinder":true],format:.binary,options:0)}
        }
        if fault == .corruptAudio && path.hasSuffix(".bickripass-part"){return Data("bad upload".utf8)}
        return files[path]
    }
    func write(_ path:String,data:Data)throws{files[path]=data;writes.append(path)}
    func rename(_ source:String,to destination:String)throws {
        if fault == .ambiguousCommit && destination==IPhoneTransfer.indexPath{throw DeviceTransferError(message:"Simulated disconnect during commit")}
        guard let data=files.removeValue(forKey:source) else{throw DeviceTransferError(message:"Missing staged file")}
        files[destination]=data
    }
    func remove(_ path:String)throws{files.removeValue(forKey:path);removed.append(path)}
    func makeDirectory(_ path:String)throws{}
}
func verifyPhoneTransfer(audio:Data,directory:URL)throws {
    let original=try PropertyListSerialization.data(fromPropertyList:["Ringtones":["OLD.m4r":["Name":"Old","GUID":"0123456789ABCDEF","Total Time":1000,"KeepUnknown":"yes"]],"PreserveRoot":"yes"],format:.binary,options:0)
    let clip=PhoneTone(title:"New tone",duration:1.5,audio:audio)
    let store=MemoryPhoneStore(index:original)
    let receipt=try IPhoneTransfer.send([clip,PhoneTone(title:"Another tone",duration:1.5,audio:audio)],to:store,backupDirectory:directory.appendingPathComponent("success"))
    let updated=try IPhoneTransfer.index(store.files[IPhoneTransfer.indexPath])
    let entries=updated["Ringtones"] as! [String:Any]
    guard receipt.count==2,entries.count==3,updated["PreserveRoot"] as? String=="yes",(entries["OLD.m4r"] as? [String:Any])?["KeepUnknown"] as? String=="yes",try Data(contentsOf:receipt.backup)==original else{throw ToneError.message("USB index merge or backup failed.")}
    for key in entries.keys where key != "OLD.m4r"{guard store.files[IPhoneTransfer.toneDirectory+"/"+key]==audio else{throw ToneError.message("USB ringtone bytes changed.")}}
    let corrupt=MemoryPhoneStore(index:original,fault:.corruptAudio)
    do{_ = try IPhoneTransfer.send([clip],to:corrupt,backupDirectory:directory.appendingPathComponent("corrupt"));throw ToneError.message("Corrupt USB upload accepted.")}catch let error as ToneError{throw error}catch{}
    guard corrupt.files[IPhoneTransfer.indexPath]==original,corrupt.files.count==2 else{throw ToneError.message("Corrupt upload cleanup changed existing tones.")}
    let concurrent=MemoryPhoneStore(index:original,fault:.changedIndex)
    do{_ = try IPhoneTransfer.send([clip],to:concurrent,backupDirectory:directory.appendingPathComponent("concurrent"));throw ToneError.message("Concurrent iPhone index change accepted.")}catch let error as ToneError{throw error}catch{}
    let changed=try IPhoneTransfer.index(concurrent.files[IPhoneTransfer.indexPath])
    guard changed["ChangedByFinder"] as? Bool==true,concurrent.files.count==2 else{throw ToneError.message("Concurrent index was overwritten.")}
    let ambiguous=MemoryPhoneStore(index:original,fault:.ambiguousCommit)
    do{_ = try IPhoneTransfer.send([clip],to:ambiguous,backupDirectory:directory.appendingPathComponent("ambiguous"));throw ToneError.message("Ambiguous commit reported success.")}catch let error as ToneError{throw error}catch{}
    guard ambiguous.files[IPhoneTransfer.indexPath]==original,ambiguous.files.keys.contains(where:{$0.hasSuffix(".m4r") && !$0.hasSuffix("OLD.m4r")}),!ambiguous.removed.contains(where:{$0.hasSuffix(".m4r")}) else{throw ToneError.message("Ambiguous commit removed potentially registered audio.")}
    let legacy=MemoryPhoneStore(index:original)
    legacy.files[IPhoneTransfer.legacyIndexPath]=legacy.files.removeValue(forKey:IPhoneTransfer.indexPath)
    _ = try IPhoneTransfer.send([clip],to:legacy,backupDirectory:directory.appendingPathComponent("legacy"))
    guard legacy.files[IPhoneTransfer.indexPath]==nil,let oldIndex=legacy.files[IPhoneTransfer.legacyIndexPath],(try IPhoneTransfer.index(oldIndex)["Ringtones"] as? [String:Any])?.count==2 else{throw ToneError.message("Legacy USB index location was not preserved.")}
    let invalid=MemoryPhoneStore(index:try PropertyListSerialization.data(fromPropertyList:["UnknownSchema":true],format:.binary,options:0))
    do{_ = try IPhoneTransfer.send([clip],to:invalid,backupDirectory:directory.appendingPathComponent("invalid"));throw ToneError.message("Unknown iPhone index schema accepted.")}catch let error as ToneError{throw error}catch{}
    guard invalid.writes.isEmpty else{throw ToneError.message("Unsupported iPhone index was modified.")}
    print("PASS: USB transfer engine preserves existing tones and unknown metadata, verifies uploads, backs up the index, rejects concurrent updates, and handles corrupt uploads and ambiguous commits.")
}
