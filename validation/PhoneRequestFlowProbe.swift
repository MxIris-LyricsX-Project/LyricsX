import AppKit
import Combine
import IOBluetooth
import MusicPlayer

private final class Wire: PhoneTransport {
    var onOpen: (() -> Void)?
    var onData: ((Data) -> Void)?
    var onClose: ((String) -> Void)?
    var onStatus: ((String) -> Void)?
    var coverPSM: UInt16? = 0x1009
    var sent: [Data] = []
    var addresses: [String] = []
    var disconnects = 0
    func connect(address: String) { addresses.append(address) }
    func disconnect() { disconnects += 1 }
    var acknowledgeCommands = true
    func send(_ data: Data) {
        sent.append(data)
        if acknowledgeCommands, data.count == 8, data[5] == 0x7c {
            var reply = data; reply[0] |= 2; reply[3] = 9
            onData?(reply)
        }
    }
    func command(_ pdu: UInt8, event: UInt8? = nil) -> Data? {
        sent.last { packet in let b = [UInt8](packet); return b.count >= 13 && b[9] == pdu && (event == nil || b[13] == event) }
    }
    func answer(_ command: Data, _ parameters: [UInt8], code: UInt8 = 0x0c, fragment: UInt8 = 0, pdu: UInt8? = nil) {
        let b = [UInt8](command)
        onData?(Data([b[0] | 2, 0x11, 0x0e, code, 0x48, 0, 0, 0x19, 0x58, pdu ?? b[9], fragment, UInt8(parameters.count >> 8), UInt8(parameters.count & 255)] + parameters))
    }
}

private final class ArtworkWire: PhoneArtworkTransport {
    var onReady: (() -> Void)?
    var onImage: ((String, Data) -> Void)?
    var onState: ((PhoneArtworkState) -> Void)?
    var endpoints: [UInt16?] = []
    var handles: [String] = []
    var sessionRestarts = 0
    func connect(address: String) {}
    func connect(address: String, psm: UInt16?) { endpoints.append(psm) }
    func fetch(handle: String) { handles.append(handle) }
    func restartSession() { sessionRestarts += 1 }
    func disconnect() {}
}

@main private enum RequestFlowProbe {
 static func main() {
  var count=0
  func check(_ ok:Bool,_ message:String){guard ok else {print("FAIL: \(message)");exit(1)};count += 1;print("PASS: \(message)")}
  let prefs=UserDefaults(suiteName:"LyricsX.FlowProbe."+UUID().uuidString)!
  prefs.set(true, forKey: "PhoneBluetoothEnabled")
  var time=Date();let wire=Wire();let phone=PhonePlayer(transport:wire,coverArt:ArtworkWire(),preferences:prefs,now:{time})
  let playing:[UInt8]=[0,2,0xbf,0x20,0,0,0x03,0xe8,1]
  func song(_ title:String)->[UInt8]{[1,0,0,0,1,0,106,0,UInt8(title.utf8.count)]+Array(title.utf8)}
  func trackEvent(_ id:UInt8){wire.answer(wire.command(0x31,event:2)!,[2,0,0,0,0,0,0,0,id],code:0x0d)}
  phone.connect(address:"00-00-00-00-00-01",name:"Fixture");wire.onOpen?()
  wire.answer(wire.command(0x20)!,song("A"));wire.answer(wire.command(0x30)!,playing)
  wire.answer(wire.command(0x10)!,[3,1,2]);wire.answer(wire.command(0x31,event:2)!,[2,0,0,0,0,0,0,0,1],code:0x0f)
  phone.skipToNextItem()
  let meta=wire.command(0x20)!,status=wire.command(0x30)!
  time=time.addingTimeInterval(0.8);phone.updatePlayerState()
  check(wire.command(0x20)==meta,"800ms metadata request retains its original transaction")
  trackEvent(2)
  check(wire.command(0x20)==meta,"track notification coalesces with command refresh")
  wire.answer(meta,song("B"));wire.answer(status,playing)
  check(phone.currentTrack?.title=="B","valid delayed reply updates title without retry")
  let afterB=wire.sent.count;trackEvent(2)
  check(phone.currentTrack?.title=="B","duplicate nonzero UID does not clear published title")
  check(wire.sent.dropFirst(afterB).filter{$0.count>9 && $0[9]==0x20}.isEmpty,"duplicate event does not send duplicate metadata query")
  phone.skipToNextItem()
  wire.answer(wire.command(0x20)!,song("Early metadata"));wire.answer(wire.command(0x30)!,playing)
  check(phone.currentTrack?.title=="Early metadata","new title can precede its notification")
  trackEvent(3)
  check(phone.currentTrack?.title=="Early metadata","late confirmation of a completed skip does not blank the new title")
  wire.answer(wire.command(0x20)!,song("Early metadata"));wire.answer(wire.command(0x30)!,playing)
  phone.skipToNextItem()
  wire.answer(wire.command(0x20)!,song("Following metadata"));wire.answer(wire.command(0x30)!,playing)
  trackEvent(3) // Late duplicate of the previous notification, before the new one.
  check(phone.currentTrack?.title=="Following metadata","old duplicate UID leaves the new metadata visible")
  trackEvent(4)
  check(phone.currentTrack?.title=="Following metadata","old duplicate UID cannot consume the pending new-song confirmation")
  wire.answer(wire.command(0x20)!,song("Following metadata"));wire.answer(wire.command(0x30)!,playing)
  trackEvent(5)
  check(phone.currentTrack==nil && phone.isLoadingTrack,"a distinct subsequent song notification still clears stale content immediately")
  wire.answer(wire.command(0x20)!,song("Actual next song"));wire.answer(wire.command(0x30)!,playing)
  // Keep the first press/release unacknowledged; more clicks must queue.
  wire.acknowledgeCommands=false
  let boundary=wire.sent.count
  phone.skipToNextItem();phone.skipToNextItem();phone.skipToPreviousItem()
  func buttons()->[Data]{Array(wire.sent.dropFirst(boundary)).filter{$0.count==8 && $0[5]==0x7c}}
  check(buttons().count==2,"only one button pair is in flight")
  check(phone.currentTrack==nil && phone.isLoadingTrack,"queued skips clear old content once")
  check(phone.playbackState.isPlaying,"metadata loading does not synthesize STOPPED")
  func ack(_ data:Data){var r=data;r[0] |= 2;r[3]=9;wire.onData?(r)}
  ack(buttons()[1]);check(buttons().count==2,"release ACK alone does not dispatch next pair")
  ack(buttons()[0]);check(buttons().count==4,"both ACKs dispatch the next queued click")
  ack(buttons()[2]);ack(buttons()[3]);check(buttons().count==6,"third click is preserved in order")
  check(buttons().map{$0[6]} == [0x4b,0xcb,0x4b,0xcb,0x4c,0xcc],"rapid next next previous preserves command order")
  ack(buttons()[4]);ack(buttons()[5])
  wire.answer(wire.command(0x20)!,song("C"));wire.answer(wire.command(0x30)!,playing)
  check(phone.currentTrack?.title=="C","metadata queries proceed after the final button acknowledgement")
  // An in-flight query from an older generation must drain before a new one.
  wire.acknowledgeCommands=true
  phone.skipToNextItem();let oldMeta=wire.command(0x20)!,oldStatus=wire.command(0x30)!
  phone.skipToNextItem()
  check(wire.command(0x20)==oldMeta,"superseding click does not flood identical query kind")
  wire.answer(oldMeta,song("Intermediate"))
  check(phone.currentTrack==nil && wire.command(0x20) != oldMeta,"old response is consumed without publication and immediately dispatches latest demand")
  wire.answer(oldStatus,playing)
  wire.answer(wire.command(0x20)!,song("D"));wire.answer(wire.command(0x30)!,playing)
  check(phone.currentTrack?.title=="D","latest generation wins after out-of-date response")
  // Real IOBluetooth trace: both eight-byte acknowledgements arrived as
  // one 16-byte callback. They must complete immediately, not time out.
  wire.acknowledgeCommands=false
  let beforeBatch=wire.sent.count
  phone.skipToNextItem()
  let pair=wire.sent.dropFirst(beforeBatch).filter{$0.count==8 && $0[5]==0x7c}
  var first=pair[0],second=pair[1];first[0] |= 2;first[3]=9;second[0] |= 2;second[3]=9
  let beforeMetadata=wire.command(0x20)!
  wire.onData?(first+second)
  check(wire.command(0x20) != beforeMetadata,"combined press/release ACK callback immediately unblocks metadata")
  func response(_ command:Data,_ parameters:[UInt8])->Data {
   Data([command[0]|2,0x11,0x0e,0x0c,0x48,0,0,0x19,0x58,command[9],0,UInt8(parameters.count>>8),UInt8(parameters.count&255)]+parameters)
  }
  let combined=response(wire.command(0x20)!,song("Batch"))+response(wire.command(0x30)!,playing)
  wire.onData?(combined)
  check(phone.currentTrack?.title=="Batch" && !phone.isLoadingTrack,"combined metadata/status callback publishes both responses")
  let fragment=Data([0x16,2,0x11,0x0e,0x0c,0x48,0])
  check(AVRCPCodec.controlPackets(fragment)==[fragment],"AVCTP fragment boundary stays intact")
  check(AVRCPCodec.controlPackets(Data(combined.dropLast()))==[Data(combined.dropLast())],"truncated batch cannot be mis-split")
  wire.acknowledgeCommands=true
  phone.skipToNextItem()
  wire.answer(wire.command(0x30)!,playing) // Old 180s status is temporarily returned.
  let durationSong=[UInt8(2)]+song("Duration").dropFirst()+[0,0,0,7,0,106,0,6]+Array("200000".utf8)
  wire.answer(wire.command(0x20)!,Array(durationSong))
  check(phone.currentTrack?.duration==200 && phone.playbackTime==0,"new metadata duration replaces the previous song clock")
  time=time.addingTimeInterval(1.1);phone.updatePlayerState()
  wire.answer(wire.command(0x30)!,playing)
  check(phone.currentTrack?.title=="Duration" && phone.playbackTime==0,"late mismatched duration does not clear the new song")
  time=time.addingTimeInterval(0.3);phone.updatePlayerState()
  let freshStatus:[UInt8]=[0,3,0x0d,0x40,0,0,0,0,1]
  wire.answer(wire.command(0x30)!,freshStatus)
  check(phone.currentTrack?.title=="Duration" && !phone.isChangingTrack,"matching new clock settles without an extra empty transition")
  phone.skipToPreviousItem()
  wire.answer(wire.command(0x20)!,Array(durationSong))
  check(phone.currentTrack==nil,"same-title response waits for restart evidence")
  wire.answer(wire.command(0x30)!,freshStatus)
  time=time.addingTimeInterval(0.3);phone.updatePlayerState()
  wire.answer(wire.command(0x20)!,Array(durationSong))
  check(phone.currentTrack?.title=="Duration","previous restart accepts same song before the two-second guard expires")
  phone.disconnect();check(!phone.isLoadingTrack,"disconnect clears queued work and loading")
  print("\(count) request lifecycle checks passed")
 }
}
