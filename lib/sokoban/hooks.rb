require "json"
require "uri"
require "net/http"
require "tempfile"

module Sokoban
  module_function

  def pre_receive(user, app_name, buildpack_url, slug_put_url=nil, slug_url=nil)
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
      # TODO: appears to be running on the prior revision
      slug, dyno_types = SlugCompiler.run(build_dir, buildpack_url,
                                          cache_dir, output_dir)

      if slug_put_url
        puts("-----> Launching...")
        put_slug(slug, slug_put_url)
        # V2 releases
        repo_size = `du -s -x #{Dir.pwd}`.split(" ").first.to_i*1024
        release_name = post_release_v2(app_name, slug, dyno_types, user,
                                       slug_url, repo_size)
        # V3 releases
        # params = release_params(slug, dyno_types, user, slug_url)
        # release_name = post_release(app_name, params)
        puts("       ...done, #{release_name}.")
        puts("       http://#{app_name}.herokuapp.com deployed to Heroku\n")
      end
    end
  end

  def post_receive(repo_put_url)
    bundle = Tempfile.new("bundle").tap(&:close)
    system("git", "bundle", "create", bundle.path,
           [:out, :err] => "/dev/null")
    Timeout.timeout((ENV["REPO_PUT_TIMEOUT"] || 120).to_i) do
      put_file(bundle.path, repo_put_url)
    end
  end

  def put_slug(slug, slug_put_url)
    Timeout.timeout((ENV["SLUG_PUT_TIMEOUT"] || 120).to_i) do
      put_file(slug, slug_put_url)
    end
  end

  def post_release(app_name, params)
    Timeout.timeout((ENV["POST_RELEASE_TIMEOUT"] || 30).to_i) do
      response = release_request(app_name, params)
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
      # might be nice to get a canonical app_url back from here?
      JSON.parse(response.body) # release name
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

  def release_request(app_name, params)
    uri = release_uri(app_name)
    Net::HTTP.start(uri.host, uri.port) do |http|
      request = Net::HTTP::Post.new(uri.request_uri)
      request.basic_auth(uri.user, uri.password)
      request["Content-Type"] = "application/json"
      request["Accept"] = "application/vnd.heroku+json; version=3"
      request.body = JSON.unparse(params)
      http.request(request)
    end
  end

  def release_uri(app_name)
    (ENV["RELEASE_URI"] || "https://api.heroku.com/apps/%s/releases") % app_name
  end

  def put_file(file, put_url)
    url = URI.parse(put_url)
    request = Net::HTTP::Put.new(url.path)
    request.body_stream = File.open(file)
    request["Content-Length"] = File.size(file)
    response = Net::HTTP.start(url.host, url.port) do |http|
      http.request(request)
    end
  end

  # The above is designed to work against the v3 releases API, which
  # doesn't exist yet! So here's some stuff that works with v2:
  def post_release_v2(app_name, slug, dyno_types, user, slug_url, repo_size)
    slug_url_regex = /https:\/\/s3.amazonaws.com\/(.+?)\/(.+?)\?/
    _, slug_put_key, slug_put_bucket = slug_url.match(slug_url_regex).to_a
    start = Time.now
    payload = {
      # "head" => head,
      # "prev_head" => commit_hash,
      # "current_seq" => current_seq,
      "slug_put_key" => slug_put_key,
      "slug_put_bucket" => slug_put_bucket,
      "repo_size" => repo_size,
      "release_descr" => "sokoban-built release", # punting for v2
      "language_pack" => "Sokoban", # punting for v2
      "buildpack" => "Sokoban", # punting for v2
      "slug_version" => 2,
      "slug_size" => File.size(slug),
      "stack" => "cedar",
      "user" => user,
      "process_types" => dyno_types,
      "git_log" => "",
      "run_deploy_hooks" => false,
      "addons" => {},
      "config_vars" => {}}

    release_name =
      Timeout.timeout(30) do
      uri = URI.parse(release_uri(app_name))
      http = Net::HTTP.new(uri.host, uri.port)
      request = Net::HTTP::Post.new(uri.request_uri)
      if uri.scheme == "https"
        http.use_ssl = true
        http.verify_mode = OpenSSL::SSL::VERIFY_NONE
      end
      request.basic_auth(uri.user, uri.password)
      request["Content-Type"] = "application/json"
      request["Accept"] = "application/json"
      request.body = JSON.unparse(payload)
      response = http.request(request)
      if (response.code != "200")
        error_message = begin
                          response.body && JSON.parse(response.body)["error"] || "failure releasing code"
                        rescue Timeout::Error
                          "timed out releasing code"
                        rescue
                          "failure releasing code"
                        end
        raise(error_message)
      end
      response.body
    end
    release_name
  end
end
