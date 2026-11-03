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
app.helperRegistrationAttempted=false
app.testRegisterHelper={registrations+=1;app.testHelperStatus = .requiresApproval}
app.manageHelperPermission()
check(registrations==4 && navigations==1 && app.requested && !app.ready,"connected permission action registers once and awaits readiness")
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
