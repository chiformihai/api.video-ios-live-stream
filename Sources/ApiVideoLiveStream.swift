//
//  ApiVideoLiveStream.swift
//
import AVFoundation
import Foundation
import HaishinKit
import VideoToolbox

public class ApiVideoLiveStream {
    private var mthkView: MTHKView?
    private var streamKey: String = ""
    private var url: String = ""
    private let rtmpStream: RTMPStream
    private let rtmpConnection = RTMPConnection()

    public var onConnectionSuccess: (() -> Void)?
    public var onConnectionFailed: ((String) -> Void)?
    public var onDisconnect: (() -> Void)?

    ///  Getter and Setter for an AudioConfig
    ///  Can't be updated
    public var audioConfig: AudioConfig? {
        didSet {
            if let audioConfig = audioConfig {
                prepareAudio(audioConfig: audioConfig)
            }
        }
    }

    /// Getter and Setter for a VideoConfig
    /// Can't be updated
    public var videoConfig: VideoConfig? {
        didSet {
            if let videoConfig = videoConfig {
                prepareVideo(videoConfig: videoConfig)
            }
        }
    }

    /// Getter and Setter for the Bitrate number for the video
    public var videoBitrate: Int {
        get {
            return rtmpStream.videoSettings[.bitrate] as! Int
        }
        set(newValue) {
            rtmpStream.videoSettings[.bitrate] = newValue
        }
    }

    /// Camera position
    public var camera: AVCaptureDevice.Position = .back {
        didSet {
            attachCamera()
        }
    }

    /// Audio mute or not.
    public var isMuted: Bool {
        get {
            return rtmpStream.audioSettings[.muted] as! Bool
        }
        set(newValue) {
            rtmpStream.audioSettings[.muted] = newValue
        }
    }

    /// init a new ApiVideoLiveStream
    /// - Parameters:
    ///   - initialAudioConfig: The ApiVideoLiveStream's new AudioConfig
    ///   - initialVideoConfig: The ApiVideoLiveStream's new VideoConfig
    ///   - preview: UiView to display the preview of camera
    public init(initialAudioConfig: AudioConfig?, initialVideoConfig: VideoConfig?, preview: UIView?) throws {
        let session = AVAudioSession.sharedInstance()

        // https://stackoverflow.com/questions/51010390/avaudiosession-setcategory-swift-4-2-ios-12-play-sound-on-silent
        if #available(iOS 10.0, *) {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
        } else {
            session.perform(NSSelectorFromString("setCategory:withOptions:error:"), with: AVAudioSession.Category.playAndRecord, with: [
                AVAudioSession.CategoryOptions.allowBluetooth,
                AVAudioSession.CategoryOptions.defaultToSpeaker,
            ])
            try session.setMode(.default)
        }
        try session.setActive(true)

        audioConfig = initialAudioConfig
        videoConfig = initialVideoConfig

        rtmpStream = RTMPStream(connection: rtmpConnection)
        DispatchQueue.main.async {
            if let orientation = DeviceUtil.videoOrientation(by: UIApplication.shared.statusBarOrientation) {
                self.rtmpStream.orientation = orientation
            }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(orientationDidChange(_:)), name: UIDevice.orientationDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(didEnterBackground(_:)), name: UIApplication.didEnterBackgroundNotification, object: nil)

        attachCamera()
        if let videoConfig = videoConfig {
            prepareVideo(videoConfig: videoConfig)
        }
        attachAudio()
        if let audioConfig = audioConfig {
            prepareAudio(audioConfig: audioConfig)
        }

        if preview != nil {
            mthkView = MTHKView(frame: preview!.bounds)
            mthkView!.translatesAutoresizingMaskIntoConstraints = false
            mthkView!.videoGravity = AVLayerVideoGravity.resizeAspectFill
            DispatchQueue.main.async {
                self.mthkView!.attachStream(self.rtmpStream)
            }
            preview!.addSubview(mthkView!)

            let maxWidth = mthkView!.widthAnchor.constraint(lessThanOrEqualTo: preview!.widthAnchor)
            let maxHeight = mthkView!.heightAnchor.constraint(lessThanOrEqualTo: preview!.heightAnchor)
            let width = mthkView!.widthAnchor.constraint(equalTo: preview!.widthAnchor)
            let height = mthkView!.heightAnchor.constraint(equalTo: preview!.heightAnchor)
            let centerX = mthkView!.centerXAnchor.constraint(equalTo: preview!.centerXAnchor)
            let centerY = mthkView!.centerYAnchor.constraint(equalTo: preview!.centerYAnchor)

            width.priority = .defaultHigh
            height.priority = .defaultHigh

            NSLayoutConstraint.activate([
                maxWidth, maxHeight, width, height, centerX, centerY,
            ])
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self, name: UIDevice.orientationDidChangeNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: UIApplication.didEnterBackgroundNotification, object: nil)
    }

    private func attachCamera() {
        rtmpStream.captureSettings[.isVideoMirrored] = camera == .front
        rtmpStream.attachCamera(DeviceUtil.device(withPosition: camera)) { error in
            print("======== Camera error ==========")
            print(error.description)
        }
    }

    private func prepareVideo(videoConfig: VideoConfig) {
        rtmpStream.captureSettings = [
            .sessionPreset: AVCaptureSession.Preset.high,
            .fps: videoConfig.fps,
            .continuousAutofocus: true,
            .continuousExposure: true,
            // .preferredVideoStabilizationMode: AVCaptureVideoStabilizationMode.auto // Add latency to video
        ]
        rtmpStream.videoSettings = [
            .width: rtmpStream.orientation.isLandscape ? videoConfig.resolution.instance.width : videoConfig.resolution.instance.height,
            .height: rtmpStream.orientation.isLandscape ? videoConfig.resolution.instance.height : videoConfig.resolution.instance.width,
            .profileLevel: kVTProfileLevel_H264_Baseline_5_2,
            .bitrate: videoConfig.bitrate,
            .maxKeyFrameIntervalDuration: 1,
        ]
    }

    private func attachAudio() {
        rtmpStream.attachAudio(AVCaptureDevice.default(for: AVMediaType.audio)) { error in
            print("======== Audio error ==========")
            print(error.description)
        }
    }

    private func prepareAudio(audioConfig: AudioConfig) {
        rtmpStream.audioSettings = [
            .bitrate: audioConfig.bitrate,
        ]
    }

    /// Start your livestream
    /// - Parameters:
    ///   - streamKey: The key of your live
    ///   - url: The url of your rtmp server, by default it's rtmp://broadcast.api.video/s
    /// - Returns: Void
    public func startStreaming(streamKey: String, url: String = "rtmp://broadcast.api.video/s") throws {
        if streamKey.isEmpty {
            throw LiveStreamError.IllegalArgumentError("Stream key must not be empty")
        }
        if audioConfig == nil || videoConfig == nil {
            throw LiveStreamError.IllegalArgumentError("Missing audio and/or video configuration")
        }

        self.streamKey = streamKey
        self.url = url

        rtmpConnection.addEventListener(.rtmpStatus, selector: #selector(rtmpStatusHandler), observer: self)
        rtmpConnection.addEventListener(.ioError, selector: #selector(rtmpErrorHandler), observer: self)

        rtmpConnection.connect(url)
    }

    /// Stop your livestream
    /// - Returns: Void
    public func stopStreaming() {
        rtmpConnection.close()
        rtmpConnection.removeEventListener(.rtmpStatus, selector: #selector(rtmpStatusHandler), observer: self)
        rtmpConnection.removeEventListener(.ioError, selector: #selector(rtmpErrorHandler), observer: self)
    }

    @objc private func rtmpStatusHandler(_ notification: Notification) {
        let e = Event.from(notification)
        guard let data: ASObject = e.data as? ASObject, let code: String = data["code"] as? String else {
            return
        }
        switch code {
        case RTMPConnection.Code.connectSuccess.rawValue:
            if onConnectionSuccess != nil {
                onConnectionSuccess!()
            }
            rtmpStream.publish(streamKey)
        case RTMPConnection.Code.connectFailed.rawValue:
            if onConnectionFailed != nil {
                onConnectionFailed!(code)
            }
        case RTMPConnection.Code.connectClosed.rawValue:
            if onDisconnect != nil {
                onDisconnect!()
            }
        default:
            break
        }
    }

    @objc
    private func rtmpErrorHandler(_ notification: Notification) {
        let e = Event.from(notification)
        print("rtmpErrorHandler: \(e)")
        DispatchQueue.main.async {
            self.rtmpConnection.connect(self.url)
        }
    }

    @objc
    private func orientationDidChange(_: Notification) {
        guard let orientation = DeviceUtil.videoOrientation(by: UIApplication.shared.statusBarOrientation) else {
            return
        }
        rtmpStream.orientation = orientation
    }

    @objc
    private func didEnterBackground(_: Notification) {
        stopStreaming()
    }
}

extension AVCaptureVideoOrientation {
    var isLandscape: Bool { return self == .landscapeLeft || self == .landscapeRight }
}

public enum LiveStreamError: Error {
    case IllegalArgumentError(String)
}
