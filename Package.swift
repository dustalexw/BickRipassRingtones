// swift-tools-version: 5.9
import PackageDescription
let package=Package(name:"BickRipassRingtones",platforms:[.macOS(.v14)],products:[.executable(name:"BickRipassRingtones",targets:["BickRipassRingtones"])],targets:[.target(name:"DeviceBridge",path:"Bridge",publicHeadersPath:"include"),.executableTarget(name:"BickRipassRingtones",dependencies:["DeviceBridge"],path:"Sources",linkerSettings:[.linkedLibrary("sqlite3")])])
