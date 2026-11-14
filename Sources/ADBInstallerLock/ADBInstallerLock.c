#include "ADBInstallerLock.h"
#include <sys/file.h>

int androdo_flock(int descriptor, int operation) {
    return flock(descriptor, operation);
}
