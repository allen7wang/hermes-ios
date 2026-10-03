require 'xcodeproj'

root = File.expand_path('..', __dir__)
project = Xcodeproj::Project.new(File.join(root, 'Hermes.xcodeproj'))
project.root_object.attributes['LastUpgradeCheck'] = '1600'
project.build_configurations.each do |configuration|
  configuration.build_settings['SDKROOT'] = 'iphoneos'
  configuration.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '17.0'
  configuration.build_settings['SWIFT_VERSION'] = '5.0'
end

target = project.new_target(:application, 'Hermes', :ios, '17.0')
group = project.main_group.new_group('Hermes', 'Hermes')
Dir.glob(File.join(root, 'Hermes', '*.swift')).sort.each do |file|
  reference = group.new_file(File.basename(file))
  target.source_build_phase.add_file_reference(reference)
end
assets = group.new_file('Assets.xcassets')
target.resources_build_phase.add_file_reference(assets)
group.new_file('Info.plist')

target.build_configurations.each do |configuration|
  settings = configuration.build_settings
  settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.a7w.hermes'
  settings['PRODUCT_NAME'] = 'Hermes'
  settings['SWIFT_VERSION'] = '5.0'
  settings['IPHONEOS_DEPLOYMENT_TARGET'] = '17.0'
  settings['TARGETED_DEVICE_FAMILY'] = '1,2'
  settings['INFOPLIST_FILE'] = 'Hermes/Info.plist'
  settings['GENERATE_INFOPLIST_FILE'] = 'NO'
  settings['ASSETCATALOG_COMPILER_APPICON_NAME'] = 'AppIcon'
  settings['MARKETING_VERSION'] = '0.2.0'
  settings['CURRENT_PROJECT_VERSION'] = '1'
  settings['CODE_SIGN_STYLE'] = 'Automatic'
  settings['ENABLE_PREVIEWS'] = 'YES'
end

tests = project.new_target(:unit_test_bundle, 'HermesTests', :ios, '17.0')
tests.add_dependency(target)
test_group = project.main_group.new_group('HermesTests', 'HermesTests')
Dir.glob(File.join(root, 'HermesTests', '*.swift')).sort.each do |file|
  reference = test_group.new_file(File.basename(file))
  tests.source_build_phase.add_file_reference(reference)
end
tests.build_configurations.each do |configuration|
  settings = configuration.build_settings
  settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.a7w.hermes.tests'
  settings['SWIFT_VERSION'] = '5.0'
  settings['IPHONEOS_DEPLOYMENT_TARGET'] = '17.0'
  settings['GENERATE_INFOPLIST_FILE'] = 'YES'
  settings['TEST_HOST'] = '$(BUILT_PRODUCTS_DIR)/Hermes.app/Hermes'
  settings['BUNDLE_LOADER'] = '$(TEST_HOST)'
  settings['CODE_SIGN_STYLE'] = 'Automatic'
end

project.save
scheme = Xcodeproj::XCScheme.new
scheme.configure_with_targets(target, tests)
scheme.save_as(project.path, 'HermesTests', true)
puts 'Generated Hermes.xcodeproj'
