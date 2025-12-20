Pod::Spec.new do |s|
  s.name             = 'MostlyGoodMetrics'
  s.version          = '0.5.4'
  s.summary          = 'Analytics SDK for iOS, macOS, tvOS, and watchOS'
  s.description      = <<-DESC
    MostlyGoodMetrics is a lightweight analytics SDK that provides event tracking,
    user identification, and automatic app lifecycle tracking with local storage
    and batch uploading capabilities.
  DESC

  s.homepage         = 'https://github.com/Mostly-Good-Metrics/mostly-good-metrics-swift-sdk'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'Josh Holtz' => 'me@joshholtz.com' }
  s.source           = { :git => 'https://github.com/Mostly-Good-Metrics/mostly-good-metrics-swift-sdk.git', :tag => s.version.to_s }

  s.ios.deployment_target = '14.0'
  s.osx.deployment_target = '11.0'
  s.tvos.deployment_target = '14.0'
  s.watchos.deployment_target = '7.0'

  s.swift_version = '5.9'

  s.source_files = 'Sources/MostlyGoodMetrics/**/*.swift'

  s.frameworks = 'Foundation'
  s.ios.frameworks = 'UIKit'
  s.osx.frameworks = 'AppKit'
  s.watchos.frameworks = 'WatchKit'
end
