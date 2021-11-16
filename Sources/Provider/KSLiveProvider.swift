//
//  KSLiveProvider.swift
//  KSHLSPlayer
//
//  Created by Ken Sun on 2016/1/18.
//  Copyright © 2016年 KS. All rights reserved.
//

import Foundation

/**
 * Provider has its own mechanism to maintain playlist and TS segments. The only thing you have
 *  to do is push and add segment to it. Please follow the rules:
 *  1. Push a segment by `push(ts: TSSegment)`.
 *  2. Fill segment data you have pushed by fill(ts: TSSegment, data: NSData). If you haven't push
 *     it before, data will be ignored.
 *  3. If you want to cancel a segment you have pushed, drop it by drop(ts: TSSegment).
 *     This may happen when you know you can't provide segment data for it anymore.
 *     Be aware if you don't drop such segment, provider will stop providing new playlist once
 *     its show time is come.
 *  4. If you drop a segment which is already been filled, nothing will happen. The segment still
 *     appears in output playlist when its show time comes.
 *
 *  Here's how provider provides playlist:
 *  1. Provider go through segment list which contains all pushed segments.
 *  2. For each segment, if its data has been filled, mark it as a valid segment.
 *  3. Once an invalid segment(a segment without filled data) encountered, provider stops going
 *     through segment list and see if new playlist is available from valid segments.
 */
open class KSLiveProvider: KSStreamProvider {
    
    struct Config {
        /**
            Maximum number of cached TS segment data.
         */
        static let tsDataCacheMax = 10
        /**
            Number of segments in output playlist.
         */
        static let playlistSegmentSize = 5
        
        /// Additional Config constants after migration
        /**
         HLS version in output playlist.
         */
        static let HLSVersion = "2"
        /**
         Number of segments that should be buffered when output is dried.
         */
        static let tsPrebufferSize = 2
    }
    
    /**
        Target duration in output playlist.
     */
    var targetDuration: Double?
    
    /**
        Sequence number in output playlist. Starts from 0.
     */
    fileprivate var sequenceNumber = 0
    
    fileprivate var buffering = false
    
    fileprivate var saveFolderPath: String?

    fileprivate var saving = false
    
    open func cleanUp() {
        synced(segmentFence, closure: { [unowned self] in
            self.segments.removeAll()
            self.outputSegments.removeAll()
            self.segmentData.removeAll()
        })
        self.outputPlaylist = nil
        sequenceNumber = 0
        buffering = false
    }
    
    /**
        push segment to input list.
     */
    open func push(_ ts: TSSegment) {
        synced(segmentFence, closure: { [unowned self] in
            self.segments += [ts]
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
        if !segments.contains(ts) { return }
        segmentData[ts.filename()] = data
        
        /**
            Maintain data cache size as `Config.tsDataCacheMax` or less.
        */
        synced(segmentFence, closure: { [unowned self] in
            if self.segmentData.count > Config.tsDataCacheMax {
                /* Remove segments from oldest */
                var overSize = self.segmentData.count - Config.tsDataCacheMax
                while overSize > 0 {
                    if self.segments.count == 0 { break }
                    if self.segmentData.removeValue(forKey: self.segments.removeFirst().filename()) != nil {
                        overSize = overSize - 1
                    }
                }
            }
        })
        /* Save file */
        if let folder = saveFolderPath, saving {
            let filePath = (folder as NSString).appendingPathComponent(ts.filename())
            try? data.write(to: URL(fileURLWithPath: filePath), options: [.atomic])
        }
    }
    
    open func startSaving(_ folder: String) {
        saveFolderPath = folder
        if !FileManager.default.fileExists(atPath: folder) {
            do {
                try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true, attributes: nil)
            } catch {
                print("create saving folder failed");
                return
            }
        }
        saving = true
        
        /* Save memory cached segments into disk */
        synced(segmentFence, closure: { [unowned self] in
            for filename in self.segmentData.keys {
                let data = self.segmentData[filename]
                let filePath = (folder as NSString).appendingPathComponent(filename)
                ((try? data?.write(to: URL(fileURLWithPath: filePath), options: [.atomic])) as ()??)
            }
        })
    }
    
    open func stopSaving() {
        saving = false
        saveFolderPath = nil
    }
    
    /**
        Provide latest output playlist.
     */
    override open func providePlaylist() -> String? {
        /* If we don't have enough segments, start buffering. */
        if outputSegments.count < Config.tsPrebufferSize {
            buffering = true
        }
        /* Before we have enough buffered segments, we don't update playlist. */
        if buffering {
            /* If buffer size is enough, stop buffering and update playlist. */
            if bufferedSegmentCount() >= Config.tsPrebufferSize {
                buffering = false
                updateOutputPlaylist()
            }
        } else {
            /* If playlist is not changed, start buffering. */
            if !updateOutputPlaylist() {
                buffering = true
            }
        }
        return outputPlaylist
    }
    
    fileprivate func updateOutputPlaylist() -> Bool {
        return synced(segmentFence, closure:{ [unowned self] () -> Bool in
            /* Check if plyalist should change */
            var changed = false
            for i in 0..<self.outputSegments.count {
                let ts = self.outputSegments[i]
                /* If any segment in output playlist doesn't exist anymore, change playlist. */
                if !self.segments.contains(ts) {
                    changed = true
                    break
                }
                /* If we have new segments, change playlist. */
                if i == self.outputSegments.count - 1 {
                    if let index = self.segments.firstIndex(of: ts), self.segments.count > index + 1 {
                        let nextNewSegment = self.segments[index + 1]
                        changed = self.segmentData[nextNewSegment.filename()] != nil
                    }
                }
            }
            if self.outputSegments.count > 0 && !changed {
                return false
            }
            /* Update playlist */
            var startIndex = 0
            if self.outputSegments.count > 0 {
                if let index = self.segments.firstIndex(of: self.outputSegments.last!) {
                    startIndex = index
                }
            }
            for i in startIndex..<self.segments.count {
                let ts = self.segments[i]
                if self.segmentData[ts.filename()] == nil { break }
                if !self.outputSegments.contains(ts) {
                    self.outputSegments += [ts]
                }
            }
            /* Remove old segments in playlist and increase sequence number. */
            if self.outputSegments.count > Config.playlistSegmentSize {
                let offset = self.outputSegments.count - Config.playlistSegmentSize
                self.outputSegments.removeSubrange((0 ..< offset))
                self.sequenceNumber += offset
            }
            /* Generate playlist */
            let m3u8 = HLSPlaylist(
                version: Config.HLSVersion,
                targetDuration: self.targetDuration,
                sequence: self.sequenceNumber,
                segments: self.outputSegments)
            self.outputPlaylist = m3u8.generate(self.serviceUrl, end: false)
            
            return true
        })
    }
}
