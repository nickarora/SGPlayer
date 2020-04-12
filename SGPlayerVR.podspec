Pod::Spec.new do |s|  
  s.name              = 'SGPlayerVR'
  s.version           = '2.0.3'
  s.summary           = 'A media player framework for iOS, macOS, and tvOS.'
  s.homepage          = 'https://github.com/nickarora/SGPlayer'

  s.author            = { 'Name' => 'nicka@substantial.com' }
  s.license           = { :type => 'MIT', :file => 'LICENSE' }

  s.platform          = :ios
  s.source            = { :http => 'https://github.com/nickarora/SGPlayer/releases/download/2.0.3/SGPlayerVR.zip' }

  s.ios.deployment_target   = '9.0'
  s.ios.vendored_frameworks = 'SGPlayer.framework'
  s.static_framework        = true;
end  