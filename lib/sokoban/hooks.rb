require "json"
require "uri"
require "net/http"

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

      system("git", "clone", Dir.pwd, build_dir,
             [:out, :err] => "/dev/null")
      slug, dyno_types = SlugCompiler.run(build_dir, buildpack_url,
                                          cache_dir, output_dir)

      if slug_put_url
        puts("-----> Launching...")
        put_slug(slug, slug_put_url)
        params = release_params(slug, dyno_types, user, slug_url)
        app_url, release_name = post_release(app_id, params)
        puts("       ...done.") # TODO: include release name
        puts("       #{app_url} deployed to Heroku")
      end
    end
  end

  def post_receive(build_dir, repo_put_url)
    bundle = Tempfile.new("bundle").tap(&:close)
    system("git", "bundle", "create", bundle.path,
           [:out, :err] => "/dev/null", :chdir => build_dir)
    Timeout.timeout((ENV["REPO_PUT_TIMEOUT"] || 120).to_i) do
      put_file(bundle, repo_put_url)
    end
  end

  def put_slug(slug, slug_put_url)
    Timeout.timeout((ENV["SLUG_PUT_TIMEOUT"] || 120).to_i) do
      put_file(slug, slug_put_url)
    end
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
    Net::HTTP.start(uri.host, uri.port) do |http|
      request = Net::HTTP::Post.new(uri.request_uri)
      request.basic_auth(uri.user, uri.password)
      request["Content-Type"] = "application/json"
      request["Accept"] = "application/vnd.heroku+json; version=3"
      request.body = JSON.unparse(params)
      http.request(request)
    end
  end

  def release_uri(app_id)
    URI.parse((ENV["RELEASE_URI"] || \
               "https://api.heroku.com/apps/%s/releases") % app_id)
  end

  def put_file(file, put_url)
    url = URI.parse(put_url)
    request = Net::HTTP::Post.new(url.path)
    request.body_stream = File.open(file)
    request["Content-Length"] = File.size(file)
    response = Net::HTTP.start(url.host, url.port) do |http|
      http.request(request)
    end
  end
end
