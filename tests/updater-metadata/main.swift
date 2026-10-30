import Foundation
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
