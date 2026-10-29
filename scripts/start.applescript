on run
 set projectPath to POSIX path of (path to me)
 set projectPath to do shell script "dirname " & quoted form of projectPath
 do shell script "trap '' HUP; /usr/bin/python3 " & quoted form of (projectPath & "/scripts/t3-watch.py") & " </dev/null >/tmp/magdot-watcher.log 2>&1 &"
 set statePath to (POSIX path of (path to home folder)) & ".magdot/state"
 do shell script "trap '' HUP; " & quoted form of (projectPath & "/build/magdot") & " watch " & quoted form of statePath & " </dev/null >/tmp/magdot-controller.log 2>&1 &" with administrator privileges
end run
