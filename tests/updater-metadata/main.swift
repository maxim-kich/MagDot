import Foundation
import AppKit
import Sparkle
func release(_ tag:String="v0.2.0", draft:Bool=false, prerelease:Bool=false, host:String="github.com") -> PublishedRelease {
    let prefix="https://\(host)/maxim-kich/MagDot/releases"
    return PublishedRelease(tag_name:tag,draft:draft,prerelease:prerelease,html_url:URL(string:"\(prefix)/tag/\(tag)")!,assets:[
        .init(name:"MagDot-\(tag)-macOS-arm64.zip",browser_download_url:URL(string:"\(prefix)/download/\(tag)/MagDot-\(tag)-macOS-arm64.zip")!,size:1024,state:"uploaded"),
        .init(name:"appcast.xml",browser_download_url:URL(string:"\(prefix)/download/\(tag)/appcast.xml")!,size:512,state:"uploaded")])
}
precondition(release().update(current:"0.1.0") != nil)
precondition(release(draft:true).update(current:"0.1.0") == nil)
precondition(release(prerelease:true).update(current:"0.1.0") == nil)
precondition(release(host:"example.com").update(current:"0.1.0") == nil)
precondition(release().update(current:"0.2.0") == nil)
precondition(release().update(current:"0.3.0") == nil)
precondition(ReleaseVersion("v0.2.0-rc1") == nil)
precondition(ReleaseVersion("v0.2") == nil)
print("Update metadata: ordinary release accepted; drafts, prereleases, foreign URLs and downgrades rejected")

let receiptSuite="MagDot.ReceiptFixture.\(UUID().uuidString)"
let receiptDefaults=UserDefaults(suiteName:receiptSuite)!
defer {receiptDefaults.removePersistentDomain(forName:receiptSuite)}
let receiptDirectory=FileManager.default.temporaryDirectory.appendingPathComponent("Receipt-\(UUID().uuidString).bundle")
try FileManager.default.createDirectory(at:receiptDirectory,withIntermediateDirectories:true)
defer {try? FileManager.default.removeItem(at:receiptDirectory)}
try PropertyListSerialization.data(fromPropertyList:["CFBundleIdentifier":"test.magdot.receipt","CFBundleShortVersionString":"9.0.2"],format:.xml,options:0).write(to:receiptDirectory.appendingPathComponent("Info.plist"))
let receiptBundle=Bundle(url:receiptDirectory)!
for intent in [true,false] {
    UpdateRelaunch.save(intent,version:"9.0.2",defaults:receiptDefaults,bundle:receiptBundle)
    precondition(UpdateRelaunch.consume(defaults:receiptDefaults,bundle:receiptBundle) == intent)
    precondition(UpdateRelaunch.consume(defaults:receiptDefaults,bundle:receiptBundle) == nil)
}
UpdateRelaunch.save(true,version:"9.0.3",defaults:receiptDefaults,bundle:receiptBundle)
precondition(UpdateRelaunch.consume(defaults:receiptDefaults,bundle:receiptBundle) == nil)
precondition(receiptDefaults.object(forKey:UpdateRelaunch.key) == nil)
for mutation in ["path","expires"] {
    UpdateRelaunch.save(true,version:"9.0.2",defaults:receiptDefaults,bundle:receiptBundle)
    var receipt=receiptDefaults.dictionary(forKey:UpdateRelaunch.key)!
    receipt[mutation] = mutation == "path" ? "/another/MagDot.app" : Date().addingTimeInterval(-1).timeIntervalSince1970 as Any
    receiptDefaults.set(receipt,forKey:UpdateRelaunch.key)
    precondition(UpdateRelaunch.consume(defaults:receiptDefaults,bundle:receiptBundle) == nil)
    precondition(receiptDefaults.object(forKey:UpdateRelaunch.key) == nil)
}
print("Relaunch receipt: ON/OFF consumed once; wrong version/path and expiry discarded")

// Drive production callbacks without networking to cover failed installation cleanup.
let checker=UpdateChecker(defaults:receiptDefaults,bundle:receiptBundle,confirm:{_,_,_ in true})
var updateActivity=UpdateActivity(controllingLED:true,activationIntent:true)
checker.activity={updateActivity}
let offered=ReleaseUpdate(version:"9.0.3",archive:URL(string:"https://example.test/update.zip")!,length:1,feed:URL(string:"https://example.test/appcast.xml")!)
checker.offerUpdate(offered) {_ in}
checker.openUpdate()
var installs=0
checker.showReady { _ in installs+=1 }
checker.beforeRestart={ valid, done in
    precondition(valid())
    updateActivity=UpdateActivity()
    done(true)
}
checker.openUpdate()
precondition(installs == 1 && checker.restartAuthorized)
precondition(receiptDefaults.dictionary(forKey:UpdateRelaunch.key)?["intent"] as? Bool == true)
let sparkle=SPUUpdater(hostBundle:receiptBundle,applicationBundle:receiptBundle,userDriver:checker,delegate:checker)
checker.updater(sparkle,didFinishUpdateCycleFor:.updates,error:NSError(domain:SUSparkleErrorDomain,code:4007))
precondition(receiptDefaults.object(forKey:UpdateRelaunch.key) == nil && checker.permitsTermination())
checker.offerUpdate(offered) {_ in}
checker.openUpdate()
checker.showReady {_ in installs+=1}
checker.openUpdate()
precondition(receiptDefaults.dictionary(forKey:UpdateRelaunch.key)?["intent"] as? Bool == false)
checker.updater(sparkle,didFinishUpdateCycleFor:.updates,error:NSError(domain:SUSparkleErrorDomain,code:4007))
precondition(checker.permitsTermination())
print("Installation failure clears receipt/consent; next cycle captures fresh intent and Quit remains available")
