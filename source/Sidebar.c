#include "Sidebar.h"
#include <CoreServices/CoreServices.h>
#include <stdlib.h>

struct Favorite { LSSharedFileListRef list; LSSharedFileListItemRef item; };
// The positional constants are sentinel pointers, not CF objects. Keep their
// use in C so Swift ARC never attempts to retain kLSSharedFileListItemLast.
void *NimboAddFinderFavorite(CFURLRef url, CFStringRef name) {
    LSSharedFileListRef list = LSSharedFileListCreate(NULL, kLSSharedFileListFavoriteItems, NULL);
    if (!list) return NULL;
    LSSharedFileListItemRef item = LSSharedFileListInsertItemURL(list, kLSSharedFileListItemLast, name, NULL, url, NULL, NULL);
    if (!item) { CFRelease(list); return NULL; }
    struct Favorite *favorite = malloc(sizeof(*favorite));
    if (!favorite) { LSSharedFileListItemRemove(list,item); CFRelease(item); CFRelease(list); return NULL; }
    favorite->list = list; favorite->item = item;
    return favorite;
}
void NimboRemoveFinderFavorite(void *handle) {
    if (!handle) return;
    struct Favorite *favorite = handle;
    LSSharedFileListItemRemove(favorite->list,favorite->item);
    CFRelease(favorite->item); CFRelease(favorite->list); free(favorite);
}

// Favorite with a custom sidebar icon and display name (like odrive's ∞).
// The icon file is a .icns written by the app; IconRef registration is the
// only public way LSSharedFileList accepts a custom sidebar image.
void NimboSetFinderFavorite(CFURLRef url, CFStringRef name, CFURLRef iconFile) {
    LSSharedFileListRef list = LSSharedFileListCreate(NULL, kLSSharedFileListFavoriteItems, NULL);
    if (!list) return;
    IconRef icon = NULL;
    FSRef ref;
    if (iconFile && CFURLGetFSRef(iconFile, &ref)) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        RegisterIconRefFromFSRef('NMBO', 'clud', &ref, &icon);
#pragma clang diagnostic pop
    }
    // Remove any earlier entry for the same folder so the new name/icon apply.
    NimboRemoveFinderFavorites(url);
    LSSharedFileListItemRef added = LSSharedFileListInsertItemURL(list, kLSSharedFileListItemLast, name, icon, url, NULL, NULL);
    if (added) CFRelease(added);
    if (icon) ReleaseIconRef(icon);
    CFRelease(list);
}

// Removes every favorite whose location resolves to url.
void NimboRemoveFinderFavorites(CFURLRef url) {
    LSSharedFileListRef list = LSSharedFileListCreate(NULL, kLSSharedFileListFavoriteItems, NULL);
    if (!list) return;
    UInt32 seed = 0;
    CFArrayRef items = LSSharedFileListCopySnapshot(list, &seed);
    if (items) {
        for (CFIndex i = 0; i < CFArrayGetCount(items); i++) {
            LSSharedFileListItemRef item = (LSSharedFileListItemRef)CFArrayGetValueAtIndex(items, i);
            CFURLRef existing = LSSharedFileListItemCopyResolvedURL(item, kLSSharedFileListNoUserInteraction | kLSSharedFileListDoNotMountVolumes, NULL);
            if (existing) {
                if (CFEqual(CFURLGetString(existing), CFURLGetString(url))) LSSharedFileListItemRemove(list, item);
                CFRelease(existing);
            }
        }
        CFRelease(items);
    }
    CFRelease(list);
}
