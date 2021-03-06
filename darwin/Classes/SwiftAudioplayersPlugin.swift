import AVKit
import AVFoundation

#if os(iOS)
import UIKit
import MediaPlayer
#endif

#if os(iOS)
import Flutter
#else
import FlutterMacOS
#endif

#if os(iOS)
let osName = "iOS"
#else
let osName = "macOS"
#endif

let CHANNEL_NAME = "xyz.luan/audioplayers"
let AudioplayersPluginStop = NSNotification.Name("AudioplayersPluginStop")

public class SwiftAudioplayersPlugin: NSObject, FlutterPlugin {
    
    var registrar: FlutterPluginRegistrar
    var channel: FlutterMethodChannel
    var notificationsHandler: NotificationsHandler? = nil

    var players = [String : WrappedMediaPlayer]()
    // last player that started playing, to be used for notifications command center
    // TODO(luan): provide generic way to control this
    var lastPlayerId: String? = nil

    var timeObservers = [TimeObserver]()
    var keyValueObservations = [String : NSKeyValueObservation]()
    
        
    var isDealloc = false
    var updateHandleMonitorKey: Int64? = nil
    
    #if os(iOS)
    var headlessEngine: FlutterEngine
    var callbackChannel: FlutterMethodChannel
    var headlessServiceInitialized = false
    #endif
    
    init(registrar: FlutterPluginRegistrar, channel: FlutterMethodChannel) {
        self.registrar = registrar
        self.channel = channel
        
        #if os(iOS)
        // this method is used to listen to audio playpause event
        // from the notification area in the background.
        self.headlessEngine = FlutterEngine.init(name: "AudioPlayerIsolate")
        // This is the method channel used to communicate with
        // `_backgroundCallbackDispatcher` defined in the Dart portion of our plugin.
        // Note: we don't add a MethodCallDelegate for this channel now since our
        // BinaryMessenger needs to be initialized first, which is done in
        // `startHeadlessService` below.
        self.callbackChannel = FlutterMethodChannel(name: "xyz.luan/audioplayers_callback", binaryMessenger: headlessEngine.binaryMessenger)
        #endif
        
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(self.needStop), name: AudioplayersPluginStop, object: nil)
        notificationsHandler = NotificationsHandler(reference: self)
    }
    
    public static func register(with registrar: FlutterPluginRegistrar) {
        // TODO(luan) apparently there is a bug in Flutter causing some inconsistency between Flutter and FlutterMacOS
        #if os(iOS)
        let binaryMessenger = registrar.messenger()
        #else
        let binaryMessenger = registrar.messenger
        #endif

        let channel = FlutterMethodChannel(name: CHANNEL_NAME, binaryMessenger: binaryMessenger)
        let instance = SwiftAudioplayersPlugin(registrar: registrar, channel: channel)
        registrar.addMethodCallDelegate(instance, channel: channel)
    }
    
    @objc func needStop() {
        isDealloc = true
        destroy()
    }
    
    func destroy() {
        for osberver in self.timeObservers {
            osberver.player.removeTimeObserver(osberver.observer)
        }
        self.timeObservers = []
        
        for (_, player) in self.players {
            player.clearObservers()
        }
        self.players = [:]
    }
    
    #if os(iOS)
    // Initializes and starts the background isolate which will process audio
    // events. `handle` is the handle to the callback dispatcher which we specified
    // in the Dart portion of the plugin.
    func startHeadlessService(handle: Int64) {
        // Lookup the information for our callback dispatcher from the callback cache.
        // This cache is populated when `PluginUtilities.getCallbackHandle` is called
        // and the resulting handle maps to a `FlutterCallbackInformation` object.
        // This object contains information needed by the engine to start a headless
        // runner, which includes the callback name as well as the path to the file
        // containing the callback.
        let info = FlutterCallbackCache.lookupCallbackInformation(handle)
        assert(info != nil, "failed to find callback")
        if info != nil {
            let entrypoint = info!.callbackName
            let uri = info!.callbackLibraryPath
            
            // Here we actually launch the background isolate to start executing our
            // callback dispatcher, `_backgroundCallbackDispatcher`, in Dart.
            self.headlessServiceInitialized = headlessEngine.run(withEntrypoint: entrypoint, libraryURI: uri)
            if self.headlessServiceInitialized {
                // The headless runner needs to be initialized before we can register it as a
                // MethodCallDelegate or else we get an illegal memory access. If we don't
                // want to make calls from `_backgroundCallDispatcher` back to native code,
                // we don't need to add a MethodCallDelegate for this channel.
                self.registrar.addMethodCallDelegate(self, channel: self.callbackChannel)
            }
        }
    }
    #endif
    
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let method = call.method
        
        guard let args = call.arguments as? [String: Any] else {
            log("Failed to parse call.arguments from Flutter.")
            result(0)
            return
        }
        guard let playerId = args["playerId"] as? String else {
            log("Call missing mandatory parameter playerId.")
            result(0)
            return
        }
        log("%@ => call %@, playerId %@", osName, method, playerId)
        
        let player = self.getOrCreatePlayer(playerId: playerId)

        if method == "startHeadlessService" {
            #if os(iOS)
            if let handleKey = args["handleKey"] {
                log("calling start headless service %@", handleKey)
                let handle = (handleKey as! [Any])[0]
                self.startHeadlessService(handle: (handle as! Int64))
            } else {
                result(0)
            }
            #else
            result(FlutterMethodNotImplemented)
            #endif
        } else if method == "monitorNotificationStateChanges" {
            #if os(iOS)
            if let handleMonitorKey = args["handleMonitorKey"] {
                log("calling monitor notification %@", handleMonitorKey)
                let handle = (handleMonitorKey as! [Any])[0]
                self.updateHandleMonitorKey = (handle as! Int64)
            } else {
                result(0)
            }
            #else
            result(FlutterMethodNotImplemented)
            #endif
        } else if method == "play" {
            guard let url = args["url"] as! String? else {
                log("Null url received on play")
                result(0)
                return
            }
            
            let isLocal: Bool = (args["isLocal"] as? Bool) ?? true
            let volume: Float = (args["volume"] as? Float) ?? 1.0

            // we might or might not want to seek
            let seekTimeMillis: Int? = (args["position"] as? Int)
            let seekTime: CMTime? = seekTimeMillis.map { toCMTime(millis: $0) }

            let respectSilence: Bool = (args["respectSilence"] as? Bool) ?? false
            let recordingActive: Bool = (args["recordingActive"] as? Bool) ?? false
            let duckAudio: Bool = (args["duckAudio"] as? Bool) ?? false
            
            player.play(
                url: url,
                isLocal: isLocal,
                volume: volume,
                time: seekTime,
                isNotification: respectSilence,
                duckAudio: duckAudio,
                recordingActive: recordingActive
            )
        } else if method == "pause" {
            player.pause()
        } else if method == "resume" {
            player.resume()
        } else if method == "stop" {
            player.stop()
        } else if method == "release" {
            player.release()
        } else if method == "seek" {
            let position = args["position"] as? Int
            if let position = position {
                let time = toCMTime(millis: position)
                player.seek(time: time)
            } else {
                log("Null position received on seek")
                result(0)
            }
        } else if method == "setUrl" {
            let url: String? = args["url"] as? String
            let isLocal: Bool = (args["isLocal"] as? Bool) ?? false
            let respectSilence: Bool = (args["respectSilence"] as? Bool) ?? false
            let recordingActive: Bool = (args["recordingActive"] as? Bool) ?? false
            
            if url == nil {
                log("Null URL received on setUrl")
                result(0)
                return
            }

            player.setUrl(
                url: url!,
                isLocal: isLocal,
                isNotification: respectSilence,
                recordingActive: recordingActive
            ) {
                player in
                result(1)
            }
        } else if method == "getDuration" {
            let duration = player.getDuration()
            result(duration)
        } else if method == "setVolume" {
            guard let volume = args["volume"] as? Float else {
                log("Error calling setVolume, volume cannot be null")
                result(0)
                return
            }

            player.setVolume(volume: volume)
        } else if method == "getCurrentPosition" {
            let currentPosition = player.getCurrentPosition()
            result(currentPosition)
        } else if method == "setPlaybackRate" {
            guard let playbackRate = args["playbackRate"] as? Float else {
                log("Error calling setPlaybackRate, playbackRate cannot be null")
                result(0)
                return
            }
            player.setPlaybackRate(playbackRate: playbackRate)
        } else if method == "setReleaseMode" {
            guard let releaseMode = args["releaseMode"] as? String else {
                log("Error calling setReleaseMode, releaseMode cannot be null")
                result(0)
                return
            }
            let looping = releaseMode.hasSuffix("LOOP")
            player.looping = looping
        } else if method == "earpieceOrSpeakersToggle" {
            guard let playingRoute = args["playingRoute"] as? String else {
                log("Error calling earpieceOrSpeakersToggle, playingRoute cannot be null")
                result(0)
                return
            }
            self.setPlayingRoute(playerId: playerId, playingRoute: playingRoute)
        } else if method == "setNotification" {
            log("setNotification called")
            let title: String? = args["title"] as? String
            let albumTitle: String? = args["albumTitle"] as? String
            let artist: String? = args["artist"] as? String
            let imageUrl: String? = args["imageUrl"] as? String
            
            let forwardSkipInterval: Int? = args["forwardSkipInterval"] as? Int
            let backwardSkipInterval: Int? = args["backwardSkipInterval"] as? Int
            let duration: Int? = args["duration"] as? Int
            let elapsedTime: Int? = args["elapsedTime"] as? Int
            
            let enablePreviousTrackButton: Bool? = args["enablePreviousTrackButton"] as? Bool
            let enableNextTrackButton: Bool? = args["enableNextTrackButton"] as? Bool

            guard let handler = notificationsHandler else {
                result(FlutterMethodNotImplemented)
                return
            }
            // TODO(luan) reconsider whether these params are optional or not + default values/errors
            handler.setNotification(
                playerId: playerId,
                title: title,
                albumTitle: albumTitle,
                artist: artist,
                imageUrl: imageUrl,
                forwardSkipInterval: forwardSkipInterval ?? 0,
                backwardSkipInterval: backwardSkipInterval ?? 0,
                duration: duration,
                elapsedTime: elapsedTime!,
                enablePreviousTrackButton: enablePreviousTrackButton,
                enableNextTrackButton: enableNextTrackButton
            )
        } else {
            log("Called not implemented method: %@", method)
            result(FlutterMethodNotImplemented)
            return
        }

        // shortcut to avoid requiring explicit call of result(1) everywhere
        if method != "setUrl" {
            result(1)
        }
    }
    
    func getOrCreatePlayer(playerId: String) -> WrappedMediaPlayer {
        if let player = players[playerId] {
            return player
        }
        let newPlayer = WrappedMediaPlayer(
            reference: self,
            playerId: playerId
        )
        players[playerId] = newPlayer
        return newPlayer
    }
    
    func onSeekCompleted(playerId: String, finished: Bool) {
        channel.invokeMethod("audio.onSeekComplete", arguments: ["playerId": playerId, "value": finished])
    }
    
    func onComplete(playerId: String) {
        channel.invokeMethod("audio.onComplete", arguments: ["playerId": playerId])
    }
    
    func onCurrentPosition(playerId: String, millis: Int) {
        channel.invokeMethod("audio.onCurrentPosition", arguments: ["playerId": playerId, "value": millis])
    }
    
    func onError(playerId: String) {
        channel.invokeMethod("audio.onError", arguments: ["playerId": playerId, "value": "AVPlayerItem.Status.failed"])
    }
    
    func onDuration(playerId: String, millis: Int) {
        channel.invokeMethod("audio.onDuration", arguments: ["playerId": playerId, "value": millis])
    }
    
    func onNotificationBackgroundPlayerStateChanged(playerId: String, value: String) {
        #if os(iOS)
        if headlessServiceInitialized {
            callbackChannel.invokeMethod(
                "audio.onNotificationBackgroundPlayerStateChanged",
                arguments: ["playerId": playerId, "updateHandleMonitorKey": updateHandleMonitorKey as Any, "value": value]
            )
        }
        #endif
    }
    
    func onNotificationPlayerStateChanged(playerId: String, isPlaying: Bool) {
        channel.invokeMethod("audio.onNotificationPlayerStateChanged", arguments: ["playerId": playerId, "value": isPlaying])
    }
    
    func onGotPreviousTrackCommand(playerId: String) {
        channel.invokeMethod("audio.onGotPreviousTrackCommand", arguments: ["playerId": playerId])
    }
    
    func onGotNextTrackCommand(playerId: String) {
        channel.invokeMethod("audio.onGotNextTrackCommand", arguments: ["playerId": playerId])
    }
    
    func updateCategory(
        recordingActive: Bool,
        isNotification: Bool,
        playingRoute: String
    ) {
        // TODO(luan) this method is a mess. figure out what is needed here and refactor
        #if os(iOS)
        let category = recordingActive ? AVAudioSession.Category.playAndRecord : (
            isNotification ? AVAudioSession.Category.ambient : AVAudioSession.Category.playback
        )
        
        do {
            let session = AVAudioSession.sharedInstance()
            // When using AVAudioSessionCategoryPlayback, by default, this implies that your app’s audio is nonmixable—activating your session
            // will interrupt any other audio sessions which are also nonmixable. AVAudioSessionCategoryPlayback should not be used with
            // AVAudioSessionCategoryOptionMixWithOthers option. If so, it prevents infoCenter from working correctly.
            if isNotification {
                try session.setCategory(category, options: AVAudioSession.CategoryOptions.mixWithOthers)
            } else {
                try session.setCategory(category)
                UIApplication.shared.beginReceivingRemoteControlEvents()
            }
            
            if playingRoute == "earpiece" {
                // Use earpiece speaker to play audio.
                try session.setCategory(AVAudioSession.Category.playAndRecord)
            }
            
            try session.setActive(true)
        } catch {
            log("Error setting category %@", error)
        }
        #endif
    }
    
    func maybeDeactivateAudioSession() {
        let hasPlaying = players.values.contains { player in player.isPlaying }
        if !hasPlaying {
            setAudioSessionActive(active: false)
        }
    }
    
    func setAudioSessionActive(active: Bool) {
        #if os(iOS)
        do {
            try AVAudioSession.sharedInstance().setActive(active)
        } catch {
            log("Error inactivating audio session %@", error)
        }
        #endif
    }
    
    func lastPlayer() -> WrappedMediaPlayer? {
        if let playerId = lastPlayerId {
            return getOrCreatePlayer(playerId: playerId)
        } else {
            return nil
        }
    }
    
    func updateNotifications(player: WrappedMediaPlayer, time: CMTime) {
        notificationsHandler?.update(playerId: player.playerId, time: time, playbackRate: player.playbackRate)
    }
    
    // TODO(luan) this should not be here. is playingRoute player-specific or global?
    func setPlayingRoute(playerId: String, playingRoute: String) {
        let wrappedPlayer = players[playerId]!
        wrappedPlayer.playingRoute = playingRoute
        
        #if os(iOS)
        let category = playingRoute == "earpiece" ? AVAudioSession.Category.playAndRecord : AVAudioSession.Category.playback
        do {
            try AVAudioSession.sharedInstance().setCategory(category)
        } catch {
            log("Error setting category %@", error)
        }
        #endif
    }
}
