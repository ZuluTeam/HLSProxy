//
//  KSStreamReceiver.swift
//  KSHLSPlayer
//
//  Created by Ken Sun on 2016/1/12.
//  Copyright © 2016年 KS. All rights reserved.
//

import Foundation
import QuartzCore
// FIXME: comparison operators with optionals were removed from the Swift Standard Libary.
// Consider refactoring the code to use the non-optional operators.
fileprivate func < <T : Comparable>(lhs: T?, rhs: T?) -> Bool {
  switch (lhs, rhs) {
  case let (l?, r?):
    return l < r
  case (nil, _?):
    return true
  default:
    return false
  }
}

// FIXME: comparison operators with optionals were removed from the Swift Standard Libary.
// Consider refactoring the code to use the non-optional operators.
fileprivate func > <T : Comparable>(lhs: T?, rhs: T?) -> Bool {
  switch (lhs, rhs) {
  case let (l?, r?):
    return l > r
  default:
    return rhs < lhs
  }
}


open class KSStreamReciever {
    
    struct Config {
        /**
            Max number of concurrent TS segments download tasks.
         */
        static let concurrentDownloadMax = 3
        /**
            Number of segments that we keep in hand to maintain downloading list.
         */
        static let segmentWindowSize = 10
        /**
            The timeout for response of request in seconds.
         */
        static let requestTimeout = 3.0
        /**
            The timeout for receiving data of request in seconds.
        */
        static let resourceTimeout = 10.0
    }
        
    let playlistUrl: String
    
    /**
        Authentication info.
     */
    var username: String?
    var password: String?
    /**
        URL query string.
    */
    var m3u8Query: String?
    var tsQuery: String?
    
    /**
        HLS components.
    */
    internal var playlist: HLSPlaylist!
    internal var segments: [TSSegment] = []
    /**
        Be sure to lock `segments` when operatiing on it.
    */
    internal let segmentFence: AnyObject = NSObject()
    
    internal var session: URLSession?
    internal var playlistTask: URLSessionTask?
    
    /**
        ts url path -> task
    */
    internal var segmentTasks: [String : URLSessionTask] = [:]
    
    internal var tsDownloads: Set<String> = Set()
    
    internal var pollingPlaylist = false
    
    /**
        Cached data for lastest playlist.
    */
    fileprivate var playlistData: Data!
    
    required public init(url: String) {
        playlistUrl = url
    }
    
    func startPollingPlaylist() {
        if pollingPlaylist { return }
        pollingPlaylist = true
        
        let conf = URLSessionConfiguration.default
        conf.timeoutIntervalForRequest = Config.requestTimeout
        conf.timeoutIntervalForResource = Config.resourceTimeout
        session = URLSession.init()
        
        getPlaylist()
    }
    
    func stopPollingPlaylist() {
        playlistTask?.cancel()
        playlistTask = nil
        pollingPlaylist = false
    }
    
    func getPlaylist() {
        let url: String
        if let m3u8Query = m3u8Query {
            url = "\(playlistUrl)?\(m3u8Query)"
        } else {
            url = playlistUrl
        }
//        let url = m3u8Query != nil ? "\(playlistUrl)?\(m3u8Query)" : playlistUrl
        var time: TimeInterval?
        
        playlistTask = session?.dataTask(with: URL.init(string: url)!, completionHandler: { [weak self] data, response, error in
            self?.handlePlaylistResponse(data, response: response, error: error, startTime: time!)
        } as! (Data?, URLResponse?, Error?) -> Void)
        if let task = playlistTask {
            time = CACurrentMediaTime()
            task.resume()
        }
    }
    
    fileprivate func handlePlaylistResponse(_ data: Data?, response: URLResponse?, error: NSError?, startTime: TimeInterval) {
        // success
        if (response as? HTTPURLResponse)?.statusCode == 200 && data?.count > 0 {
            var interval: TimeInterval!
            // playlist is unchanged
            if playlistData != nil && playlistData == data! {
                playlistDidNotChange()
                interval = (playlist?.targetDuration ?? 1.0) / 2
            } else {
                playlistData = data
                playlist = HLSPlaylist(data: playlistData)
                playlistDidUpdate()
                getSegments()
                interval = playlist.targetDuration ?? 1.0
            }
            // polling playlist
            if pollingPlaylist && prepareForPlaylist() {
                // interval should minus past time for connection
                let delay = interval - (CACurrentMediaTime() - startTime)
                if delay <= 0 {
                    getPlaylist()
                } else {
                    let popTime = DispatchTime.now() + Double(Int64(delay * Double(NSEC_PER_SEC))) / Double(NSEC_PER_SEC)
                    DispatchQueue.main.asyncAfter(deadline: popTime, execute: { [weak self] in
                        self?.getPlaylist()
                    })
                }
            }
        }
        // failure
        else {
            playlistDidFail(response as? HTTPURLResponse, error: error)
        }
    }
    
    // override
    func playlistDidFail(_ response: HTTPURLResponse?, error: NSError?) {
        
    }
    
    // override
    func playlistDidNotChange() {
        
    }
    // override
    func playlistDidUpdate() {
        
    }
    // override
    func prepareForPlaylist() -> Bool {
        return true
    }
    // override
    func getSegments() {
        
    }
    
    func isSegmentConnectionFull() -> Bool {
        return segmentTasks.count >= Config.concurrentDownloadMax
    }
    
    func downloadSegment(_ ts: TSSegment) {
        if isSegmentConnectionFull() { return }
        
        willDownloadSegment(ts)
        
        tsDownloads.insert(ts.url)
        
        let url: String
        if let tsQuery = tsQuery {
            url = "\(ts.url)?\(tsQuery)"
        } else {
            url = ts.url
        }
//        let url = tsQuery != nil ? "\(ts.url)?\(tsQuery)" : ts.url
        let task = session?.dataTask(with: URL.init(string: url)!, completionHandler: { [weak self] data, response, error in
            self?.handleSegmentResponse(ts, data: data, response: response, error: error)
        } as! (Data?, URLResponse?, Error?) -> Void)
        if task != nil {
            segmentTasks[ts.url] = task
            task!.resume()
        }
    }
    
    fileprivate func handleSegmentResponse(_ ts: TSSegment, data: Data?, response: URLResponse?, error: NSError?) {
        // success
        if (response as? HTTPURLResponse)?.statusCode == 200 && data?.count > 0 {
            didDownloadSegment(ts, data: data!)
        }
        // failure
        else {
            segmentDidFail(ts, response: response as? HTTPURLResponse, error: error)
        }
    }
    
    func finishSegment(_ ts: TSSegment) {
        segmentTasks[ts.url] = nil
        if !isSegmentConnectionFull() {
            getSegments()
        }
    }
    
    // override
    func segmentDidFail(_ ts: TSSegment, response: HTTPURLResponse?, error: NSError?) {
        // this must be called to finish task
        finishSegment(ts)
    }
    
    // override
    func willDownloadSegment(_ ts: TSSegment) {
        
    }
    
    // override
    func didDownloadSegment(_ ts: TSSegment, data: Data) {
        // this must be called to finish task
        finishSegment(ts)
    }
}

protocol KSStreamReceiverDelegate: AnyObject {
    
    func receiver(_ receiver: KSStreamReciever, didReceivePlaylist playlist: HLSPlaylist)
    
    func receiver(_ receiver: KSStreamReciever, playlistDidNotChange playlist: HLSPlaylist)
    
    func receiver(_ receiver: KSStreamReciever, playlistDidFailWithError error: NSError?, urlStatusCode code: Int)
    
    func receiver(_ receiver: KSStreamReciever, didReceiveSegment segment: TSSegment, data: Data)
    
    func receiver(_ receiver: KSEventReceiver, segmentDidFail segment: TSSegment, withError error: NSError?)
}
