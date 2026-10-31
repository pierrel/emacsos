executable('proof-provider',
  ['proof/main.c','proof/sleep.c','proof/reap.c','proof/start.c'],
  include_directories: includes,
  link_with: [liblogind_core, libshared],
  dependencies: [threads, libacl, libudev],
  c_args: ['-ffunction-sections','-fdata-sections','-Wno-error=missing-declarations','-Wno-error=missing-prototypes'],
  link_args: ['-Wl,--gc-sections','-Wl,--wrap=fopen','-Wl,--wrap=fopen64','-Wl,--wrap=execute_directories','-Wl,--wrap=send_prepare_for','-Wl,--wrap=do_sleep'],
  install: false)
