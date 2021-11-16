//
//  HLSPlaylist.swift
//  KSHLSPlayer
//
//  Created by Ken Sun on 2016/1/11.
//  Copyright © 2016年 KS. All rights reserved.
//

import Foundation

open class HLSPlaylist {
    
    struct Schema {
        static let Head = "#EXTM3U"
        static let ListType = "#EXT-X-PLAYLIST-TYPE"
        static let TargetDuration = "#EXT-X-TARGETDURATION"
        static let Version = "#EXT-X-VERSION"
        static let Sequence = "#EXT-X-MEDIA-SEQUENCE"
        static let Discontinuity = "#EXT-X-DISCONTINUITY"
        static let Inf = "#EXTINF"
        static let Endlist = "#EXT-X-ENDLIST"
    }
    
    public enum StreamType: String {
        case LIVE, EVENT, VOD
    }
    
    var type: StreamType?
    
    var version: String?
    
    var targetDuration: Double?
    
    var sequence: Int?
    
    var end: Bool?
    
    fileprivate(set) open var segments: [TSSegment] = []
    
    fileprivate(set) open var segmentNames: [String] = []
    
    fileprivate(set) open var discontinuity: Bool = false
    
    init(version: String?, targetDuration: Double?, sequence: Int?, segments: [TSSegment]) {
        self.version = version
        self.targetDuration = targetDuration
        self.sequence = sequence
        self.segments = segments
        for ts in segments {
            segmentNames.append(ts.filename())
        }
    }
    
    init(data: Data) {
        if let text = NSString(data: data, encoding: String.Encoding.utf8.rawValue) as String? {
            parseText(text)
        }
    }
    
    fileprivate func parseText(_ text: String) {
        segments = []
        segmentNames = []
        version = nil
        targetDuration = nil
        sequence = nil
        end = nil
        let lines = text.components(separatedBy: "\n")
        for i in 0..<lines.count {
            let str = lines[i]
            // target duration
            if targetDuration == nil && str.hasPrefix(Schema.TargetDuration) {
//                let value = str.substring(from: Schema.TargetDuration.index(after: Schema.TargetDuration.endIndex))
                let value = String(str[..<Schema.TargetDuration.endIndex])
                targetDuration = Double(value)
            }
            // version
            else if version == nil && str.hasPrefix(Schema.Version) {
//                version = str.substring(from: Schema.Version.index(after: Schema.Version.endIndex))
                version = String(str[..<Schema.Version.endIndex])
            }
            // sequence
            else if sequence == nil && str.hasPrefix(Schema.Sequence) {
//                let value = str.substring(from: Schema.Sequence.index(after: Schema.Sequence.endIndex))
                let value = String(str[..<Schema.Sequence.endIndex])
                sequence = Int(value)
            }
            // segments
            else if str.hasPrefix(Schema.Inf) {
                let seq = (sequence ?? 0) + segments.count
//                let value = str.substring(with: Schema.Inf.index(after: Schema.Inf.endIndex)..<str.index(before: str.endIndex))
                let value = String(str[Schema.Inf.endIndex..<str.endIndex])
                let ts = TSSegment(url: lines[i + 1], duration: Double(value)!, sequence: seq)
                segments.append(ts)
                segmentNames.append(ts.filename())
            }
            // end list
            else if str.hasPrefix(Schema.Endlist) {
                end = true
            }
        }
    }
    
    func generate(_ baseUrl: String?) -> String {
        return generate(baseUrl, end: isEnd())
    }
    
    func generate(_ baseUrl: String?, end: Bool) -> String {
        // head
        var string = Schema.Head + "\n"
        // Type
        if let t = type {
            string += Schema.ListType + ":\(t.rawValue)\n"
        }
        // target duration
        if let t = targetDuration {
            string += Schema.TargetDuration + ":\(t)\n"
        }
        // version
        if let v = version {
            string += Schema.Version + ":\(v)\n"
        }
        // sequence
        if let s = sequence {
            string += Schema.Sequence + ":\(s)\n"
        }
        // segments
        for ts in segments {
            // duration
            string += Schema.Inf + ":\(ts.duration),\n"
            // url
            if let base = baseUrl {
                string += "\(base)/\(ts.filename())\n"
            } else {
                string += "\(ts.url)\n"
            }
        }
        // end list
        if end {
            string += Schema.Endlist
        }
        return string
    }
    
    func isEnd() -> Bool {
        return end ?? false
    }
    
    func addSegment(_ ts: TSSegment) {
        segments += [ts]
        segmentNames += [ts.filename()]
    }
}
