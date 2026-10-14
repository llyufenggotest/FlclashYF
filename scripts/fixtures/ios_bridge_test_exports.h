#pragma once
#include <stdbool.h>
#include <stdlib.h>
#include "../../core/bride.h"
void invokeMethod(void *, char *);
void setEventListener(void *);
void quickSetup(void *, char *, char *);
bool startTUN(void *, int, char *);
void stopTun(void);
void forceGC(void);
void testEmitEvent(const char *);
