// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import SQLite3

func gestureThreadURL(_ thread:String,environment:String?=nil)->URL? {
    let allowed=CharacterSet(charactersIn:"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
    func valid(_ s:String)->Bool{!s.isEmpty && s.count<=128 && s.unicodeScalars.allSatisfy{allowed.contains($0)}}
    let local=environment ?? (try? String(contentsOfFile:NSHomeDirectory()+"/.t3/userdata/environment-id",encoding:.utf8))?.trimmingCharacters(in:.whitespacesAndNewlines)
    guard valid(thread),let local,valid(local) else{return nil}
    return URL(string:"t3code://threads/"+local+"/"+thread)
}
func pendingInputThread()throws->String? {
    var handle:OpaquePointer?
    guard sqlite3_open_v2(NSHomeDirectory()+"/.t3/userdata/statev2.sqlite",&handle,SQLITE_OPEN_READONLY,nil)==SQLITE_OK,let db=handle else{if let handle{sqlite3_close(handle)};throw DatabaseError()}
    defer{sqlite3_close(db)};sqlite3_busy_timeout(db,150)
    return try query(db,"SELECT r.thread_id FROM orchestration_v2_projection_runtime_requests r JOIN orchestration_v2_projection_threads t USING(thread_id) WHERE r.resolved_at IS NULL AND r.status NOT IN ('resolved','cancelled','failed','expired') AND r.kind IN ('user_input','approval','permission') AND t.archived_at IS NULL AND t.deleted_at IS NULL ORDER BY r.created_at DESC,r.runtime_request_id LIMIT 1").first?.first
}

// A successful handoff advances the gesture queue even before T3 records a visit.
// A later completion in the same thread becomes eligible again.
func nextGestureDone(_ finished:[String:Double],delivered:[String:Double])->String? {
    finished.filter{($0.value > (delivered[$0.key] ?? 0))}.sorted{$0.value == $1.value ? $0.key<$1.key:$0.value>$1.value}.first?.key
}

// Match T3's unread Done badge from the latest run, independently of MagDot's
// LED expiry and of which turns MagDot happened to observe running.
func pendingDoneThreads(path:String=NSHomeDirectory()+"/.t3/userdata/statev2.sqlite")throws->[String:Double] {
    var handle:OpaquePointer?
    guard sqlite3_open_v2(path,&handle,SQLITE_OPEN_READONLY,nil)==SQLITE_OK,let db=handle else{if let handle{sqlite3_close(handle)};throw DatabaseError()}
    defer{sqlite3_close(db)};sqlite3_busy_timeout(db,150)
    let rows=try query(db,"""
        SELECT r.thread_id,r.completed_at,json_extract(t.payload_json,'$.lastVisitedAt')
        FROM orchestration_v2_projection_runs r JOIN orchestration_v2_projection_threads t USING(thread_id)
        WHERE t.archived_at IS NULL AND t.deleted_at IS NULL AND r.status='completed' AND r.completed_at IS NOT NULL
        AND json_extract(t.payload_json,'$.settledOverride') IS NOT 'settled'
        AND NOT EXISTS(SELECT 1 FROM orchestration_v2_projection_runs newer WHERE newer.thread_id=r.thread_id AND newer.ordinal>r.ordinal)
        AND (json_extract(t.payload_json,'$.snoozedUntil') IS NULL OR json_extract(t.payload_json,'$.snoozedUntil')<=strftime('%Y-%m-%dT%H:%M:%fZ','now'))
        """)
    var result=[String:Double]()
    for row in rows{let completed=timestamp(row[1]),visited=timestamp(row[2]);if completed>0 && !row[2].isEmpty && (visited==0 || completed>visited){result[row[0]]=completed}}
    return result
}

// Observe unread episodes rather than requiring a running -> completed edge.
// Marking an old completion unread therefore gets its own Done-light duration.
struct UnreadDoneLight {
    private var episodes=[String:(completion:Double,observed:Double)]()
    mutating func update(_ unread:[String:Double],now:Double,duration:Double)->Bool{
        episodes=episodes.filter{unread[$0.key] != nil}
        for (thread,completion) in unread where episodes[thread]?.completion != completion{episodes[thread]=(completion,now)}
        return episodes.values.contains{duration==0 || now<$0.observed+duration}
    }
    // The current unread list is authoritative for Done. The older turn tracker
    // can retain a completion after a manual settle, so never revive it here.
    static func mode(tracked:String,unread:Bool,working:Bool=false)->String{
        if tracked=="attention"{return "attention"}
        if unread{return "finished"}
        return tracked=="finished" ? (working ? "working":"idle"):tracked
    }
}
