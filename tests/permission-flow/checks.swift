setbuf(stdout,nil)
func check(_ value:Bool,_ message:String){if !value {fputs("FAILED: \(message)\n",stderr);exit(1)}}
let application=NSApplication.shared
application.setActivationPolicy(.accessory)
// Exercise the real launch entry point with disconnected hardware and no OS calls.
let directory=FileManager.default.temporaryDirectory.appendingPathComponent("magdot-permission-\(UUID().uuidString)")
try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
defer {try? FileManager.default.removeItem(at:directory)}
let connectionFile=directory.appendingPathComponent("connection")
try "disconnected".write(to:connectionFile,atomically:true,encoding:.utf8)
setenv("MAGDOT_TEST_DIR",directory.path,1)
setenv("MAGDOT_TEST_CONNECTION_FILE",connectionFile.path,1)
let launched=App()
launched.testOnboardingRequired=true
launched.applicationDidFinishLaunching(Notification(name:NSApplication.didFinishLaunchingNotification))
check(launched.onboardingWindow?.isVisible == true && launched.settingsWindow == nil,"launch presents only onboarding, including --settings")
check(!launched.requested && !launched.helperRegistrationAttempted,"disconnected launch does not register or activate")
launched.connectionTimer?.invalidate()
launched.onboardingWindow?.close()
if let item=launched.item {NSStatusBar.system.removeStatusItem(item)}
unsetenv("MAGDOT_TEST_CONNECTION_FILE")
let app=App()
app.startItem=NSMenuItem();app.stopItem=NSMenuItem()
app.testOnboardingRequired=true
app.showSettings()
check(app.onboardingWindow?.isVisible == true && app.settingsWindow == nil,"first-run Settings request presents only onboarding")
let welcome=app.onboardingWindow
welcome?.close()
_ = app.applicationShouldHandleReopen(application,hasVisibleWindows:false)
check(app.onboardingWindow === welcome && welcome?.isVisible == true && app.settingsWindow == nil,"reopen restores the same onboarding window")
app.connectionGate.connected=true
app.updateOnboarding()
check(app.onboardingDoneButton?.isEnabled == true,"connected setup can finish")
app.dismissOnboarding()
check(!app.onboardingRequired && app.onboardingWindow == nil,"completion closes onboarding")
_ = app.applicationShouldHandleReopen(application,hasVisibleWindows:false)
check(app.settingsWindow?.window?.isVisible == true,"completed setup reopens Settings")
let settings=app.settingsWindow
app.showSettings()
check(app.settingsWindow === settings,"Settings requests reuse one controller")
app.testOnboardingRequired=true
app.updateOnboarding()
check(settings?.window?.isVisible == false && app.onboardingWindow?.isVisible == true,"onboarding excludes existing Settings")
app.dismissOnboarding()
app.settingsWindow?.window?.close()

var registrations=0,navigations=0
app.testOpenLoginItems={navigations+=1}
app.testRegisterHelper={registrations+=1;app.testHelperStatus = .requiresApproval}
app.connectionGate.connected=false
app.connectionGate.activationEnabled=false
app.testHelperStatus = .notRegistered
app.settingsWindow?.managePermission?()
check(registrations==1 && navigations==0,"registration never forces navigation")
check(app.connectionGate.activationEnabled && !app.requested && !app.ready,"disconnected permission action preserves activation intent without starting")
app.manageHelperPermission()
check(registrations==1 && navigations==1,"pending approval only navigates")
app.testHelperStatus = .enabled
app.manageHelperPermission()
check(registrations==1 && navigations==1,"approved helper performs neither permission action")
app.testHelperStatus = .notFound
app.manageHelperPermission()
check(registrations==2 && navigations==1,"missing helper registration is retryable explicitly")
app.testHelperStatus = .notRegistered
app.testRegisterHelper={registrations+=1;throw NSError(domain:"fixture",code:1)}
app.manageHelperPermission()
check(registrations==3 && navigations==1 && app.status.title=="Helper setup needs attention","registration error does not navigate")
app.connectionGate.connected=true
app.manageHelperPermission()
check(!app.requested && app.activationError != nil,"connected registration failure remains visible and does not start")
app.helperRegistrationAttempted=false
app.testRegisterHelper={registrations+=1;app.testHelperStatus = .requiresApproval}
app.manageHelperPermission()
check(registrations==5 && navigations==1 && app.requested && !app.ready,"connected permission action registers once and awaits readiness")
app.ended(true)
app.connectionGate.activationEnabled=false
app.observedHelperApproval=false
app.testHelperStatus = .enabled
app.checkConnection()
check(!app.requested,"approval does not override user deactivation")
app.connectionGate.activationEnabled=true
app.observedHelperApproval=false
app.checkConnection()
check(app.requested && !app.ready,"approval resumes requested activation without claiming helper readiness")
app.ended(true)
print("Permission and window routing fixtures passed")

// Update preparation waits for the production stop completion before unregistration.
let updating=App()
updating.startItem=NSMenuItem();updating.stopItem=NSMenuItem()
var unregisters=0
updating.testUnregisterHelper={unregisters+=1}
var result:Bool?
updating.requested=true;updating.stopping=true;updating.ready=true
updating.prepareUpdateRestart(stillAuthorized:{true}) {result=$0}
check(result == nil && unregisters == 0,"update waits for restoration before unregister")
updating.ended(true)
check(result == true && unregisters == 1,"restoration acknowledgement permits unregister")
result=nil
updating.requested=true;updating.stopping=true
updating.prepareUpdateRestart(stillAuthorized:{true}) {result=$0}
updating.ended(false)
check(result == false && unregisters == 1,"restoration failure prevents unregister")
result=nil
updating.prepareUpdateRestart(stillAuthorized:{true}) {result=$0}
check(result == false && unregisters == 1,"retry cannot bypass failed restoration using temporary OFF")
updating.updateRestorationFailed=false
updating.requested=true;updating.stopping=true;result=nil
var authorized=true
updating.prepareUpdateRestart(stillAuthorized:{authorized}) {result=$0}
authorized=false
updating.ended(true)
check(result == false && unregisters == 1,"late stop after cancellation never unregisters")
updating.testUnregisterHelper={throw NSError(domain:"fixture",code:2)}
result=nil
updating.prepareUpdateRestart(stillAuthorized:{true}) {result=$0}
check(result == false,"unregistration failure prevents install")
print("Updater stop acknowledgement fixtures passed")

let resumed=App()
resumed.startItem=NSMenuItem();resumed.stopItem=NSMenuItem()
resumed.testOnboardingRequired=false
resumed.testHelperStatus = .requiresApproval
setenv("MAGDOT_TEST_CONNECTION_FILE",connectionFile.path,1)
try "disconnected".write(to:connectionFile,atomically:true,encoding:.utf8)
resumed.resumeAfterUpdate(true)
let resumedSettings=resumed.settingsWindow
check(resumed.connectionGate.activationEnabled && !resumed.requested && !resumed.ready && !resumed.connectorView.isActive,"ON receipt unplugged retains intent without claiming control")
check(resumedSettings?.navigation.selectedRow == 2,"update opens Settings About")
try "connected".write(to:connectionFile,atomically:true,encoding:.utf8)
resumed.checkConnection()
check(resumed.requested && !resumed.ready && !resumed.connectorView.isActive,"ON reconnect waits for approval and READY")
resumed.ended(true)
resumed.resumeAfterUpdate(false)
check(resumed.settingsWindow === resumedSettings && resumedSettings?.navigation.selectedRow == 2,"update reuses Settings controller on About")
resumed.testHelperStatus = .enabled
resumed.observedHelperApproval=false
resumed.checkConnection()
check(!resumed.requested && !resumed.connectionGate.activationEnabled && !resumed.connectorView.isActive,"OFF receipt remains OFF even after approval")
unsetenv("MAGDOT_TEST_CONNECTION_FILE")
resumedSettings?.close()
print("Updater resume and About routing fixtures passed")

updating.testUnregisterHelper={unregisters+=1}
updating.connectionGate.activationEnabled=true
updating.connectionGate.pendingStart=true
result=nil
updating.prepareUpdateRestart(stillAuthorized:{true}) {result=$0}
check(result == true && !updating.connectionGate.activationEnabled && !updating.connectionGate.pendingStart,"update disables deferred ON intent even without a running session")
