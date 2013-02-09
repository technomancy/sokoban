require 'zlib'
require 'rack/request'
require 'rack/response'
require 'rack/utils'
require 'redis'
require 'time'
require 'fileutils'
require 'scrolls'

module Sokoban
  class Receiver
    include Scrolls

    ROUTES =
      [["POST", :service_rpc, /(.*?)\/git-upload-pack$/,  'upload-pack'],
       ["POST", :service_rpc, /(.*?)\/git-receive-pack$/, 'receive-pack'],

       ["GET", :get_info_refs,    /(.*?)\/info\/refs$/],
       ["GET", :get_text_file,    /(.*?)\/HEAD$/],
       ["GET", :get_text_file,    /(.*?)\/objects\/info\/alternates$/],
       ["GET", :get_text_file,    /(.*?)\/objects\/info\/http-alternates$/],
       ["GET", :get_info_packs,   /(.*?)\/objects\/info\/packs$/],
       ["GET", :get_text_file,    /(.*?)\/objects\/info\/[^\/]*$/],
       ["GET", :get_loose_object, /(.*?)\/objects\/[0-9a-f]{2}\/[0-9a-f]{38}$/],
       ["GET", :get_pack_file,    /(.*?)\/objects\/pack\/pack-[0-9a-f]{40}\\.pack$/],
       ["GET", :get_idx_file,     /(.*?)\/objects\/pack\/pack-[0-9a-f]{40}\\.idx$/],
      ]

    def initialize(repo_url)
      Scrolls.global_context(app: "sokoban", receiver: true)
      bundle = File.join("/tmp", "repo.bundle")
      @repo_dir = File.join("/tmp", "repo")
      FileUtils.rm_rf(@repo_dir)

      log(action: "fetch") do
        system("curl --retry 3 --max-time 90 #{repo_url} > #{bundle}")
        system("git bundle verify #{bundle}") or raise "Corrupt repo."
        system("git clone --bare #{bundle} #{@repo_dir}")
        File.delete(bundle)
      end

      install_hooks
    end

    def install_hooks
      hooks_dir = File.join(@repo_dir, "hooks")
      FileUtils.rm_rf(hooks_dir)
      FileUtils.mkdir_p(hooks_dir)
      sokoban = "/home/phil/src/sokoban/bin/sokoban" # TODO: calculate properly
      File.open(File.join(hooks_dir, "pre-receive"), "w") do |f|
        f.puts("ruby -I #{$LOAD_PATH.join(':')} #{sokoban} pre_receive")
      end
      File.open(File.join(hooks_dir, "post-receive"), "w") do |f|
        f.puts("ruby -I #{$LOAD_PATH.join(':')} #{sokoban} post_receive")
      end
      FileUtils.chmod_R(0755, hooks_dir)
    end

    def call(env)
      @env = env
      @req = Rack::Request.new(env)

      method, *args = route(@req.request_method, @req.path_info)

      Dir.chdir(@repo_dir) do
        self.send(method, *args)
      end
    end

    def route(req_method, req_path)
      ROUTES.each do |method, handler, matcher, rpc|
        if m = matcher.match(req_path)
          if method == req_method
            file = req_path.sub(m[1] + '/', '')
            return [handler, rpc || file]
          else
            return [:not_allowed]
          end
        end
      end
      [:not_found]
    end

    def reply
      host = UDPSocket.open { |s| s.connect("64.233.187.99", 1); s.addr.last }
      url = "http://#{host}:#{ENV["PORT"]}"
      log(fn: "reply", url: url)
      Redis.new(:url => ENV["REDIS_URL"]).lpush(ENV["REPLY_KEY"], url)
    end

    # ---------------------------------
    # actual command handling functions
    # ---------------------------------

    def service_rpc(rpc)
      if content_type_matches?(rpc)
        input = read_body

        @res = Rack::Response.new
        @res.status = 200
        @res["Content-Type"] = "application/x-git-%s-result" % rpc
        @res.finish do
          command = "git #{rpc} --stateless-rpc #{@repo_dir}"
          IO.popen(command, File::RDWR) do |pipe|
            pipe.write(input)
            while !pipe.eof?
              block = pipe.read(16)   # 16B at a time
              @res.write block        # steam it to the client
            end
          end
        end
      else
        not_allowed
      end
    end

    def get_info_refs(reqfile)
      service_name = get_service_type

      if service_name == 'upload-pack' or service_name == 'receive-pack'
        refs = `git #{service_name} --stateless-rpc --advertise-refs .`

        @res = Rack::Response.new
        @res.status = 200
        @res["Content-Type"] = "application/x-git-%s-advertisement" % service_name
        hdr_nocache
        @res.write(pkt_write("# service=git-#{service_name}\n"))
        @res.write(pkt_flush)
        @res.write(refs)
        @res.finish
      else
        dumb_info_refs(reqfile)
      end
    end

    def dumb_info_refs(reqfile)
      `git update-server-info`
      send_file(reqfile, "text/plain; charset=utf-8") do
        hdr_nocache
      end
    end

    def get_info_packs(reqfile)
      # objects/info/packs
      send_file(reqfile, "text/plain; charset=utf-8") do
        hdr_nocache
      end
    end

    def get_loose_object(reqfile)
      send_file(reqfile, "application/x-git-loose-object") do
        hdr_cache_forever
      end
    end

    def get_pack_file(reqfile)
      send_file(reqfile, "application/x-git-packed-objects") do
        hdr_cache_forever
      end
    end

    def get_idx_file(reqfile)
      send_file(reqfile, "application/x-git-packed-objects-toc") do
        hdr_cache_forever
      end
    end

    def get_text_file(reqfile)
      send_file(reqfile, "text/plain") do
        hdr_nocache
      end
    end

    # ------------------------
    # logic helping functions
    # ------------------------

    # some of this borrowed from the Rack::File implementation
    def send_file(reqfile, content_type)
      reqfile = File.join(@repo_dir, reqfile)
      return render_not_found if !File.exists?(reqfile)

      @res = Rack::Response.new
      @res.status = 200
      @res["Content-Type"]  = content_type
      @res["Last-Modified"] = File.mtime(reqfile).httpdate

      yield

      if size = File.size?(reqfile)
        @res["Content-Length"] = size.to_s
        @res.finish do
          File.open(reqfile, "rb") do |file|
            while part = file.read(8192)
              @res.write part
            end
          end
        end
      else
        body = [File.read(reqfile)]
        size = Rack::Utils.bytesize(body.first)
        @res["Content-Length"] = size
        @res.write body
        @res.finish
      end
    end

    def get_service_type
      service_type = @req.params['service']
      return false if !service_type
      return false if service_type[0, 4] != 'git-'
      service_type.gsub('git-', '')
    end

    def content_type_matches?(rpc)
      @req.content_type == "application/x-git-%s-request" % rpc
    end

    def get_git_config(config_name)
      `git config #{config_name}`.chomp
    end

    def read_body
      if @env["HTTP_CONTENT_ENCODING"] =~ /gzip/
        input = Zlib::GzipReader.new(@req.body).read
      else
        input = @req.body.read
      end
    end

    # --------------------------------------
    # HTTP error response handling functions
    # --------------------------------------

    PLAIN_TYPE = {"Content-Type" => "text/plain"}

    def not_allowed
      if @env['SERVER_PROTOCOL'] == "HTTP/1.1"
        [405, PLAIN_TYPE, ["Method Not Allowed"]]
      else
        [400, PLAIN_TYPE, ["Bad Request"]]
      end
    end

    def not_found
      [404, PLAIN_TYPE, ["Not Found"]]
    end

    def no_access
      [403, PLAIN_TYPE, ["Forbidden"]]
    end


    # ------------------------------
    # packet-line handling functions
    # ------------------------------

    def pkt_flush
      '0000'
    end

    def pkt_write(str)
      (str.size + 4).to_s(base=16).rjust(4, '0') + str
    end


    # ------------------------
    # header writing functions
    # ------------------------

    def hdr_nocache
      @res["Expires"] = "Fri, 01 Jan 1980 00:00:00 GMT"
      @res["Pragma"] = "no-cache"
      @res["Cache-Control"] = "no-cache, max-age=0, must-revalidate"
    end

    def hdr_cache_forever
      now = Time.now().to_i
      @res["Date"] = now.to_s
      @res["Expires"] = (now + 31536000).to_s;
      @res["Cache-Control"] = "public, max-age=31536000";
    end

  end
end

=begin
require "puma"
repo_url = "http://p.hagelb.org/hooke.bundle"
s = Puma::Server.new(Sokoban::Receiver.new(repo_url))
s.add_tcp_listener("localhost", (ENV["PORT"] || 5000))
t = s.run
=end
