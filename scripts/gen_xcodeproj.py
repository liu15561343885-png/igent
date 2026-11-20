#!/usr/bin/env python3
"""生成 igent.xcodeproj/project.pbxproj（Xcode 16 / objectVersion 77 / 文件系统同步组）。

用脚本而不是手写：24 位对象 ID 手动数位极易出错，一旦长度不对 Xcode 直接拒绝打开。

⚠️ 一次性生成器。工程已入库，之后请在 Xcode 里编辑；重跑本脚本会覆盖工程文件。
"""
from pathlib import Path

IDS = {n: f"AA{n:022d}" for n in range(1, 26)}
for n, v in IDS.items():
    assert len(v) == 24, (n, v, len(v))

P = IDS


def i(n: int) -> str:
    return P[n]


PROJECT_DEBUG = """
				ALWAYS_SEARCH_USER_PATHS = NO;
				ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS = YES;
				CLANG_ANALYZER_NONNULL = YES;
				CLANG_ENABLE_MODULES = YES;
				CLANG_ENABLE_OBJC_ARC = YES;
				COPY_PHASE_STRIP = NO;
				DEBUG_INFORMATION_FORMAT = dwarf;
				ENABLE_STRICT_OBJC_MSGSEND = YES;
				ENABLE_TESTABILITY = YES;
				GCC_C_LANGUAGE_STANDARD = gnu17;
				GCC_DYNAMIC_NO_PIC = NO;
				GCC_NO_COMMON_BLOCKS = YES;
				GCC_OPTIMIZATION_LEVEL = 0;
				GCC_PREPROCESSOR_DEFINITIONS = (
					"DEBUG=1",
					"$(inherited)",
				);
				IPHONEOS_DEPLOYMENT_TARGET = 18.0;
				MTL_ENABLE_DEBUG_INFO = INCLUDE_SOURCE;
				MTL_FAST_MATH = YES;
				ONLY_ACTIVE_ARCH = YES;
				SDKROOT = iphoneos;
				SWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG $(inherited)";
				SWIFT_OPTIMIZATION_LEVEL = "-Onone";
				SWIFT_VERSION = 6.0;
"""

PROJECT_RELEASE = """
				ALWAYS_SEARCH_USER_PATHS = NO;
				ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS = YES;
				CLANG_ANALYZER_NONNULL = YES;
				CLANG_ENABLE_MODULES = YES;
				CLANG_ENABLE_OBJC_ARC = YES;
				COPY_PHASE_STRIP = NO;
				DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";
				ENABLE_NS_ASSERTIONS = NO;
				ENABLE_STRICT_OBJC_MSGSEND = YES;
				GCC_C_LANGUAGE_STANDARD = gnu17;
				GCC_NO_COMMON_BLOCKS = YES;
				IPHONEOS_DEPLOYMENT_TARGET = 18.0;
				MTL_ENABLE_DEBUG_INFO = NO;
				MTL_FAST_MATH = YES;
				SDKROOT = iphoneos;
				SWIFT_COMPILATION_MODE = wholemodule;
				SWIFT_OPTIMIZATION_LEVEL = "-O";
				SWIFT_VERSION = 6.0;
				VALIDATE_PRODUCT = YES;
"""

TARGET_DEBUG = """
				ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;
				CODE_SIGN_STYLE = Automatic;
				CURRENT_PROJECT_VERSION = 1;
				ENABLE_PREVIEWS = YES;
				GENERATE_INFOPLIST_FILE = NO;
				INFOPLIST_FILE = App/Support/Info.plist;
				IPHONEOS_DEPLOYMENT_TARGET = 18.0;
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/Frameworks",
				);
				MARKETING_VERSION = 0.1;
				PRODUCT_BUNDLE_IDENTIFIER = local.igent;
				PRODUCT_NAME = "$(TARGET_NAME)";
				SWIFT_EMIT_LOC_STRINGS = YES;
				SWIFT_VERSION = 6.0;
				TARGETED_DEVICE_FAMILY = "1,2";
"""

TARGET_RELEASE = """
				ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;
				CODE_SIGN_STYLE = Automatic;
				CURRENT_PROJECT_VERSION = 1;
				ENABLE_PREVIEWS = YES;
				GENERATE_INFOPLIST_FILE = NO;
				INFOPLIST_FILE = App/Support/Info.plist;
				IPHONEOS_DEPLOYMENT_TARGET = 18.0;
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/Frameworks",
				);
				MARKETING_VERSION = 0.1;
				PRODUCT_BUNDLE_IDENTIFIER = local.igent;
				PRODUCT_NAME = "$(TARGET_NAME)";
				SWIFT_EMIT_LOC_STRINGS = YES;
				SWIFT_VERSION = 6.0;
				TARGETED_DEVICE_FAMILY = "1,2";
"""

pbxproj = f"""// !$*UTF8*$!
{{
	archiveVersion = 1;
	classes = {{
	}};
	objectVersion = 77;
	objects = {{

/* Begin PBXFileReference section */
		{i(5)} /* igent.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = igent.app; sourceTree = BUILT_PRODUCTS_DIR; }};
/* End PBXFileReference section */

/* Begin PBXFileSystemSynchronizedRootGroup section */
		{i(9)} /* igent */ = {{
			isa = PBXFileSystemSynchronizedRootGroup;
			path = App/igent;
			sourceTree = "<group>";
		}};
/* End PBXFileSystemSynchronizedRootGroup section */

/* Begin PBXFrameworksBuildPhase section */
		{i(7)} /* Frameworks */ = {{
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXFrameworksBuildPhase section */

/* Begin PBXGroup section */
		{i(2)} = {{
			isa = PBXGroup;
			children = (
				{i(9)} /* igent */,
				{i(3)} /* Products */,
			);
			sourceTree = "<group>";
		}};
		{i(3)} /* Products */ = {{
			isa = PBXGroup;
			children = (
				{i(5)} /* igent.app */,
			);
			name = Products;
			sourceTree = "<group>";
		}};
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
		{i(4)} /* igent */ = {{
			isa = PBXNativeTarget;
			buildConfigurationList = {i(11)} /* Build configuration list for PBXNativeTarget "igent" */;
			buildPhases = (
				{i(6)} /* Sources */,
				{i(7)} /* Frameworks */,
				{i(8)} /* Resources */,
			);
			buildRules = (
			);
			dependencies = (
			);
			fileSystemSynchronizedGroups = (
				{i(9)} /* igent */,
			);
			name = igent;
			packageProductDependencies = (
				{i(17)} /* CoreKit */,
				{i(19)} /* LLMKit */,
				{i(21)} /* StorageKit */,
				{i(23)} /* AgentKit */,
				{i(25)} /* WebSeamKit */,
			);
			productName = igent;
			productReference = {i(5)} /* igent.app */;
			productType = "com.apple.product-type.application";
		}};
/* End PBXNativeTarget section */

/* Begin PBXProject section */
		{i(1)} /* Project object */ = {{
			isa = PBXProject;
			attributes = {{
				BuildIndependentTargetsInParallel = 1;
				LastSwiftUpdateCheck = 1640;
				LastUpgradeCheck = 1640;
				TargetAttributes = {{
					{i(4)} = {{
						CreatedOnToolsVersion = 16.4;
					}};
				}};
			}};
			buildConfigurationList = {i(10)} /* Build configuration list for PBXProject "igent" */;
			developmentRegion = en;
			hasScannedForEncodings = 0;
			knownRegions = (
				en,
				Base,
			);
			mainGroup = {i(2)};
			minimizedProjectReferenceProxies = 1;
			packageReferences = (
				{i(16)} /* XCLocalSwiftPackageReference "Packages/CoreKit" */,
				{i(18)} /* XCLocalSwiftPackageReference "Packages/LLMKit" */,
				{i(20)} /* XCLocalSwiftPackageReference "Packages/StorageKit" */,
				{i(22)} /* XCLocalSwiftPackageReference "Packages/AgentKit" */,
				{i(24)} /* XCLocalSwiftPackageReference "Packages/WebSeamKit" */,
			);
			preferredProjectObjectVersion = 77;
			productRefGroup = {i(3)} /* Products */;
			projectDirPath = "";
			projectRoot = "";
			targets = (
				{i(4)} /* igent */,
			);
		}};
/* End PBXProject section */

/* Begin PBXResourcesBuildPhase section */
		{i(8)} /* Resources */ = {{
			isa = PBXResourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXResourcesBuildPhase section */

/* Begin PBXSourcesBuildPhase section */
		{i(6)} /* Sources */ = {{
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXSourcesBuildPhase section */

/* Begin XCBuildConfiguration section */
		{i(12)} /* Debug */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{{PROJECT_DEBUG}			}};
			name = Debug;
		}};
		{i(13)} /* Release */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{{PROJECT_RELEASE}			}};
			name = Release;
		}};
		{i(14)} /* Debug */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{{TARGET_DEBUG}			}};
			name = Debug;
		}};
		{i(15)} /* Release */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{{TARGET_RELEASE}			}};
			name = Release;
		}};
/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
		{i(10)} /* Build configuration list for PBXProject "igent" */ = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{i(12)} /* Debug */,
				{i(13)} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
		{i(11)} /* Build configuration list for PBXNativeTarget "igent" */ = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{i(14)} /* Debug */,
				{i(15)} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
/* End XCConfigurationList section */

/* Begin XCLocalSwiftPackageReference section */
		{i(16)} /* XCLocalSwiftPackageReference "Packages/CoreKit" */ = {{
			isa = XCLocalSwiftPackageReference;
			relativePath = Packages/CoreKit;
		}};
		{i(18)} /* XCLocalSwiftPackageReference "Packages/LLMKit" */ = {{
			isa = XCLocalSwiftPackageReference;
			relativePath = Packages/LLMKit;
		}};
		{i(20)} /* XCLocalSwiftPackageReference "Packages/StorageKit" */ = {{
			isa = XCLocalSwiftPackageReference;
			relativePath = Packages/StorageKit;
		}};
		{i(22)} /* XCLocalSwiftPackageReference "Packages/AgentKit" */ = {{
			isa = XCLocalSwiftPackageReference;
			relativePath = Packages/AgentKit;
		}};
		{i(24)} /* XCLocalSwiftPackageReference "Packages/WebSeamKit" */ = {{
			isa = XCLocalSwiftPackageReference;
			relativePath = Packages/WebSeamKit;
		}};
/* End XCLocalSwiftPackageReference section */

/* Begin XCSwiftPackageProductDependency section */
		{i(17)} /* CoreKit */ = {{
			isa = XCSwiftPackageProductDependency;
			package = {i(16)} /* XCLocalSwiftPackageReference "Packages/CoreKit" */;
			productName = CoreKit;
		}};
		{i(19)} /* LLMKit */ = {{
			isa = XCSwiftPackageProductDependency;
			package = {i(18)} /* XCLocalSwiftPackageReference "Packages/LLMKit" */;
			productName = LLMKit;
		}};
		{i(21)} /* StorageKit */ = {{
			isa = XCSwiftPackageProductDependency;
			package = {i(20)} /* XCLocalSwiftPackageReference "Packages/StorageKit" */;
			productName = StorageKit;
		}};
		{i(23)} /* AgentKit */ = {{
			isa = XCSwiftPackageProductDependency;
			package = {i(22)} /* XCLocalSwiftPackageReference "Packages/AgentKit" */;
			productName = AgentKit;
		}};
		{i(25)} /* WebSeamKit */ = {{
			isa = XCSwiftPackageProductDependency;
			package = {i(24)} /* XCLocalSwiftPackageReference "Packages/WebSeamKit" */;
			productName = WebSeamKit;
		}};
/* End XCSwiftPackageProductDependency section */
	}};
	rootObject = {i(1)} /* Project object */;
}}
"""

out = Path(__file__).resolve().parent.parent / "igent.xcodeproj" / "project.pbxproj"
out.parent.mkdir(parents=True, exist_ok=True)
out.write_text(pbxproj, encoding="utf-8")
print(f"wrote {out} ({len(pbxproj)} bytes)")

scheme = f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "1640"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{i(4)}"
               BuildableName = "igent.app"
               BlueprintName = "igent"
               ReferencedContainer = "container:igent.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
      </Testables>
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{i(4)}"
            BuildableName = "igent.app"
            BlueprintName = "igent"
            ReferencedContainer = "container:igent.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{i(4)}"
            BuildableName = "igent.app"
            BlueprintName = "igent"
            ReferencedContainer = "container:igent.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
"""

scheme_path = out.parent / "xcshareddata" / "xcschemes" / "igent.xcscheme"
scheme_path.parent.mkdir(parents=True, exist_ok=True)
scheme_path.write_text(scheme, encoding="utf-8")
print(f"wrote {scheme_path} ({len(scheme)} bytes)")
