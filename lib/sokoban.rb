require "timeout"

module Sokoban
  module_function

  def proxy
    require "sokoban/proxy"
    Sokoban.start_server(Sokoban::Proxy.new, (ENV["PORT"] || 5000))
  end

  def receive(*args)
    require "sokoban/receiver"
    Sokoban.start_server(Sokoban::Receiver.new(*args), (ENV["PORT"] || 5001))
  end

  def post_receive_hook(*args)
    require "sokoban/hooks"
    Sokoban.post_receive(*args)
  ensure
    suicide_dyno
  end

  def start_server(handler, port)
    require "puma"
    s = Puma::Server.new(handler)
    s.add_tcp_listener("0.0.0.0", port)
    thread = s.run
    thread.join unless defined? IRB
  end

  def suicide_dyno
    # TODO: exit dyno, if running in one
  end
end
