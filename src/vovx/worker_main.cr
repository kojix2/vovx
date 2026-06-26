require "./constants"
require "./paths"
require "./logger"
require "./voice_style_option"
require "./voicevox_client"
require "./worker"

module VOVX
  VERSION = {{ `shards version #{__DIR__}`.chomp.stringify }}
end

VOVX.run_worker
