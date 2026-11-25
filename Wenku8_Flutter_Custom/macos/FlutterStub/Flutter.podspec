Pod::Spec.new do |s|
  s.name = 'Flutter'
  s.version = '1.0.0'
  s.summary = 'Local stub so CocoaPods never queries the CDN for the legacy Flutter pod.'
  s.homepage = 'https://flutter.dev'
  s.license = { :type => 'BSD' }
  s.author = { 'Flutter Dev Team' => 'flutter-dev@googlegroups.com' }
  s.source = { :path => '.' }
  s.source_files = 'Sources/*.m'
  s.ios.deployment_target = '12.0'
  s.osx.deployment_target = '10.15'
end
