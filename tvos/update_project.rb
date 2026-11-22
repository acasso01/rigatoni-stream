# Refresh Apple TV sources and branding while preserving signing and bundle identity.
require 'xcodeproj'
require 'yaml'
Dir.chdir(__dir__)
project = Xcodeproj::Project.open('RigatoniStreamTV.xcodeproj')
release = YAML.load_file('project.yml').fetch('targets').fetch('RigatoniStreamTV').fetch('settings').fetch('base')
version = release.fetch('CURRENT_PROJECT_VERSION').to_s
marketing_version = release.fetch('MARKETING_VERSION').to_s
team = YAML.load_file('project.yml').fetch('settings').fetch('base').fetch('DEVELOPMENT_TEAM')
target = project.targets.find { |candidate| candidate.name == 'RigatoniStreamTV' }
abort 'Apple TV target missing' unless target
group = project.main_group.children.find { |candidate| candidate.respond_to?(:path) && candidate.path == 'RigatoniStreamTV' }
group ||= project.main_group.new_group('RigatoniStreamTV', 'RigatoniStreamTV')
Dir.glob('RigatoniStreamTV/*.swift').map { |path| File.basename(path) }.sort.each do |name|
  file = group.files.find { |candidate| candidate.path == name } || group.new_file(name)
  target.source_build_phase.add_file_reference(file) unless target.source_build_phase.files_references.include?(file)
end
%w[Core.swift Library.swift DirectProviders.swift ProviderManagement.swift DirectPlayback.swift Discovery.swift Series.swift EPG.swift Saved.swift LocalProviders.swift CatalogPresentation.swift].each do |name|
  unless target.source_build_phase.files_references.any? { |file| file.path&.end_with?(name) }
    shared = project.main_group.children.find { |candidate| candidate.name == 'Shared' } || project.main_group.new_group('Shared')
    file = shared.new_file('../ios/RigatoniStream/' + name)
    target.source_build_phase.add_file_reference(file)
  end
end
asset = group.files.find { |candidate| candidate.path == 'Assets.xcassets' } || group.new_file('Assets.xcassets')
target.resources_build_phase.add_file_reference(asset) unless target.resources_build_phase.files_references.include?(asset)
target.build_configurations.each do |config|
  config.build_settings['ASSETCATALOG_COMPILER_APPICON_NAME'] = 'AppIcon'
  config.build_settings['DEVELOPMENT_TEAM'] = team
  config.build_settings['INFOPLIST_KEY_CFBundleDisplayName'] = 'Ant Streams'
  config.build_settings['MARKETING_VERSION'] = marketing_version
  config.build_settings['CURRENT_PROJECT_VERSION'] = version
  path = config.build_settings['INFOPLIST_FILE']
  abort 'Expected a local generated Info.plist' unless path && !path.include?('$')
  info = Xcodeproj::Plist.read_from_path(path)
  info['NSAppTransportSecurity'] = { 'NSAllowsArbitraryLoads' => true }
  info['CFBundleDisplayName'] = 'Ant Streams'
  info['CFBundleName'] = 'Ant Streams'
  info['CFBundleShortVersionString'] = marketing_version
  info['CFBundleVersion'] = version
  Xcodeproj::Plist.write_to_path(info, path)
end
project.save
puts "Updated Ant Streams TV sources and logo; enabled standalone/direct HTTP provider support; preserved signing; set release version #{marketing_version} (#{version})."
