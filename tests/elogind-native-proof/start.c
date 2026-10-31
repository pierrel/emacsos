#include "../src/login/logind-dbus.c"
int proof_start(Manager *m);
int proof_start(Manager *m) { return elogind_execute_shutdown_or_sleep(m, handle_action_lookup(HANDLE_SUSPEND), NULL); }
