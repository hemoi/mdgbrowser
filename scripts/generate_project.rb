#!/usr/bin/env ruby

require "fileutils"
require "xcodeproj"

ROOT = File.expand_path("..", __dir__)
PROJECT_PATH = File.join(ROOT, "RetoBrowser.xcodeproj")

FileUtils.rm_rf(PROJECT_PATH)

project = Xcodeproj::Project.new(PROJECT_PATH)
project.root_object.attributes["LastSwiftUpdateCheck"] = "2640"
project.root_object.attributes["LastUpgradeCheck"] = "2640"

app_target = project.new_target(:application, "RetoBrowser", :ios, "26.0")
swiftterm_target = project.new_target(:framework, "SwiftTerm", :ios, "26.0")
test_target = project.new_target(:unit_test_bundle, "RetoBrowserTests", :ios, "26.0")
test_target.add_dependency(app_target)
app_target.add_dependency(swiftterm_target)
app_target.frameworks_build_phase.add_file_reference(swiftterm_target.product_reference)

def add_package_product(project, target, repository_url, requirement, product_name)
  package = project.new(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference)
  package.repositoryURL = repository_url
  package.requirement = requirement
  project.root_object.package_references << package

  dependency = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  dependency.package = package
  dependency.product_name = product_name
  target.package_product_dependencies << dependency

  build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
  build_file.product_ref = dependency
  target.frameworks_build_phase.files << build_file
end

add_package_product(
  project,
  app_target,
  "https://github.com/orlandos-nl/Citadel.git",
  { "kind" => "exactVersion", "version" => "0.12.1" },
  "Citadel"
)

add_package_product(
  project,
  app_target,
  "https://github.com/Wellz26/swift-nio-ssh.git",
  { "kind" => "exactVersion", "version" => "0.3.4" },
  "NIOSSH"
)

add_package_product(
  project,
  app_target,
  "https://github.com/apple/swift-nio.git",
  { "kind" => "upToNextMajorVersion", "minimumVersion" => "2.81.0" },
  "NIOCore"
)

sources_group = project.main_group.new_group("Sources", "Sources")
app_group = sources_group.new_group("RetoBrowser", "RetoBrowser")
Dir.glob(File.join(ROOT, "Sources/RetoBrowser/*.swift")).sort.each do |path|
  reference = app_group.new_file(File.basename(path))
  app_target.source_build_phase.add_file_reference(reference)
end

# SwiftTerm is vendored at a reviewed upstream revision so the Korean/CJK fixes
# are reproducible without requiring Xcode's separately downloaded Metal
# toolchain. It remains a Swift 5 static framework, matching upstream's package
# language mode and keeping its concurrency boundary outside the Swift 6 app.
vendor_group = project.main_group.new_group("Vendor", "Vendor")
swiftterm_group = vendor_group.new_group("SwiftTerm", "SwiftTerm/Sources/SwiftTerm")
Dir.glob(File.join(ROOT, "Vendor/SwiftTerm/Sources/SwiftTerm/**/*.swift")).sort.each do |path|
  next if path.include?("/Mac/") && !path.end_with?("/Mac/MacAccessibilityService.swift")
  reference = swiftterm_group.new_file(path.delete_prefix(File.join(ROOT, "Vendor/SwiftTerm/Sources/SwiftTerm/")))
  swiftterm_target.source_build_phase.add_file_reference(reference)
end

resources_group = project.main_group.new_group("Resources", "Resources")
pets_reference = resources_group.new_file("Pets")
pets_reference.last_known_file_type = "folder"
app_target.resources_build_phase.add_file_reference(pets_reference)

assets_reference = resources_group.new_file("Assets.xcassets")
assets_reference.last_known_file_type = "folder.assetcatalog"
app_target.resources_build_phase.add_file_reference(assets_reference)

vendor_group = project.main_group.new_group("Vendor", "Vendor")
cssh_group = vendor_group.new_group("CSSH", "CSSH")
cssh_reference = cssh_group.new_file("CSSH.xcframework")
cssh_reference.last_known_file_type = "wrapper.xcframework"
app_target.frameworks_build_phase.add_file_reference(cssh_reference)
[
  "THIRD_PARTY_NOTICES.md",
  "licenses/libssh2-COPYING",
  "licenses/openssl-LICENSE.txt",
].each do |relative_path|
  app_target.resources_build_phase.add_file_reference(cssh_group.new_file(relative_path))
end

tests_group = project.main_group.new_group("Tests", "Tests")
app_tests_group = tests_group.new_group("RetoBrowserTests", "RetoBrowserTests")
Dir.glob(File.join(ROOT, "Tests/RetoBrowserTests/*.swift")).sort.each do |path|
  reference = app_tests_group.new_file(File.basename(path))
  test_target.source_build_phase.add_file_reference(reference)
end

app_target.build_configurations.each do |configuration|
  settings = configuration.build_settings
  settings["ASSETCATALOG_COMPILER_APPICON_NAME"] = "AppIcon"
  settings["ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS"] = "YES"
  settings["CURRENT_PROJECT_VERSION"] = "1"
  settings["ENABLE_PREVIEWS"] = "YES"
  settings["GENERATE_INFOPLIST_FILE"] = "NO"
  settings["INFOPLIST_FILE"] = "Resources/Info.plist"
  settings["IPHONEOS_DEPLOYMENT_TARGET"] = "26.0"
  settings["MARKETING_VERSION"] = "1.0"
  settings["PRODUCT_BUNDLE_IDENTIFIER"] = "dev.modot.RetoBrowser"
  settings["PRODUCT_NAME"] = "$(TARGET_NAME)"
  settings["SWIFT_STRICT_CONCURRENCY"] = "complete"
  settings["SWIFT_VERSION"] = "6.0"
  settings["TARGETED_DEVICE_FAMILY"] = "1,2"
end


swiftterm_target.build_configurations.each do |configuration|
  settings = configuration.build_settings
  settings["DEFINES_MODULE"] = "YES"
  settings["GENERATE_INFOPLIST_FILE"] = "YES"
  settings["IPHONEOS_DEPLOYMENT_TARGET"] = "14.0"
  settings["MACH_O_TYPE"] = "staticlib"
  settings["PRODUCT_BUNDLE_IDENTIFIER"] = "dev.modot.SwiftTerm"
  settings["SKIP_INSTALL"] = "YES"
  settings["SWIFT_STRICT_CONCURRENCY"] = "minimal"
  settings["SWIFT_SUPPRESS_WARNINGS"] = "YES"
  settings["SWIFT_VERSION"] = "5.0"
  settings["TARGETED_DEVICE_FAMILY"] = "1,2"
end

test_target.build_configurations.each do |configuration|
  settings = configuration.build_settings
  settings["BUNDLE_LOADER"] = "$(TEST_HOST)"
  settings["GENERATE_INFOPLIST_FILE"] = "YES"
  settings["IPHONEOS_DEPLOYMENT_TARGET"] = "26.0"
  settings["PRODUCT_BUNDLE_IDENTIFIER"] = "dev.modot.RetoBrowserTests"
  settings["SWIFT_STRICT_CONCURRENCY"] = "complete"
  settings["SWIFT_VERSION"] = "6.0"
  settings["TEST_HOST"] = "$(BUILT_PRODUCTS_DIR)/RetoBrowser.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/RetoBrowser"
end

project.save

scheme = Xcodeproj::XCScheme.new
scheme.configure_with_targets(app_target, test_target, launch_target: true)
scheme.save_as(PROJECT_PATH, "RetoBrowser", true)

puts "Generated #{PROJECT_PATH}"
