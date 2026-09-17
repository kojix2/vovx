require "../worker_helper"
require "socket"

describe VOVX::CancellationToken do
  it "rejects already cancelled operations" do
    token = VOVX::CancellationToken.new
    token.cancel
    expect_raises(VOVX::CancelledError) { token.check! }
    expect_raises(VOVX::CancelledError) { token.pause(120.seconds) }
    expect_raises(VOVX::CancelledError) { VOVX.voicevox_engine_running?(token) }
    expect_raises(VOVX::CancelledError) { VOVX.fetch_voice_styles(token) }
    expect_raises(VOVX::CancelledError) { VOVX.synthesize("one", 1, 1.0, token) }
  end

  it "interrupts an HTTP request waiting for a response" do
    server = TCPServer.new("127.0.0.1", 0)
    accepted = Channel(TCPSocket).new(1)
    request_started = Channel(Nil).new(1)
    spawn do
      socket = server.accept
      accepted.send(socket)
      socket.gets
      request_started.send(nil)
    rescue Socket::Error
    end
    token = VOVX::CancellationToken.new
    completed = Channel(Exception?).new(1)
    context = Fiber::ExecutionContext::Parallel.new("vovx-http-spec", 1)
    context.spawn do
      client = HTTP::Client.new("127.0.0.1", server.local_address.port)
      client.read_timeout = 120.seconds
      token.with_client(client) { client.get("/") }
      completed.send(nil)
    rescue ex
      completed.send(ex)
    ensure
      client.try &.close
    end
    socket = receive_with_timeout(accepted)
    receive_with_timeout(request_started)
    token.cancel
    receive_with_timeout(completed).should be_a(VOVX::CancelledError)
  ensure
    token.try &.cancel
    socket.try &.close
    server.try &.close
  end

  it "preserves non-cancellation errors and joins its monitor" do
    token = VOVX::CancellationToken.new
    client = HTTP::Client.new("127.0.0.1", 1)
    expect_raises(Exception, "request failed") do
      token.with_client(client) { raise "request failed" }
    end
    token.with_client(client) { 42 }.should eq(42)
  ensure
    client.try &.close
  end
end
