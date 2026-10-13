# Refresh source membership and branding without changing signing or bundle identity.
require 'xcodeproj'
Dir.chdir(__dir__)
project = Xcodeproj::Project.open('RigatoniStreamTV.xcodeproj')
target = project.targets.find { |candidate| candidate.name == 'RigatoniStreamTV' }
abort 'Apple TV target missing' unless target
group = project.main_group.children.find { |candidate| candidate.respond_to?(:path) && candidate.path == 'RigatoniStreamTV' }
group ||= project.main_group.new_group('RigatoniStreamTV', 'RigatoniStreamTV')
Dir.glob('RigatoniStreamTV/*.swift').map { |path| File.basename(path) }.sort.each do |name|
  file = group.files.find { |candidate| candidate.path == name } || group.new_file(name)
  target.source_build_phase.add_file_reference(file) unless target.source_build_phase.files_references.include?(file)
end
%w[Core.swift Library.swift DirectProviders.swift ProviderManagement.swift DirectPlayback.swift Discovery.swift Series.swift EPG.swift Saved.swift].each do |name|
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
  config.build_settings['INFOPLIST_KEY_CFBundleDisplayName'] = 'Ant Streams'
  config.build_settings['MARKETING_VERSION'] = '0.2.2'
  config.build_settings['CURRENT_PROJECT_VERSION'] = '4'
  path = config.build_settings['INFOPLIST_FILE']
  abort 'Expected a local generated Info.plist' unless path && !path.include?('$')
  info = Xcodeproj::Plist.read_from_path(path)
  info['NSAppTransportSecurity'] = { 'NSAllowsArbitraryLoads' => true }
  info['CFBundleDisplayName'] = 'Ant Streams'
  info['CFBundleName'] = 'Ant Streams'
  info['CFBundleShortVersionString'] = '0.2.2'
  info['CFBundleVersion'] = '4'
  Xcodeproj::Plist.write_to_path(info, path)
end
project.save
puts 'Updated Ant Streams sources and logo; enabled standalone HTTP access; preserved signing.'
