#!/usr/bin/env python3
"""Real app -> fake LED socket timing. Only a temporary fixture database is written."""
import datetime,json,os,pathlib,socket,sqlite3,subprocess,tempfile,threading,time
app=pathlib.Path('build/test/MagDot.app/Contents/MacOS/MagDot').resolve()
with tempfile.TemporaryDirectory(prefix='md-fresh-') as folder:
    root=pathlib.Path(folder)
    db=sqlite3.connect(root/'fixture.sqlite')
    db.executescript('''PRAGMA journal_mode=WAL;
    CREATE TABLE orchestration_v2_projection_threads(thread_id TEXT PRIMARY KEY,payload_json TEXT,deleted_at TEXT,archived_at TEXT);
    CREATE TABLE orchestration_v2_projection_runs(run_id TEXT PRIMARY KEY,thread_id TEXT,status TEXT,requested_at TEXT,completed_at TEXT,payload_json TEXT DEFAULT '{}');
    CREATE TABLE orchestration_v2_projection_runtime_requests(thread_id TEXT,resolved_at TEXT,status TEXT,kind TEXT);
    CREATE TABLE orchestration_v2_projection_provider_turns(provider_turn_id TEXT PRIMARY KEY,thread_id TEXT,status TEXT,started_at TEXT,completed_at TEXT);
    INSERT INTO orchestration_v2_projection_provider_turns VALUES('stale','chat','running','2026-01-01T00:00:00Z',NULL);
    INSERT INTO orchestration_v2_projection_threads VALUES('chat','{}',NULL,NULL);
    ''')
    delay=root/'delay';delay.write_text('0')
    server=socket.socket(socket.AF_UNIX);server.bind(str(root/'socket'));server.listen(1);server.settimeout(.2)
    events=[];errors=[];stop=threading.Event()
    def serve():
        try:
            while not stop.is_set():
                try:conn,_=server.accept();break
                except socket.timeout:pass
            else:return
            with conn:
                conn.settimeout(.2);conn.sendall(b'READY\n');buffer=b''
                while not stop.is_set():
                    try:data=conn.recv(4096)
                    except socket.timeout:continue
                    if not data:break
                    buffer+=data
                    while b'\n' in buffer:
                        line,buffer=buffer.split(b'\n',1)
                        events.append((time.monotonic(),line.decode().split()[0]))
        except Exception as error:errors.append(repr(error))
    thread=threading.Thread(target=serve);thread.start()
    env=dict(os.environ,MAGDOT_TEST_DIR=folder,MAGDOT_TEST_DB_PATH=str(root/'fixture.sqlite'),MAGDOT_TEST_POLL_DELAY_FILE=str(delay))
    log=open(root/'app.log','w+')
    process=subprocess.Popen([str(app)],env=env,stdout=log,stderr=log)
    latencies=[]
    def wait_mode(mode,after,timeout=1.25):
        deadline=time.monotonic()+timeout
        while time.monotonic()<deadline:
            assert process.poll() is None,'app exited'
            assert not errors,errors
            matches=[t for t,state in events if t>=after and state==mode]
            if matches:return min(matches)-after
            time.sleep(.005)
        raise AssertionError(f'{mode} not delivered within {timeout}s; events={events[-8:]}')
    def stamp(age=0):return (datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(seconds=age)).isoformat(timespec='milliseconds').replace('+00:00','Z')
    def change(sql,params,mode):
        db.execute(sql,params);db.commit();committed=time.monotonic()
        latencies.append(wait_mode(mode,committed))
    try:
        wait_mode('idle',time.monotonic(),3)
        change('INSERT INTO orchestration_v2_projection_runs(run_id,thread_id,status,requested_at,completed_at) VALUES(?,?,?,?,?)',('one','chat','running',stamp(age=7200),None),'working')
        change("UPDATE orchestration_v2_projection_runs SET status='completed',completed_at=? WHERE run_id='one'",(stamp(),),'finished')
        change('INSERT INTO orchestration_v2_projection_runtime_requests VALUES(?,?,?,?)',('chat',None,'pending','approval'),'attention')
        change("UPDATE orchestration_v2_projection_runtime_requests SET resolved_at='yes'",(),'finished')
        change('INSERT INTO orchestration_v2_projection_runs(run_id,thread_id,status,requested_at,completed_at) VALUES(?,?,?,?,?)',('two','chat','running',stamp(),None),'working')
        change("UPDATE orchestration_v2_projection_runs SET status='cancelled',completed_at=? WHERE run_id='two'",(stamp(),),'idle')
        change("UPDATE orchestration_v2_projection_runtime_requests SET resolved_at=NULL",(),'attention')
        change("UPDATE orchestration_v2_projection_runtime_requests SET resolved_at='yes'",(),'idle')
        change('INSERT INTO orchestration_v2_projection_runs(run_id,thread_id,status,requested_at,completed_at) VALUES(?,?,?,?,?)',('three','chat','running',stamp(),None),'working')
        delay.write_text('3');blocked=time.monotonic()
        wait_mode('system',blocked,2.5)
        # Even when an old background request returns, it must not re-arm working.
        time.sleep(3.2)
        assert all(state=='system' for t,state in events if t>blocked+2.5),events[-12:]
        db.execute("UPDATE orchestration_v2_projection_runs SET status='cancelled',completed_at=? WHERE run_id='three'",(stamp(),));db.commit()
        delay.write_text('0')
        wait_mode('idle',time.monotonic(),4.5)
        print(f'{len(latencies)} committed transitions: max app-to-socket delay {max(latencies)*1000:.0f}ms; mean {sum(latencies)/len(latencies)*1000:.0f}ms',flush=True)
        print('Two-hour active run, stale provider rejection, cache invalidation, delayed-result rejection, freshness fallback and recovery passed; no physical LED involved',flush=True)
    finally:
        process.terminate();process.wait(timeout=5);stop.set();thread.join(timeout=3);server.close();db.close();log.close()
