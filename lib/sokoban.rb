require "json"
require "timeout"
require "uri"

module Sokoban
  module_function

  def proxy
    require "sokoban/proxy"
    Sokoban.start_server(Sokoban::Proxy.new, (ENV["PORT"] || 5000))
  end

  def receive(*urls)
    require "sokoban/receiver"
    Sokoban.start_server(Sokoban::Receiver.new(*urls), (ENV["PORT"] || 5001))
  end

  def pre_receive(user, app_id, buildpack_url,
                  slug_put_url=nil, slug_url=nil, repo_put_url=nil)
    if STDIN.read.split("\n").grep(/\s+refs\/heads\/master$/).empty?
      puts "Pushed to non-master branch, skipping build."
    else
      require "slug_compiler"

      build_dir = "/tmp/build"
      cache_dir = "/tmp/cache"
      output_dir = "/tmp/out"
      FileUtils.rm_rf(build_dir)

      system("git", "clone", Dir.pwd, build_dir)
      slug, dyno_types = SlugCompiler.run(build_dir, buildpack_url,
                                          cache_dir, output_dir)

      if slug_put_url
        print("-----> Launching...")
        put_slug(slug, slug_put_url)
        params = release_params(slug, dyno_types, user, slug_url)
        app_url, release_name = post_release(app_id, params)
        puts("...done, #{release_name}")
        puts("       http://#{app_url} deployed to Heroku")
      end
    end
  rescue
    suicide_dyno
    raise
  end

  def post_receive
    # TODO: ensure failures here trickle back to client
    # post_repo
  ensure
    suicide_dyno
  end

  def put_slug(slug, slug_url)
    # TODO: the signature we get from push_meta doesn't check out:
    # The request signature we calculated does not match the signature
    # you provided. Check your key and signing method.
    # Timeout.timeout((ENV["POST_SLUG_TIMEOUT"] || 120).to_i) do
    #   url = URI.parse(slug_url)
    #   request = Net::HTTP::Post.new(url.path)
    #   request.body_stream = File.open(slug)
    #   request["Content-Length"] = File.size(slug)
    #   response = Net::HTTP.start(url.host, url.port) do |http|
    #     http.request(request)
    #   end
    # end
  end

  def post_release(app_id, params)
    Timeout.timeout((ENV["POST_RELEASE_TIMEOUT"] || 30).to_i) do
      start = Time.now
      response = release_request(app_id, params)
      if (response.code == "200")
        log("post_release at=post_response elapsed=#{Time.now - start}")
      else
        log("measure=slugc.release.error code='#{response.code}' " \
            "body='#{response.body.strip}' elapsed=#{Time.now - start}")
        error_message = begin
                          response.body && JSON.parse(response.body)["error"] \
                          or "failure releasing code"
                        rescue Timeout::Error
                          "timed out releasing code"
                        rescue
                          "failure releasing code"
                        end
        abort(error_message)
      end
      log("measure=slugc.release.time val=#{Time.now - start}")
      # TODO: need app_url as well as release_name from this call
      JSON.parse(response.body)
    end
  end

  def release_params(slug, dyno_types, user, slug_url)
    { "addons" => [], # TODO
      "config_vars" => [], # TODO
      "slug_size" => File.size(slug),
      "stack" => "cedar",
      "user" => user,
      "description" => "TODO: A Sokoban-built release!",
      "dyno_types" => dyno_types,
      "slug_url" => slug_url,
      }
  end

  def release_request(app_id, params)
    uri = release_uri(app_id)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true

    request = Net::HTTP::Post.new(uri.request_uri)
    request.basic_auth(uri.user, uri.password)
    request["Content-Type"] = "application/json"
    request["Accept"] = "application/vnd.heroku+json; version=3"
    request.body = JSON.unparse(params)
    http.request(request)
  end

  def release_uri(app_id)
    URI.parse("https://#{ENV['HEROKU_HOST'] || 'api.heroku.com'}/"\
              "apps/#{app_id}/releases")
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
