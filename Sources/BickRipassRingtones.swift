import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import CryptoKit

let accent=Color(red:0.46,green:0.34,blue:0.66)
func durationText(_ seconds:Double)->String {let value=max(0,Int(seconds));return String(format:"%d:%02d",value/60,value%60)}
func toneColor(_ name:String)->Color {switch name{case "coral":return Color(red:0.83,green:0.58,blue:0.47);case "mint":return Color(red:0.46,green:0.65,blue:0.59);case "blue":return Color(red:0.46,green:0.61,blue:0.76);case "rose":return Color(red:0.73,green:0.50,blue:0.63);case "amber":return Color(red:0.76,green:0.62,blue:0.35);case "indigo":return Color(red:0.47,green:0.48,blue:0.66);case "sage":return Color(red:0.55,green:0.63,blue:0.48);default:return accent}}

@MainActor final class LibraryModel:ObservableObject {
    @Published private(set) var library:ToneLibrary
    @Published var tones:[Tone]=[]
    @Published var collections:[String]=[]
    @Published var selection=Set<String>() { didSet { selectionChanged() } }
    @Published var section="all"
    @Published var search=""
    @Published var grid=false
    @Published var sort="name"
    @Published var editing:Tone?
    @Published var busy:String?
    @Published var error:String?
    @Published var notice:String?
    @Published var transfer=false
    @Published var newCollection=false
    @Published var collectionName=""
    @Published var playing=false
    @Published var position=0.0
    @Published var nowPlaying:Tone?
    @Published var lastExport:URL?
    @Published var usbPhones:[USBPhone]=[]
    @Published var usbPhoneID="" {didSet{if oldValue != usbPhoneID{verifiedPhoneID=nil;usbPhoneName=nil}}}
    @Published var verifiedPhoneID:String?
    @Published var usbPhoneName:String?
    @Published var usbLastBackup:URL?
    @Published var usbStatus="Connect your iPhone by USB, unlock it, and tap Refresh."
    @Published var usbChecking=false
    var transferTones:[Tone]{let selected=tones.filter{selection.contains($0.id)};return selected.isEmpty ? editing.map{[$0]} ?? []:selected}
    func refreshUSB(){
        guard !usbChecking,busy==nil else{return};usbChecking=true;verifiedPhoneID=nil
        Task {
            do{usbPhones=try await Task.detached{try USBPhoneStore.devices()}.value;usbPhoneID=usbPhones.first?.id ?? "";usbStatus=usbPhones.isEmpty ? "No USB iPhone found. Check the cable and unlock the phone.":"Choose the iPhone, then check its connection."}
            catch{usbPhones=[];usbPhoneID="";usbStatus=error.localizedDescription}
            usbChecking=false
        }
    }
    func checkUSB(){
        guard !usbChecking,busy==nil,!usbPhoneID.isEmpty else{return};usbChecking=true;verifiedPhoneID=nil
        let id=usbPhoneID
        Task {
            do {
                let phone=try await Task.detached{let store=try USBPhoneStore(udid:id);_ = try IPhoneTransfer.index(IPhoneTransfer.snapshot(from:store).data);return (store.name,store.version)}.value
                if id==usbPhoneID{usbPhoneName=phone.0;verifiedPhoneID=id;usbStatus="Ready: \(phone.0) · iOS \(phone.1)."}
            }catch{usbStatus=error.localizedDescription}
            usbChecking=false
        }
    }
    func sendToUSB(){
        guard busy==nil,let verified=verifiedPhoneID,verified==usbPhoneID,let name=usbPhoneName else{return}
        do{try save()}catch{self.error=error.localizedDescription;return}
        let selected=transferTones
        guard !selected.isEmpty,selected.count<=200 else{error="Select 1–200 tones for USB transfer.";return}
        let alert=NSAlert();alert.messageText="Send \(selected.count) ringtone\(selected.count==1 ? "":"s") to \(name)?";alert.informativeText="USB compatibility mode adds the selected M4R clips and updates the phone's ringtone index. Existing tones are preserved and the index is backed up on this Mac. Availability in Settings depends on iOS. The default ringtone will not be changed.";alert.addButton(withTitle:"Send to iPhone");alert.addButton(withTitle:"Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else{return}
        let library=self.library;busy="Preparing iPhone ringtones…"
        Task {
            do {
                let result=try await Task.detached { [self] () throws -> PhoneTransferReceipt in
                    var prepared:[PhoneTone]=[]
                    for (i,tone) in selected.enumerated(){
                        let result=try library.export([tone],format:"m4r")
                        prepared.append(PhoneTone(title:tone.title,duration:tone.length,audio:try Data(contentsOf:result.file)))
                        Task{@MainActor in if self.busy != nil{self.busy="Preparing \(i+1) of \(selected.count)…"}}
                    }
                    let store=try USBPhoneStore(udid:verified)
                    let identifier=SHA256.hash(data:Data(verified.utf8)).map{String(format:"%02x",$0)}.joined()
                    let backup=library.directory.appendingPathComponent("device-backups").appendingPathComponent(identifier)
                    return try IPhoneTransfer.send(prepared,to:store,backupDirectory:backup){completed,total in
                        Task{@MainActor in if self.busy != nil{self.busy="Sending \(completed) of \(total) to iPhone…"}}
                    }
                }.value
                busy=nil;usbStatus="Transferred \(result.count) tones to \(name). Check Settings → Sounds & Haptics → Ringtone. Close and reopen Settings if needed.";notice="USB transfer finished. Original ringtone index backed up in device-backups.";usbLastBackup=result.backup
            }catch{busy=nil;usbStatus=error.localizedDescription;self.error=error.localizedDescription}
        }
    }
    private var player:AVAudioPlayer?,timer:Timer?,clipEnd=0.0,clipStart=0.0
    init(library:ToneLibrary){self.library=library;reload();if let first=tones.sorted(by:{$0.title<$1.title}).first{selection=[first.id];editing=first}}
    var visible:[Tone]{
        tones.filter { t in
            let match=section=="all" || section=="favorites" && t.favorite || section=="recent" && Date().timeIntervalSince1970-t.created<7*86400 || section=="ready" && t.length<=30 || section=="collection:"+t.collection
            return match && (search.isEmpty || [t.title,t.artist,t.collection,t.category].contains{$0.localizedCaseInsensitiveContains(search)})
        }.sorted {a,b in sort=="recent" ? a.created>b.created : sort=="duration" ? a.length<b.length:a.title.localizedStandardCompare(b.title) == .orderedAscending}
    }
    var pageTitle:String { ["all":"All tones","favorites":"Favorites","recent":"Recently added","ready":"iPhone-ready"][section] ?? String(section.dropFirst(11)) }
    func reload(){do{tones=try library.tones();collections=try library.collections()}catch{self.error=error.localizedDescription}}
    func selectionChanged(){guard let id=selection.sorted().first,let t=tones.first(where:{$0.id==id}) else{editing=nil;return};if editing?.id != id {editing=t}}
    func save() throws {guard let t=editing else{return};try library.save(t);reload();notice="Changes saved."}
    func favorite(_ tone:Tone){var t=tone;t.favorite.toggle();do{try library.save(t);reload();if editing?.id==t.id{editing?.favorite=t.favorite}}catch{self.error=error.localizedDescription}}
    func chooseLibrary(){
        guard busy==nil else{return}
        guard let directory=LibraryRecovery.pickLibrary() else{return}
        do {
            let opened=try ToneLibrary(directory:directory)
            let newTones=try opened.tones()
            pause();player=nil;nowPlaying=nil;position=0
            library=opened;tones=newTones;collections=try opened.collections()
            selection=[];editing=nil;search="";section="all";lastExport=nil
            if let first=visible.first{selection=[first.id];editing=first}
            LibraryLocation.remember(directory)
            notice="Opened \(tones.count) tones from \(directory.lastPathComponent)."
        }catch{self.error=error.localizedDescription}
    }
    func chooseFiles(){let panel=NSOpenPanel();panel.title="Import audio into BickRipassRingtones";panel.allowsMultipleSelection=true;panel.canChooseDirectories=false;panel.allowedContentTypes=[.audio,UTType(filenameExtension:"m4r") ?? .data];if panel.runModal() == .OK{importFiles(panel.urls)}}
    func importFiles(_ urls:[URL]) {
        guard !urls.isEmpty,busy==nil else{return};busy="Importing \(urls.count) audio file\(urls.count==1 ? "":"s")…"
        let library=self.library
        Task {
            let result=await Task.detached { () -> ([String],[String]) in
                var ids:[String]=[],errors:[String]=[]
                for url in urls {let access=url.startAccessingSecurityScopedResource();defer{if access{url.stopAccessingSecurityScopedResource()}};do{ids.append(try library.importFile(url))}catch{errors.append(url.lastPathComponent+": "+error.localizedDescription)}}
                return (ids,errors)
            }.value
            self.busy=nil;self.reload()
            if let id=result.0.last{self.section="all";self.selection=[id];self.selectionChanged()}
            if !result.1.isEmpty{self.error=result.1.joined(separator:"\n\n")}else{self.notice="\(result.0.count) tones imported."}
        }
    }
    func chooseArtwork(){
        guard let id=editing?.id,busy==nil else{return}
        let panel=NSOpenPanel();panel.title="Choose ringtone artwork";panel.prompt="Use artwork";panel.allowedContentTypes=[.image];panel.canChooseDirectories=false;panel.allowsMultipleSelection=false
        guard panel.runModal() == .OK,let url=panel.url else{return}
        busy="Saving artwork…";let library=self.library
        Task {
            do {
                let filename=try await Task.detached {
                    let access=url.startAccessingSecurityScopedResource();defer{if access{url.stopAccessingSecurityScopedResource()}}
                    return try library.setArtwork(toneID:id,source:url)
                }.value
                self.reload();if self.editing?.id==id{self.editing?.artwork=filename}
                self.busy=nil;self.notice="Artwork saved. M4R and MP3 exports include it."
            }catch{self.busy=nil;self.error=error.localizedDescription}
        }
    }
    func removeArtwork(){guard let id=editing?.id else{return};do{try library.removeArtwork(toneID:id);reload();editing?.artwork=nil;notice="Artwork removed from this tone."}catch{self.error=error.localizedDescription}}
    func createCollection(){do{try library.addCollection(collectionName);reload();section="collection:"+collectionName.trimmingCharacters(in:.whitespacesAndNewlines);collectionName="";newCollection=false}catch{self.error=error.localizedDescription}}
    func activate(_ tone:Tone){
        let target=editing?.id==tone.id ? editing!:tone
        let modifiers=NSEvent.modifierFlags.intersection([.command,.shift])
        if modifiers.isEmpty{selection=[tone.id]}
        editing=target
        play(target,force:true)
    }
    func play(_ tone:Tone?=nil,force:Bool=false){
        guard let t=tone ?? editing else{return}
        if playing,nowPlaying?.id==t.id,!force{pause();return}
        do {
            if player==nil || nowPlaying?.id != t.id {player=try AVAudioPlayer(contentsOf:library.previewURL(t));player?.prepareToPlay()}
            clipStart=t.start;clipEnd=t.end
            guard t.start>=0,t.end>t.start,t.end<=t.duration+0.01 else{throw ToneError.message("Choose valid clip times before previewing.")}
            player?.currentTime=t.start;player?.play();nowPlaying=t;playing=true;position=0
            timer?.invalidate();timer=Timer.scheduledTimer(withTimeInterval:0.05,repeats:true){[weak self] _ in Task{@MainActor in self?.tick()}}
        }catch{self.error=error.localizedDescription}
    }
    func tick(){guard let p=player else{return};position=min(1,max(0,(p.currentTime-clipStart)/max(0.1,clipEnd-clipStart)));if p.currentTime>=clipEnd || !p.isPlaying{pause();position=1}}
    func pause(){player?.pause();playing=false;timer?.invalidate();timer=nil}
    func skip(_ offset:Int){let items=visible;guard !items.isEmpty else{return};let index=items.firstIndex(where:{$0.id==editing?.id}) ?? 0;let t=items[(index+offset+items.count)%items.count];selection=[t.id];editing=t;play(t,force:true)}
    func export(format:String){
        guard busy==nil else{return}
        do{try save()}catch{self.error=error.localizedDescription;return}
        let selected=tones.filter{selection.contains($0.id)}
        let exportTones=selected.isEmpty ? editing.map{[$0]} ?? []:selected
        guard !exportTones.isEmpty else{return}
        busy="Preparing \(exportTones.count) tone\(exportTones.count==1 ? "":"s")…"
        let library=self.library
        Task {
            do {
                let result=try await Task.detached{try library.export(exportTones,format:format)}.value
                busy=nil;lastExport=result.file
                let panel=NSSavePanel();panel.title="Save BickRipassRingtones export";panel.nameFieldStringValue=result.file.lastPathComponent;panel.canCreateDirectories=true
                panel.allowedContentTypes=[UTType(filenameExtension:result.file.pathExtension) ?? .data]
                if panel.runModal() == .OK,let destination=panel.url {
                    if destination.standardizedFileURL != result.file.standardizedFileURL {
                        if FileManager.default.fileExists(atPath:destination.path){try FileManager.default.removeItem(at:destination)}
                        try FileManager.default.copyItem(at:result.file,to:destination)
                    };lastExport=destination;notice="Export saved. Use Share or AirDrop to send it along."
                }else{notice="Export prepared. It is available in Recent export."}
            }catch{busy=nil;self.error=error.localizedDescription}
        }
    }
    func reveal(){if let url=lastExport{NSWorkspace.shared.activateFileViewerSelecting([url])}}
    func airDrop(){guard let url=lastExport else{return};guard let service=NSSharingService(named:.sendViaAirDrop) else{error="AirDrop is unavailable on this Mac. Use Show in Finder to share the file.";return};service.perform(withItems:[url])}
}

struct ToneArt:View {
    let tone:Tone;var size:CGFloat=36;var artworkURL:URL?=nil
    var body:some View {
        ZStack {
            if let url=artworkURL,let image=NSImage(contentsOf:url) {
                Image(nsImage:image).resizable().scaledToFill().frame(width:size,height:size)
            }else{
                RoundedRectangle(cornerRadius:size*0.15).fill(LinearGradient(colors:[toneColor(tone.color).opacity(0.65),toneColor(tone.color)],startPoint:.topLeading,endPoint:.bottomTrailing))
                Circle().stroke(.white.opacity(0.16),lineWidth:1).padding(size*0.12).offset(x:size*0.20,y:-size*0.18)
                Image(systemName:"waveform").font(.system(size:size*0.43,weight:.light)).foregroundStyle(.white.opacity(0.95))
            }
        }.frame(width:size,height:size).clipShape(RoundedRectangle(cornerRadius:size*0.15)).accessibilityLabel(tone.artwork==nil ? "Default artwork":"Artwork for \(tone.title)")
    }
}
struct SidebarView:View {
    @ObservedObject var model:LibraryModel
    var body:some View {VStack(alignment:.leading,spacing:0){
        HStack(spacing:9){Image(systemName:"waveform.path").foregroundStyle(accent);Text("BickRipassRingtones").font(.system(size:17,weight:.bold,design:.rounded)).tracking(-0.8).lineLimit(1).minimumScaleFactor(0.7)}.padding(.horizontal,18).padding(.top,28).padding(.bottom,28)
        List(selection:Binding<String?>(get:{model.section},set:{model.section=$0 ?? "all"})){Section("LIBRARY"){
            Label("All tones",systemImage:"music.note.list").badge(model.tones.count).tag("all")
            Label("Favorites",systemImage:"heart").badge(model.tones.filter(\.favorite).count).tag("favorites")
            Label("Recently added",systemImage:"clock").tag("recent")
            Label("iPhone-ready",systemImage:"iphone").tag("ready")
        }
        Section{ForEach(model.collections,id:\.self){name in Label(name,systemImage:"rectangle.stack").tag("collection:"+name)}}header:{HStack{Text("COLLECTIONS");Spacer();Button{model.newCollection=true}label:{Image(systemName:"plus")}.buttonStyle(.borderless).help("New collection")}}
        }.listStyle(.sidebar)
        VStack(alignment:.leading,spacing:9){Label("Saved on this Mac",systemImage:"checkmark.circle.fill").font(.caption).foregroundStyle(.secondary);Text("Your originals stay yours.\nNo account. No subscription.").font(.caption2).foregroundStyle(.tertiary);Button{model.transfer=true}label:{Label("iPhone transfer guide",systemImage:"iphone.and.arrow.forward")}.buttonStyle(.borderless).font(.caption).padding(.top,10)}.padding(20)
    }.frame(minWidth:200,idealWidth:220,maxWidth:260).background(Color(nsColor:.windowBackgroundColor))}
}
struct LibraryHero:View {
    let importAudio:()->Void
    var body:some View {HStack{
        VStack(alignment:.leading,spacing:10){Text("A HOME FOR EVERY HELLO").font(.system(size:9,weight:.semibold)).tracking(2).foregroundStyle(accent);Text("Small sounds. Big personality.").font(.system(size:27,weight:.bold,design:.rounded)).tracking(-0.8);Text("Collect, make, and take your favorite little sounds.").font(.callout).foregroundStyle(.secondary);Button("Find your next sound  ↗",action:importAudio).buttonStyle(.borderless).foregroundStyle(accent).font(.caption.weight(.semibold))}
        Spacer()
        ZStack {RoundedRectangle(cornerRadius:15).fill(Color(red:0.87,green:0.65,blue:0.54).gradient).frame(width:105,height:115).rotationEffect(.degrees(18)).offset(x:34,y:-9);Image(systemName:"sparkle").font(.system(size:55,weight:.ultraLight)).foregroundStyle(.white.opacity(0.7)).offset(x:34,y:-9);RoundedRectangle(cornerRadius:15).fill(accent.gradient).frame(width:112,height:120).rotationEffect(.degrees(-12)).offset(x:-32,y:10);Image(systemName:"waveform").font(.system(size:53,weight:.light)).foregroundStyle(.white.opacity(0.9)).rotationEffect(.degrees(-12)).offset(x:-32,y:7)}.frame(width:205,height:150)
    }.padding(.horizontal,25).frame(height:177).background(accent.opacity(0.075),in:RoundedRectangle(cornerRadius:13))}
}
struct ToneRow:View {
    let tone:Tone
    @ObservedObject var model:LibraryModel
    var body:some View {
        HStack(spacing:12) {
            HStack(spacing:12) {
                ToneArt(tone:tone,artworkURL:model.library.artworkURL(tone))
                VStack(alignment:.leading,spacing:4) {
                    Text(tone.title).font(.system(size:12,weight:.semibold)).lineLimit(1)
                    Text(tone.artist).font(.system(size:10)).foregroundStyle(.secondary).lineLimit(1)
                }.frame(maxWidth:.infinity,alignment:.leading)
                Text(durationText(tone.length)).font(.system(size:11,design:.monospaced)).foregroundStyle(.secondary).frame(width:40)
                Text(tone.category).font(.system(size:10)).foregroundStyle(.secondary).frame(width:70)
                Text(tone.format).font(.system(size:9,weight:.medium)).foregroundStyle(.secondary).padding(5).background(.quaternary,in:RoundedRectangle(cornerRadius:4)).frame(width:45)
            }.contentShape(Rectangle()).simultaneousGesture(TapGesture().onEnded{model.activate(tone)})
            Button{model.favorite(tone)}label:{Image(systemName:tone.favorite ? "heart.fill":"heart").foregroundStyle(tone.favorite ? accent:.secondary)}.buttonStyle(.borderless).help("Favorite \(tone.title)")
            Button{model.activate(tone)}label:{Image(systemName:"play.fill").font(.caption2)}.buttonStyle(.borderless).help("Play \(tone.title) from the start")
        }.padding(.vertical,5)
    }
}
struct ToneGridItem:View {
    let tone:Tone
    @ObservedObject var model:LibraryModel
    var body:some View {
        Button { model.activate(tone) } label: {
            VStack(alignment:.leading,spacing:9) {
                ToneArt(tone:tone,size:135,artworkURL:model.library.artworkURL(tone))
                Text(tone.title).font(.caption.weight(.semibold))
                Text(durationText(tone.length)+" · "+tone.artist).font(.system(size:9)).foregroundStyle(.secondary).lineLimit(1)
            }.padding(10).background(model.selection.contains(tone.id) ? accent.opacity(0.12):Color.clear,in:RoundedRectangle(cornerRadius:10))
        }.buttonStyle(.plain).contextMenu {
            Button("Play from start"){model.activate(tone)}
            Button(tone.favorite ? "Remove favorite":"Favorite"){model.favorite(tone)}
        }
    }
}
struct WaveformView:View {
    let tone:Tone
    var body:some View {Canvas {ctx,size in
        let start=tone.start/max(0.1,tone.duration)*size.width,end=tone.end/max(0.1,tone.duration)*size.width
        ctx.fill(Path(CGRect(x:start,y:0,width:max(0,end-start),height:size.height)),with:.color(accent.opacity(0.12)))
        let peak=max(0.01,tone.peaks.max() ?? 0.01)
        for (i,p) in tone.peaks.enumerated(){let x=CGFloat(i)/CGFloat(max(1,tone.peaks.count))*size.width;let h=max(2,p/peak*size.height*0.75);let color=x>=start && x<=end ? accent:accent.opacity(0.25);ctx.fill(Path(roundedRect:CGRect(x:x,y:(size.height-h)/2,width:max(1,size.width/CGFloat(max(1,tone.peaks.count))-1),height:h),cornerRadius:1),with:.color(color))}
    }.frame(height:64).background(accent.opacity(0.04),in:RoundedRectangle(cornerRadius:6)).clipShape(RoundedRectangle(cornerRadius:6)).accessibilityLabel("Waveform of \(tone.title)")}
}
struct InspectorView:View {
    @ObservedObject var model:LibraryModel
    var body:some View {ScrollView {if let tone=model.editing{VStack(alignment:.leading,spacing:14){
        Text("NOW IN YOUR COLLECTION").font(.system(size:9,weight:.semibold)).tracking(1.5).foregroundStyle(.secondary)
        HStack{Spacer();Button(action:model.chooseArtwork){ToneArt(tone:tone,size:170,artworkURL:model.library.artworkURL(tone))}.buttonStyle(.plain).help("Change artwork");Spacer()}.padding(.vertical,5)
        HStack{Button(tone.artwork==nil ? "Add artwork…":"Change artwork…",action:model.chooseArtwork);Spacer();if tone.artwork != nil{Button("Remove",action:model.removeArtwork).foregroundStyle(.secondary)}}.font(.caption)
        Text("Artwork is embedded in M4R and MP3 exports. WAV and original-file exports stay unchanged.").font(.system(size:10)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
        Text(tone.title).font(.title2.bold()).lineLimit(2);Text(tone.artist).font(.caption).foregroundStyle(.secondary)
        HStack{Text(durationText(tone.duration)+" original");Text(tone.format);Text(ByteCountFormatter.string(fromByteCount:tone.size,countStyle:.file))}.font(.system(size:9)).foregroundStyle(.secondary)
        Divider()
        textField("Title",path:\.title);textField("Artist / source",path:\.artist)
        Picker("Collection",selection:binding(\.collection)){ForEach(model.collections,id:\.self){Text($0).tag($0)}}.font(.caption)
        Picker("Kind",selection:binding(\.category)){ForEach(["Ringtone","Text tone","Alert"],id:\.self){Text($0).tag($0)}}.font(.caption)
        Divider();Text("MAKE THE PERFECT CUT").font(.system(size:9,weight:.semibold)).tracking(1.4).foregroundStyle(.secondary)
        WaveformView(tone:tone)
        HStack{Text(String(format:"%0.1fs selected",tone.length));Spacer();Text("30s max")}.font(.caption2).foregroundStyle(.secondary)
        HStack{numberField("Start · seconds",path:\.start);numberField("End · seconds",path:\.end)}
        Picker("Fade in / out",selection:binding(\.fade)){ForEach([0.0,0.1,0.3,0.5,1,2,3],id:\.self){value in Text(value==0 ? "No fade":String(format:"%0.1f seconds",value)).tag(value)}}.font(.caption)
        Toggle("Balance volume on export",isOn:binding(\.normalize)).font(.caption).toggleStyle(.checkbox)
        HStack{Button("Save changes"){do{try model.save()}catch{model.error=error.localizedDescription}};Spacer();Button{model.play(model.editing,force:true)}label:{Label("Preview",systemImage:"play.fill")}}.font(.caption)
        Menu{exportItems}label:{Label("Export tone",systemImage:"square.and.arrow.up")}.menuStyle(.borderlessButton).padding(10).frame(maxWidth:.infinity).background(accent,in:RoundedRectangle(cornerRadius:7)).foregroundStyle(.white)
        Text("Preview plays the selected original audio. Fades and volume balancing apply on export.").font(.system(size:10)).foregroundStyle(.tertiary).fixedSize(horizontal:false,vertical:true)
    }.padding(20)}else{ContentUnavailableView("Choose a tone",systemImage:"waveform",description:Text("Select a tone to edit and export it."))}}.frame(width:285).background(Color(nsColor:.controlBackgroundColor).opacity(0.75))}
    @ViewBuilder var exportItems:some View {Button("iPhone ringtone · M4R"){singleExport("m4r")};Button("MP3 audio"){singleExport("mp3")};Button("WAV audio"){singleExport("wav")};Divider();Button("Untouched original"){singleExport("original")}}
    func singleExport(_ format:String){if let id=model.editing?.id{model.selection=[id]};model.export(format:format)}
    func binding<T>(_ key:WritableKeyPath<Tone,T>)->Binding<T>{Binding(get:{model.editing![keyPath:key]},set:{model.editing?[keyPath:key]=$0})}
    func textField(_ title:String,path:WritableKeyPath<Tone,String>)->some View {VStack(alignment:.leading,spacing:5){Text(title).font(.caption2).foregroundStyle(.secondary);TextField(title,text:binding(path)).textFieldStyle(.roundedBorder)}}
    func numberField(_ title:String,path:WritableKeyPath<Tone,Double>)->some View {VStack(alignment:.leading,spacing:5){Text(title).font(.caption2).foregroundStyle(.secondary);TextField(title,value:binding(path),format:.number.precision(.fractionLength(1))).textFieldStyle(.roundedBorder)}}
}
struct LibraryContent:View {
    @ObservedObject var model:LibraryModel
    var body:some View {VStack(spacing:0){
        HStack(spacing:18){Button{model.skip(-1)}label:{Image(systemName:"backward.end.fill")}.buttonStyle(.borderless).accessibilityLabel("Previous tone");Button{model.play()}label:{Image(systemName:model.playing ? "pause.fill":"play.fill").frame(width:33,height:33).background(accent.opacity(0.10),in:Circle())}.buttonStyle(.borderless).keyboardShortcut(.space,modifiers:[]).help("Play or pause");Button{model.skip(1)}label:{Image(systemName:"forward.end.fill")}.buttonStyle(.borderless).accessibilityLabel("Next tone")
            VStack(spacing:5){Text(model.nowPlaying?.title ?? "A little sound goes a long way.").font(.caption.weight(.medium));Text(model.nowPlaying?.artist ?? "Choose a tone to listen").font(.system(size:9)).foregroundStyle(.secondary);ProgressView(value:model.position).tint(accent).frame(maxWidth:270)}.frame(maxWidth:.infinity)
            TextField("Search your library",text:$model.search).textFieldStyle(.roundedBorder).frame(width:195)
            Button{model.transfer=true}label:{Label("Devices",systemImage:"iphone")}.help("Mac and iPhone transfer options")
        }.foregroundStyle(accent).padding(.horizontal,25).frame(height:73)
        Divider()
        HStack(spacing:0){VStack(alignment:.leading,spacing:20){
            HStack(alignment:.center){VStack(alignment:.leading,spacing:6){Text("YOUR PERSONAL SOUNDTRACK").font(.system(size:9,weight:.semibold)).tracking(2).foregroundStyle(.secondary);Text(model.pageTitle).font(.system(size:31,weight:.bold,design:.rounded));Text("\(model.tones.count) tones · \(model.collections.count) collections · all yours").font(.caption).foregroundStyle(.secondary)};Spacer();Menu{Button("iPhone ringtone · M4R"){model.export(format:"m4r")};Button("MP3 audio"){model.export(format:"mp3")};Button("WAV audio"){model.export(format:"wav")};Button("Original files"){model.export(format:"original")}}label:{Label(model.selection.count>1 ? "Export \(model.selection.count) tones":"Export",systemImage:"square.and.arrow.up")}.disabled(model.tones.isEmpty);Button{model.chooseFiles()}label:{Label("Import audio",systemImage:"plus")}.buttonStyle(.borderedProminent).tint(accent).keyboardShortcut("i",modifiers:[.command])}
            LibraryHero(importAudio:model.chooseFiles)
            HStack{Picker("View",selection:$model.grid){Image(systemName:"list.bullet").tag(false);Image(systemName:"square.grid.2x2").tag(true)}.pickerStyle(.segmented).labelsHidden().frame(width:75);Text(model.selection.count>1 ? "\(model.selection.count) selected":"Your collection").font(.caption).foregroundStyle(.secondary);Spacer();Picker("Sort",selection:$model.sort){Text("Name").tag("name");Text("Recently added").tag("recent");Text("Duration").tag("duration")}.frame(width:175).font(.caption)}
            if model.visible.isEmpty {ContentUnavailableView("Room for your next favorite",systemImage:"music.note",description:Text("Import audio or try a different search.")).frame(maxWidth:.infinity,maxHeight:.infinity)}else if model.grid{
                ScrollView {
                    LazyVGrid(columns:[GridItem(.adaptive(minimum:140))],spacing:18) {
                        ForEach(model.visible) { t in ToneGridItem(tone:t,model:model) }
                    }
                }.frame(maxHeight:.infinity)
            }else{List(selection:$model.selection){ForEach(model.visible){t in ToneRow(tone:t,model:model).tag(t.id).listRowSeparator(.visible)}}.listStyle(.inset).scrollContentBackground(.hidden).frame(maxHeight:.infinity)}
            Button(action:model.chooseFiles){HStack(spacing:13){Image(systemName:"arrow.down.circle").font(.title2).foregroundStyle(accent.opacity(0.5));VStack(alignment:.leading,spacing:5){Text("There’s room for your next favorite.").font(.caption.weight(.medium));Text("Drop audio here, or browse files · MP3, M4A, M4R, WAV & more").font(.system(size:10)).foregroundStyle(.secondary)};Spacer()}.padding(16).frame(maxWidth:.infinity).background(accent.opacity(0.025),in:RoundedRectangle(cornerRadius:8)).overlay(RoundedRectangle(cornerRadius:8).strokeBorder(accent.opacity(0.2),style:StrokeStyle(lineWidth:1,dash:[4,4])))}.buttonStyle(.plain)
            HStack{Label("LOCAL LIBRARY",systemImage:"circle.fill").font(.system(size:8,weight:.medium)).foregroundStyle(.secondary);Spacer();Text(model.notice ?? "Good sounds deserve a good home.").font(.caption2).foregroundStyle(.secondary).lineLimit(1)}
        }.padding(25).frame(minWidth:520,maxWidth:.infinity)
        Divider();InspectorView(model:model)
        }.frame(maxHeight:.infinity)
    }.background(Color(nsColor:.textBackgroundColor)).onDrop(of:[UTType.fileURL],isTargeted:nil){providers in
        let group=DispatchGroup(),lock=NSLock()
        var urls:[URL]=[]
        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier:UTType.fileURL.identifier,options:nil) {item,_ in
                defer{group.leave()}
                let url=(item as? URL) ?? (item as? Data).flatMap{URL(dataRepresentation:$0,relativeTo:nil)}
                if let url=url{lock.lock();urls.append(url);lock.unlock()}
            }
        }
        group.notify(queue:.main){model.importFiles(urls)}
        return !providers.isEmpty
    }}
}
struct TransferView:View {
    @ObservedObject var model:LibraryModel
    @Environment(\.dismiss) private var dismiss
    var body:some View {
        VStack(alignment:.leading,spacing:17){
            HStack{Text("Send your tones to iPhone.").font(.system(size:27,weight:.bold,design:.rounded));Spacer();Button{dismiss()}label:{Image(systemName:"xmark.circle.fill").foregroundStyle(.secondary)}.buttonStyle(.plain).disabled(model.busy != nil)}
            ScrollView {
                VStack(alignment:.leading,spacing:17){
                    GroupBox {
                        VStack(alignment:.leading,spacing:14){
                            Label("USB transfer · compatibility mode",systemImage:"cable.connector").font(.headline)
                            Text("Select tones in your library, connect and unlock your iPhone, and approve Trust This Computer on the phone when asked.").font(.callout).foregroundStyle(.secondary)
                            HStack{Picker("iPhone",selection:$model.usbPhoneID){if model.usbPhones.isEmpty{Text("No phone selected").tag("")};ForEach(model.usbPhones){phone in Text(phone.label).tag(phone.id)}};Button("Refresh",action:model.refreshUSB).disabled(model.usbChecking || model.busy != nil)}
                            HStack{Button("Check connection",action:model.checkUSB).disabled(model.usbPhoneID.isEmpty || model.usbChecking || model.busy != nil);if model.usbChecking{ProgressView().controlSize(.small)};Spacer();Text("\(model.transferTones.count) tones selected").font(.caption).foregroundStyle(.secondary)}
                            Text(model.usbStatus).font(.callout).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
                            if let busy=model.busy{HStack{ProgressView().controlSize(.small);Text(busy).font(.caption)}}
                            Button("Review & send to iPhone",action:model.sendToUSB).buttonStyle(.borderedProminent).tint(accent).disabled(model.verifiedPhoneID != model.usbPhoneID || model.verifiedPhoneID==nil || model.transferTones.isEmpty || model.usbChecking || model.busy != nil)
                            if let backup=model.usbLastBackup{Button("Show transfer backup"){NSWorkspace.shared.activateFileViewerSelecting([backup])}}
                            Text("Setup: brew install libimobiledevice").font(.system(.caption,design:.monospaced)).textSelection(.enabled)
                            Text("Uses the iPhone media service, with an index backup and read-back verification. iOS compatibility varies; iOS 27 is not yet device-verified. This is not Apple’s official sync interface. It does not set your default ringtone.").font(.caption).foregroundStyle(.secondary)
                        }.padding(12)
                    }
                    if let file=model.lastExport{GroupBox("Recent export"){HStack{Image(systemName:"waveform").font(.title);VStack(alignment:.leading){Text(file.lastPathComponent).font(.headline);Text("Ready to share").font(.caption).foregroundStyle(.secondary)};Spacer();Button("Show in Finder"){model.reveal()};Button("AirDrop…"){model.airDrop()};ShareLink(item:file){Image(systemName:"square.and.arrow.up")}}.padding(9)}}
                    DisclosureGroup("AirDrop and GarageBand alternative"){
                        VStack(alignment:.leading,spacing:12){Text("Export WAV for GarageBand, or M4R for workflows accepting ringtone files. Send it with AirDrop or iCloud Drive. In GarageBand on iPhone, import the file, return to My Songs, then Share → Ringtone → Export → Use sound as.");Link("Apple’s ringtone guide ↗",destination:URL(string:"https://support.apple.com/en-us/120692")!);Text("AirDrop transfers a file, rather than assigning a ringtone. Protected Apple Music downloads cannot be imported.").font(.caption).foregroundStyle(.secondary)}.font(.callout).padding(.vertical,10)
                    }
                }
            }
            HStack{Button("Open library folder"){NSWorkspace.shared.open(model.library.directory)};Spacer();Button("Done"){dismiss()}.keyboardShortcut(.defaultAction).disabled(model.busy != nil)}
        }.padding(30).frame(width:680).frame(maxHeight:850)
    }
}
struct RootView:View {
    @ObservedObject var model:LibraryModel
    var body:some View {NavigationSplitView{SidebarView(model:model)}detail:{LibraryContent(model:model)}.navigationSplitViewStyle(.balanced).tint(accent).frame(minWidth:1100,minHeight:740).overlay{if let busy=model.busy{ZStack{Color(nsColor:.windowBackgroundColor).opacity(0.9);VStack(spacing:17){ProgressView();Text(busy).font(.headline);Text("Your original audio stays unchanged.").font(.caption).foregroundStyle(.secondary)}}}}
        .sheet(isPresented:$model.transfer){TransferView(model:model)}
        .sheet(isPresented:$model.newCollection){VStack(alignment:.leading,spacing:20){Text("A new collection.").font(.title.bold());TextField("Collection name",text:$model.collectionName).textFieldStyle(.roundedBorder).onSubmit(model.createCollection);HStack{Button("Cancel"){model.newCollection=false};Spacer();Button("Create collection",action:model.createCollection).keyboardShortcut(.defaultAction)}}.padding(30).frame(width:400)}
        .alert("BickRipassRingtones",isPresented:Binding(get:{model.error != nil},set:{if !$0{model.error=nil}})){Button("OK"){model.error=nil}}message:{Text(model.error ?? "")}
    }
}
@MainActor enum LibraryRecovery {
    static func pickLibrary()->URL? {
        let panel=NSOpenPanel();panel.title="Locate your ringtone library";panel.message="Choose Library, or the unzipped release folder that contains it.";panel.prompt="Open library";panel.canChooseDirectories=true;panel.canChooseFiles=false;panel.allowsMultipleSelection=false
        while panel.runModal() == .OK {
            if let url=panel.url,let library=LibraryLocation.existingLibrary(at:url){return library}
            let alert=NSAlert();alert.messageText="Choose the folder containing library.sqlite3";alert.informativeText="Select the Library folder from the unzipped release. Your files have not been changed.";alert.runModal()
        }
        return nil
    }
    static func recover(defaultDirectory:URL)->URL? {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps:true)
        while true {
            let alert=NSAlert();alert.messageText="Locate your ringtone library";alert.informativeText="macOS may launch a temporary copy of this app where nearby folders are not visible. Your Library folder can still be beside the original app. Select it once and its location will be remembered.";alert.addButton(withTitle:"Locate Library…");alert.addButton(withTitle:"Start an empty library");alert.addButton(withTitle:"Quit")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                if let url=pickLibrary(){LibraryLocation.remember(url);return url}
            case .alertSecondButtonReturn:
                LibraryLocation.remember(defaultDirectory);return defaultDirectory
            default:return nil
            }
        }
    }
}
enum AppContext {static var library:ToneLibrary!}
struct BickRipassRingtonesApp:App {
    @StateObject private var model=LibraryModel(library:AppContext.library)
    var body:some Scene {WindowGroup("BickRipassRingtones"){RootView(model:model)}.defaultSize(width:1380,height:960).windowStyle(.titleBar).commands{CommandGroup(replacing:.newItem){Button("Import audio…",action:model.chooseFiles).keyboardShortcut("i");Button("New collection…"){model.newCollection=true}.keyboardShortcut("n");Divider();Button("Open library…",action:model.chooseLibrary).keyboardShortcut("o",modifiers:[.command,.shift]).disabled(model.busy != nil)};CommandMenu("Tones"){Button("Play / pause"){model.play()};Button("Export M4R…"){model.export(format:"m4r")}.keyboardShortcut("e");Button("Transfer to iPhone…"){model.transfer=true};Divider();Button("Reveal recent export"){model.reveal()}.disabled(model.lastExport==nil)}}}
}
@main struct BickRipassRingtonesMain {
    @MainActor static func main(){
        do {
            if CommandLine.arguments.contains("--verify"){try verifyNativeLibrary();return}
            let path=Bundle.main.object(forInfoDictionaryKey:"BickRipassRingtonesDataDirectory") as? String
            let portable=Bundle.main.object(forInfoDictionaryKey:"BickRipassRingtonesPortableLibrary") as? String == "Library"
            let standard=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("BickRipassRingtones")
            let resolved=LibraryLocation.resolve(bundleURL:Bundle.main.bundleURL,portable:portable,configured:path,remembered:LibraryLocation.remembered(),defaultDirectory:standard)
            let directory:URL
            switch resolved {
            case .ready(let url):directory=url
            case .needsRecovery:
                guard let recovered=LibraryRecovery.recover(defaultDirectory:standard) else{return}
                directory=recovered
            }
            AppContext.library=try ToneLibrary(directory:directory)
            BickRipassRingtonesApp.main()
        }catch{if CommandLine.arguments.contains("--verify"){fputs("Verification failed: \(error.localizedDescription)\n",stderr);exit(1)};let alert=NSAlert();alert.messageText="BickRipassRingtones could not open its library";alert.informativeText=error.localizedDescription;alert.runModal()}
    }
}
