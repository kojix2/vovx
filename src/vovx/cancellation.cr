require "http/client"

module VOVX
  class CancelledError < Exception
    def initialize
      super("operation cancelled")
    end
  end

  # HTTP 待機も中断できる、処理ごとに使い捨てる停止トークン。
  class CancellationToken
    POLL_INTERVAL = 20.milliseconds

    @mutex = Mutex.new
    @cancelled = false

    def cancel : Nil
      @mutex.synchronize { @cancelled = true }
    end

    def cancelled? : Bool
      @mutex.synchronize { @cancelled }
    end

    def check! : Nil
      raise CancelledError.new if cancelled?
    end

    def pause(interval : Time::Span) : Nil
      deadline = Time.instant + interval
      loop do
        check!
        remaining = deadline - Time.instant
        break if remaining <= Time::Span.zero
        sleep Math.min(remaining, POLL_INTERVAL)
      end
    end

    # クライアントの操作と監視は同じ execution context で行う。
    # 接続中はまだ socket がないので、完了まで繰り返し close を試す。
    def with_client(client : HTTP::Client, & : -> T) : T forall T
      check!
      done = Channel(Nil).new
      monitor_done = Channel(Nil).new
      Fiber::ExecutionContext.current.spawn(name: "vovx-http-cancellation") do
        loop do
          select
          when done.receive?
            break
          when timeout(POLL_INTERVAL)
            client.close if cancelled?
          end
        end
      ensure
        monitor_done.close
      end

      begin
        result = yield
        check!
        result
      rescue ex
        check!
        raise ex
      ensure
        done.close
        monitor_done.receive?
      end
    end
  end
end
