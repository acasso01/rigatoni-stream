# Update existing generated projects without resetting signing or private HTTP settings.
require 'xcodeproj'
require 'pathname'
Dir.chdir(__dir__)
project = Xcodeproj::Project.open('RigatoniStream.xcodeproj')
target = project.targets.find { |candidate| candidate.name == 'RigatoniStream' }
abort 'RigatoniStream application target missing' unless target
group = project.main_group.children.find { |candidate| candidate.respond_to?(:path) && candidate.path == 'RigatoniStream' }
group ||= project.main_group.new_group('RigatoniStream', 'RigatoniStream')
%w[PictureInPictureBridge.h PictureInPictureBridge.m RigatoniStream-Bridging-Header.h Discovery.swift Series.swift ShowsView.swift].each do |name|
  file = group.files.find { |candidate| candidate.path == name } || group.new_file(name)
  if (name.end_with?('.m') || name.end_with?('.swift')) && !target.source_build_phase.files_references.include?(file)
    target.source_build_phase.add_file_reference(file)
  end
end
asset = group.files.find { |candidate| candidate.path == 'Assets.xcassets' } || group.new_file('Assets.xcassets')
target.resources_build_phase.add_file_reference(asset) unless target.resources_build_phase.files_references.include?(asset)
target.build_configurations.each do |config|
  config.build_settings['ASSETCATALOG_COMPILER_APPICON_NAME'] = 'AppIcon'
  config.build_settings['SWIFT_OBJC_BRIDGING_HEADER'] = 'RigatoniStream/RigatoniStream-Bridging-Header.h'
  path = config.build_settings['INFOPLIST_FILE']
  abort 'Expected local generated Info.plist' unless path && !path.include?('$')
  info = Xcodeproj::Plist.read_from_path(path)
  info['CFBundleDisplayName'] = 'Ant Streams'
  info['CFBundleName'] = 'Ant Streams'
  info['CFBundleShortVersionString'] = '0.2.0'
  info['CFBundleVersion'] = '2'
  config.build_settings['INFOPLIST_KEY_CFBundleDisplayName'] = 'Ant Streams'
  config.build_settings['MARKETING_VERSION'] = '0.2.0'
  config.build_settings['CURRENT_PROJECT_VERSION'] = '2'
  info['UIBackgroundModes'] = ((info['UIBackgroundModes'] || []) + ['audio']).uniq
  Xcodeproj::Plist.write_to_path(info, path)
end
project.save
puts 'Added native PiP sources and audio background mode; kept signing and local HTTP settings.'
