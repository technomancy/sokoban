require "timeout"

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

  def pre_receive(buildpack_url, slug_url=nil, release_url=nil)
    if STDIN.read.split("\n").grep(/\s+refs\/heads\/master$/).empty?
      puts "Pushed to non-master branch, skipping build."
    else
      require "slug_compiler"

      build_dir = "/tmp/build"
      cache_dir = "/tmp/cache"
      output_dir = "/tmp/out"
      FileUtils.rm_rf(build_dir)

      system("git", "clone", Dir.pwd, build_dir)
      slug, process_types = SlugCompiler.run(build_dir, buildpack_url,
                                             cache_dir, output_dir)
      put_slug(slug, slug_url) if slug_url
      post_release(release_url) if slug_url && release_url
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
    Timeout.timeout((ENV["POST_SLUG_TIMEOUT"] || 120).to_i) do
      url = URI.parse(slug_url)
      request = Net::HTTP::Post.new(url.path)
      request.body_stream = File.open(slug)
      request["Content-Length"] = File.size(slug)
      response = Net::HTTP.start(url.host, url.port) do |http|
        http.request(request)
      end
      response.code == "200"
    end
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
