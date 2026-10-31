#include "../src/sleep/sleep.c"
int proof_external(Manager *m);
int proof_sleep(Manager *m);
int proof_external(Manager *m) { return execute_external(m, SLEEP_SUSPEND); }
int proof_sleep(Manager *m) { arg_operation = SLEEP_SUSPEND; return execute(m, SLEEP_SUSPEND, NULL); }
