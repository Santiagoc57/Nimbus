#include <CoreFoundation/CoreFoundation.h>
void *NimboAddFinderFavorite(CFURLRef url, CFStringRef name);
void NimboRemoveFinderFavorite(void *handle);
void NimboSetFinderFavorite(CFURLRef url, CFStringRef name, CFURLRef iconFile);
