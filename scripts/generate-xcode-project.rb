#!/usr/bin/env ruby
# Maintainer tool only. The generated project and scheme are checked in;
# opening/building Filicon.xcworkspace does not require Ruby or this gem.
require 'xcodeproj'

root = File.expand_path('..', __dir__)
Dir.chdir(root)
project = Xcodeproj::Project.new('Filicon.xcodeproj')
project.root_object.compatibility_version = 'Xcode 14.0'
project.root_object.development_region = 'en'
project.root_object.known_regions = %w[en es fr ja ko zh-Hans zh-Hant Base]
project.root_object.attributes['LastUpgradeCheck'] = '2600'

package = project.new(Xcodeproj::Project::Object::XCLocalSwiftPackageReference)
package.relative_path = '.'
project.root_object.package_references << package

def link_product(project, target, package, name)
  product = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  product.package = package
  product.product_name = name
  target.package_product_dependencies << product
  build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
  build_file.product_ref = product
  target.frameworks_build_phase.files << build_file
end

def configure(target)
  target.build_configurations.each do |config|
    config.build_settings.merge!({
      'SWIFT_VERSION' => '6.0',
      'MACOSX_DEPLOYMENT_TARGET' => '14.0',
      'CODE_SIGN_STYLE' => 'Manual',
      'CODE_SIGN_IDENTITY' => '-',
      'ENABLE_HARDENED_RUNTIME' => 'YES',
      'ENABLE_USER_SCRIPT_SANDBOXING' => 'YES',
      'SWIFT_EMIT_LOC_STRINGS' => 'NO',
      'COMBINE_HIDPI_IMAGES' => 'YES',
      'LD_RUNPATH_SEARCH_PATHS' => ['$(inherited)', '@executable_path/../Frameworks'],
    })
    if config.name == 'Debug'
      config.build_settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] = ['$(inherited)', 'DEBUG']
      config.build_settings['ENABLE_TESTABILITY'] = 'YES'
      config.build_settings['SWIFT_OPTIMIZATION_LEVEL'] = '-Onone'
    else
      # Xcode omits runtime for ad-hoc signing unless explicitly requested.
      # Debug uses Xcode's debugger/test-injection defaults; Release matches
      # the hardened standalone packaging script, even when signed locally.
      config.build_settings['OTHER_CODE_SIGN_FLAGS'] = '--options runtime'
      config.build_settings['CODE_SIGN_INJECT_BASE_ENTITLEMENTS'] = 'NO'
    end
  end
end

sources = project.main_group.new_group('Sources', 'Sources')
support = project.main_group.new_group('Support', 'Support')
Dir['Support/*.{plist,entitlements}'].sort.each { |path| support.new_file(File.basename(path)) }
project.main_group.new_file('Package.swift')
project.main_group.new_file('README.md')

app = project.new_target(:application, 'Filicon', :osx, '14.0')
configure(app)
app_group = sources.new_group('Filicon', 'Filicon')
Dir['Sources/Filicon/*.swift'].sort.each do |path|
  app.source_build_phase.add_file_reference(app_group.new_file(File.basename(path)))
end
# Reuse the Swift package libraries; do not copy their implementations into
# the app or compile a second set of domain/service modules.
manifest = File.read('Package.swift')
app_dependencies = manifest.match(/\.executableTarget\(\s*name: "Filicon",\s*dependencies: \[([^\]]+)\]/)[1].scan(/"([^"]+)"/).flatten
app_dependencies.each { |name| link_product(project, app, package, name) }
resources = app_group.new_group('Resources', 'Resources')
strings = resources.new_variant_group('Localizable.strings')
Dir['Sources/Filicon/Resources/*.lproj'].sort.each do |directory|
  locale = File.basename(directory, '.lproj')
  ref = strings.new_file("#{locale}.lproj/Localizable.strings")
  ref.name = locale
end
app.resources_build_phase.add_file_reference(strings)
avatars = resources.new_file('PetAvatars')
avatars.last_known_file_type = 'folder'
app.resources_build_phase.add_file_reference(avatars)
# Xcode can omit CodeSign after a localized-resource-only incremental build.
# Declare a changing bundle output so normal signing tracks the resource tree.
# Always inspect membership, but preserve the output on unchanged builds.
resource_signing = app.new_shell_script_build_phase('Track Resource Signing')
resource_signing.shell_path = '/bin/zsh'
resource_signing.shell_script = '/bin/zsh "${SRCROOT}/scripts/resource-signing-digest.sh" "${SRCROOT}/Sources/Filicon/Resources" "${SCRIPT_OUTPUT_FILE_0}"'
resource_signing.input_paths = ['$(SRCROOT)/scripts/resource-signing-digest.sh', '$(SRCROOT)/Sources/Filicon/Resources']
resource_signing.output_paths = ['$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/FiliconResources.sha256']
resource_signing.always_out_of_date = '1'
app.build_configurations.each do |config|
  config.build_settings.merge!({
    'INFOPLIST_FILE' => 'Support/Info.plist',
    'PRODUCT_BUNDLE_IDENTIFIER' => 'com.filicon.app',
    'CODE_SIGN_ENTITLEMENTS' => 'Support/Filicon.entitlements',
    'USE_RECURSIVE_SCRIPT_INPUTS_IN_SCRIPT_PHASES' => 'YES',
    'GENERATE_INFOPLIST_FILE' => 'NO',
    'ENABLE_DEBUG_DYLIB' => 'NO',
  })
end

xpc = project.new_target(:xpc_service, 'FiliconLocalToolXPCService', :osx, '14.0')
configure(xpc)
xpc_group = sources.new_group('FiliconLocalToolXPCService', 'FiliconLocalToolXPCService')
xpc.source_build_phase.add_file_reference(xpc_group.new_file('main.swift'))
link_product(project, xpc, package, 'FiliconLocalTools')
xpc.product_reference.path = 'FiliconLocalToolService.xpc'
xpc.build_configurations.each do |config|
  config.build_settings.merge!({
    'PRODUCT_NAME' => 'FiliconLocalToolService',
    'EXECUTABLE_NAME' => 'FiliconLocalToolXPCService',
    'INFOPLIST_FILE' => 'Support/LocalToolService-Info.plist',
    'PRODUCT_BUNDLE_IDENTIFIER' => 'com.filicon.app.LocalToolService',
    # The service is not a debugger target. Do not inject get-task-allow.
    'CODE_SIGN_INJECT_BASE_ENTITLEMENTS' => 'NO',
    'GENERATE_INFOPLIST_FILE' => 'NO',
    'SKIP_INSTALL' => 'YES',
    'CODE_SIGN_ENTITLEMENTS' => config.name == 'Debug' ? 'Support/LocalToolService-Debug.entitlements' : 'Support/LocalToolService.entitlements',
  })
end
app.add_dependency(xpc)
embed_xpc = app.new_copy_files_build_phase('Embed XPC Services')
embed_xpc.dst_subfolder_spec = '1'
embed_xpc.dst_path = 'Contents/XPCServices'
embed_xpc.add_file_reference(xpc.product_reference).settings = { 'ATTRIBUTES' => ['CodeSignOnCopy', 'RemoveHeadersOnCopy'] }

embed_helpers = app.new_copy_files_build_phase('Embed Helpers')
embed_helpers.dst_subfolder_spec = '1'
embed_helpers.dst_path = 'Contents/Helpers'
{ 'FiliconLocalToolHelper' => 'FiliconLocalTools', 'FiliconUpdateHelper' => 'FiliconUpdater' }.each do |name, library|
  target = project.new_target(:command_line_tool, name, :osx, '14.0')
  configure(target)
  target.build_configurations.each { |config| config.build_settings['SKIP_INSTALL'] = 'YES' }
  group = sources.new_group(name, name)
  Dir["Sources/#{name}/*.swift"].sort.each do |path|
    target.source_build_phase.add_file_reference(group.new_file(File.basename(path)))
  end
  link_product(project, target, package, library)
  app.add_dependency(target)
  embed_helpers.add_file_reference(target.product_reference).settings = { 'ATTRIBUTES' => ['CodeSignOnCopy'] }
end

tests = project.new_target(:unit_test_bundle, 'FiliconXcodeTests', :osx, '14.0')
configure(tests)
tests.add_dependency(app)
test_group = project.main_group.new_group('XcodeTests', 'XcodeTests')
Dir['XcodeTests/*.swift'].sort.each do |path|
  tests.source_build_phase.add_file_reference(test_group.new_file(File.basename(path)))
end
# Test-host symbols are supplied by Filicon, not linked twice into the bundle.
dump_package = project.new(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference)
dump_package.repositoryURL = 'https://github.com/pointfreeco/swift-custom-dump'
dump_package.requirement = { 'kind' => 'upToNextMajorVersion', 'minimumVersion' => '1.3.3' }
project.root_object.package_references << dump_package
link_product(project, tests, dump_package, 'CustomDump')
tests.build_configurations.each do |config|
  config.build_settings.merge!({
    'GENERATE_INFOPLIST_FILE' => 'YES',
    'PRODUCT_BUNDLE_IDENTIFIER' => 'com.filicon.app.XcodeTests',
    'TEST_HOST' => '$(BUILT_PRODUCTS_DIR)/Filicon.app/Contents/MacOS/Filicon',
    'BUNDLE_LOADER' => '$(TEST_HOST)',
    'LD_RUNPATH_SEARCH_PATHS' => ['$(inherited)', '@loader_path/../Frameworks'],
  })
end

project.predictabilize_uuids
project.save
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(app)
scheme.set_launch_target(app)
scheme.add_test_target(tests)
# Do not attach the debugger to the sandboxed service during normal Run.
# XCTest can still re-sign services for diagnostics; smoke-xcode-xpc.sh
# separately verifies the strict sandbox without testmanager involvement.
scheme.launch_action.xml_element.attributes['debugXPCServices'] = 'NO'
scheme.test_action.xml_element.attributes['debugXPCServices'] = 'NO'
scheme.test_action.should_use_launch_scheme_args_env = false
scheme.test_action.environment_variables = Xcodeproj::XCScheme::EnvironmentVariables.new([
  { key: 'FILICON_DATA_ROOT', value: '$(PROJECT_TEMP_DIR)/FiliconXcodeTestData', enabled: true },
])
scheme.test_action.xml_element.attributes['testTimeoutsEnabled'] = 'YES'
scheme.test_action.xml_element.attributes['defaultTestExecutionTimeAllowance'] = '30'
scheme.test_action.xml_element.attributes['maximumTestExecutionTimeAllowance'] = '60'
scheme.save_as(project.path, 'Filicon App', true)
puts 'Generated Filicon.xcodeproj; open Filicon.xcworkspace and select Filicon App.'
