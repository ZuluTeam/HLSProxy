//
//  KSEventStorage.swift
//  KSHLSPlayer
//
//  Created by Ken Sun on 2016/1/19.
//  Copyright © 2016年 KS. All rights reserved.
//

import Foundation

let documentDirectory: String = {
    NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0]
}()

func documentFile(_ filename: String) -> String {
    return documentDirectory + "/" + filename
}

open class KSEventStorage {
    
    static let root: String = documentFile("Events")
    
    struct Config {
        /**
            Maximum cache size in disk.
         */
        static let diskCacheSize = 50 * 1024 * 1024;    // 50 MB
    }
    
    let eventId: String
    
    required public init(eventId: String) {
        self.eventId = eventId
    }
    
    // MARK: - Storage Paths
    
    open func folderPath() -> String {
        return (KSEventStorage.root as NSString).appendingPathComponent(eventId)
    }
    
    open func playlistPath() -> String {
        return (folderPath() as NSString).appendingPathComponent("playlist.m3u8")
    }
    
    open func tsPath(_ filename: String) -> String {
        return (folderPath() as NSString).appendingPathComponent(filename)
    }
    
    fileprivate func assureFolder() -> Bool {
        let fm = FileManager()
        let folder = folderPath()
        if !fm.fileExists(atPath: folder) {
            do {
                try fm.createDirectory(atPath: folder, withIntermediateDirectories: true, attributes: nil)
            } catch {
                print("Create folder for event \(eventId) failed.")
                return false
            }
        }
        return true
    }
    
    fileprivate func removeFile(_ filePath: String) -> Bool {
        let fm = FileManager()
        if fm.fileExists(atPath: filePath) {
            do {
                try fm.removeItem(atPath: filePath)
            } catch {
                print("Remove file failed - \(filePath)")
                return false
            }
        }
        return true
    }
    
    // MARK: - Playlist
    
    open func loadPlaylist() -> HLSPlaylist? {
        if let data = try? Data(contentsOf: URL(fileURLWithPath: playlistPath())) {
            return HLSPlaylist(data: data)
        } else {
            return nil
        }
    }
    
    open func savePlaylist(_ text: String) -> Bool {
        // assure folder exists
        if !assureFolder() { return false }
        
        let filePath = playlistPath()
        
        // remove old file
        if !removeFile(filePath) { return false }

        // save file
        do {
            try text.write(toFile: filePath, atomically: true, encoding: String.Encoding.utf8)
            return true
        } catch {
            print("Save playlist for event \(eventId) failed.")
            return false
        }
    }
    
    // MARK: - TS
    
    open func tsFileExists(_ filename: String) -> Bool {
        return FileManager().fileExists(atPath: tsPath(filename))
    }
    
    open func loadTS(_ filename: String) -> Data? {
        do {
            return try Data.init(contentsOf: URL(fileURLWithPath: tsPath(filename)), options: NSData.ReadingOptions.uncachedRead)
        } catch {
            return nil
        }
    }
    
    open func saveTS(_ data: Data, filename: String) -> Bool {
        // assure folder exists
        if !assureFolder() { return false }
        
        let filePath = tsPath(filename)
        
        // remove old file
        if !removeFile(filePath) { return false }
        
        // save file
        return ((try? data.write(to: URL(fileURLWithPath: filePath), options: [.atomic])) != nil)
    }
    
    open func deleteFiles() -> Bool {
        do {
            try FileManager.default.removeItem(atPath: folderPath())
            return true
        } catch {
            print("Delete event \(eventId) failed.")
            return false
        }
    }
}
