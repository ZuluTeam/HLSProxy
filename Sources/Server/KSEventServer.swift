//
//  KSEventServer.swift
//  KSHLSPlayer
//
//  Created by Ken Sun on 2016/1/23.
//  Copyright © 2016年 KS. All rights reserved.
//

import Foundation

open class KSEventServer: KSStreamServer, KSEventReceiverDelegate {
    
    struct Config {
        static let tsCacheUpperLine = 25
        
        static let tsCacheLowerLine = 20
        
        static let defaultPort: UInt16 = 9999
        
        /**
            Number of times we tolerate unchanged playlist is received in a sequence.
        */
        static let playlistUnchangeMax = 10
        /**
            Number of times we tolerate playlist requests failed in a sequence.
         */
        static let playlistFailureMax = 10
    }
    
    fileprivate var receiver: KSEventReceiver!
    
    fileprivate var provider: KSEventProvider!
    
    public let eventId: String
    
    fileprivate var idleTimerPaused = false
    
    public init(source: String, eventId: String) {
        self.eventId = eventId
        super.init(source: source)
    }
    
    // override
    open override func startService() -> Bool {
        if !super.startService() { return false }
        
        /* Prepare http server */
        do {
            try prepareHttpServer()
        } catch {
            print("Establish http server failed.")
            return false
        }
        
        /* Prepare provider */
        let service = "http://localhost:\(Config.defaultPort)"
        provider = KSEventProvider(serviceUrl: service, eventId: eventId)
        
        /* Prepare receiver */
        receiver = KSEventReceiver(url: sourceUrl)
        receiver.delegate = self
        if !provider.completePreload {
            receiver.start()
        }
        /* Start service if buffer is enough */
        if provider.isBufferEnough() {
            serviceDidReady()
        }
        
        return true
    }
    
    // override
    open override func stopService() {
        super.stopService()
        receiver?.stop()
        receiver = nil
        provider?.cleanUp()
        provider = nil
    }
    
    // override
    open override func outputPlaylist() -> String? {
        stopIdleTimer()
        if !idleTimerPaused {
            resetIdleTimer()
        }
        return provider?.outputPlaylist
    }
    
    // override
    open override func outputSegmentData(_ filename: String) -> Data? {
        let data = provider?.consume(filename)
        if let r = receiver, let p = provider, r.paused && p.cachedSegmentSize() <= Config.tsCacheLowerLine {
            receiver.resume()
        }
        return data
    }
    
    open func pauseIdleTimer() {
        idleTimerPaused = true
        stopIdleTimer()
    }
    
    open func resumeIdleTimer() {
        idleTimerPaused = false
        resetIdleTimer()
    }
    
    // MARK: - KSEventReceiverDelegate
    
    func receiver(_ receiver: KSStreamReciever, didReceivePlaylist playlist: HLSPlaylist) {
        if playlistUnchangeTimes > 0 {
            playlistUnchangeTimes = 0
        }
        if playlistFailureTimes > 0 {
            playlistFailureTimes = 0
        }
        if let p = provider, p.targetDuration() == nil && playlist.targetDuration != nil {
            p.setTargetDuration(playlist.targetDuration!)
        }
    }
    
    func receiver(_ receiver: KSStreamReciever, playlistDidNotChange playlist: HLSPlaylist) {
        if playlistFailureTimes > 0 {
            playlistFailureTimes = 0
        }
        playlistUnchangeTimes += 1
        if playlistUnchangeTimes > Config.playlistUnchangeMax {
            executeDelegateFunc({ _self in
                _self.delegate?.streamServer(_self, streamDidFail: KSError(code: .playlistUnchanged))
            })
            stopService()
        }
    }
    
    func receiver(_ receiver: KSStreamReciever, playlistDidFailWithError error: NSError?, urlStatusCode code: Int) {
        if code == 404 {
            executeDelegateFunc({ _self in
                _self.delegate?.streamServer(_self, streamDidFail: KSError(code: .playlistNotFound))
            })
            stopService()
        } else if code == 403 {
            executeDelegateFunc({ _self in
                _self.delegate?.streamServer(_self, streamDidFail: KSError(code: .accessDenied))
            })
            stopService()
        } else {
            playlistFailureTimes += 1
            if playlistFailureTimes > Config.playlistFailureMax {
                executeDelegateFunc({ _self in
                    _self.delegate?.streamServer(_self, streamDidFail: KSError(code: .playlistUnavailable))
                })
                stopService()
            }
        }
    }
    
    func receiver(_ receiver: KSStreamReciever, didReceiveSegment segment: TSSegment, data: Data) {
        provider?.fill(segment, data: data)
        
        /* Pause downloading if cache is near to full */
        if let r = self.receiver, let p = provider, !r.paused && p.cachedSegmentSize() >= Config.tsCacheUpperLine {
            r.pause()
        }
        if let p = provider, p.isBufferEnough() {
            serviceDidReady()
        }
    }
    
    func receiver(_ receiver: KSEventReceiver, segmentDidFail segment: TSSegment, withError error: NSError?) {
        provider?.drop(segment)
    }
    
    func receiver(_ receiver: KSEventReceiver, playlistDidEnd playlist: HLSPlaylist) {
        // end playlist
        provider?.endPlaylist()
        
        executeDelegateFunc({ _self in
            _self.delegate?.streamServer(_self, playlistDidEnd: playlist)
        })
    }
    
    func receiver(_ receiver: KSEventReceiver, didPushSegments segments: [TSSegment]) {
        for ts in segments {
            provider?.push(ts)
        }
    }
    
    func receiver(_ receiver: KSEventReceiver, shouldDownloadSegment segment: TSSegment) -> Bool {
        return provider != nil && !(provider!.hasSegmentData(segment.filename()))
    }
}
