#!/usr/bin/env python3
"""Run the installed FlClash core with isolated HOME/config, TUN off, no proxy ports.
The private IPC connection is only to this child, never to the user's FlClash.
"""
import json, os, socket, subprocess, sys, signal, time
from pathlib import Path
root=Path(sys.argv[1]);root.mkdir(parents=True,exist_ok=True)
server=socket.socket(socket.AF_UNIX);server.bind(str(root/'control.sock'));server.listen(1);server.settimeout(8)
unowned=socket.socket();unowned.bind(('127.0.0.1',0));unowned.listen(1);(root/'unowned-port').write_text(str(unowned.getsockname()[1]))
reserve=socket.socket();reserve.bind(('127.0.0.1',0));port=reserve.getsockname()[1];reserve.close()
config={'mode':'rule','mixed-port':0,'allow-lan':False,'tun':{'enable':False},'dns':{'enable':True,'enhanced-mode':'fake-ip','nameserver':['127.0.0.1:53535']},'external-controller':f'127.0.0.1:{port}','secret':'fixture-quote"-slash\\-token','proxies':[],'proxy-groups':[],'rules':['DOMAIN,fixture.example,DIRECT','MATCH,DIRECT']}
(root/'config.yaml').write_text(json.dumps(config))
p=subprocess.Popen(['/Applications/FlClash.app/Contents/MacOS/FlClashCore',str(root/'control.sock')],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
conn=None
try:
    def stop(*_):raise SystemExit(0)
    signal.signal(signal.SIGTERM,stop);signal.signal(signal.SIGINT,stop)
    conn,_=server.accept();conn.settimeout(10);f=conn.makefile('rb')
    def action(method,data):
        conn.sendall((json.dumps({'id':method,'method':method,'data':json.dumps(data)})+'\n').encode())
        while True:
            line=f.readline()
            if not line:raise RuntimeError('fixture core disconnected')
            answer=json.loads(line)
            if answer.get('id')==method:
                if answer.get('code')!=0:raise RuntimeError('fixture action failed')
                return answer.get('data')
    assert action('initClash',{'home-dir':str(root),'version':891}) is True
    result=action('setupConfig',{'selected-map':{},'test-url':'http://127.0.0.1/'})
    if result not in ('',None):raise RuntimeError('fixture config rejected')
    (root/'ready').write_text(str(port))
    while True:time.sleep(1)
finally:
    if conn:conn.close()
    p.terminate()
    try:p.wait(timeout=3)
    except subprocess.TimeoutExpired:p.kill();p.wait()
    server.close();unowned.close()
