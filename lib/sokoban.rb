require "heroku/api"
require "redis"
require "rack/streaming_proxy"
require "uuid"

module Sokoban
  class Error < StandardError
    attr_accessor :status
  end

  class Proxy
    def initialize
      @uuid = UUID.new
      @redis = Redis.new(:url => ENV["REDIS_URL"])
    end

    def proxy(env, base_url)
      req  = Rack::Request.new(env)
      url = base_url + env["PATH_INFO"]
      url += "?" + env["QUERY_STRING"] unless env["QUERY_STRING"].empty?

      begin # only want to catch proxy errors, not app errors
        proxy = Rack::StreamingProxy::ProxyRequest.new(req, url)
        [proxy.status, proxy.headers, proxy]
      rescue => e
        msg = "Proxy error when proxying to #{url}: #{e.class}: #{e.message}"
        env["rack.errors"].puts msg
        env["rack.errors"].puts e.backtrace.map { |l| "\t" + l }
        env["rack.errors"].flush
        raise StandardError, msg
      end
    end

    def call(env)
      app_name = env["REQUEST_PATH"][/^(.+?)\.git/, 1]
      receiver_url = ensure_receiver(app_name, api_key(env))

      puts "call app_name=#{app_name} receiver=#{receiver_url}"
      proxy(env, receiver_url)
    rescue Error => e
      [e.status, {"Content-Type" => "text/plain"}, [e.message]]
    end

    def ensure_receiver(app_name, api_key)
      JSON.parse(@redis.hget(app_name) || launch(app_name, api_key))
    end

    def receiver_config
      # TODO: get release_url, repo get/put urls from core
      { "REDIS_URL" => ENV["REDIS_URL"],
        "REPLY_KEY" => "launched.#{@uuid.generate}",
        "REPO_GET_URL" => "http://p.hagelb.org/sokoban.bundle",
      }
    end

    def launch(app_name, api_key)
      heroku = Heroku::API.new(:api_key => api_key)
      heroku.post_ps(app_name, command, { :ps_env => receiver_config })
      @redis.blpop.tap {|receiver| @redis.hset(app_name, receiver) }
    end

    def api_key(env)
      auth = Rack::Auth::Basic::Request.new(env)
      if auth.provided? && auth.basic? && auth.credentials
        auth.credentials[1]
      else
        raise Error.new("Not authorized\n").tap{|e| e.status = 401 }
      end
    end
  end
end
