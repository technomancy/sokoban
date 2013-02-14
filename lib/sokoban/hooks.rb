require "json"
require "uri"

module Sokoban
  module_function

  def pre_receive(user, app_id, buildpack_url, slug_put_url=nil, slug_url=nil)
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
        puts("...done.") # TODO: include release name
        puts("       http://#{app_url} deployed to Heroku")
      end
    end
  end

  def post_receive(repo_put_url)
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
      response = release_request(app_id, params)
      unless (response.code =~ /^2/)
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
      # TODO: need app_url as well as release_name from this call
      # JSON.parse(response.body)
      app_id
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
    URI.parse((ENV["RELEASE_URI"] || \
               "https://api.heroku.com/apps/%s/releases") % app_id)
  end
end
