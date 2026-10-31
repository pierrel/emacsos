#include "../src/login/elogind.c"
int proof_reap(Manager *m);
int proof_reap(Manager *m) { return elogind_sigchld_handler(NULL, NULL, m); }
