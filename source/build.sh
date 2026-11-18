#!/bin/zsh
set -euo pipefail
ROOT=${0:A:h:h}
APP=${NIMBO_APP:-$ROOT/Nimbo.app}
BUNDLE_ID=${NIMBO_BUNDLE_ID:-local.nimbo.cloudsearch}
PROVIDER_ID=${NIMBO_PROVIDER_ID:-$BUNDLE_ID.provider}
APP_NAME=${NIMBO_APP_NAME:-Nimbo}
OPTIMIZATION=${NIMBO_OPTIMIZATION:--O}
WMO_FLAG=${NIMBO_WMO:--whole-module-optimization}
TEST_FLAGS=()
if [[ ${NIMBO_NATIVE_TESTING:-0} == 1 ]]; then TEST_FLAGS=(-D NIMBO_TESTING); fi
SDK=${NIMBO_SDK:-$(xcrun --show-sdk-path)}
# rclone: NIMBO_RCLONE, or vendor/rclone (scripts/fetch-rclone.sh), or the local work copy.
if [[ -n ${NIMBO_RCLONE:-} ]]; then RCLONE=$NIMBO_RCLONE
elif [[ -x "$ROOT/vendor/rclone" ]]; then RCLONE="$ROOT/vendor/rclone"
elif [[ -x "$ROOT/../vendor/rclone" ]]; then RCLONE="$ROOT/../vendor/rclone"
else RCLONE="$ROOT/../../work/nimbo/rclone-v1.76.0-osx-amd64/rclone"; fi
# Intermediate files: the local work folder when present, otherwise .build inside the repository.
if [[ -n ${NIMBO_BUILD_DIR:-} ]]; then BUILD=$NIMBO_BUILD_DIR
elif [[ -d "$ROOT/../../work/nimbo" ]]; then BUILD="$ROOT/../../work/nimbo"
else BUILD="$ROOT/.build"; fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$BUILD/swift-modules-overlay"
# Local workaround for duplicate SwiftBridging module maps in this Mac's CLT.
# The VFS overlay changes only the compiler's view, never system files.
EXTRA=()
if [[ -f /Library/Developer/CommandLineTools/usr/include/swift/bridging.modulemap ]]; then
  python3 - "$BUILD" <<'PY'
import pathlib,json,sys
p=pathlib.Path(sys.argv[1]).resolve()
(p/'empty.modulemap').write_text('// legacy duplicate module map hidden for this build only\n')
(p/'toolchain-overlay.json').write_text(json.dumps({'version':0,'roots':[{'type':'file','name':'/Library/Developer/CommandLineTools/usr/include/swift/module.modulemap','external-contents':str(p/'empty.modulemap')}]}))
PY
  EXTRA=(-vfsoverlay "$BUILD/toolchain-overlay.json")
fi
xcrun swiftc -parse-as-library -swift-version 5 "$OPTIMIZATION" "$WMO_FLAG" -sdk "$SDK" -target x86_64-apple-macosx13.0 -module-cache-path "$BUILD/swift-modules-overlay" "${EXTRA[@]}" "$ROOT/source/FinderService.swift" -o "$APP/Contents/Resources/NimboDriveService" -framework NetFS
xcrun clang -c -isysroot "$SDK" -target x86_64-apple-macosx13.0 "$ROOT/source/Sidebar.c" -o "$BUILD/Sidebar.o"
 xcrun swiftc -swift-version 5 "$OPTIMIZATION" "$WMO_FLAG" -sdk "$SDK" -target x86_64-apple-macosx13.0 -module-cache-path "$BUILD/swift-modules-overlay" "${EXTRA[@]}" -import-objc-header "$ROOT/source/Sidebar.h" "${TEST_FLAGS[@]}" "$ROOT/source/NativeProtocol.swift" "$ROOT/source/NativeAutoUnsync.swift" "$ROOT/source/NativeClient.swift" "$ROOT/source/NativeFileCommand.swift" "$ROOT/source/NativeController.swift" "$ROOT/source/CloudCore.swift" "$ROOT/source/DriveAPI.swift" "$ROOT/source/SyncSettings.swift" "$ROOT/source/SyncFilters.swift" "$ROOT/source/SecureLocalStore.swift" "$ROOT/source/SecureConfig.swift" "$ROOT/source/ActivityLog.swift" "$ROOT/source/TransferCenter.swift" "$ROOT/source/TransferController.swift" "$ROOT/source/DriveWriteAPI.swift" "$ROOT/source/DriveSplitUpload.swift" "$ROOT/source/CloudSend.swift" "$ROOT/source/SendController.swift" "$ROOT/source/CloudThumbnails.swift" "$ROOT/source/SpotlightReconciler.swift" "$ROOT/source/SpotlightIndexer.swift" "$ROOT/source/SyncCore.swift" "$ROOT/source/SyncSplit.swift" "$ROOT/source/SyncFolderPlan.swift" "$ROOT/source/SyncController.swift" "$ROOT/source/LaunchAtLogin.swift" "$ROOT/source/FinderController.swift" "$ROOT/source/FinderWebLinks.swift" "$ROOT/source/CloudAccountScope.swift" "$ROOT/source/TrashStore.swift" "$ROOT/source/TrashController.swift" "$ROOT/source/SharedDriveController.swift" "$ROOT/source/ActivityController.swift" "$ROOT/source/CloudBrowser.swift" "$ROOT/source/OAuthDesktopClient.swift" "$ROOT/source/NimboTheme.swift" "$ROOT/source/NimboComponents.swift" "$ROOT/source/AddDriveAccountPanel.swift" "$ROOT/source/GoogleClientPanel.swift" "$ROOT/source/NimboPresentation.swift" "$ROOT/source/main.swift" "$BUILD/Sidebar.o" -o "$APP/Contents/MacOS/Nimbo" -framework AppKit -framework CoreServices -framework FileProvider -framework Security -framework CoreSpotlight -framework Carbon -framework UserNotifications
 xcrun swiftc -swift-version 5 "$OPTIMIZATION" "$WMO_FLAG" -sdk "$SDK" -target x86_64-apple-macosx13.0 -module-cache-path "$BUILD/swift-modules-overlay" "${EXTRA[@]}" "$ROOT/source/CloudCore.swift" "$ROOT/source/DriveAPI.swift" "$ROOT/source/SyncSettings.swift" "$ROOT/source/SyncFilters.swift" "$ROOT/source/SecureLocalStore.swift" "$ROOT/source/SecureConfig.swift" "$ROOT/source/ActivityLog.swift" "$ROOT/source/TransferCenter.swift" "$ROOT/source/CloudThumbnails.swift" "$ROOT/source/SpotlightReconciler.swift" "$ROOT/source/SpotlightIndexer.swift" "$ROOT/source/SyncFolderPlan.swift" "$ROOT/source/SyncCore.swift" "$ROOT/source/SyncSplit.swift" "$ROOT/source/DriveWriteAPI.swift" "$ROOT/source/DriveSplitUpload.swift" "$ROOT/source/LaunchAtLogin.swift" "$ROOT/source/NimboCLI.swift" -o "$APP/Contents/Resources/nimbo" -framework Security -framework AppKit -framework CoreSpotlight
chmod 755 "$APP/Contents/Resources/nimbo"
cp "$RCLONE" "$APP/Contents/Resources/rclone"
chmod 755 "$APP/Contents/Resources/rclone"
cp "$ROOT/CONECTAR_GOOGLE_DRIVE.html" "$APP/Contents/Resources/"
cp "$ROOT/RCLONE-LICENSE.txt" "$APP/Contents/Resources/"
cp "$ROOT/source/Nimbo.icns" "$APP/Contents/Resources/Nimbo.icns"
cp "$ROOT/source/NimboHeader.icns" "$APP/Contents/Resources/NimboHeader.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Nimbo</string>
<key>CFBundleDisplayName</key><string>Nimbo</string>
<key>CFBundleIdentifier</key><string>local.nimbo.cloudsearch</string>
<key>CFBundleExecutable</key><string>Nimbo</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.120.0</string>
<key>CFBundleVersion</key><string>145</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>CFBundleIconFile</key><string>Nimbo.icns</string>
<key>CFBundleIconName</key><string>Nimbo</string>
<key>LSUIElement</key><true/>
<key>CFBundleURLTypes</key><array><dict><key>CFBundleURLName</key><string>local.nimbo.unsync</string><key>CFBundleURLSchemes</key><array><string>nimbo</string></array></dict></array>
<key>NSServices</key><array>
<dict><key>NSMessage</key><string>composeCloudSend</string><key>NSPortName</key><string>Nimbo</string><key>NSMenuItem</key><dict><key>default</key><string>Enviar a Nimbo…</string></dict><key>NSSendTypes</key><array><string>public.file-url</string></array><key>NSRequiredContext</key><dict/></dict>
<dict><key>NSMessage</key><string>unsyncFiles</string><key>NSMenuItem</key><dict><key>default</key><string>Desincronizar / liberar espacio con Nimbo</string></dict><key>NSSendTypes</key><array><string>public.file-url</string></array></dict>
<dict><key>NSMessage</key><string>syncFiles</string><key>NSMenuItem</key><dict><key>default</key><string>Sincronizar ahora con Nimbo</string></dict><key>NSSendTypes</key><array><string>public.file-url</string></array></dict>
<dict><key>NSMessage</key><string>pinFiles</string><key>NSMenuItem</key><dict><key>default</key><string>Conservar sin conexión con Nimbo</string></dict><key>NSSendTypes</key><array><string>public.file-url</string></array></dict>
</array>
</dict></plist>
PLIST
EXT="$APP/Contents/PlugIns/NimboDrive.appex"
mkdir -p "$EXT/Contents/MacOS"
mkdir -p "$EXT/Contents/Resources"
cp "$ROOT/source/BadgeAssets/NimboCloudBadge.png" "$EXT/Contents/Resources/"
cp "$ROOT/source/BadgeAssets/NimboCheckBadge.png" "$EXT/Contents/Resources/"
cp "$ROOT/source/BadgeAssets/NimboUploadBadge.png" "$ROOT/source/BadgeAssets/NimboErrorBadge.png" "$ROOT/source/BadgeAssets/NimboUploadBadge.icns" "$ROOT/source/BadgeAssets/NimboErrorBadge.icns" "$EXT/Contents/Resources/"
cp "$ROOT/source/BadgeAssets/NimboCloudBadge.icns" "$EXT/Contents/Resources/"
cp "$ROOT/source/BadgeAssets/NimboCheckBadge.icns" "$EXT/Contents/Resources/"
xcrun swiftc -parse-as-library -swift-version 5 "$OPTIMIZATION" "$WMO_FLAG" -sdk "$SDK" -target x86_64-apple-macosx13.0 -module-cache-path "$BUILD/swift-modules-overlay" "${EXTRA[@]}" "${TEST_FLAGS[@]}" -Xlinker -e -Xlinker _NSExtensionMain "$ROOT/source/SyncSettings.swift" "$ROOT/source/DriveAPI.swift" "$ROOT/source/DriveWriteAPI.swift" "$ROOT/source/DriveSplitUpload.swift" "$ROOT/source/SecureLocalStore.swift" "$ROOT/source/SecureConfig.swift" "$ROOT/source/NativeWriteStore.swift" "$ROOT/source/NativeStore.swift" "$ROOT/source/NativeFixtureDrive.swift" "$ROOT/source/NativeProtocol.swift" "$ROOT/source/NativeFileAction.swift" "$ROOT/source/NativeProvider.swift" -framework FileProvider -framework UniformTypeIdentifiers -framework Security -o "$EXT/Contents/MacOS/NimboDrive"
python3 - "$APP" "$EXT" "$BUNDLE_ID" "$PROVIDER_ID" "$APP_NAME" "$BUILD" <<'PYTHON'
import plistlib,pathlib,sys
app,ext,bundle,provider,name,build=sys.argv[1:]
p=pathlib.Path(app)/'Contents/Info.plist'; d=plistlib.loads(p.read_bytes()); d.update(CFBundleIdentifier=bundle,CFBundleName=name,CFBundleDisplayName=name); p.write_bytes(plistlib.dumps(d))
d={'CFBundleIdentifier':provider,'CFBundleName':'Google Drive','CFBundleExecutable':'NimboDrive','CFBundlePackageType':'XPC!','CFBundleShortVersionString':'1.120.0','CFBundleVersion':'145','LSMinimumSystemVersion':'13.0','UTExportedTypeDeclarations':[{'UTTypeIdentifier':'local.nimbo.cloudsearch.badge.cloud','UTTypeDescription':'Nimbo cloud badge','UTTypeConformsTo':['com.apple.icon-decoration.badge'],'UTTypeIconFile':'NimboCloudBadge.icns','UTTypeIconFiles':['NimboCloudBadge']},{'UTTypeIdentifier':'local.nimbo.cloudsearch.badge.check','UTTypeDescription':'Nimbo synced badge','UTTypeConformsTo':['com.apple.icon-decoration.badge'],'UTTypeIconFile':'NimboCheckBadge.icns','UTTypeIconFiles':['NimboCheckBadge']},{'UTTypeIdentifier':'local.nimbo.cloudsearch.badge.upload','UTTypeDescription':'Nimbo uploading badge','UTTypeConformsTo':['com.apple.icon-decoration.badge'],'UTTypeIconFile':'NimboUploadBadge.icns','UTTypeIconFiles':['NimboUploadBadge']},{'UTTypeIdentifier':'local.nimbo.cloudsearch.badge.error','UTTypeDescription':'Nimbo upload error badge','UTTypeConformsTo':['com.apple.icon-decoration.badge'],'UTTypeIconFile':'NimboErrorBadge.icns','UTTypeIconFiles':['NimboErrorBadge']}],'NSExtension':{'NSExtensionPointIdentifier':'com.apple.fileprovider-nonui','NSExtensionPrincipalClass':'NimboNativeProvider','NSExtensionFileProviderSupportsEnumeration':True,'NSExtensionFileProviderAllowsUserControlledEviction':True,'NSFileProviderDecorations':[{'Identifier':'local.nimbo.cloudsearch.provider.decoration.cloud','BadgeImageType':'local.nimbo.cloudsearch.badge.cloud','Category':'Badge','Label':'Sólo en la nube'},{'Identifier':'local.nimbo.cloudsearch.provider.decoration.synced','BadgeImageType':'local.nimbo.cloudsearch.badge.check','Category':'Badge','Label':'Disponible sin conexión'},{'Identifier':'local.nimbo.cloudsearch.provider.decoration.uploading','BadgeImageType':'local.nimbo.cloudsearch.badge.upload','Category':'Badge','Label':'Subiendo a Google Drive'},{'Identifier':'local.nimbo.cloudsearch.provider.decoration.failed','BadgeImageType':'local.nimbo.cloudsearch.badge.error','Category':'Badge','Label':'No se pudo subir'}],'NSExtensionFileProviderActions':[{'NSExtensionFileProviderActionIdentifier':'local.nimbo.sync','NSExtensionFileProviderActionName':'Sincronizar ahora con Nimbo','NSExtensionFileProviderActionActivationRule':'TRUEPREDICATE'},{'NSExtensionFileProviderActionIdentifier':'local.nimbo.pin','NSExtensionFileProviderActionName':'Conservar sin conexión con Nimbo','NSExtensionFileProviderActionActivationRule':'TRUEPREDICATE'},{'NSExtensionFileProviderActionIdentifier':'local.nimbo.evict','NSExtensionFileProviderActionName':'Desincronizar / liberar espacio con Nimbo','NSExtensionFileProviderActionActivationRule':'TRUEPREDICATE'}]}}
(pathlib.Path(ext)/'Contents/Info.plist').write_bytes(plistlib.dumps(d))
(pathlib.Path(build)/'native-entitlements.plist').write_bytes(plistlib.dumps({'com.apple.security.app-sandbox':True,'com.apple.security.network.client':True}))
(pathlib.Path(build)/'finder-entitlements.plist').write_bytes(plistlib.dumps({'com.apple.security.app-sandbox':True,'com.apple.security.temporary-exception.files.absolute-path.read-only':['/','/Volumes/']}))
PYTHON
codesign --force --sign - --entitlements "$BUILD/native-entitlements.plist" "$EXT"
# Finder opts out (sets PlugInKit election to "ignore") any Finder Sync
# extension whose containing app also contains an enabled File Provider
# extension. Keep Finder Sync in its own helper app, outside Nimbo's PlugIns.
rm -rf "$APP/Contents/PlugIns/NimboFinderSync.appex"
FINDER_HELPER="$APP/Contents/Library/LoginItems/NimboFinderHelper.app"
FINDER_HELPER_ID="$BUNDLE_ID.finderhelper"
FINDER_EXT="$FINDER_HELPER/Contents/PlugIns/NimboFinderSync.appex"
mkdir -p "$FINDER_HELPER/Contents/MacOS" "$FINDER_EXT/Contents/MacOS"
printf 'int main(void){return 0;}\n' > "$BUILD/finder-helper-main.c"
xcrun clang -isysroot "$SDK" -target x86_64-apple-macosx13.0 "$BUILD/finder-helper-main.c" -o "$FINDER_HELPER/Contents/MacOS/NimboFinderHelper"
python3 - "$FINDER_HELPER" "$FINDER_HELPER_ID" <<'PYTHON'
import plistlib,pathlib,sys
helper,bundle=sys.argv[1:]
d={'CFBundleIdentifier':bundle,'CFBundleName':'Nimbo Finder','CFBundleDisplayName':'Nimbo Finder','CFBundleExecutable':'NimboFinderHelper','CFBundlePackageType':'APPL','CFBundleInfoDictionaryVersion':'6.0','CFBundleShortVersionString':'1.120.0','CFBundleVersion':'145','LSMinimumSystemVersion':'13.0','LSBackgroundOnly':True,'CFBundleIconFile':'Nimbo.icns'}
(pathlib.Path(helper)/'Contents/Info.plist').write_bytes(plistlib.dumps(d))
PYTHON
mkdir -p "$FINDER_HELPER/Contents/Resources"
cp "$ROOT/source/Nimbo.icns" "$FINDER_HELPER/Contents/Resources/Nimbo.icns"
xcrun swiftc -parse-as-library -swift-version 5 "$OPTIMIZATION" "$WMO_FLAG" -sdk "$SDK" -target x86_64-apple-macosx13.0 -module-cache-path "$BUILD/swift-modules-overlay" "${EXTRA[@]}" "${TEST_FLAGS[@]}" -Xlinker -e -Xlinker _NSExtensionMain "$ROOT/source/FinderSync.swift" -framework Cocoa -framework FinderSync -o "$FINDER_EXT/Contents/MacOS/NimboFinderSync"
python3 - "$FINDER_EXT" "$FINDER_HELPER_ID" <<'PYTHON'
import plistlib,pathlib,sys
ext,bundle=sys.argv[1:]
d={'CFBundleIdentifier':bundle+'.findersync','CFBundleName':'Nimbo Finder','CFBundleDisplayName':'Nimbo Finder','CFBundleExecutable':'NimboFinderSync','CFBundlePackageType':'XPC!','CFBundleInfoDictionaryVersion':'6.0','CFBundleDevelopmentRegion':'en','CFBundleSupportedPlatforms':['MacOSX'],'CFBundleSignature':'????','CFBundleShortVersionString':'1.120.0','CFBundleVersion':'145','LSMinimumSystemVersion':'11.0','NSExtension':{'NSExtensionAttributes':{},'NSExtensionPointIdentifier':'com.apple.FinderSync','NSExtensionPrincipalClass':'NimboFinderSync.NimboFinderSync'}}
(pathlib.Path(ext)/'Contents/Info.plist').write_bytes(plistlib.dumps(d))
PYTHON
codesign --force --sign - --entitlements "$BUILD/finder-entitlements.plist" "$FINDER_EXT"
codesign --force --sign - "$FINDER_HELPER"
# Native File Provider UI actions are associated with the provider's host app.
ACTION_EXT="$APP/Contents/PlugIns/NimboActions.appex"
mkdir -p "$ACTION_EXT/Contents/MacOS"
xcrun swiftc -parse-as-library -swift-version 5 "$OPTIMIZATION" "$WMO_FLAG" -sdk "$SDK" -target x86_64-apple-macosx13.0 -module-cache-path "$BUILD/swift-modules-overlay" "${EXTRA[@]}" -Xlinker -e -Xlinker _NSExtensionMain "$ROOT/source/NativeProtocol.swift" "$ROOT/source/NativeAutoUnsync.swift" "$ROOT/source/NativeClient.swift" "$ROOT/source/SyncSettings.swift" "$ROOT/source/DriveAPI.swift" "$ROOT/source/SecureLocalStore.swift" "$ROOT/source/NimboTheme.swift" "$ROOT/source/ProviderWebLinks.swift" "$ROOT/source/ProviderActionUI.swift" -framework AppKit -framework FileProvider -framework FileProviderUI -framework Security -o "$ACTION_EXT/Contents/MacOS/NimboActions"
python3 - "$APP" "$ACTION_EXT" "$BUNDLE_ID" <<'PYTHON'
import plistlib,pathlib,sys
app,ext,bundle=sys.argv[1:]
host=plistlib.loads((pathlib.Path(app)/'Contents/Info.plist').read_bytes())
actions=[{'NSExtensionFileProviderActionIdentifier':identifier,'NSExtensionFileProviderActionName':name,'NSExtensionFileProviderActionActivationRule':'SUBQUERY ( fileproviderItems, $fileproviderItem, $fileproviderItem.userInfo.links == 1 ).@count > 0'} for identifier,name in [('local.nimbo.providerui.copy-link','Copiar enlace de Google Drive'),('local.nimbo.providerui.preview','Abrir vista web en Google Drive')]]
d={'CFBundleIdentifier':bundle+'.actions','CFBundleName':'Nimbo Actions','CFBundleExecutable':'NimboActions','CFBundlePackageType':'XPC!','CFBundleShortVersionString':host['CFBundleShortVersionString'],'CFBundleVersion':host['CFBundleVersion'],'LSMinimumSystemVersion':'13.0','NSExtension':{'NSExtensionPointIdentifier':'com.apple.fileprovider-actionsui','NSExtensionPrincipalClass':'NimboProviderActionUI','NSExtensionFileProviderActions':actions}}
(pathlib.Path(ext)/'Contents/Info.plist').write_bytes(plistlib.dumps(d))
PYTHON
codesign --force --sign - --entitlements "$BUILD/native-entitlements.plist" "$ACTION_EXT"
codesign --force --sign - "$APP/Contents/Resources/rclone"
codesign --force --sign - "$APP/Contents/Resources/nimbo"
codesign --force --sign - "$APP/Contents/Resources/NimboDriveService"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
cp "$APP/Contents/Resources/nimbo" "$ROOT/nimbo"
chmod 755 "$ROOT/nimbo"
echo "Built $APP"
