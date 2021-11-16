//
//  KSStreamServer.swift
//  KSHLSPlayer
//
//  Created by Ken Sun on 2016/1/21.
//  Copyright © 2016年 KS. All rights reserved.
//

import Foundation
import Swifter

open class KSStreamServer {
    
    struct Config {
        /**
            Timeout in seconds of client being idle from requesting m3u8 playlist.
         */
        static let clientIdleTimeout = 5.0
        /**
            Number of times we tolerate playlist requests failed in a sequence.
         */
        static let playlistFailureMax = 10
        /**
            Number of times we tolerate unchanged playlist is received in a sequence.
         */
        static let playlistUnchangeMax = 10
        /**
            Playlist filename.
         */
        static let playlistFilename = "stream.m3u8"
        
        static let defaultPort: UInt16 = 9999
    }
        
    weak var delegate: KSStreamServerDelegate?
    
    /**
        Stream source url.
     */
    internal let sourceUrl: String
    /**
        Local server address. Dynamically generated every time {@link #startService()} is called.
        http://x.x.x.x:port
     */
    internal var serviceUrl: String!
    /**
        Local http server for HLS service.
     */
    internal var httpServer: HttpServer?
    
    internal(set) open var streaming = false
    
    internal var serviceReadyNotified = false
    
    internal var playlistFailureTimes = 0
    
    internal var playlistUnchangeTimes = 0
    
    fileprivate var idleTimer: Timer?
    
    public init(source: String) {
        self.sourceUrl = source
    }
    
    open func playlistUrl() -> String? {
        return serviceUrl != nil ? serviceUrl + "/" + Config.playlistFilename : nil
    }
    
    // override
    open func startService() -> Bool {
        if streaming { return false }
        streaming = true
        serviceReadyNotified = false
        playlistFailureTimes = 0
        playlistUnchangeTimes = 0
        return true
    }
    // override
    open func stopService() {
        streaming = false
        stopIdleTimer()
        httpServer?.stop()
    }
    // override
    open func outputPlaylist() -> String? {
        return nil
    }
    // override
    open func outputSegmentData(_ filename: String) -> Data? {
        return nil
    }
    
    internal func prepareHttpServer() throws {
        httpServer = HttpServer()
        if let server = httpServer {
            // m3u8
            server["/" + Config.playlistFilename] = { [weak self] request in
                if let m3u8 = self?.outputPlaylist() {
                    return HttpResponse.ok(.text(m3u8))
                } else {
                    return HttpResponse.notFound
                }
            }
            // ts
            server["/(.+).ts"] = { [weak self] request in
                if let filename = request.path.split(separator: "/").last {
                    if let data = self?.outputSegmentData(String(filename)) {
                        return HttpResponse.raw(200, "OK", nil, { (writer) in
                            try writer.write(data.byteArray())
                        })
                    } else {
                        return HttpResponse.notFound
                    }
                } else {
                    return HttpResponse.badRequest(nil)
                }
            }
            try server.start(Config.defaultPort)
        }
    }
    
    internal func resetIdleTimer() {
        stopIdleTimer()
        idleTimer = Timer.scheduledTimer(timeInterval: Config.clientIdleTimeout, target: self, selector: #selector(clientDidIdle), userInfo: nil, repeats: false)
    }
    
    internal func stopIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = nil
    }
    
    internal func serviceDidReady() {
        if serviceReadyNotified { return }
        
        if let urlStr = playlistUrl(), let url = URL(string: urlStr), delegate != nil  {
            serviceReadyNotified = true
            executeDelegateFunc({ _self in
                _self.delegate?.streamServer(_self, streamDidReady: url)
            })
        }
    }
    
    @objc fileprivate func clientDidIdle() {
        executeDelegateFunc({ _self in
            _self.delegate?.streamServer(clientIdle: _self)
        })
    }
    
    internal func executeDelegateFunc(_ block: @escaping (_ _self: KSStreamServer) -> ()) {
        if delegate != nil {
            DispatchQueue.main.async(execute: { [weak self] in
                if let weakSelf = self {
                    block(weakSelf)
                }
            })
        }
    }
}

public protocol KSStreamServerDelegate: AnyObject {
    
    func streamServer(_ server: KSStreamServer, streamDidReady url: URL)
    
    func streamServer(_ server: KSStreamServer, streamDidFail error: KSError)
    
    func streamServer(_ server: KSStreamServer, playlistDidEnd playlist: HLSPlaylist)
    
    func streamServer(clientIdle server: KSStreamServer)
}

extension Data {
    
    func byteArray() -> [UInt8] {
        return Array(UnsafeBufferPointer(start: (self as NSData).bytes.bindMemory(to: UInt8.self, capacity: self.count), count: self.count))
    }
}
