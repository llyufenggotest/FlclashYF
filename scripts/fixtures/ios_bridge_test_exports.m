#import <Foundation/Foundation.h>
#import "ios_bridge_test_exports.h"
#import <string.h>
void (*release_object_func)(void *);
void *(*retain_object_func)(void *);
void (*free_string_func)(char *);
int (*protect_func)(void *, int);
int (*resolve_uid_func)(void *, int, const char *, const char *);
char *(*resolve_package_func)(void *, int);
void (*result_func)(void *, const char *);
void (*system_log_func)(const char *, const char *);
static NSLock *listenerLock;
static void *listener;
void setEventListener(void *value) {
  static dispatch_once_t once;
  dispatch_once(&once, ^{ listenerLock = [NSLock new]; });
  [listenerLock lock]; void *old = listener; listener = value; [listenerLock unlock];
  if (old) release_object_func(old);
}
void testEmitEvent(const char *data) {
  [listenerLock lock]; void *retained = listener ? retain_object_func(listener) : NULL; [listenerLock unlock];
  if (retained) { result_func(retained, data); release_object_func(retained); }
}
void invokeMethod(void *callback, char *data) {
  free(data);
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
    result_func(callback, "reply"); release_object_func(callback);
  });
}
void quickSetup(void *callback, char *init, char *setup) {
  free(init); free(setup); result_func(callback, NULL); release_object_func(callback);
}
bool startTUN(void *callback, int fd, char *data) { free(data); return true; }
void stopTun(void) {}
void forceGC(void) {}
