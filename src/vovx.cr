require "./vovx/constants"
require "./vovx/logger"
require "./vovx/settings"
require "./vovx/text"
require "./vovx/voice_style_option"
require "./vovx/voicevox_client"
require "./vovx/macos"
require "./vovx/playback_controller"
require "./vovx/app"
require "./vovx/cli"

module VOVX
  VERSION = {{ `shards version #{__DIR__}`.chomp.stringify }}
end
