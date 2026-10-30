#!/usr/bin/env python3
"""Real launchd socket activation with fake SMC; no privileged installation."""
import os, pathlib, plistlib, subprocess, tempfile, time
root = pathlib.Path.cwd()
with tempfile.TemporaryDirectory(prefix='md-socket-') as folder:
    directory = pathlib.Path(folder)
    label = f'local.magdot.socket-test.{os.getpid()}'
    domain = f'gui/{os.getuid()}'
    target = f'{domain}/{label}'
    config = directory / 'agent.plist'
    env = dict(os.environ, MAGDOT_TEST_DIR=folder)
    config.write_bytes(plistlib.dumps(dict(Label=label,
        ProgramArguments=[str(root/'build/test/helper'), 'daemon'],
        EnvironmentVariables=dict(MAGDOT_TEST_DIR=folder, MAGDOT_TEST_LAUNCHD='1'),
        ThrottleInterval=1,
        Sockets=dict(Listener=dict(SockPathName=folder+'/socket', SockType='stream', SockPathMode=384)))))
    subprocess.run(['launchctl','bootstrap',domain,str(config)],check=True)
    def wait_idle():
        for _ in range(100):
            report = subprocess.check_output(['launchctl','print',target],text=True)
            if '\tpid = ' not in report and not (directory/'status').exists(): return
            time.sleep(.1)
        raise AssertionError('Helper remained running after session ended: '+report)
    try:
        wait_idle()
        for _ in range(2):
            result = subprocess.run([str(root/'build/test/MagDot.app/Contents/MacOS/MagDot'),'--quit-smoke'],env=env,capture_output=True,text=True,timeout=25)
            assert result.returncode == 0 and 'acknowledged=true' in result.stdout, (result.stdout,result.stderr)
            wait_idle()
        running = subprocess.Popen([str(root/'build/test/MagDot.app/Contents/MacOS/MagDot'),'--start'],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        try:
            for _ in range(100):
                if (directory/'status').exists():break
                time.sleep(.1)
            assert (directory/'status').exists(), 'Relaunch failed to start helper'
            running.kill(); running.wait(timeout=5)
            wait_idle()
        finally:
            if running.poll() is None: running.kill(); running.wait()
        connection = directory/'connection'
        connection.write_text('disconnected')
        watcher = subprocess.Popen([str(root/'build/test/MagDot.app/Contents/MacOS/MagDot')],env=dict(env,MAGDOT_TEST_CONNECTION_FILE=str(connection)),stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        def wait_session(expected):
            for _ in range(100):
                assert watcher.poll() is None
                if (directory/'status').exists()==expected:return
                time.sleep(.1)
            raise AssertionError('Connection transition did not reach expected session state')
        try:
            time.sleep(2); wait_session(False); wait_idle()
            for _ in range(3):
                connection.write_text('connected'); wait_session(True)
                connection.write_text('disconnected'); wait_session(False); wait_idle()
            print('Socket activation: unplugged startup and three reconnect cycles passed')
        finally:
            watcher.terminate(); watcher.wait(timeout=10)
        executable = directory/'bundle-executable' 
        executable.touch()
        removed = subprocess.Popen([str(root/'build/test/MagDot.app/Contents/MacOS/MagDot')],env=dict(env,MAGDOT_TEST_BUNDLE_EXECUTABLE=str(executable)),stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        try:
            for _ in range(100):
                if (directory/'status').exists():break
                time.sleep(.1)
            assert (directory/'status').exists()
            executable.unlink()
            stdout,stderr=removed.communicate(timeout=15)
            assert removed.returncode==0 and 'acknowledged=true' in stdout,(stdout,stderr)
            wait_idle()
        finally:
            if removed.poll() is None: removed.kill(); removed.wait()
        print('Bundle disappearance triggers Quit and restoration')
        print('launchd: idle has no helper; two Quit/relaunch cycles and crash restoration passed')
    finally:
        subprocess.run(['launchctl','bootout',target],check=True)
