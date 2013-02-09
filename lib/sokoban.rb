module Sokoban
  module_function

  def proxy
    require "sokoban/proxy"
    Sokoban.start_server(Sokoban::Proxy.new, (ENV["PORT"] || 5000))
  end

  def receive(repo_url = ENV["REPO_GET_URL"])
    require "sokoban/receiver"
    Sokoban.start_server(Sokoban::Receiver.new(repo_url), (ENV["PORT"] || 5001))
  end

  def pre_receive
    if STDIN.read.split("\n").grep(/\s+refs\/heads\/master$/).empty?
      puts "Pushed to non-master branch, skipping build."
    else
      File.write("/tmp/requiring", "yup")
      require "slug_compiler"
      build_dir = "/tmp/build"
      buildpack_url = "/home/phil/src/heroku-buildpack-clojure"
      cache_dir = "/tmp/cache"
      output_dir = "/tmp/out"
      File.write("/tmp/cloning", "ya")
      system("git", "clone", File.join(Dir.pwd, ".."), build_dir)
      File.write("/tmp/compiling", "yes")
      slug, process_types = SlugCompiler.run(build_dir, buildpack_url,
                                             cache_dir, output_dir)
      puts "done"
    end
  rescue
    suicide_dyno
    raise
  end

  def post_receive
    post_repo
    post_slug
    post_release
  ensure
    suicide_dyno
  end

  def start_server(handler, port, join=true)
    require "puma"
    s = Puma::Server.new(handler)
    s.add_tcp_listener("0.0.0.0", port)
    # s.run.join
    s.run
  end

  def suicide_dyno
    # TODO: exit dyno, if running in one
  end
end

# $LOAD_PATH << "/home/phil/src/sokoban/lib"
# thread = Sokoban.receive("http://p.hagelb.org/hooke.bundle")
