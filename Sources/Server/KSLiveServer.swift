//
//  KSLiveServer.swift
//  KSHLSPlayer
//
//  Created by Ken Sun on 2016/1/23.
//  Copyright © 2016年 KS. All rights reserved.
//

import Foundation

open class KSLiveServer: KSStreamServer, KSLiveReceiverDelegate {
    
    fileprivate var receiver: KSLiveReceiver!
    
    fileprivate var provider: KSLiveProvider!
    
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
        provider = KSLiveProvider(serviceUrl: service)
        
        /* Prepare receiver */
        receiver = KSLiveReceiver(url: sourceUrl)
        receiver.delegate = self
        
        receiver.start()
        
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
        resetIdleTimer()
        return provider?.providePlaylist()
    }
    // override
    open override func outputSegmentData(_ filename: String) -> Data? {
        return provider?.provideSegment(filename)
    }
    
    open func startRecording(_ folderPath: String) {
        provider?.startSaving(folderPath)
    }
    
    open func stopRecording() {
        provider?.stopSaving()
    }
    
    // MARK: - KSLiveReceiverDelegate
    
    func receiver(_ receiver: KSStreamReciever, didReceivePlaylist playlist: HLSPlaylist) {
        if playlistUnchangeTimes > 0 {
            playlistUnchangeTimes = 0
        }
        if playlistFailureTimes > 0 {
            playlistFailureTimes = 0
        }
        provider.targetDuration = playlist.targetDuration
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
        if let p = provider, p.isBufferEnough() {
            serviceDidReady()
        }
    }
    
    func receiver(_ receiver: KSEventReceiver, segmentDidFail segment: TSSegment, withError error: NSError?) {
        print("Download ts failed - \(segment.url)")
        provider?.drop(segment)
    }
    
    func receiver(_ receiver: KSLiveReceiver, didPushSegment segment: TSSegment) {
        provider?.push(segment)
    }
    
    func receiver(_ receiver: KSLiveReceiver, didDropSegment segment: TSSegment) {
        provider?.drop(segment)
    }
}
