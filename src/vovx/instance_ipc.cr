require "socket"

module VOVX
  def self.forward_to_running_instance(text : String) : Bool
    UNIXSocket.open(SOCKET_PATH) do |socket|
      socket.print text
    end
    log_event("instance.forwarded chars=#{text.size} socket=#{SOCKET_PATH}")
    true
  rescue ex : Socket::ConnectError | File::NotFoundError
    log_event("instance.forward_unavailable socket=#{SOCKET_PATH} message=#{ex.message}")
    false
  rescue ex
    log_event("instance.forward_failed socket=#{SOCKET_PATH} message=#{ex.message}")
    false
  end

  def self.start_instance_server(&on_text : String -> Nil) : UNIXServer?
    File.delete?(SOCKET_PATH)
    server = UNIXServer.new(SOCKET_PATH)
    log_event("instance.server_started socket=#{SOCKET_PATH}")

    spawn(name: "vovx-instance-server") do
      loop do
        client = server.accept?
        break if client.nil?

        begin
          text = client.gets_to_end
          log_event("instance.received chars=#{text.size}")
          on_text.call(text)
        rescue ex
          log_event("instance.receive_failed message=#{ex.message}")
        ensure
          client.close
        end
      end
    rescue ex : IO::Error
      log_event("instance.server_stopped message=#{ex.message}")
    rescue ex
      log_event("instance.server_failed message=#{ex.message}")
    end

    server
  rescue ex
    log_event("instance.server_start_failed socket=#{SOCKET_PATH} message=#{ex.message}")
    nil
  end

  def self.stop_instance_server(server : UNIXServer?) : Nil
    server.try &.close
    File.delete?(SOCKET_PATH)
    log_event("instance.server_closed socket=#{SOCKET_PATH}")
  rescue ex
    log_event("instance.server_close_failed message=#{ex.message}")
  end
end
