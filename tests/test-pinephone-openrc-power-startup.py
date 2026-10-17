import os, signal, subprocess, sys, tempfile, time
from pathlib import Path
source=Path(sys.argv[1]).read_text() if len(sys.argv)>1 else (Path(__file__).resolve().parents[1]/'deploy/pinephone/openrc-session').read_text()
a=source.index('mkfifo -m 0600 "$runtime/power-events"');b=source.index('"$root/process-group" /usr/bin/swayidle',a)
startup=source[a:b]
for readiness in ('delayed', 'absent'):
    with tempfile.TemporaryDirectory(prefix='phone-power-startup-') as name:
        root=Path(name); runtime=root/'runtime';runtime.mkdir()
        (root/'process-group').write_text('#!/bin/sh\nexec "$@"\n')
        (root/'session-power').write_text('''#!/bin/sh
    if [ "$1" = monitor ]; then
        echo reached >"$X_TEST_ROOT/setup-reached"
        read answer <"$X_TEST_ROOT/setup-continue"
        echo registered >"$X_TEST_ROOT/inputs-registered"
        exec 8<>"$X_TEST_ROOT/runtime/power-events"
        read event <&8
        exit
    fi
    if [ "$1" = wake ]; then
        [ -e "$X_TEST_ROOT/inputs-registered" ] || echo lost >"$X_TEST_ROOT/unprotected-display"
        echo display >"$X_TEST_ROOT/display-reached"
        printf 'active\\n' >"$X_TEST_ROOT/runtime/power-events"
    fi
    ''')
        for file in ('process-group','session-power'):(root/file).chmod(0o755)
        os.mkfifo(root/'setup-continue')
        env=os.environ.copy();env['X_TEST_ROOT']=name
        script='set -eu\nroot="'+name+'"\nruntime="$root/runtime"\nfail() { exit 1; }\n'+startup+'\nwait "$power_pid"\n'
        process=subprocess.Popen(['/bin/sh','-c',script],env=env,start_new_session=True)
        try:
            deadline=time.monotonic()+2
            while not (root/'setup-reached').exists():
                assert time.monotonic()<deadline
                time.sleep(.01)
            time.sleep(.1)
            assert not (root/'display-reached').exists(), 'initial display changed before monitor registration'
            if readiness == 'delayed':
                with (root/'setup-continue').open('w') as fifo:fifo.write('continue\n')
                assert process.wait(timeout=3)==0
                assert (root/'display-reached').exists()
                assert not (root/'unprotected-display').exists()
                print('Initial display waits for input-registration readiness: OK')
            else:
                assert process.wait(timeout=5)!=0
                assert not (root/'display-reached').exists()
                print('Missing input-registration readiness aborts before display: OK')
        finally:
            try:
                os.killpg(process.pid,signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
