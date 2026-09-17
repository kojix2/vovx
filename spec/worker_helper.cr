# ameba:disable Lint/SpecFilename
require "./spec_helper"

def receive_with_timeout(channel : Channel(T)) : T forall T
  select
  when value = channel.receive
    value
  when timeout(3.seconds)
    raise "worker timed out"
  end
end
