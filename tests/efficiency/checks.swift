setbuf(stdout,nil)
func check(_ value:Bool,_ message:String){if !value {fputs("FAILED: \(message)\n",stderr);exit(1)}}
let parser=TimestampParser()
check(parser.parse("")==0,"empty")
check(parser.parse("invalid")==0,"invalid")
let date=parser.parse("2026-11-02T00:00:00Z")
check(date>0,"whole seconds")
check(abs(parser.parse("2026-11-02T01:00:00.125+01:00")-date-0.125)<0.00001,"fraction and timezone")
var freshness=LEDFreshness()
check(freshness.mode("working",now:10)=="system","no unconfirmed LED state")
check(freshness.confirm(startedAt:10,now:10.1),"fresh result accepted")
check(freshness.mode("working",now:11.49)=="working","fresh state retained")
check(freshness.mode("working",now:11.51)=="system","stalled reads cannot renew stale state")
check(!freshness.confirm(startedAt:10,now:12),"late result rejected")
check(freshness.mode("finished",now:12)=="system","late result cannot refresh freshness")
check(freshness.confirm(startedAt:12,now:12.1),"recovers on next fresh result")
let directory=FileManager.default.temporaryDirectory.appendingPathComponent("magdot-efficiency-\(UUID().uuidString)")
try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
defer {try? FileManager.default.removeItem(at:directory)}
let path=directory.appendingPathComponent("fixture.sqlite").path
var writer:OpaquePointer?
check(sqlite3_open(path,&writer)==SQLITE_OK,"open fixture")
defer {sqlite3_close(writer)}
func exec(_ sql:String) throws {_ = try query(writer!,sql)}
try exec("PRAGMA journal_mode=WAL")
try exec("CREATE TABLE orchestration_v2_projection_threads(thread_id TEXT PRIMARY KEY,payload_json TEXT,deleted_at TEXT,archived_at TEXT)")
try exec("CREATE TABLE orchestration_v2_projection_provider_turns(provider_turn_id TEXT PRIMARY KEY,thread_id TEXT,status TEXT,started_at TEXT,completed_at TEXT)")
try exec("CREATE TABLE orchestration_v2_projection_runtime_requests(thread_id TEXT,resolved_at TEXT,status TEXT,kind TEXT)")
try exec("INSERT INTO orchestration_v2_projection_threads VALUES('a','{\"lastVisitedAt\":\"2026-11-02T00:00:01Z\"}',NULL,NULL),('irrelevant','{}',NULL,NULL)")
try exec("INSERT INTO orchestration_v2_projection_provider_turns VALUES('old-turn','a','running','2026-11-02T00:00:00Z',NULL)")
// Large irrelevant history must not cause visit JSON reads.
try exec("WITH RECURSIVE ids(n) AS (VALUES(1) UNION ALL SELECT n+1 FROM ids WHERE n<5000) INSERT INTO orchestration_v2_projection_threads SELECT 'unused-'||n,'{}',NULL,NULL FROM ids")
// Committed writes must be visible on the very next read, not after cache TTL.
let reader=T3Reader(path:path)
var snapshot=try reader.read()
check(snapshot.0.count==1 && snapshot.1.isEmpty && !snapshot.2,"idle visits are not read")
let refreshes=reader.refreshCount
_ = try reader.read()
check(reader.refreshCount==refreshes,"unchanged DB cached")
var tracker=Tracker()
check(tracker.update(snapshot.0,visits:snapshot.1,attention:false,now:date+0.1)=="working","running observed")
_ = try reader.read(observedTurns:tracker.active)
try exec("UPDATE orchestration_v2_projection_provider_turns SET status='completed',completed_at='2026-11-02T00:00:01Z'")
snapshot=try reader.read(observedTurns:tracker.active)
check(snapshot.1.count==1 && snapshot.1["a"]==date+1,"completion visit included same poll")
check(reader.visitRowsRead==1,"only relevant visit read")
check(tracker.update(snapshot.0,visits:snapshot.1,attention:false,now:date+2,dismissed:snapshot.3)=="idle","recorded read acknowledges completion without foreground gate")
snapshot=try reader.read(finishedThreads:Set(tracker.finished.keys))
check(tracker.update(snapshot.0,visits:snapshot.1,attention:false,now:date+3)=="idle","cached visit stays acknowledged")
try exec("INSERT INTO orchestration_v2_projection_runtime_requests VALUES('a',NULL,'pending','approval')")
check(try reader.read().2,"external writer invalidates attention cache")
try exec("UPDATE orchestration_v2_projection_threads SET archived_at='archived'")
check(!(try reader.read().2),"archived request excluded")
try exec("UPDATE orchestration_v2_projection_threads SET archived_at=NULL")
check(try reader.read().2,"unarchive observed next poll")
try exec("BEGIN IMMEDIATE")
try exec("UPDATE orchestration_v2_projection_runtime_requests SET resolved_at='resolved'")
check(try reader.read().2,"uncommitted writer not exposed")
try exec("COMMIT")
check(!(try reader.read().2),"resolved request observed immediately after commit")
_ = try reader.read(finishedThreads:["a"])
try exec("UPDATE orchestration_v2_projection_threads SET payload_json='{\"lastVisitedAt\":\"2026-11-02T00:00:05Z\"}' WHERE thread_id='a'")
snapshot=try reader.read(finishedThreads:["a"])
check(snapshot.1["a"]==date+5,"visit change immediately invalidates same-key cache")
var expiryTracker=Tracker()
_ = expiryTracker.update([Turn(id:"expiry",thread:"a",status:"running",started:date,completed:0)],visits:[:],attention:false,now:date)
let completed=[Turn(id:"expiry",thread:"a",status:"completed",started:date,completed:date+1)]
check(expiryTracker.update(completed,visits:[:],attention:false,now:date+2,doneDuration:2)=="finished","completion shown")
check(expiryTracker.update(completed,visits:[:],attention:false,now:date+4,doneDuration:2)=="idle","cached rows still expire locally")
// Each dismissal must invalidate a same-key cache and clear only its thread.
for dismissal in ["read","snooze","settle","archive","delete","remove"] {
    try exec("DELETE FROM orchestration_v2_projection_provider_turns")
    try exec("DELETE FROM orchestration_v2_projection_threads WHERE thread_id IN ('a','b')")
    try exec("INSERT INTO orchestration_v2_projection_threads VALUES('a','{}',NULL,NULL),('b','{}',NULL,NULL)")
    try exec("INSERT INTO orchestration_v2_projection_provider_turns VALUES('ta','a','running','2026-11-02T00:00:00Z',NULL),('tb','b','running','2026-11-02T00:00:00Z',NULL)")
    var pending=Tracker()
    var value=try reader.read()
    _ = pending.update(value.0,visits:value.1,attention:false,now:date,dismissed:value.3)
    try exec("UPDATE orchestration_v2_projection_provider_turns SET status='completed',completed_at='2026-11-02T00:00:01Z'")
    value=try reader.read(observedTurns:pending.active)
    check(pending.update(value.0,visits:value.1,attention:false,now:date+2,doneDuration:0,dismissed:value.3)=="finished","unread completion retained")
    let keys=Set(pending.finished.keys)
    _ = try reader.read(finishedThreads:keys)
    switch dismissal {
    case "read": try exec("UPDATE orchestration_v2_projection_threads SET payload_json='{\"lastVisitedAt\":\"2026-11-02T00:00:02Z\"}' WHERE thread_id='a'")
    case "snooze": try exec("UPDATE orchestration_v2_projection_threads SET payload_json='{\"snoozedUntil\":\"2999-01-01T00:00:00Z\"}' WHERE thread_id='a'")
    case "settle": try exec("UPDATE orchestration_v2_projection_threads SET payload_json='{\"settledOverride\":\"settled\"}' WHERE thread_id='a'")
    case "archive": try exec("UPDATE orchestration_v2_projection_threads SET archived_at='archived' WHERE thread_id='a'")
    case "delete": try exec("UPDATE orchestration_v2_projection_threads SET deleted_at='deleted' WHERE thread_id='a'")
    default: try exec("DELETE FROM orchestration_v2_projection_threads WHERE thread_id='a'")
    }
    value=try reader.read(finishedThreads:keys)
    _ = pending.update(value.0,visits:value.1,attention:false,now:date+3,doneDuration:0,dismissed:value.3)
    check(Set(pending.finished.keys)==["b"],"\(dismissal) immediately clears only its thread")
    try exec("INSERT OR IGNORE INTO orchestration_v2_projection_threads VALUES('a','{}',NULL,NULL)")
    try exec("UPDATE orchestration_v2_projection_threads SET payload_json='{}',archived_at=NULL,deleted_at=NULL WHERE thread_id='a'")
    value=try reader.read(finishedThreads:Set(pending.finished.keys))
    _ = pending.update(value.0,visits:value.1,attention:false,now:date+4,doneDuration:0,dismissed:value.3)
    check(Set(pending.finished.keys)==["b"],"\(dismissal) does not replay when cleared")
}
print("Read/snooze/settle/archive/delete cache invalidation, independent dismissal, and no replay passed")
try exec("DROP TABLE orchestration_v2_projection_runtime_requests")
do {_ = try reader.read();preconditionFailure("schema failure must surface")}catch{}
try exec("CREATE TABLE orchestration_v2_projection_runtime_requests(thread_id TEXT,resolved_at TEXT,status TEXT,kind TEXT)")
check(!(try reader.read().2),"reader recovers after error")
reader.close()
try FileManager.default.moveItem(atPath:path,toPath:path+".old")
do {_ = try reader.read();preconditionFailure("missing file must surface")}catch{}
var replacement:OpaquePointer?
check(sqlite3_open(path,&replacement)==SQLITE_OK,"replacement")
_ = try query(replacement!,"CREATE TABLE orchestration_v2_projection_threads(thread_id TEXT PRIMARY KEY,payload_json TEXT,deleted_at TEXT,archived_at TEXT)")
_ = try query(replacement!,"CREATE TABLE orchestration_v2_projection_provider_turns(provider_turn_id TEXT PRIMARY KEY,thread_id TEXT,status TEXT,started_at TEXT,completed_at TEXT)")
_ = try query(replacement!,"CREATE TABLE orchestration_v2_projection_runtime_requests(thread_id TEXT,resolved_at TEXT,status TEXT,kind TEXT)")
sqlite3_close(replacement)
check(try reader.read().0.isEmpty,"file replacement reconnects")
try FileManager.default.moveItem(atPath:path,toPath:path+".second")
try FileManager.default.copyItem(atPath:path+".second",toPath:path)
var changed:OpaquePointer?
check(sqlite3_open(path,&changed)==SQLITE_OK,"changed inode")
_ = try query(changed!,"INSERT INTO orchestration_v2_projection_threads VALUES('new','{}',NULL,NULL)")
_ = try query(changed!,"INSERT INTO orchestration_v2_projection_runtime_requests VALUES('new',NULL,'pending','permission')")
sqlite3_close(changed)
check(try reader.read().2,"inode replacement invalidates live cache")
reader.close()
print("Timestamp formats, unchanged cache, concurrent writes, bounded visits, same-poll acknowledgment, schema errors and file replacement passed")

// Real AppKit lifecycle checks; no App delegate or helper/SMC is started.
let application=NSApplication.shared
application.setActivationPolicy(.accessory)
application.finishLaunching()
func pump(_ seconds:Double,mode:RunLoop.Mode = .default){
 let until=Date().addingTimeInterval(seconds)
 while Date()<until {
  if let event=application.nextEvent(matching:.any,until:min(until,Date().addingTimeInterval(0.02)),inMode:mode,dequeue:true){application.sendEvent(event)}
  application.updateWindows()
 }
}
func awaitUI(_ message:String,_ predicate:()->Bool){
 let deadline=Date().addingTimeInterval(3)
 while !predicate() && Date()<deadline {pump(0.02)}
 check(predicate(),message)
}
let settings=SequenceSettings()
var activeValue=false
settings.active={activeValue}
check(settings.statusTimer==nil,"unopened Settings has no timer")
settings.present();pump(1.0)
awaitUI("visible Settings timer"){settings.statusTimer != nil}
activeValue=true
settings.window?.miniaturize(nil);pump(0.3)
check(settings.statusTimer==nil,"minimized Settings stops timer")
settings.window?.deminiaturize(nil)
awaitUI("restore animation completes"){settings.statusTimer != nil}
check(settings.statusTimer != nil,"restored Settings timer")
check(settings.activation.state == .on,"restore immediately refreshes changed values")
settings.window?.close();pump(0.2)
let updates=settings.statusUpdateCount
pump(1.2)
settings.updateStatus()
check(settings.statusTimer==nil && settings.statusUpdateCount==updates,"closed Settings does no updates")
activeValue=false
settings.present();pump(0.1)
check(settings.activation.state == .off,"reopen refreshes before periodic timer")
activeValue=true
settings.windowDidBecomeKey(Notification(name:NSWindow.didBecomeKeyNotification))
check(settings.activation.state == .on,"focus refreshes even with existing timer")
settings.window?.orderOut(nil)
check(settings.statusTimer==nil,"ordered-out window stops timer")
activeValue=false
settings.window?.makeKeyAndOrderFront(nil)
awaitUI("order-front completes"){settings.statusTimer != nil}
check(settings.activation.state == .off && settings.statusTimer != nil,"order-front refreshes values and restarts timer")
application.hide(nil)
awaitUI("hide completes"){application.isHidden && settings.statusTimer==nil}
check(settings.statusTimer==nil,"hidden app stops timer")
activeValue=true
application.unhide(nil);settings.window?.makeKeyAndOrderFront(nil)
awaitUI("unhide completes"){settings.statusTimer != nil}
check(settings.activation.state == .on && settings.statusTimer != nil,"app unhide refreshes values")
settings.suspended=true
check(settings.statusTimer==nil,"sleep suspension")
settings.suspended=false
awaitUI("wake resumes visible Settings timer"){settings.statusTimer != nil}
check(settings.statusTimer != nil,"wake resumes exactly one timer")
settings.selected=1;settings.refresh()
let previousRow=settings.rows.first!
settings.windowDidBecomeKey(Notification(name:NSWindow.didBecomeKeyNotification))
check(settings.rows.first !== previousRow,"focus rebuilds preference-backed States rows")
let focusRow=settings.rows.first!
settings.window?.close();settings.present()
awaitUI("States reopen completes"){settings.statusTimer != nil}
check(settings.rows.first !== focusRow,"reopen reloads States rows")
settings.window?.close()
var ticks=0
let timer=Timer(timeInterval:0.05,repeats:true){_ in ticks+=1}
RunLoop.main.add(timer,forMode:.common)
pump(0.35,mode:.eventTracking);timer.invalidate()
check(ticks>=3,"common-mode heartbeat during event tracking")
print("Settings visible/minimized/closed/suspended lifecycle and common-mode timer passed")
