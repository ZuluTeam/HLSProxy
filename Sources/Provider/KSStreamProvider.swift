//
//  KSStreamProvider.swift
//  KSHLSPlayer
//
//  Created by Ken Sun on 2016/1/19.
//  Copyright © 2016年 KS. All rights reserved.
//

import Foundation

open class KSStreamProvider {
    
    struct Config {
        /**
         Number of segments that should be buffered when output is dried.
         */
        static let tsPrebufferSize = 2
        /**
         HLS version in output playlist.
         */
        static let HLSVersion = "2"
    }
    
    /**
        Base URL of TS segment in output playlist.
     */
    let serviceUrl: String
    
    internal var outputPlaylist: String?
    
    /**
        TS segment input list.
        Segments in this list will be added to output if it's filled or not if it's dropped.
     */
    internal var segments: [TSSegment] = []
    /**
        TS segment output list.
        Segments in this list will be added to output playlist.
     */
    internal var outputSegments: [TSSegment] = []
    /**
        Segment data cache.
        TS filename -> data
     */
    internal var segmentData: [String : Data] = [:]
    
    internal let segmentFence: AnyObject = NSObject()
    
    public init(serviceUrl: String) {
        self.serviceUrl = serviceUrl
    }
    
    open func isBufferEnough() -> Bool {
        return bufferedSegmentCount() >= Config.tsPrebufferSize
    }
    
    open func bufferedSegmentCount() -> Int {
        var bufferCount = 0
        synced(segmentFence, closure: { [unowned self] in
            /**
                Start from the next segment of last one in output playlist.
                If not found, start from first.
             */
            let bufferIndex = self.indexOfNextOutputSegment() ?? 0
            for i in bufferIndex..<self.segments.count {
                if self.segmentData[self.segments[i].filename()] == nil { break }
                bufferCount += 1
            }
        })
        return bufferCount
    }
    
    open func cachedSegmentSize() -> Int {
        return segmentData.count
    }
    
    /**
        Provide latest output playlist.
     */
    open func providePlaylist() -> String? {
        return outputPlaylist
    }
    
    /**
     Provide TS segment data with specified filename.
     */
    open func provideSegment(_ filename: String) -> Data? {
        return segmentData[filename]
    }

    internal func indexOfNextOutputSegment() -> Int? {
        if let ts = outputSegments.last, ts != segments.last, let index = segments.firstIndex(of: ts) {
            return index + 1
        }
        return nil
    }
}
