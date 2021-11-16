//
//  KSEventProvider.swift
//  KSHLSPlayer
//
//  Created by Ken Sun on 2016/1/18.
//  Copyright © 2016年 KS. All rights reserved.
//

import Foundation

open class KSEventProvider: KSStreamProvider {
    
    struct Config {
        /**
            Output segment data cache may be full if consumption is not fast enough. To prevent manager
            from halting forever, we set the maximum times allowing output unchanged. It this limit is hit,
            manager will clean cache automatically for receiving new segment data.
         */
        static let unchangedOutputMax = 10
        
        /// Additional Config constants after migration
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
        Event will be cached with this id as key.
     */
    let eventId: String
    
    /**
        Event storage for `eventId`.
     */
    fileprivate let storage: KSEventStorage
    
    fileprivate let playlist: HLSPlaylist
    
    /**
        If true, manager will clean segment data cache automatically when cache is full.
        Otherwise, you should clean by yourself. Monitor segment data cache and call
        {@link #consumeSegment(String)} to consume segment. Default is false.
     */
    var autoManageCache = false
    
    fileprivate var consumedSegments: Set<String> = Set()
        
    fileprivate var outputUnchangeTimes = 0
    
    /**
        Represent whether preload from disk is complete.
     
        While initializing provider, playlist and TS data will be loaded from disk if they were cached.
        If this playlist is ended and all TS data of segments in it are available, this property will be true.
     */
    fileprivate(set) open var completePreload = false
    
    fileprivate var ending = false
    
    fileprivate var buffering = false
    
    public override convenience init(serviceUrl: String) {
        self.init(serviceUrl: serviceUrl, eventId: "\(Date.init().timeIntervalSince1970)")
    }
    
    required public init(serviceUrl: String, eventId: String) {
        self.eventId = eventId
        storage = KSEventStorage(eventId: eventId)
        playlist = storage.loadPlaylist() ?? HLSPlaylist(version: Config.HLSVersion, targetDuration: nil, sequence: nil, segments: [])
        super.init(serviceUrl: serviceUrl)
        
        /* Load ts data from disk */
        if playlist.segments.count > 0 {
            var incomplete = false
            // load ts data from disk
            for ts in playlist.segments {
                segments.append(ts)
                if !hasSegmentData(ts.filename()) {
                    incomplete = true
                }
            }
            // update status
            completePreload = !incomplete && playlist.isEnd()
        } else if playlist.isEnd() {
            completePreload = true
        }
        if completePreload {
            ending = true
        }
    }
    
    open func cleanUp() {
        synced(segmentFence, closure: { [unowned self] in
            self.segments.removeAll()
            self.segmentData.removeAll()
            self.outputSegments.removeAll()
        })
        outputPlaylist = nil
    }
    
    open func setTargetDuration(_ duration: Double) {
        playlist.targetDuration = duration
    }
    
    open func targetDuration() -> Double? {
        return playlist.targetDuration
    }
    
    /**
        Whether segment data exists in memory or disk.
        If not in memory but in disk, load it to memory.
        @param filename
        @return
     */
    open func hasSegmentData(_ filename: String) -> Bool {
        if segmentData[filename] != nil {
            return true
        } else {
            if let data = storage.loadTS(filename) {
                segmentData[filename] = data
                return true
            } else {
                return false
            }
        }
    }
    
    /**
        Whether playlist is ended and all data of segments in playlist exist in memory or disk.
     */
    open func hasAllSegmentData() -> Bool {
        if !playlist.isEnd() { return false }
        
        for ts in playlist.segments {
            let filename = ts.filename()
            if segmentData[filename] != nil { continue }
            if !storage.tsFileExists(filename) { return false }
        }
        return true
    }
    
    /**
        Push segment to input list.
     */
    open func push(_ ts: TSSegment) {
        synced(segmentFence, closure: { [unowned self] in
            if !self.playlist.segmentNames.contains(ts.filename()) {
                /* Add segment to playlist */
                self.playlist.addSegment(ts)
                self.segments += [ts]
                /* Try to load segment data from disk */
                self.hasSegmentData(ts.filename())
            }
        })
    }
    
    /**
        Drop segment from input list if data doesn't exist.
     */
    open func drop(_ ts: TSSegment) {
        synced(segmentFence, closure: { [unowned self] in
            if self.segmentData[ts.filename()] == nil {
                if let index = self.segments.firstIndex(of: ts) {
                    self.segments.remove(at: index)
                }
            }
        })
    }
    
    open func fill(_ ts: TSSegment, data: Data) {
        synced(segmentFence, closure: { [unowned self] in
            let filename = ts.filename()
            self.segmentData[filename] = data
            self.storage.saveTS(data, filename: filename)
        })
    }
    
    open func consume(_ filename: String) -> Data? {
        return synced(segmentFence, closure: { [unowned self] () -> Data? in
            for i in 0..<self.segments.count {
                if self.segments[i].filename() == filename {
                    self.consumedSegments.insert(filename)
                    self.segments.remove(at: i)
                    break
                }
            }
            return self.segmentData.removeValue(forKey: filename)
        })
    }
    
    open func endPlaylist() {
        ending = true
        buffering = false
        playlist.end = true
        updateEndingList()
    }
    
    fileprivate func updateOutputPlaylist() -> Bool {
        var didUpdate = false
        synced(segmentFence, closure: { [unowned self] in
            let (newTS, startIndex): (TSSegment?, Int?) = {
                /* New segment is the next one of the last one in output list */
                if let index = self.indexOfNextOutputSegment() {
                    return (self.segments[index], index)
                }
                /* New segment is the first one in list */
                else {
                    let ts = self.segments.first
                    return (ts, ts != nil ? 0 : nil)
                }
            }()
            /* Can't prepare for new playlist */
            if newTS == nil || self.segmentData[newTS!.filename()] == nil {
                return
            }
            /* Add new segments to output list */
            var newSegmentCount = 0
            if let index = startIndex {
                for i in index..<self.segments.count {
                    let ts = self.segments[i]
                    /* No data for next segment, stop adding to output playlist */
                    if !self.isConsumed(ts) && !self.hasSegmentData(ts.filename()) {
                        break
                    }
                    if !self.outputSegments.contains(ts) {
                        self.outputSegments += [ts]
                        newSegmentCount += 1
                    }
                }
            }
            /* Generate output playlist */
            let output = HLSPlaylist(version: Config.HLSVersion, targetDuration: self.playlist.targetDuration, sequence: 0, segments: self.outputSegments)
            output.type = HLSPlaylist.StreamType.EVENT
            output.end = false
            if self.playlist.isEnd() {
                /* Check if playlist is sync */
                if self.outputSegments.last?.filename() == self.playlist.segmentNames.last {
                    self.ending = true
                    output.end = true
                }
            }
            self.outputPlaylist = output.generate(self.serviceUrl, end: output.end!)
            
            /* Save playlist to disk */
            if !self.playlist.isEnd() && newSegmentCount > 0 {
                self.storage.savePlaylist(self.playlist.generate(self.serviceUrl))
            }
            
            didUpdate = newSegmentCount > 0
        })
        
        return didUpdate
    }
    
    fileprivate func updateEndingList() {
        synced(segmentFence, closure: { [unowned self] in
            /* Add new segments to output playlist */
            if let startIndex = self.indexOfNextOutputSegment() ?? (self.segments.first != nil ? 0 : nil) {
                /* Add new segments to output playlist */
                for i in startIndex..<self.segments.count {
                    let ts = self.segments[i]
                    /* No data for next segment, stop adding to output playlist */
                    if !self.isConsumed(ts) && !self.hasSegmentData(ts.filename()) {
                        break
                    }
                    if !self.outputSegments.contains(ts) {
                        self.outputSegments += [ts]
                    }
                }
            }
            /* Generate output playlist */
            let output = HLSPlaylist(version: Config.HLSVersion, targetDuration: self.playlist.targetDuration, sequence: 0, segments: self.outputSegments)
            output.type = HLSPlaylist.StreamType.EVENT
            output.end = self.segments.count == 0 || self.outputSegments.last == self.segments.last
            self.outputPlaylist = output.generate(self.serviceUrl, end: output.end!)
            
            /* Save playlist to disk */
            self.storage.savePlaylist(self.playlist.generate(self.serviceUrl))
        })
    }
    
    override open func providePlaylist() -> String? {
        /* If we don't have enough segments, start buffering */
        if outputSegments.count < Config.tsPrebufferSize && !ending {
            buffering = true
        }
        /* Before we have enough buffer, we don't update playlist */
        if buffering {
            /* If buffer is enough, stop buffering and update playlist */
            if bufferedSegmentCount() >= Config.tsPrebufferSize {
                buffering = false
                updateOutputPlaylist()
                outputUnchangeTimes = 0
            }
            /* If output list unchanged limit hits, clean cache */
            outputUnchangeTimes += 1
            if outputUnchangeTimes > Config.unchangedOutputMax {
                synced(segmentFence, closure: { [unowned self] in
                    self.outputUnchangeTimes = 0
                    /* Drop some segments */
                    if let index = self.indexOfNextOutputSegment() {
                        let ts = self.segments.remove(at: index)
                        self.segmentData[ts.filename()] = nil
                    }
                })
            }
        } else {
            if ending {
                updateEndingList()
            } else {
                /* If playlist is not changed, start buffering */
                if !updateOutputPlaylist() {
                    buffering = true
                }
            }
        }
        return outputPlaylist
    }
    
    fileprivate func isConsumed(_ ts: TSSegment) -> Bool {
        return consumedSegments.contains(ts.filename())
    }
}

