require 'xcodeproj'

root = File.expand_path('..', __dir__)
project_path = File.join(root, 'Hermes.xcodeproj')
project = File.exist?(project_path) ? Xcodeproj::Project.open(project_path) : Xcodeproj::Project.new(project_path)
project.root_object.attributes['LastUpgradeCheck'] = '1600'
# objectVersion >= 52 is required for Xcode to read Swift package references; the gem
# defaults to 46 and exposes no writer, so poke the ivar directly.
if project.object_version.to_i < 54
  project.instance_variable_set(:@object_version, '54')
  project.root_object.compatibility_version = 'Xcode 13.0'
end
project.build_configurations.each do |configuration|
  configuration.build_settings['SDKROOT'] = 'iphoneos'
  configuration.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '17.0'
  configuration.build_settings['SWIFT_VERSION'] = '5.0'
end

target = project.targets.find { |item| item.name == 'Hermes' } || project.new_target(:application, 'Hermes', :ios, '17.0')
group = project.main_group.find_subpath('Hermes', false) || project.main_group.new_group('Hermes', 'Hermes')
Dir.glob(File.join(root, 'Hermes', '*.swift')).sort.each do |file|
  next unless File.basename(file).match?(/\A[A-Za-z_][A-Za-z0-9_]*\.swift\z/)
  reference = group.files.find { |item| item.path == File.basename(file) } || group.new_file(File.basename(file))
  target.source_build_phase.add_file_reference(reference) unless target.source_build_phase.files_references.include?(reference)
end
assets = group.files.find { |item| item.path == 'Assets.xcassets' } || group.new_file('Assets.xcassets')
target.resources_build_phase.add_file_reference(assets) unless target.resources_build_phase.files_references.include?(assets)
group.new_file('Info.plist') unless group.files.any? { |item| item.path == 'Info.plist' }

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
  settings['MARKETING_VERSION'] = '3.1.0'
  settings['CURRENT_PROJECT_VERSION'] = '1'
  settings['CODE_SIGN_STYLE'] = 'Automatic'
  settings['ENABLE_PREVIEWS'] = 'YES'
end

# Swift package dependencies (idempotent across regenerations)
def ensure_package(project, url, minimum_version)
  requirement = { 'kind' => 'upToNextMajorVersion', 'minimumVersion' => minimum_version }
  existing = project.root_object.package_references.find { |ref| ref.repositoryURL == url }
  if existing
    existing.requirement = requirement
    return existing
  end
  ref = project.new(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference)
  ref.repositoryURL = url
  ref.requirement = requirement
  project.root_object.package_references << ref
  ref
end

def ensure_package_dependency(project, target, package_ref, product_name)
  dep = target.package_product_dependencies.find { |item| item.product_name == product_name }
  unless dep
    dep = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
    dep.product_name = product_name
    dep.package = package_ref
    target.package_product_dependencies << dep
  end
  return if target.frameworks_build_phase.files.any? { |item| item.product_ref == dep }
  build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
  build_file.product_ref = dep
  target.frameworks_build_phase.files << build_file
end

markdown_ui = ensure_package(project, 'https://github.com/gonzalezreal/swift-markdown-ui.git', '2.4.0')
highlightr = ensure_package(project, 'https://github.com/raspu/Highlightr.git', '2.2.0')
ensure_package_dependency(project, target, markdown_ui, 'MarkdownUI')
ensure_package_dependency(project, target, highlightr, 'Highlightr')

tests = project.targets.find { |item| item.name == 'HermesTests' } || project.new_target(:unit_test_bundle, 'HermesTests', :ios, '17.0')
tests.add_dependency(target) unless tests.dependencies.any? { |item| item.target == target }
test_group = project.main_group.find_subpath('HermesTests', false) || project.main_group.new_group('HermesTests', 'HermesTests')
Dir.glob(File.join(root, 'HermesTests', '*.swift')).sort.each do |file|
  next unless File.basename(file).match?(/\A[A-Za-z_][A-Za-z0-9_]*\.swift\z/)
  reference = test_group.files.find { |item| item.path == File.basename(file) } || test_group.new_file(File.basename(file))
  tests.source_build_phase.add_file_reference(reference) unless tests.source_build_phase.files_references.include?(reference)
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
