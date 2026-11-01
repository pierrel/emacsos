"""Model only kernel PM read/arm/commit sinks; source registrations are real."""
import array, fcntl, os, re, sys, time
from pathlib import Path

def sources():
    active = set()
    for info in Path('/proc').glob('[0-9]*/fdinfo/11'):
        try:
            registration = info.read_text()
            event = info.with_name('10').read_text()
        except OSError:
            continue
        watch = re.search(r'tfd:\s*10\s+events:\s*([0-9a-f]+)', registration)
        if (watch and int(watch[1], 16) & (1 << 29)
                and re.search(r'eventfd-count:\s*1\s*$', event, re.M)):
            active.add(re.search(r'eventfd-id:\s*(\d+)', event)[1])
    # Test input devices are real eventfds. Observe their counts, never read
    # the queue or poll the consumer's epoll as part of modeled admission.
    for info in Path('/proc').glob('[0-9]*/fdinfo/4'):
        try:
            registration=info.read_text()
            for target in (3,5):
                watch=re.search(r'tfd:\s*'+str(target)+r'\s+events:\s*([0-9a-f]+)',registration)
                event=info.with_name(str(target)).read_text()
                count=re.search(r'eventfd-count:\s*([0-9a-f]+)',event)
                if watch and int(watch[1],16)&(1<<29) and count and int(count[1],16):
                    active.add('input-'+re.search(r'eventfd-id:\s*(\d+)',event)[1])
        except OSError:pass
    return active

root=Path(sys.argv[1]);operation = sys.argv[2]
if operation == 'sources':
    print(' '.join(sorted(sources())))
elif operation == 'read':
    # Kernel wakeup_count waits for active sources to finish. The production
    # timeout must interrupt this read while wake waits for the display lock.
    while sources():
        time.sleep(0.01)
    print((root/'power/wakeup_count').read_text().strip())
elif operation == 'accept':
    if sources() or (root/'power/wakeup_count').read_text().strip() != sys.argv[3]:
        sys.exit(1)
    (root/'accepted-wakeup-count').write_text(sys.argv[3])
elif operation == 'submit':
    if sources() or (root/'power/wakeup_count').read_text().strip() != (root/'accepted-wakeup-count').read_text():
        sys.exit(1)
    (root/'power/state').write_text('mem\n')
else:
    raise AssertionError(operation)
