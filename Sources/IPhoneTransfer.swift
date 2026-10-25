import Foundation
import CryptoKit
#if canImport(DeviceBridge)
import DeviceBridge
#endif

struct USBPhone:Identifiable,Hashable,Sendable {let id:String;var label:String {"USB iPhone · "+id.suffix(6)}}
struct DeviceTransferError:LocalizedError {
    let message:String
    var errorDescription:String?{message}
}
protocol RingtoneDeviceStore:AnyObject {
    func read(_ path:String)throws->Data?
    func write(_ path:String,data:Data)throws
    func rename(_ source:String,to destination:String)throws
    func remove(_ path:String)throws
    func makeDirectory(_ path:String)throws
}
final class USBPhoneStore:RingtoneDeviceStore {
    let name:String
    let version:String
    private let session:UnsafeMutableRawPointer
    static func devices()throws->[USBPhone]{
        var raw:UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,count:Int32=0,error:UnsafeMutablePointer<CChar>?
        let code=br_devices(&raw,&count,&error)
        defer{if let error=error{br_free(error)};if let raw=raw{br_free_devices(raw,count)}}
        guard code==0 else{throw DeviceTransferError(message:error.map{String(cString:$0)} ?? "Could not detect USB iPhones.")}
        return (0..<Int(count)).compactMap{i in raw?[i].map{USBPhone(id:String(cString:$0))}}
    }
    init(udid:String)throws {
        var name:UnsafeMutablePointer<CChar>?,error:UnsafeMutablePointer<CChar>?
        let opened=udid.withCString{br_connect($0,&name,&error)}
        defer{if let name=name{br_free(name)};if let error=error{br_free(error)}}
        guard let opened=opened else{throw DeviceTransferError(message:error.map{String(cString:$0)} ?? "Connect, unlock, and trust this iPhone before transferring.")}
        session=opened;self.name=name.map{String(cString:$0)} ?? "iPhone";self.version=br_ios_version(opened).map{String(cString:$0)} ?? "unknown"
    }
    deinit{br_disconnect(session)}
    private func failure(_ error:UnsafeMutablePointer<CChar>?,fallback:String)->DeviceTransferError{DeviceTransferError(message:error.map{String(cString:$0)} ?? fallback)}
    func read(_ path:String)throws->Data? {
        var bytes:UnsafeMutablePointer<UInt8>?,length=0,error:UnsafeMutablePointer<CChar>?
        let code=path.withCString{br_read(session,$0,&bytes,&length,&error)}
        defer{if let bytes=bytes{br_free(bytes)};if let error=error{br_free(error)}}
        if code==8{return nil}
        guard code==0 else{throw failure(error,fallback:"Could not read the iPhone file.")}
        guard let bytes=bytes else{return Data()};return Data(bytes:bytes,count:length)
    }
    func write(_ path:String,data:Data)throws {
        var error:UnsafeMutablePointer<CChar>?
        let code=data.withUnsafeBytes{buffer in path.withCString{br_write(session,$0,buffer.bindMemory(to:UInt8.self).baseAddress,data.count,&error)}}
        defer{if let error=error{br_free(error)}}
        guard code==0 else{throw failure(error,fallback:"The iPhone upload failed.")}
    }
    func rename(_ source:String,to destination:String)throws {
        var error:UnsafeMutablePointer<CChar>?
        let code=source.withCString{s in destination.withCString{br_rename(session,s,$0,&error)}}
        defer{if let error=error{br_free(error)}}
        guard code==0 else{throw failure(error,fallback:"Could not commit the iPhone upload.")}
    }
    func remove(_ path:String)throws {
        var error:UnsafeMutablePointer<CChar>?
        let code=path.withCString{br_remove(session,$0,&error)}
        defer{if let error=error{br_free(error)}}
        guard code==0 else{throw failure(error,fallback:"Could not remove the unfinished upload.")}
    }
    func makeDirectory(_ path:String)throws {
        var error:UnsafeMutablePointer<CChar>?
        let code=path.withCString{br_mkdir(session,$0,&error)}
        defer{if let error=error{br_free(error)}}
        guard code==0 else{throw failure(error,fallback:"The iPhone media directory is unavailable.")}
    }
}
struct PhoneTone:Sendable {let title:String;let duration:Double;let audio:Data}
struct PhoneTransferReceipt:Sendable {let count:Int;let backup:URL;let names:[String]}

/// Adds unique tone files and commits the index only after every byte has been read back.
/// No existing ringtone is replaced or deleted.
enum IPhoneTransfer {
    static let indexPath="/iTunes_Control/Ringtones/Ringtones.plist"
    static let legacyIndexPath="/iTunes_Control/iTunes/Ringtones.plist"
    static func snapshot(from store:RingtoneDeviceStore)throws->(path:String,data:Data?) {
        if let data=try store.read(indexPath){return (indexPath,data)}
        if let data=try store.read(legacyIndexPath){return (legacyIndexPath,data)}
        return (indexPath,nil)
    }
    static let toneDirectory="/iTunes_Control/Ringtones"
    static func index(_ bytes:Data?)throws->[String:Any] {
        guard let bytes=bytes else{return ["Ringtones":[String:Any]()]}
        guard bytes.count<=16*1024*1024,
              let root=try PropertyListSerialization.propertyList(from:bytes,options:[],format:nil) as? [String:Any],
              root["Ringtones"] is [String:Any] else {
            throw DeviceTransferError(message:"This iPhone uses an unsupported ringtone index. Nothing was changed. Use Finder or AirDrop instead.")
        }
        return root
    }
    static func send(_ tones:[PhoneTone],to store:RingtoneDeviceStore,backupDirectory:URL,progress:(Int,Int)->Void = {_,_ in})throws->PhoneTransferReceipt {
        guard !tones.isEmpty,tones.count<=200,tones.allSatisfy({!$0.audio.isEmpty && $0.audio.count<=20*1024*1024 && $0.duration.isFinite && $0.duration>0 && $0.duration<=30.01}) else {
            throw DeviceTransferError(message:"Choose 1–200 prepared ringtone clips of up to 30 seconds.")
        }
        let snapshot=try snapshot(from:store)
        let targetIndex=snapshot.path,baseline=snapshot.data
        var root=try index(baseline),entries=root["Ringtones"] as! [String:Any]
        try FileManager.default.createDirectory(at:backupDirectory,withIntermediateDirectories:true)
        let transaction=UUID().uuidString.lowercased()
        let backup=backupDirectory.appendingPathComponent(transaction+"-Ringtones.plist")
        try (baseline ?? PropertyListSerialization.data(fromPropertyList:root,format:.binary,options:0)).write(to:backup,options:.atomic)
        try store.makeDirectory("/iTunes_Control")
        try store.makeDirectory("/iTunes_Control/iTunes")
        try store.makeDirectory(toneDirectory)
        var uploaded:[String]=[],temporary:[String]=[],names:[String]=[]
        var commitAttempted=false
        do {
            for (offset,tone) in tones.enumerated(){
                var filename=""
                for _ in 0..<100 {
                    let candidate=UUID().uuidString.replacingOccurrences(of:"-",with:"").prefix(16).uppercased()+".m4r"
                    if entries[candidate]==nil,try store.read(toneDirectory+"/"+candidate)==nil{filename=candidate;break}
                }
                guard !filename.isEmpty else{throw DeviceTransferError(message:"Could not reserve a unique ringtone filename.") }
                let final=toneDirectory+"/"+filename,staged=final+".bickripass-part"
                temporary.append(staged)
                try store.write(staged,data:tone.audio)
                guard try store.read(staged)==tone.audio else{throw DeviceTransferError(message:"The iPhone audio verification failed. Its ringtone index was not changed.")}
                try store.rename(staged,to:final);uploaded.append(final)
                entries[filename]=["Name":tone.title,"GUID":UUID().uuidString.replacingOccurrences(of:"-",with:"").prefix(16).uppercased(),"PID":Int64.random(in:1...Int64.max),"Protected Content":false,"Total Time":Int((tone.duration*1000).rounded())]
                names.append(tone.title);progress(offset+1,tones.count)
            }
            guard try store.read(targetIndex)==baseline else{throw DeviceTransferError(message:"The iPhone's ringtone index changed during transfer. Try again after Finder has finished syncing.")}
            root["Ringtones"]=entries
            let updated=try PropertyListSerialization.data(fromPropertyList:root,format:.binary,options:0)
            let stagedIndex=targetIndex+".bickripass-"+transaction
            temporary.append(stagedIndex)
            try store.write(stagedIndex,data:updated)
            guard try store.read(stagedIndex)==updated else{throw DeviceTransferError(message:"Ringtone index upload could not be verified. The original index was not replaced.")}
            // A disconnect during rename is ambiguous: retain audio once commit is attempted.
            commitAttempted=true
            try store.rename(stagedIndex,to:targetIndex)
            guard try store.read(targetIndex)==updated else{throw DeviceTransferError(message:"The index update could not be confirmed. Uploaded audio was retained. The original index backup is saved on this Mac.")}
            return PhoneTransferReceipt(count:tones.count,backup:backup,names:names)
        }catch{
            if !commitAttempted{for path in uploaded{try? store.remove(path)}}
            for path in temporary{try? store.remove(path)}
            throw error
        }
    }
}
