#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/wait.h>
#include <sys/file.h>
#include "logind.h"
#include "logind-dbus.h"
#include "exec-util.h"
#include "sleep.h"
int __real_do_sleep(Manager *m, SleepOperation operation);
int proof_external(Manager *m);
int proof_sleep(Manager *m);
int proof_reap(Manager *m);
int proof_start(Manager *m);
FILE *__real_fopen(const char *path, const char *mode);
FILE *__wrap_fopen(const char *path, const char *mode);
FILE *__wrap_fopen64(const char *path, const char *mode);
int __wrap_execute_directories(const char *const *d, usec_t t, gather_stdout_callback_t const c[_STDOUT_CONSUME_MAX], void *const a[_STDOUT_CONSUME_MAX], char *v[], char *e[], ExecDirFlags f);
int __wrap_send_prepare_for(Manager *m, InhibitWhat what, bool active);
int __wrap_do_sleep(Manager *m, SleepOperation operation);
static int false_signals;
static void path(char *out, const char *name) { snprintf(out, 4096, "%s/%s", getenv("PROOF_DIR"), name); }
static void number(const char *name, long value) { char p[4096]; path(p,name); FILE *f=__real_fopen(p,"w"); if(!f) _exit(91); fprintf(f,"%ld\n",value); fclose(f); }
FILE *__wrap_fopen(const char *p, const char *mode) {
        if (strcmp(p,"/sys/power/state")==0) { char sink[4096]; path(sink,"kernel"); return __real_fopen(sink,mode); }
        if (strncmp(p,"/sys/",5)==0) { fprintf(stderr,"UNEXPECTED SYSFS ACCESS\n"); abort(); }
        return __real_fopen(p,mode);
}
FILE *__wrap_fopen64(const char *path, const char *mode) { return __wrap_fopen(path,mode); }
int __wrap_execute_directories(const char *const *d, usec_t t, gather_stdout_callback_t const c[_STDOUT_CONSUME_MAX], void *const a[_STDOUT_CONSUME_MAX], char *v[], char *e[], ExecDirFlags f) { return 0; }
int __wrap_send_prepare_for(Manager *m, InhibitWhat what, bool active) { if(!active) false_signals++; return 0; }
int __wrap_do_sleep(Manager *m, SleepOperation operation) {
        if(getenv("PROOF_PRE_TOOL")) {
                char p[4096], c; path(p,"ready"); int f=open(p,O_WRONLY); write(f,"p",1); close(f);
                path(p,"release"); f=open(p,O_RDONLY); if(read(f,&c,1)!=1) _exit(98); close(f);
        }
        return proof_external(m);
}
static void barrier_tool(void) {
        char p[4096], c;
        int inside = getenv("PROOF_KERNEL_BARRIER") != NULL;
        sigset_t mask;
        if (inside) { sigemptyset(&mask); sigaddset(&mask,SIGTERM); sigprocmask(SIG_BLOCK,&mask,NULL); }
        number("toolpid",getpid());
        const char *names[]={"call.lock","display.lock"}; int targets[]={8,6};
        for (int i=0;i<2;i++) {
                path(p,names[i]); int fd=open(p,O_RDWR|O_CREAT,0600);
                if(fd<0 || flock(fd,LOCK_EX|LOCK_NB)<0) _exit(75);
                if(fd!=targets[i]) { if(dup2(fd,targets[i])<0) _exit(95); close(fd); }
        }
        if(inside) number("commit",1);
        path(p,"ready"); int r=open(p,O_WRONLY); if(r<0) _exit(92); if(write(r,"r",1)!=1) _exit(93); close(r);
        path(p,"release"); r=open(p,O_RDONLY); if(r<0 || read(r,&c,1)!=1) _exit(94); close(r);
        if(inside) sigprocmask(SIG_UNBLOCK,&mask,NULL);
        else number("commit",1);
        _exit(getenv("PROOF_FAIL") ? 75 : 0);
}

int main(int argc, char **argv) {
        if(argc==1) barrier_tool();
        if(strcmp(argv[1],"parsed-guard")==0) {
                Manager parsed={}; parsed.allow_suspend_interrupts=true;
                if(manager_parse_config_file(&parsed)<0) return 98;
                number("prepared_config",!parsed.allow_suspend_interrupts);
                number("result",__real_do_sleep(&parsed,SLEEP_SUSPEND)); return 0;
        }
        Manager m={}; char *tools[]={strdup(argv[0]),NULL}; char *states[]={"mem",NULL};
        m.suspend_by_using=tools; m.states[SLEEP_SUSPEND]=states;
        if(strcmp(argv[1],"guard")==0) { tools[0]=getenv("PROOF_GUARD"); number("result",proof_sleep(&m)); return 0; }
        if(strcmp(argv[1],"fallback")==0) { char *failed[]={"/bin/false",NULL}; m.suspend_by_using=failed; number("result",proof_sleep(&m)); return 0; }
        if(strcmp(argv[1],"unconfigured")==0) { m.suspend_by_using=NULL; number("result",proof_sleep(&m)); return 0; }
        if(strcmp(argv[1],"external")==0) { number("result",proof_external(&m)); return 0; }
        if(strcmp(argv[1],"shutdown-reap")==0) {
                if(sd_event_new(&m.event)<0) return 95;
                m.delayed_action=m.sleep_fork_action=handle_action_lookup(HANDLE_POWEROFF);
                m.sleep_fork_pid=fork(); if(m.sleep_fork_pid==0) _exit(1);
                siginfo_t info={}; if(waitid(P_PID,m.sleep_fork_pid,&info,WEXITED|WNOWAIT)<0) return 99;
                proof_reap(&m);
                number("busy",m.delayed_action!=NULL); number("outer",m.sleep_fork_pid); number("false",false_signals);
                return 0;
        }
        if(strcmp(argv[1],"owner")==0) {
                if(sd_event_new(&m.event)<0) return 95;
                /* Match the daemon's blocked signals before native fork/reset. */
                sigset_t mask; sigemptyset(&mask); sigaddset(&mask,SIGTERM); sigaddset(&mask,SIGCHLD); sigprocmask(SIG_BLOCK,&mask,NULL);
                m.delayed_action=handle_action_lookup(HANDLE_SUSPEND);
                if(proof_start(&m)<0) return 96;
                number("outerpid",m.sleep_fork_pid);
                char p[4096], command; path(p,"control"); int fd=open(p,O_RDONLY);
                while(read(fd,&command,1)==1) {
                        if(command=='q') _exit(0);
                        if(command=='u') { pid_t unrelated=fork(); if(unrelated==0) _exit(0); waitpid(unrelated,NULL,0); }
                        proof_reap(&m);
                        number("false",false_signals); number("busy",m.delayed_action!=NULL); number("outer",m.sleep_fork_pid);
                        path(p,"ack"); int ack=open(p,O_WRONLY); write(ack,"a",1); close(ack);
                }
                return 0;
        }
        return 97;
}
