import json
import os
import plistlib
import subprocess
import sys
from pathlib import Path

app = Path(sys.argv[1])
extension = app / 'Contents/PlugIns/RMFinder.appex'
common = dict(CFBundleDevelopmentRegion='en_GB', CFBundleShortVersionString='0.1.0', CFBundleVersion='8', LSMinimumSystemVersion='14.0', CFBundleSupportedPlatforms=['MacOSX'])
app_info = dict(common, CFBundleName='rmconvert', CFBundleDisplayName='rmconvert', CFBundleIdentifier='com.robertsmacros.rmconvert', CFBundleExecutable='RMConvertApp', CFBundlePackageType='APPL', NSPrincipalClass='NSApplication', NSHighResolutionCapable=True, LSUIElement=True, NSHumanReadableCopyright='Roberts Macros · no macro too micro')
app_info['CFBundleDocumentTypes'] = [dict(CFBundleTypeName='rmconvert internal request', CFBundleTypeRole='Editor', LSHandlerRank='Owner', LSItemContentTypes=['com.robertsmacros.rmconvert.request'])]
app_info['UTExportedTypeDeclarations'] = [dict(UTTypeIdentifier='com.robertsmacros.rmconvert.request', UTTypeConformsTo=['public.data'], UTTypeDescription='rmconvert internal request', UTTypeTagSpecification={'public.filename-extension':['rmconvert-request']})]
app_info['NSServices'] = [dict(NSMenuItem={'default': title + '…'}, NSMessage='chooseConversion', NSPortName='rmconvert', NSSendTypes=['public.file-url', 'NSFilenamesPboardType'], NSUserData=title, NSRequiredContext={'NSApplicationIdentifier':'com.apple.finder'}) for title in ['Convert', 'PDF']]
extension_info = dict(common, CFBundleName='rmconvert Finder', CFBundleDisplayName='rmconvert', CFBundleIdentifier='com.robertsmacros.rmconvert.Finder', CFBundleExecutable='RMFinder', CFBundlePackageType='XPC!', NSPrincipalClass='NSApplication', LSUIElement=True, NSExtension=dict(NSExtensionPointIdentifier='com.apple.FinderSync', NSExtensionPrincipalClass='RMFinderSync', NSExtensionAttributes={}))
for bundle, info in [(app, app_info), (extension, extension_info)]:
    (bundle / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
doctor = subprocess.check_output([str(app / 'Contents/MacOS/rmconvert'), '--doctor'])
available = sorted(set(json.loads(doctor)) | {'native','textutil','plutil','iconutil'})
for bundle in [app, extension]:
    (bundle / 'Contents/Resources/availability.json').write_text(json.dumps(available))
