# Native production comparison. Outputs stay in ignored tmp; never benchmarks a stub app.
require_relative "support"
require_relative "http_client"
require "base64"
require "digest"
require "stringio"
require "zlib"
require "time"
include BenchmarkSupport

def webp_dimensions(bytes)
  return unless bytes.byteslice(0, 4) == "RIFF" && bytes.byteslice(8, 4) == "WEBP"

  offset = 12
  while offset + 8 <= bytes.bytesize
    chunk = bytes.byteslice(offset, 4)
    size = bytes.byteslice(offset + 4, 4).unpack1("V")
    data = offset + 8
    return if data + size > bytes.bytesize

    case chunk
    when "VP8X" # Extended WebP stores 24-bit dimensions minus one.
      return unless size >= 10

      width = 1 + bytes.byteslice(data + 4, 3).unpack("C3").each_with_index.sum { |byte, i| byte << (8 * i) }
      height = 1 + bytes.byteslice(data + 7, 3).unpack("C3").each_with_index.sum { |byte, i| byte << (8 * i) }
      return [width, height]
    when "VP8 " # Lossy WebP frame header, dimensions are 14-bit little-endian values.
      if size >= 10 && bytes.byteslice(data + 3, 3) == "\x9d\x01\x2a".b
        width = bytes.byteslice(data + 6, 2).unpack1("v") & 0x3fff
        height = bytes.byteslice(data + 8, 2).unpack1("v") & 0x3fff
        return [width, height]
      end
    when "VP8L" # Lossless WebP packs dimensions into four bytes after its signature.
      if size >= 5 && bytes.getbyte(data) == 0x2f
        b1, b2, b3, b4 = bytes.byteslice(data + 1, 4).unpack("C4")
        width = 1 + b1 + ((b2 & 0x3f) << 8)
        height = 1 + ((b2 >> 6) | (b3 << 2) | ((b4 & 0x0f) << 10))
        return [width, height]
      end
    end

    offset = data + size + (size.odd? ? 1 : 0)
  end

  nil
end

# The load generator inherits this soft limit. macOS commonly starts at 256,
# which silently caps large Cable runs before the server reaches its capacity.
nofile_soft, nofile_hard = Process.getrlimit(Process::RLIMIT_NOFILE)
nofile_target = nofile_hard == Process::RLIM_INFINITY ? 4096 : [4096, nofile_hard].min
Process.setrlimit(Process::RLIMIT_NOFILE, nofile_target, nofile_hard) if nofile_soft < nofile_target
nofile_soft = Process.getrlimit(Process::RLIMIT_NOFILE).first

repo = File.expand_path("..", __dir__)
workspace = File.dirname(repo)
work = File.join(repo, "tmp/bench")
linux_host = RUBY_PLATFORM.include?("linux")
options = { apps: "ruby,express", rounds: 2, duration: 4, concurrencies: "16", port: 25130,
  seed: File.join(workspace, "once-campfire-rust/parity/.seed/default"), preflight: false,
  validation_only: false, save_bodies: false,
  loadgen: ENV.fetch("LOADGEN", File.join(workspace, "once-campfire-verification/loadgen/target/release/loadgen")),
  env_file: ENV.fetch("BENCH_ENV_FILE", File.join(workspace, "once-campfire-elixir/parity/reference.env")),
  output: File.join(work, "results"), cpus: linux_host ? "8-11" : "0-3", client_cpus: linux_host ? "12-15" : "4-7", suites: "http", cable_clients: "100,500,1000", cable_tput_secs: 15, routes: "room_show,messages_page,sidebar,search,avatar,static_css,up,post_message" }
OptionParser.new do |parser|
  options.each do |key, default|
    if [true, false].include?(default)
      parser.on("--#{key}") { options[key] = true }
    else
      type = default.is_a?(Integer) ? Integer : String
      parser.on("--#{key.to_s.tr('_', '-')} VALUE", type) { |value| options[key] = value }
    end
  end
parser.on("--help") { puts parser; exit }
end.parse!
unless File.executable?(options[:loadgen])
  raise "load generator not executable at #{options[:loadgen]}; build once-campfire-verification/loadgen or set LOADGEN"
end
raise "use an even number of rounds" unless options[:rounds].positive? && options[:rounds].even?
if options[:validation_only]
  raise "validation-only runs require --suites cable" unless options[:suites] == "cable"
  raise "validation-only runs do not produce comparative performance results" if options[:cable_tput_secs].to_i > 0
end
raise "throughput runs require a Linux host for CPU pinning; use --preflight or --validation-only on macOS" unless linux_host || options[:preflight] || options[:validation_only]
apps = options[:apps].split(",")
raise "unknown app" unless (apps - %w[ruby django laravel express mojo oxcaml]).empty?
if apps.include?("oxcaml")
  source = File.join(repo, "once-campfire-oxcaml")
  reference_css = File.binread(File.join(source, "reference/app/assets/stylesheets/_reset.css"))
  packaged_css = File.binread(File.join(source, "assets/campfire.css"))
  raise "OxCaml packaged CSS differs from its pinned Rails source asset" unless packaged_css == reference_css
end
if !linux_host && !(apps - %w[mojo express oxcaml]).empty?
  raise "macOS preflight currently supports only --apps mojo, express, and oxcaml"
end
labels = JSON.parse(File.read(File.join(options[:seed], "labels.json")))
original_seed_sha = Digest::SHA256.file(File.join(options[:seed], "db/production.sqlite3")).hexdigest
room = Integer(labels.fetch("rooms.watercooler"))
write_room = Integer(labels.fetch("rooms.hq"))
base = "http://127.0.0.1:#{options[:port]}"
fixture_env = File.readlines(options[:env_file], chomp: true).reject { |line| line.empty? || line.start_with?("#") }.to_h { |line| line.split("=", 2) }
loadgen_command = linux_host ? ["taskset", "-c", options[:client_cpus], options[:loadgen]] : [options[:loadgen]]
load_snapshot = -> do
  if File.file?("/proc/loadavg")
    File.read("/proc/loadavg").strip
  elsif RUBY_PLATFORM.include?("darwin")
    output, status = Open3.capture2("sysctl", "-n", "vm.loadavg")
    status.success? ? output.strip : "unavailable"
  else
    "unavailable"
  end
end
lg = ->(*args) do
  if ENV["LOADGEN_DEBUG"]
    output, errors, status = Open3.capture3(*loadgen_command, *args)
    File.open(File.join(work, "loadgen-debug-#{Process.pid}.log"), "ab") { |file| file.write(errors) }
    raise "load generator failed" unless status.success?
    JSON.parse(output)
  else
    JSON.parse(run(*loadgen_command, *args))
  end
end
container = "cf-native-bench-#{Process.pid}"
redis_container = "#{container}-redis"
redis_port = options[:port] + 2
results = []
expected_message_ids = {}
expected_mention_ids = nil
expected_sidebar_room_ids = nil
expected_boost_ids = {}
expected_attachment_blob_urls = {}
expected_attachment_range_prefixes = {}
expected_attachment_dispositions = {}
metadata = { started_at: Time.now.utc.iso8601, seed_sha256: original_seed_sha, host_platform: RUBY_PLATFORM,
  cpu_pinning: linux_host ? "taskset and Docker cpuset" : "Docker cpuset only; validation only", server_cpus: options[:cpus],
  client_cpus: options[:client_cpus], client_nofile_soft: nofile_soft, network: linux_host ? "host" : "bridge with published benchmark port",
  accept_encoding: "gzip", duration: options[:duration],
  concurrencies: options[:concurrencies], rounds: options[:rounds], loadgen_sha256: Digest::SHA256.file(options[:loadgen]).hexdigest,
  suites: options[:suites], routes: options[:routes], cable_clients: options[:cable_clients], cable_tput_secs: options[:cable_tput_secs], images: {}, image_labels: {}, source_revisions: {}, preflight_only: options[:preflight], validation_only: options[:validation_only] }
observer_app = nil
completed = false
sql = ->(db, query) do
  readonly = query.match?(/\A(?:SELECT|PRAGMA)/i)
  output = if readonly && observer_app == "laravel"
    # The FPM-owned WAL can create its shared-memory file even for a read-only observer.
    # Read as that same UID inside the disposable container, without booting Laravel.
    run("docker", "exec", "--user", "www-data", container, "php", "-r",
      '$pdo = new PDO("sqlite:/rails/storage/db/production.sqlite3"); $pdo->exec("PRAGMA busy_timeout = 10000"); echo json_encode($pdo->query($argv[1])->fetchAll(PDO::FETCH_ASSOC));', query)
  else
    run("sqlite3", "-cmd", ".timeout 10000", *(readonly ? ["-readonly"] : []), "-json", db, query)
  end
  output.strip.empty? ? [] : JSON.parse(output)
end
check_sample = ->(name, value) do
  raise "#{name}: unsuccessful requests #{value}" unless value.fetch("errors").zero? && value.fetch("invalid_responses", 0).zero? && value.fetch("statuses").keys == ["200"]
end
begin
  options[:rounds].times do |iteration|
    order = iteration.even? ? apps : apps.reverse
    order.each do |app|
      image = ENV.fetch("#{app.upcase}_IMAGE", app == "ruby" ? "campfire-ruby:readme-659f957" : "once-campfire-#{app}:app")
      oxcaml_source = File.join(repo, "once-campfire-oxcaml")
      oxcaml_source = File.join(workspace, "once-campfire-express/once-campfire-oxcaml") unless File.directory?(oxcaml_source)
      source = app == "oxcaml" ? oxcaml_source :
        File.join(workspace, "once-campfire#{app == 'ruby' ? '' : "-#{app}"}")
      metadata[:images][app] = run("docker", "image", "inspect", "-f", "{{.Id}}", image).strip
      metadata[:image_labels][app] = JSON.parse(run("docker", "image", "inspect", "-f", "{{json .Config.Labels}}", image))
      revision, _revision_error, revision_status = Open3.capture3("git", "-C", source, "rev-parse", "--verify", "HEAD")
      metadata[:source_revisions][app] = { head: revision_status.success? ? revision.strip : nil,
        dirty: !run("git", "-C", source, "status", "--porcelain").strip.empty? }
      data = File.join(work, "runtime", Process.pid.to_s, "#{app}-#{iteration + 1}")
      prepare_storage(options[:seed], data)
      FileUtils.mkdir_p(File.join(data, "logs"))
      db = File.join(data, "db/production.sqlite3")
      unless linux_host
        # Docker Desktop shares this file across macOS and its Linux VM. Rollback
        # journaling avoids cross-OS WAL shared-memory races during validation.
        journal_mode = run("sqlite3", db, "PRAGMA journal_mode=DELETE").strip.downcase
        raise "could not disable WAL for macOS validation fixture: #{journal_mode}" unless journal_mode == "delete"
      end
      sql.call(db, "UPDATE push_subscriptions SET endpoint = 'https://127.0.0.1:9/push/' || id; UPDATE webhooks SET url = 'http://127.0.0.1:9/hook/' || id;")
      if app == "oxcaml"
        # Docker Desktop may not invalidate SQLite's open-page cache after a
        # host-side write to a mounted rollback-journal database. Seed these
        # ban inputs before the OxCaml process opens its connection.
        ban_user_id = Integer(labels.fetch("users.kevin"))
        sql.call(db, "INSERT INTO sessions(user_id,token,ip_address,last_active_at,created_at,updated_at) VALUES(#{ban_user_id},'bench-ban-public-a','203.0.113.77',CURRENT_TIMESTAMP,CURRENT_TIMESTAMP,CURRENT_TIMESTAMP),(#{ban_user_id},'bench-ban-public-b','203.0.113.77',CURRENT_TIMESTAMP,CURRENT_TIMESTAMP,CURRENT_TIMESTAMP),(#{ban_user_id},'bench-ban-private','127.0.0.1',CURRENT_TIMESTAMP,CURRENT_TIMESTAMP,CURRENT_TIMESTAMP)")
      end
      if %w[ruby express mojo oxcaml].include?(app)
        sql.call(db, "INSERT INTO searches(created_at,query,updated_at,user_id) VALUES(CURRENT_TIMESTAMP,'benchmark account deactivation preflight',CURRENT_TIMESTAMP,#{Integer(labels.fetch('users.jz'))})")
      end
      raise "invalid seed" unless sql.call(db, "SELECT COUNT(*) AS n FROM messages WHERE room_id=#{room}").first.fetch("n") > 50
      initial_max_id = sql.call(db, "SELECT MAX(id) AS id FROM messages").first.fetch("id")
      initial_messages = sql.call(db, "SELECT COUNT(*) AS n FROM messages WHERE room_id=#{write_room}").first.fetch("n")
      initial_boosts = sql.call(db, "SELECT COUNT(*) AS n FROM boosts").first.fetch("n")
      config = fixture_env.merge("WEB_CONCURRENCY" => "3", "JOB_CONCURRENCY" => "3", "RAILS_MAX_THREADS" => "5",
        "RAILS_LOG_LEVEL" => "warn", "HTTP_PORT" => options[:port].to_s, "TARGET_PORT" => (options[:port] + 1).to_s)
      app_overrides = JSON.parse(ENV.fetch("#{app.upcase}_BENCH_ENV", "{}"))
      config.merge!(app_overrides)
      if app == "oxcaml"
        config["CAMPFIRE_STORAGE_PATH"] = "/rails/storage"
        config["HTTP_PORT"] = options[:port].to_s
        domains = oxcaml_domain_count(cpu_set: options[:cpus], linux_host: linux_host, overrides: app_overrides)
        config["WEB_WORKERS"] = domains.to_s
      end
      if app == "django"
        redis_image = ENV.fetch("DJANGO_REDIS_IMAGE", "redis:7.2-alpine")
        metadata[:images]["django_redis"] = run("docker", "image", "inspect", "-f", "{{.Id}}", redis_image).strip
        run("docker", "run", "-d", "--name", redis_container, "--network", "host", "--cpuset-cpus", options[:cpus], redis_image,
          "redis-server", "--bind", "127.0.0.1", "--port", redis_port.to_s, "--save", "", "--appendonly", "no")
        config["REDIS_URL"] = "redis://127.0.0.1:#{redis_port}/0"
        config["WEB_WORKERS"] ||= "3"
      end
      config["HTTP_WORKERS"] ||= "4" if app == "mojo"
      metadata[:topology] ||= {}
      metadata[:topology][app] = app == "express" ? {http_workers: config.fetch("WEB_WORKERS", "3"), cable: "native ws with cluster IPC", jobs: "leased auxiliary SQLite"} : app == "django" ? {http_workers: config.fetch("WEB_WORKERS"), cable: "ASGI with isolated Redis", jobs: "leased auxiliary SQLite"} :
        app == "laravel" ? {http_workers: 8, http: "nginx/FPM OPcache", cable: "native Workerman", jobs: "auxiliary SQLite queue worker"} : app == "mojo" ? {http_workers: config.fetch("HTTP_WORKERS"), image_config: "MOJO_BENCH_ENV", http: "native Mojo server", cable: "native WebSocket with per-worker SQLite polling"} : app == "oxcaml" ? {http_domains: config.fetch("WEB_WORKERS", "1"), runtime: "OxCaml/Eio", cable: "Action Cable protocol over RFC 6455 with in-process Eio event bus"} : {http_workers: 3, threads: 5, http: "Thruster/Puma", cable: "native Rails", jobs: "native Ruby Redis"}
      if app == "mojo"
        image_labels = metadata[:image_labels][app] || {}
        metadata[:topology][app][:compiler_version] = image_labels.fetch("org.modular.mojo.version", "unknown")
        metadata[:topology][app][:optimization] = image_labels.fetch("org.modular.mojo.optimization", "unknown")
      end
      config["WEB_WORKERS"] ||= linux_host ? "3" : "1" if app == "express"
      command = ["docker", "run", "-d", "--name", container]
      if linux_host
        command.concat(["--network", "host"])
      else
        command.concat(["-p", "127.0.0.1:#{options[:port]}:#{config.fetch('HTTP_PORT')}"])
      end
      command.concat(["--cpuset-cpus", options[:cpus]])
      command.concat environment(config)
      command.concat mounts(File.join(data, "db") => "/rails/storage/db", File.join(data, "files") => "/rails/storage/files", File.join(data, "logs") => "/rails/storage/logs")
      command << image
      run(*command)
      client = BenchmarkHTTPClient.new(base)
      deadline = clock + 90
      until client.ready?
        raise "#{app} failed to start; inspect #{container} logs" if clock > deadline
        sleep 0.1
      end
      observer_app = app
      sleep 10 unless options[:preflight]
      cookie = lg.call("login", "--base", base, "--email", labels.fetch("emails.david"), "--password", labels.fetch("passwords.all")).fetch("cookie")
      scrape = lg.call("scrape", "--base", base, "--cookie", cookie, "--room", room.to_s)
      csrf = scrape.fetch("csrf")
      raise "no CSRF token" unless csrf && !csrf.empty?
      routes = { "room_show" => "/rooms/#{room}", "messages_page" => "/rooms/#{room}/messages?before=#{labels.fetch('messages.busy_060')}",
        "sidebar" => "/users/me/sidebar", "search" => "/searches?q=coffee", "avatar" => "/users/#{labels.fetch('avatar_tokens.jason')}/avatar",
        "static_css" => scrape.fetch("css"), "up" => "/up", "post_message" => nil }
      routes["profile"] = "/users/me/profile" if %w[ruby express mojo oxcaml].include?(app)
      routes["user"] = "/users/#{Integer(labels.fetch('users.david'))}" if %w[ruby express mojo oxcaml].include?(app)
      routes["account"] = "/account/edit" if %w[ruby express mojo].include?(app)
      routes["account"] = "/account/edit" if app == "oxcaml"
      routes["autocomplete_users"] = "/autocompletable/users?#{URI.encode_www_form(room_id: room, filter: "david")}" if %w[ruby express mojo oxcaml].include?(app)
      if app == "oxcaml"
        routes["webmanifest"] = "/webmanifest"
        routes["service_worker"] = "/service-worker"
      end
      preflight = {}
      static_asset_checks = {}
      attachment_posts = 0
      boost_mutation = nil
      unless options[:validation_only]
      Net::HTTP.new("127.0.0.1", options[:port], nil).start do |http|
        if app == "mojo"
          session_form_response = http.get("/session/new")
          raise "#{app} sign-in form failed: HTTP #{session_form_response.code}" unless session_form_response.code == "200"
          session_form_csrf = session_form_response.body[/<meta name="csrf-token" content="([^"]+)"/, 1]
          prior_session_cookie = session_form_response.get_fields("set-cookie")&.map { |value| value.split(";", 2).first }&.find { |value| value.start_with?("_campfire_session=") }
          raise "#{app} sign-in form omitted CSRF state" unless session_form_csrf && prior_session_cookie
          login_request = Net::HTTP::Post.new("/session")
          login_request["Cookie"] = prior_session_cookie
          login_request.set_form_data("email_address" => labels.fetch("emails.david"),
            "password" => labels.fetch("passwords.all"), "authenticity_token" => CGI.unescapeHTML(session_form_csrf))
          login_response = http.request(login_request)
          raise "#{app} sign-in failed: HTTP #{login_response.code}" unless login_response.code == "302" && login_response["location"] == "/"
          rotated_cookie_pairs = login_response.get_fields("set-cookie")&.map { |value| value.split(";", 2).first } || []
          new_session_cookie = rotated_cookie_pairs.find { |value| value.start_with?("_campfire_session=") }
          raise "#{app} sign-in did not rotate encrypted session state" unless new_session_cookie && new_session_cookie != prior_session_cookie
          raise "#{app} sign-in omitted the authenticated session cookie" unless rotated_cookie_pairs.any? { |value| value.start_with?("session_token=") }
          rotated_cookie = rotated_cookie_pairs.join("; ")
          rotated_auth_response = http.get("/users/me/sidebar", "Cookie" => rotated_cookie)
          raise "#{app} rotated sign-in cookies did not authenticate: HTTP #{rotated_auth_response.code}" unless rotated_auth_response.code == "200"
          join_code_before_rotation_check = sql.call(db, "SELECT join_code FROM accounts ORDER BY id LIMIT 1").first.fetch("join_code")
          stale_csrf_request = Net::HTTP::Post.new("/account/join_code")
          stale_csrf_request["Cookie"] = rotated_cookie
          stale_csrf_request["Origin"] = base
          stale_csrf_request["Sec-Fetch-Site"] = "same-origin"
          stale_csrf_request.set_form_data("authenticity_token" => CGI.unescapeHTML(session_form_csrf))
          stale_csrf_response = http.request(stale_csrf_request)
          raise "#{app} accepted pre-login CSRF state after session rotation: HTTP #{stale_csrf_response.code}" unless stale_csrf_response.code == "422"
          raise "#{app} stale-CSRF login request changed join code" unless sql.call(db, "SELECT join_code FROM accounts ORDER BY id LIMIT 1").first.fetch("join_code") == join_code_before_rotation_check
          preflight["login_session_rotation"] = { login_status: login_response.code.to_i,
            stale_csrf_status: stale_csrf_response.code.to_i, encrypted_cookie_rotated: true, authenticated: true }
        end
        routes.each do |name, path|
          next unless path
          response = http.get(path, "Cookie" => cookie, "Accept-Encoding" => "gzip")
          raise "#{app} #{name}: HTTP #{response.code}" unless response.code == "200"
          body = response.body
          body = Zlib::GzipReader.new(StringIO.new(body)).read if response["content-encoding"] == "gzip"
          if app == "oxcaml" && %w[room_show messages_page sidebar search static_css profile user account autocomplete_users].include?(name)
            expected_encoding = body.bytesize >= 1024 ? "gzip" : nil
            raise "#{app} #{name} encoding mismatch for #{body.bytesize}-byte response" unless response["content-encoding"] == expected_encoding
          end
          if options[:save_bodies]
            File.write(File.join(options[:output], "#{app}-#{iteration + 1}-#{name}.html"), body)
          end
          raise "#{name}: empty body" if body.empty?
          if name == "profile"
            required_fields = %w[user[name] user[email_address] user[bio] user[password]]
            missing_fields = required_fields.reject { |field| body.include?("name=\"#{field}\"") }
            raise "#{app} profile form missing fields #{missing_fields.inspect}" unless missing_fields.empty?
          end
          if name == "user"
            expected_name = sql.call(db, "SELECT name FROM users WHERE id=#{Integer(labels.fetch('users.david'))}").first&.fetch("name")
            raise "#{app} user profile missing its subject" unless expected_name && body.include?(expected_name)
          end
          if name == "account"
            required_fields = %w[account[name] account[settings][restrict_room_creation_to_administrators]]
            missing_fields = required_fields.reject { |field| body.include?("name=\"#{field}\"") }
            raise "#{app} account settings form missing fields #{missing_fields.inspect}" unless missing_fields.empty?
            member_name = sql.call(db, "SELECT name FROM users WHERE id=#{Integer(labels.fetch('users.loner'))} AND status=0").first&.fetch("name")
            raise "#{app} account member list omits its active member" unless member_name && body.include?(member_name)
            raise "#{app} account admin controls missing" unless body.include?("/account/users/#{Integer(labels.fetch('users.loner'))}")
          end
          if name == "avatar" && app == "oxcaml"
            avatar = sql.call(db, "SELECT b.content_type FROM active_storage_attachments a JOIN active_storage_blobs b ON b.id=a.blob_id WHERE a.record_type='User' AND a.record_id=#{Integer(labels.fetch('users.jason'))} AND a.name='avatar'").first
            if avatar && %w[image/png image/jpeg image/gif image/bmp image/webp].include?(avatar.fetch("content_type"))
              raise "#{app} variable avatar was not rendered as WebP" unless response["content-type"].start_with?("image/webp") && body.start_with?("RIFF") && body.byteslice(8, 4) == "WEBP"
              width, height = webp_dimensions(body)
              raise "#{app} avatar variant has no readable WebP dimensions" unless width && height
              raise "#{app} avatar variant dimensions exceed Rails' 512x512 limit: #{width}x#{height}" unless width.positive? && height.positive? && width <= 512 && height <= 512
              preflight["avatar_variant"] = { content_type: "image/webp", width: width, height: height }
            end
          end
          raise "#{name}: unpopulated" if %w[room_show messages_page search].include?(name) && !body.match?(/data-message-id="\d+"/)
          if name == "messages_page" && app == "oxcaml"
            raise "#{app} messages_page returned a room layout instead of the Rails message partial" if body.match?(/<!doctype|<nav\b|<main\b/i)
          end
          raise "sidebar missing room" if name == "sidebar" && !(body.include?("shared_rooms") && body.include?(room.to_s))
          if name == "sidebar"
            sidebar_ids = body.scan(/data-room-id="(\d+)"/).flatten.map(&:to_i)
            expected_membership_ids = sql.call(db, "SELECT r.id FROM rooms r JOIN memberships m ON m.room_id=r.id WHERE m.user_id=#{Integer(labels.fetch('users.david'))} AND COALESCE(m.involvement,'')<>'invisible' ORDER BY r.id").map { |item| item.fetch("id") }
            raise "#{app} sidebar omits visible rooms" unless sidebar_ids.sort == expected_membership_ids.sort
            expected_sidebar_room_ids ||= sidebar_ids
            raise "#{app} sidebar room order differs: #{sidebar_ids.inspect}" unless sidebar_ids == expected_sidebar_room_ids
          end
          raise "invalid avatar" if name == "avatar" && !(response["content-type"].start_with?("image/") && body.bytesize > 100)
          raise "invalid CSS" if name == "static_css" && !(response["content-type"].start_with?("text/css") && body.include?("{"))
          if name == "static_css" && app == "oxcaml"
            reference_css = File.read(File.join(repo, "once-campfire-oxcaml/reference/app/assets/stylesheets/_reset.css"))
            raise "#{app} static CSS differs from the pinned Rails reset stylesheet" unless body == reference_css
          end
          raise "invalid health" if name == "up" && !body.include?("background-color: green")
          if name == "autocomplete_users"
            raise "#{app} autocomplete HTML missing Lexxy items" unless body.include?("<lexxy-prompt-item") && body.include?("autocompletable__name")
          end
          if %w[room_show messages_page search].include?(name)
            ids = body.scan(/data-message-id="(\d+)"/).flatten.map(&:to_i)
            expected_message_ids[name] ||= ids
            raise "#{app} #{name}: different result window from first implementation: #{ids.inspect} expected #{expected_message_ids[name].inspect}" unless ids == expected_message_ids[name]
          end
          if name == "room_show"
            required_markup = %w[message__day-separator message__avatar message__actions message__timestamp message__room]
            missing_markup = required_markup.reject { |fragment| body.include?(fragment) }
            raise "#{app} room_show: missing rendered message structures #{missing_markup.inspect}" unless missing_markup.empty?
            raise "#{app} room_show: importmap missing" unless body.include?('type="importmap"') && body.include?('rel="modulepreload"')
            if app == "oxcaml"
              oxcaml_markup = %w[id="nav" id="main-content" id="footer" id="sidebar"
                class="skip-navigation btn" data-controller="local-time lightbox"
                data-controller="soft-keyboard" data-messages-target="message"
                data-reply-target="body" data-reply-target="author" data-reply-target="link"
                data-reply-composer-outlet="#composer"
                class="message__heading" class="message__body-content"
                data-local-time-target="date" data-local-time-target="time"
                class="message__actions-menu border shadow" message__edit-btn
                data-copy-to-clipboard-content-value=
                src="/assets/menu-dots-horizontal.svg" src="/assets/boost.svg"
                src="/assets/reply.svg" src="/assets/link.svg" src="/assets/pencil.svg"]
              missing_oxcaml_markup = oxcaml_markup.reject { |fragment| body.include?(fragment) }
              raise "#{app} room_show: missing Rails layout/message structures #{missing_oxcaml_markup.inspect}" unless missing_oxcaml_markup.empty?
              raise "#{app} room_show: missing client-keyed boost frames" unless body.match?(/id="boosting_message_[^" ]+"/)
              %w[Thumbs\ up Clapping Waving\ hand Muscle Red\ heart Face\ with\ tears\ of\ joy Party\ popper Fire].each do |reaction|
                raise "#{app} room_show: reaction menu missing #{reaction}" unless body.include?(reaction)
              end
              message_keys = body.scan(/id="message_([^" ]+)"/).flatten
              raise "#{app} room_show: missing Rails client-key message IDs" if message_keys.empty?
              message_keys.each do |key|
                %W[id="edit_message_#{key}" id="boosting_message_#{key}"
                  data-turbo-frame="boosting_message_#{key}" id="new_boost_message_#{key}"] .each do |fragment|
                  raise "#{app} room_show: message #{key} missing #{fragment}" unless body.include?(fragment)
                end
              end
            end
            asset_paths = body.scan(/(?:href|src)="(\/assets\/[^" ]+)"/).flatten.uniq
            %w[.css .js .svg .png].each do |extension|
              asset_path = asset_paths.find { |candidate| candidate.end_with?(extension) }
              raise "#{app} room_show: no #{extension} asset referenced" unless asset_path
              asset_response = http.get(asset_path, "Cookie" => cookie)
              raise "#{app} asset #{asset_path}: HTTP #{asset_response.code}" unless asset_response.code == "200" && !asset_response.body.empty?
              static_asset_checks[extension] = { status: asset_response.code.to_i,
                content_type: asset_response["content-type"], bytes: asset_response.body.bytesize }
            end
            if app == "oxcaml"
              %w[/assets/menu-dots-horizontal.svg /assets/boost.svg /assets/reply.svg /assets/link.svg /assets/pencil.svg].each do |asset_path|
                asset_response = http.get(asset_path, "Cookie" => cookie)
                unless asset_response.code == "200" && asset_response["content-type"].to_s.start_with?("image/svg+xml")
                  raise "#{app} action icon #{asset_path}: HTTP #{asset_response.code} (#{asset_response["content-type"]})"
                end
              end
            end
            avatar_path = body[/<img aria-hidden="true" src="(\/users\/[^" ]+\/avatar(?:\?v=[^" ]*)?)" width="48"/, 1]
            raise "#{app} room_show: message avatar URL missing" unless avatar_path
            avatar = http.get(avatar_path, "Cookie" => cookie)
            raise "#{app} room_show: signed message avatar HTTP #{avatar.code}" unless avatar.code == "200" && avatar["content-type"].start_with?("image/")
          boost_ids = body.scan(/id="boost_(\d+)"/).flatten.map(&:to_i)
            expected_boost_ids[name] ||= boost_ids
            raise "#{app} room_show: different ordered boost IDs: #{boost_ids.inspect} expected #{expected_boost_ids[name].inspect}" unless boost_ids == expected_boost_ids[name]
            boost_avatars = body.scan(/<img aria-label="[^"]*" src="(\/users\/[^" ]+\/avatar(?:\?v=[^" ]*)?)"/).flatten.uniq
            raise "#{app} room_show: no boost avatar URLs found" if boost_ids.any? && boost_avatars.empty?
            boost_avatars.each do |boost_avatar_path|
              boost_avatar = http.get(boost_avatar_path, "Cookie" => cookie)
              raise "#{app} room_show: signed boost avatar HTTP #{boost_avatar.code}" unless boost_avatar.code == "200" && boost_avatar["content-type"].start_with?("image/")
            end
          end
          preflight[name] = { message_ids: expected_message_ids[name], decoded_bytes: body.bytesize, wire_bytes: response.body.bytesize,
            body_sha256: Digest::SHA256.hexdigest(body), encoding: response["content-encoding"], content_type: response["content-type"] }
          preflight[name][:room_ids] = sidebar_ids if name == "sidebar"
      end
      if app == "oxcaml"
        manifest_response = http.get(routes.fetch("webmanifest"))
        unless manifest_response.code == "200" && manifest_response["content-type"].to_s.start_with?("application/json")
          raise "#{app} webmanifest response mismatch: HTTP #{manifest_response.code}, #{manifest_response["content-type"]}"
        end
        manifest = JSON.parse(manifest_response.body)
        account_name = sql.call(db, "SELECT name FROM accounts ORDER BY id LIMIT 1").first&.fetch("name") || "Campfire"
        unless manifest.fetch("name") == account_name && manifest.fetch("start_url") == "/" &&
            manifest.fetch("display") == "standalone" && manifest.fetch("scope") == "/" &&
            manifest.fetch("icons").any? { |icon| icon.fetch("type") == "image/png" } &&
            manifest.fetch("shortcuts").map { |shortcut| shortcut.fetch("url") }.include?("/rooms/opens/new")
          raise "#{app} webmanifest fields differ from the account install contract"
        end
        worker_response = http.get(routes.fetch("service_worker"))
        unless worker_response.code == "200" && worker_response["content-type"].to_s.start_with?("text/javascript") &&
            %w[push notificationclick showNotification setAppBadge].all? { |fragment| worker_response.body.include?(fragment) }
          raise "#{app} service worker response mismatch: HTTP #{worker_response.code}"
        end
        qr_url = "https://campfire.example.test/join?code=preflight"
        qr_id = Base64.urlsafe_encode64(qr_url, padding: false)
        qr_response = http.get("/qr_code/#{qr_id}")
        unless qr_response.code == "200" && qr_response["content-type"].to_s.start_with?("image/svg+xml") &&
            qr_response["cache-control"].to_s.include?("max-age=31536000") && qr_response.body.include?("<svg")
          raise "#{app} QR code response mismatch: HTTP #{qr_response.code}, #{qr_response["content-type"]}"
        end
        invalid_unfurl = Net::HTTP::Post.new("/unfurl_link")
        invalid_unfurl["Cookie"] = cookie
        invalid_unfurl["Origin"] = base
        invalid_unfurl["Content-Type"] = "application/json"
        invalid_unfurl.body = JSON.generate(url: "http://127.0.0.1/private")
        invalid_unfurl_response = http.request(invalid_unfurl)
        raise "#{app} unfurl accepted invalid CSRF: HTTP #{invalid_unfurl_response.code}" unless invalid_unfurl_response.code == "422"
        private_unfurl = Net::HTTP::Post.new("/unfurl_link")
        private_unfurl["Cookie"] = cookie
        private_unfurl["Origin"] = base
        private_unfurl["Content-Type"] = "application/json"
        private_unfurl["X-CSRF-Token"] = CGI.unescapeHTML(csrf)
        private_unfurl.body = JSON.generate(url: "http://127.0.0.1/private")
        private_unfurl_response = http.request(private_unfurl)
        raise "#{app} unfurl requested a private address: HTTP #{private_unfurl_response.code}" unless private_unfurl_response.code == "204"
        missing_unfurl = Net::HTTP::Post.new("/unfurl_link")
        missing_unfurl["Cookie"] = cookie
        missing_unfurl["Origin"] = base
        missing_unfurl["Content-Type"] = "application/json"
        missing_unfurl["X-CSRF-Token"] = CGI.unescapeHTML(csrf)
        missing_unfurl.body = JSON.generate({})
        missing_unfurl_response = http.request(missing_unfurl)
        raise "#{app} unfurl accepted a missing URL: HTTP #{missing_unfurl_response.code}" unless missing_unfurl_response.code == "400"
        static_asset_checks["webmanifest"] = { status: manifest_response.code.to_i,
          content_type: manifest_response["content-type"], shortcuts: manifest.fetch("shortcuts").length }
        static_asset_checks["service_worker"] = { status: worker_response.code.to_i,
          content_type: worker_response["content-type"], bytes: worker_response.body.bytesize }
        static_asset_checks["qr_code"] = { status: qr_response.code.to_i,
          content_type: qr_response["content-type"], cache_control: qr_response["cache-control"] }
        static_asset_checks["unfurl_link"] = { invalid_csrf_status: invalid_unfurl_response.code.to_i,
          private_address_status: private_unfurl_response.code.to_i,
          missing_url_status: missing_unfurl_response.code.to_i }
      end
      if %w[ruby express mojo oxcaml].include?(app)
        mention_path = routes.fetch("autocomplete_users")
        mention_response = http.get(mention_path, "Cookie" => cookie, "Accept" => "application/json")
        raise "#{app} autocomplete JSON: HTTP #{mention_response.code}" unless mention_response.code == "200" && mention_response["content-type"].start_with?("application/json")
        mentions = JSON.parse(mention_response.body)
        raise "#{app} autocomplete JSON has no users" if mentions.empty?
        unless mentions.all? { |mention| %w[id name label avatar avatar_url sgid value].all? { |key| mention.key?(key) } }
          raise "#{app} autocomplete JSON fields differ"
        end
        mention_ids = mentions.map { |mention| Integer(mention.fetch("id")) }
        expected_mention_ids ||= mention_ids
        raise "#{app} autocomplete result IDs differ: #{mention_ids.inspect}" unless mention_ids == expected_mention_ids
        preflight["autocomplete_json"] = { status: mention_response.code.to_i, user_ids: mention_ids }
      end
      if %w[ruby express mojo oxcaml].include?(app)
        room_form = http.get("/rooms/opens/new", "Cookie" => cookie, "Accept-Encoding" => "identity")
        raise "#{app} open-room form: HTTP #{room_form.code}" unless room_form.code == "200" && room_form.body.include?('name="room[name]"') && room_form.body.include?('name="authenticity_token"')
        created_room_name = "Benchmark room #{Process.pid} #{iteration + 1}"
        invalid_room_create = Net::HTTP::Post.new("/rooms/opens/new")
        invalid_room_create["Cookie"] = cookie
        invalid_room_create.set_form_data("authenticity_token" => "invalid-csrf-token", "room[name]" => created_room_name)
        invalid_room_response = http.request(invalid_room_create)
        raise "#{app} open-room accepted invalid CSRF: HTTP #{invalid_room_response.code}" unless invalid_room_response.code == "422"
        raise "#{app} invalid-CSRF request persisted an open-room" unless sql.call(db, "SELECT COUNT(*) AS n FROM rooms WHERE name='#{created_room_name}' AND type='Rooms::Open'").first.fetch("n").zero?
        room_create = Net::HTTP::Post.new("/rooms/opens/new")
        room_create["Cookie"] = cookie
        room_create["Origin"] = base
        room_create["Sec-Fetch-Site"] = "same-origin"
        room_create["Accept"] = "text/html"
        room_create.set_form_data("authenticity_token" => CGI.unescapeHTML(csrf), "room[name]" => created_room_name)
        room_create_response = http.request(room_create)
        raise "#{app} open-room create failed: HTTP #{room_create_response.code}" unless room_create_response.code == "302"
        created_room = sql.call(db, "SELECT id,creator_id FROM rooms WHERE name='#{created_room_name}' AND type='Rooms::Open'").first
        raise "#{app} open-room was not persisted" unless created_room && created_room.fetch("creator_id").to_i == Integer(labels.fetch("users.david"))
        empty_message_page = http.get("/rooms/#{Integer(created_room.fetch('id'))}/messages", "Cookie" => cookie)
        if app == "oxcaml" && empty_message_page.code != "204"
          raise "#{app} empty message page should return 204, got HTTP #{empty_message_page.code}"
        end
        open_show = http.get("/rooms/#{Integer(created_room.fetch('id'))}", "Cookie" => cookie, "Accept-Encoding" => "identity")
        raise "#{app} created open-room is not accessible: HTTP #{open_show.code}" unless open_show.code == "200"
        active_user_ids = sql.call(db, "SELECT id FROM users WHERE status=0 ORDER BY id").map { |item| item.fetch("id").to_i }
        room_member_ids = sql.call(db, "SELECT user_id FROM memberships WHERE room_id=#{Integer(created_room.fetch('id'))} ORDER BY user_id").map { |item| item.fetch("user_id").to_i }
        raise "#{app} open-room memberships differ: #{room_member_ids.inspect}" unless room_member_ids == active_user_ids
        open_edit_form = http.get("/rooms/opens/#{Integer(created_room.fetch('id'))}/edit", "Cookie" => cookie, "Accept-Encoding" => "identity")
        raise "#{app} open-room edit form failed: HTTP #{open_edit_form.code}" unless open_edit_form.code == "200" && open_edit_form.body.include?(created_room_name)
        edited_open_name = created_room_name + " updated"
        open_edit = Net::HTTP::Post.new("/rooms/opens/#{Integer(created_room.fetch('id'))}")
        open_edit["Cookie"] = cookie
        open_edit["Origin"] = base
        open_edit["Sec-Fetch-Site"] = "same-origin"
        open_edit.set_form_data("authenticity_token" => CGI.unescapeHTML(csrf), "room[name]" => edited_open_name)
        open_edit_response = http.request(open_edit)
        raise "#{app} open-room edit failed: HTTP #{open_edit_response.code}" unless open_edit_response.code == "302"
        edited_open = sql.call(db, "SELECT name FROM rooms WHERE id=#{Integer(created_room.fetch('id'))}").first
        edited_open_members = sql.call(db, "SELECT user_id FROM memberships WHERE room_id=#{Integer(created_room.fetch('id'))} ORDER BY user_id").map { |item| item.fetch("user_id").to_i }
        raise "#{app} open-room edit changed its active-user membership set" unless edited_open.fetch("name") == edited_open_name && edited_open_members == active_user_ids
        edited_open_show = http.get("/rooms/#{Integer(created_room.fetch('id'))}", "Cookie" => cookie, "Accept-Encoding" => "identity")
        raise "#{app} edited open-room is not accessible: HTTP #{edited_open_show.code}" unless edited_open_show.code == "200"
        room_form_checks = { opens: room_form.code.to_i, open_edit_status: open_edit_response.code.to_i }

        selected_user_ids = [Integer(labels.fetch("users.david")), Integer(labels.fetch("users.loner"))].uniq.sort
        closed_form = http.get("/rooms/closeds/new", "Cookie" => cookie, "Accept-Encoding" => "identity")
        direct_form = http.get("/rooms/directs/new", "Cookie" => cookie, "Accept-Encoding" => "identity")
        unless closed_form.code == "200" && closed_form.body.include?('name="room[name]"') &&
            direct_form.code == "200" && direct_form.body.include?('name="user_ids[]"')
          raise "#{app} closed/direct room forms are incomplete"
        end
        closed_name = "Benchmark private room #{Process.pid} #{iteration + 1}"
        closed_create = Net::HTTP::Post.new("/rooms/closeds/new")
        closed_create["Cookie"] = cookie
        closed_create["Origin"] = base
        closed_create["Sec-Fetch-Site"] = "same-origin"
        closed_create.set_form_data("authenticity_token" => CGI.unescapeHTML(csrf),
          "room[name]" => closed_name, "user_ids[]" => selected_user_ids.map(&:to_s))
        closed_response = http.request(closed_create)
        raise "#{app} closed-room create failed: HTTP #{closed_response.code}" unless closed_response.code == "302"
        closed_room = sql.call(db, "SELECT id FROM rooms WHERE name='#{closed_name}' AND type='Rooms::Closed'").first
        raise "#{app} closed-room was not persisted" unless closed_room
        closed_show = http.get("/rooms/#{Integer(closed_room.fetch('id'))}", "Cookie" => cookie, "Accept-Encoding" => "identity")
        raise "#{app} created closed-room is not accessible: HTTP #{closed_show.code}" unless closed_show.code == "200"
        closed_member_ids = sql.call(db, "SELECT user_id FROM memberships WHERE room_id=#{Integer(closed_room.fetch('id'))} ORDER BY user_id").map { |item| item.fetch("user_id").to_i }
        raise "#{app} closed-room members differ: #{closed_member_ids.inspect}" unless closed_member_ids == selected_user_ids
        closed_edit_form = http.get("/rooms/closeds/#{Integer(closed_room.fetch('id'))}/edit", "Cookie" => cookie, "Accept-Encoding" => "identity")
        raise "#{app} closed-room edit form failed: HTTP #{closed_edit_form.code}" unless closed_edit_form.code == "200" && closed_edit_form.body.include?(closed_name)
        edited_closed_name = closed_name + " updated"
        closed_edit = Net::HTTP::Post.new("/rooms/closeds/#{Integer(closed_room.fetch('id'))}")
        closed_edit["Cookie"] = cookie
        closed_edit["Origin"] = base
        closed_edit["Sec-Fetch-Site"] = "same-origin"
        closed_edit.set_form_data("authenticity_token" => CGI.unescapeHTML(csrf),
          "room[name]" => edited_closed_name, "user_ids[]" => labels.fetch("users.david").to_s)
        closed_edit_response = http.request(closed_edit)
        raise "#{app} closed-room edit failed: HTTP #{closed_edit_response.code}" unless closed_edit_response.code == "302"
        edited_room = sql.call(db, "SELECT name FROM rooms WHERE id=#{Integer(closed_room.fetch('id'))}").first
        edited_members = sql.call(db, "SELECT user_id FROM memberships WHERE room_id=#{Integer(closed_room.fetch('id'))} ORDER BY user_id").map { |item| item.fetch("user_id").to_i }
        raise "#{app} closed-room edit did not persist" unless edited_room.fetch("name") == edited_closed_name && edited_members == [Integer(labels.fetch("users.david"))]
        edited_show = http.get("/rooms/#{Integer(closed_room.fetch('id'))}", "Cookie" => cookie, "Accept-Encoding" => "identity")
        raise "#{app} edited closed-room is not accessible: HTTP #{edited_show.code}" unless edited_show.code == "200"
        delete_room_id = Integer(closed_room.fetch("id"))
        delete_message_client_id = "bench-delete-room-#{Process.pid}-#{iteration + 1}"
        delete_message = Net::HTTP::Post.new("/rooms/#{delete_room_id}/messages")
        delete_message["Cookie"] = cookie
        delete_message["Origin"] = base
        delete_message["Sec-Fetch-Site"] = "same-origin"
        delete_message["Accept"] = "text/vnd.turbo-stream.html"
        delete_message.set_form_data("authenticity_token" => CGI.unescapeHTML(csrf),
          "message[body]" => "bench room deletion", "message[client_message_id]" => delete_message_client_id)
        delete_message_response = http.request(delete_message)
        raise "#{app} room-delete message create failed: HTTP #{delete_message_response.code}" unless delete_message_response.code == "200"
        delete_message_row = sql.call(db, "SELECT id FROM messages WHERE client_message_id='#{delete_message_client_id}'").first
        raise "#{app} room-delete message was not persisted" unless delete_message_row
        delete_message_id = Integer(delete_message_row.fetch("id"))
        raise "#{app} room-delete message is missing FTS" unless sql.call(db, "SELECT COUNT(*) AS n FROM message_search_index WHERE rowid=#{delete_message_id}").first.fetch("n").to_i == 1
        delete_room_request = Net::HTTP::Post.new("/rooms/closeds/#{delete_room_id}")
        delete_room_request["Cookie"] = cookie
        delete_room_request["Origin"] = base
        delete_room_request["Sec-Fetch-Site"] = "same-origin"
        delete_room_request.set_form_data("authenticity_token" => CGI.unescapeHTML(csrf), "_method" => "delete")
        delete_room_response = http.request(delete_room_request)
        raise "#{app} room delete failed: HTTP #{delete_room_response.code}" unless delete_room_response.code == "302" && delete_room_response["location"] == "/"
        delete_counts = {
          rooms: sql.call(db, "SELECT COUNT(*) AS n FROM rooms WHERE id=#{delete_room_id}").first.fetch("n").to_i,
          memberships: sql.call(db, "SELECT COUNT(*) AS n FROM memberships WHERE room_id=#{delete_room_id}").first.fetch("n").to_i,
          messages: sql.call(db, "SELECT COUNT(*) AS n FROM messages WHERE id=#{delete_message_id}").first.fetch("n").to_i,
          rich_text: sql.call(db, "SELECT COUNT(*) AS n FROM action_text_rich_texts WHERE record_type='Message' AND record_id=#{delete_message_id}").first.fetch("n").to_i,
          attachments: sql.call(db, "SELECT COUNT(*) AS n FROM active_storage_attachments WHERE (record_type='Message' AND record_id=#{delete_message_id}) OR (record_type='ActionText::RichText' AND record_id IN (SELECT id FROM action_text_rich_texts WHERE record_type='Message' AND record_id=#{delete_message_id}))").first.fetch("n").to_i,
          fts: sql.call(db, "SELECT COUNT(*) AS n FROM message_search_index WHERE rowid=#{delete_message_id}").first.fetch("n").to_i
        }
        raise "#{app} room delete left persisted rows: #{delete_counts.inspect}" unless delete_counts.values.all?(&:zero?)
        room_form_checks[:closeds] = { status: closed_response.code.to_i, edit_status: closed_edit_response.code.to_i,
          members: closed_member_ids, edited_members: edited_members,
          delete_status: delete_room_response.code.to_i, delete_counts: delete_counts }

        direct_count_before = sql.call(db, "SELECT COUNT(*) AS n FROM rooms WHERE type='Rooms::Direct'").first.fetch("n").to_i
        direct_create = Net::HTTP::Post.new("/rooms/directs/new")
        direct_create["Cookie"] = cookie
        direct_create["Origin"] = base
        direct_create["Sec-Fetch-Site"] = "same-origin"
        direct_create.set_form_data("authenticity_token" => CGI.unescapeHTML(csrf),
          "user_ids[]" => selected_user_ids.map(&:to_s))
        direct_response = http.request(direct_create)
        raise "#{app} direct-room create failed: HTTP #{direct_response.code}" unless direct_response.code == "302"
        direct_room_id = direct_response["location"]&.match(%r{\A/rooms/(\d+)\z})&.captures&.first&.to_i
        raise "#{app} direct-room redirect is invalid" unless direct_room_id
        direct_show = http.get("/rooms/#{direct_room_id}", "Cookie" => cookie, "Accept-Encoding" => "identity")
        raise "#{app} created direct-room is not accessible: HTTP #{direct_show.code}" unless direct_show.code == "200"
        direct_members = sql.call(db, "SELECT user_id,involvement FROM memberships WHERE room_id=#{direct_room_id} ORDER BY user_id")
        raise "#{app} direct-room members differ" unless direct_members.map { |item| item.fetch("user_id").to_i } == selected_user_ids && direct_members.all? { |item| item.fetch("involvement") == "everything" }
        duplicate_response = http.request(direct_create)
        raise "#{app} duplicate direct-room create failed: HTTP #{duplicate_response.code}" unless duplicate_response.code == "302" && duplicate_response["location"] == "/rooms/#{direct_room_id}"
        direct_count_after = sql.call(db, "SELECT COUNT(*) AS n FROM rooms WHERE type='Rooms::Direct'").first.fetch("n").to_i
        raise "#{app} duplicate direct-room request created another room" unless direct_count_after <= direct_count_before + 1
        room_form_checks[:directs] = { status: direct_response.code.to_i, duplicate_status: duplicate_response.code.to_i,
          room_id: direct_room_id, members: selected_user_ids }
        preflight["room_creation"] = { form_status: room_form.code.to_i, create_status: room_create_response.code.to_i,
          invalid_csrf_status: invalid_room_response.code.to_i, room_id: created_room.fetch("id").to_i,
          memberships: room_member_ids.length, created_room_statuses: [open_show.code.to_i, edited_open_show.code.to_i, closed_show.code.to_i, direct_show.code.to_i],
          room_forms: room_form_checks }
      end
      if %w[ruby express mojo oxcaml].include?(app)
        profile_response = http.get("/users/me/profile", "Cookie" => cookie, "Accept-Encoding" => "identity")
        raise "#{app} profile: HTTP #{profile_response.code}" unless profile_response.code == "200"
        profile_before = sql.call(db, "SELECT name,bio,email_address,password_digest FROM users WHERE id=#{Integer(labels.fetch('users.david'))}").first
        raise "#{app} profile user missing" unless profile_before
        invalid_profile = Net::HTTP::Post.new("/users/me/profile")
        invalid_profile["Cookie"] = cookie
        invalid_profile.set_form_data("_method" => "patch", "authenticity_token" => "invalid-csrf-token",
          "user[name]" => profile_before.fetch("name"), "user[email_address]" => profile_before.fetch("email_address"),
          "user[bio]" => "invalid csrf must not persist", "user[password]" => "")
        invalid_profile_response = http.request(invalid_profile)
        raise "#{app} profile accepted invalid CSRF: HTTP #{invalid_profile_response.code}" unless invalid_profile_response.code == "422"
        profile_after_invalid = sql.call(db, "SELECT bio FROM users WHERE id=#{Integer(labels.fetch('users.david'))}").first
        raise "#{app} invalid-CSRF profile update persisted" unless profile_after_invalid.fetch("bio") == profile_before.fetch("bio")
        profile_bio = "Benchmark profile preflight #{Process.pid} #{iteration + 1}"
        profile_update = Net::HTTP::Post.new("/users/me/profile")
        profile_update["Cookie"] = cookie
        profile_update["Origin"] = base
        profile_update["Sec-Fetch-Site"] = "same-origin"
        profile_update.set_form_data("_method" => "patch", "authenticity_token" => CGI.unescapeHTML(csrf),
          "user[name]" => profile_before.fetch("name"), "user[email_address]" => profile_before.fetch("email_address"),
          "user[bio]" => profile_bio, "user[password]" => "")
        profile_update_response = http.request(profile_update)
        raise "#{app} profile update failed: HTTP #{profile_update_response.code}" unless profile_update_response.code == "302"
        profile_after = sql.call(db, "SELECT name,bio,email_address,password_digest FROM users WHERE id=#{Integer(labels.fetch('users.david'))}").first
        raise "#{app} profile fields did not persist" unless profile_after.fetch("name") == profile_before.fetch("name") &&
          profile_after.fetch("email_address") == profile_before.fetch("email_address") && profile_after.fetch("bio") == profile_bio
        raise "#{app} empty profile password changed digest" unless profile_after.fetch("password_digest") == profile_before.fetch("password_digest")
        preflight["profile_update"] = { form_status: profile_response.code.to_i, invalid_csrf_status: invalid_profile_response.code.to_i,
          update_status: profile_update_response.code.to_i, password_digest_unchanged: true }
      end
      if app == "oxcaml"
        transfer_url = profile_response.body[%r{value="(https?://[^"]+/session/transfers/[^"]+)"}, 1]
        raise "oxcaml profile has no absolute signed session-transfer link" unless transfer_url&.start_with?("#{base}/session/transfers/")
        transfer_path = URI.parse(transfer_url).request_uri
        expected_transfer_qr = "/qr_code/#{Base64.urlsafe_encode64(transfer_url, padding: false)}"
        raise "oxcaml profile transfer QR link did not encode the absolute transfer URL" unless profile_response.body.include?("href=\"#{expected_transfer_qr}\"")
        routes["session_transfer"] = transfer_path
        transfer_page = http.get(transfer_path, "Cookie" => cookie)
        raise "oxcaml session-transfer page: HTTP #{transfer_page.code}" unless transfer_page.code == "200"
        transfer_csrf = transfer_page.body[/<meta name="csrf-token" content="([^"]+)"/, 1]
        raise "oxcaml transfer page omitted CSRF token" unless transfer_csrf
        transfer_user_id = Integer(labels.fetch("users.david"))
        sessions_before = sql.call(db, "SELECT COUNT(*) AS n FROM sessions WHERE user_id=#{transfer_user_id}").first.fetch("n").to_i
        invalid_transfer = Net::HTTP::Put.new(transfer_path)
        invalid_transfer["Cookie"] = cookie
        invalid_transfer.set_form_data("authenticity_token" => "invalid-csrf-token")
        invalid_transfer_response = http.request(invalid_transfer)
        raise "oxcaml session transfer accepted invalid CSRF: HTTP #{invalid_transfer_response.code}" unless invalid_transfer_response.code == "422"
        sessions_after_invalid_transfer = sql.call(db, "SELECT COUNT(*) AS n FROM sessions WHERE user_id=#{transfer_user_id}").first.fetch("n").to_i
        raise "oxcaml invalid-CSRF transfer created a session" unless sessions_after_invalid_transfer == sessions_before
        transfer_request = Net::HTTP::Put.new(transfer_path)
        transfer_request["Cookie"] = cookie
        transfer_request["Origin"] = base
        transfer_request["Sec-Fetch-Site"] = "same-origin"
        transfer_request.set_form_data("authenticity_token" => CGI.unescapeHTML(transfer_csrf))
        transfer_response = http.request(transfer_request)
        raise "oxcaml session transfer failed: HTTP #{transfer_response.code}" unless transfer_response.code == "302" && transfer_response["location"] == "/"
        transfer_cookie_header = transfer_response.get_fields("set-cookie") || []
        transfer_session_cookie = transfer_cookie_header.find { |value| value.start_with?("session_token=") }&.split(";")&.first
        raise "oxcaml transfer did not issue an authenticated session cookie" unless transfer_session_cookie
        sessions_after = sql.call(db, "SELECT COUNT(*) AS n FROM sessions WHERE user_id=#{transfer_user_id}").first.fetch("n").to_i
        raise "oxcaml transfer did not persist a Rails session" unless sessions_after == sessions_before + 1
        transferred_cookie = cookie.sub(/session_token=[^;]+/, transfer_session_cookie)
        transferred_account = http.get("/account/edit", "Cookie" => transferred_cookie)
        raise "oxcaml transferred cookie is not authenticated: HTTP #{transferred_account.code}" unless transferred_account.code == "200"

        expired_path = "/session/transfers/#{labels.fetch('transfers.david_expired')}"
        expired_page = http.get(expired_path, "Cookie" => cookie)
        expired_csrf = expired_page.body[/<meta name="csrf-token" content="([^"]+)"/, 1]
        raise "oxcaml expired-transfer form unavailable: HTTP #{expired_page.code}" unless expired_page.code == "200" && expired_csrf
        expired_request = Net::HTTP::Put.new(expired_path)
        expired_request["Cookie"] = cookie
        expired_request.set_form_data("authenticity_token" => CGI.unescapeHTML(expired_csrf))
        expired_response = http.request(expired_request)
        raise "oxcaml accepted expired session-transfer token: HTTP #{expired_response.code}" unless expired_response.code == "400"
        preflight["session_transfer"] = { show_status: transfer_page.code.to_i,
          invalid_csrf_status: invalid_transfer_response.code.to_i,
          update_status: transfer_response.code.to_i, persisted_session: true,
          transferred_cookie_authenticated: true, expired_status: expired_response.code.to_i }
      end
      if %w[ruby express mojo oxcaml].include?(app)
        account_page = http.get("/account/edit", "Cookie" => cookie)
        unless account_page.code == "200" && account_page.body.include?("Account settings") &&
            account_page.body.include?('name="account[name]"')
          raise "#{app} account settings page mismatch: HTTP #{account_page.code}"
        end
        account_before = sql.call(db, "SELECT id,name,join_code,COALESCE(json_extract(settings,'$.restrict_room_creation_to_administrators'),0) AS restricted,settings,COALESCE(custom_styles,'') AS custom_styles FROM accounts ORDER BY id LIMIT 1").first
        raise "#{app} account settings record missing" unless account_before
        if app == "oxcaml"
          invite_url = "#{base}/join/#{account_before.fetch('join_code')}"
          invite_qr = "/qr_code/#{Base64.urlsafe_encode64(invite_url, padding: false)}"
          unless account_page.body.include?("value=\"#{invite_url}\"") && account_page.body.include?("href=\"#{invite_qr}\"")
            raise "oxcaml account invite URL or QR link mismatch"
          end
        end
        account_restricted = account_before.fetch("restricted").to_i != 0
        original_settings = begin
          JSON.parse(account_before.fetch("settings") || "{}")
        rescue JSON::ParserError
          {}
        end
        account_update_path = app == "oxcaml" ? "/account" : "/account/edit"
        invalid_account = Net::HTTP::Post.new(account_update_path)
        invalid_account["Cookie"] = cookie
        invalid_account.set_form_data("_method" => "patch", "authenticity_token" => "invalid-csrf-token",
          "account[name]" => "invalid csrf must not persist")
        invalid_account_response = http.request(invalid_account)
        raise "#{app} account settings accepted invalid CSRF: HTTP #{invalid_account_response.code}" unless invalid_account_response.code == "422"
        unchanged_account = sql.call(db, "SELECT name FROM accounts WHERE id=#{Integer(account_before.fetch('id'))}").first
        raise "#{app} invalid-CSRF account update persisted" unless unchanged_account.fetch("name") == account_before.fetch("name")
        temporary_account_name = "Benchmark account #{Process.pid} #{iteration + 1}"
        account_update = Net::HTTP::Post.new(account_update_path)
        account_update["Cookie"] = cookie
        account_update["Origin"] = base
        account_update["Sec-Fetch-Site"] = "same-origin"
        account_fields = { "_method" => "patch", "authenticity_token" => CGI.unescapeHTML(csrf),
          "account[name]" => temporary_account_name }
        account_restricted_after = !account_restricted
        account_fields["account[settings][restrict_room_creation_to_administrators]"] = account_restricted_after ? "1" : "0"
        account_update.set_form_data(account_fields)
        account_update_response = http.request(account_update)
        raise "#{app} account settings update failed: HTTP #{account_update_response.code}" unless account_update_response.code == "302"
        updated_account = sql.call(db, "SELECT name,COALESCE(json_extract(settings,'$.restrict_room_creation_to_administrators'),0) AS restricted,settings FROM accounts WHERE id=#{Integer(account_before.fetch('id'))}").first
        restricted_after = updated_account.fetch("restricted").to_i != 0
        raise "#{app} account settings did not persist" unless updated_account.fetch("name") == temporary_account_name && restricted_after == account_restricted_after
        updated_settings = JSON.parse(updated_account.fetch("settings") || "{}")
        original_settings.each do |key, value|
          next if key == "restrict_room_creation_to_administrators"
          raise "#{app} account settings update dropped #{key}" unless updated_settings[key] == value
        end
        restore_account = Net::HTTP::Post.new(account_update_path)
        restore_account["Cookie"] = cookie
        restore_account["Origin"] = base
        restore_account["Sec-Fetch-Site"] = "same-origin"
        restore_fields = { "_method" => "patch", "authenticity_token" => CGI.unescapeHTML(csrf),
          "account[name]" => account_before.fetch("name") }
        restore_fields["account[settings][restrict_room_creation_to_administrators]"] = account_restricted ? "1" : "0"
        restore_account.set_form_data(restore_fields)
        restore_response = http.request(restore_account)
        raise "#{app} account settings restore failed: HTTP #{restore_response.code}" unless restore_response.code == "302"
        restored_account = sql.call(db, "SELECT name,COALESCE(json_extract(settings,'$.restrict_room_creation_to_administrators'),0) AS restricted FROM accounts WHERE id=#{Integer(account_before.fetch('id'))}").first
        restricted_restored = restored_account.fetch("restricted").to_i != 0
        raise "#{app} account settings did not restore" unless restored_account.fetch("name") == account_before.fetch("name") && restricted_restored == account_restricted
        preflight["account_settings"] = { invalid_csrf_status: invalid_account_response.code.to_i,
          update_status: account_update_response.code.to_i, settings_preserved: true, restored: true }

        if app == "oxcaml"
          custom_styles_path = "/account/custom_styles/edit"
          styles_page = http.get(custom_styles_path, "Cookie" => cookie)
          raise "oxcaml custom-styles page failed: HTTP #{styles_page.code}" unless styles_page.code == "200"
          styles_csrf = styles_page.body[/<meta name="csrf-token" content="([^"]+)"/, 1]
          raise "oxcaml custom-styles page omitted CSRF token" unless styles_csrf
          styles_update_path = "/account/custom_styles"
          styles_invalid = Net::HTTP::Post.new(styles_update_path)
          styles_invalid["Cookie"] = cookie
          styles_invalid["Origin"] = base
          styles_invalid.set_form_data("_method" => "patch", "authenticity_token" => "invalid-csrf-token",
            "account[custom_styles]" => "body { color: red; }")
          styles_invalid_response = http.request(styles_invalid)
          raise "oxcaml custom styles accepted invalid CSRF: HTTP #{styles_invalid_response.code}" unless styles_invalid_response.code == "422"
          original_custom_styles = account_before.fetch("custom_styles").to_s
          invalid_styles = sql.call(db, "SELECT COALESCE(custom_styles,'') AS styles FROM accounts WHERE id=#{Integer(account_before.fetch('id'))}").first.fetch("styles")
          raise "oxcaml invalid-CSRF custom styles persisted" unless invalid_styles == original_custom_styles
          custom_styles = ".benchmark-style-preflight { color: rgb(1, 2, 3); }"
          styles_update = Net::HTTP::Post.new(styles_update_path)
          styles_update["Cookie"] = cookie
          styles_update["Origin"] = base
          styles_update.set_form_data("_method" => "patch", "authenticity_token" => CGI.unescapeHTML(styles_csrf),
            "account[custom_styles]" => custom_styles)
          styles_update_response = http.request(styles_update)
          raise "oxcaml custom styles update failed: HTTP #{styles_update_response.code}" unless styles_update_response.code == "302"
          saved_styles = sql.call(db, "SELECT custom_styles FROM accounts WHERE id=#{Integer(account_before.fetch('id'))}").first.fetch("custom_styles")
          raise "oxcaml custom styles did not persist" unless saved_styles == custom_styles
          styled_account_page = http.get("/account/edit", "Cookie" => cookie)
          expected_style_tag = "<style data-turbo-track=\"reload\">#{custom_styles}</style>"
          raise "oxcaml custom styles were not injected into HTML head" unless styled_account_page.code == "200" && styled_account_page.body.include?(expected_style_tag)
          styles_restore = Net::HTTP::Post.new(styles_update_path)
          styles_restore["Cookie"] = cookie
          styles_restore["Origin"] = base
          styles_restore.set_form_data("_method" => "patch", "authenticity_token" => CGI.unescapeHTML(styles_csrf),
            "account[custom_styles]" => original_custom_styles)
          styles_restore_response = http.request(styles_restore)
          raise "oxcaml custom styles restore failed: HTTP #{styles_restore_response.code}" unless styles_restore_response.code == "302"
          restored_styles = sql.call(db, "SELECT COALESCE(custom_styles,'') AS styles FROM accounts WHERE id=#{Integer(account_before.fetch('id'))}").first.fetch("styles")
          raise "oxcaml custom styles did not restore" unless restored_styles == original_custom_styles
          preflight["custom_styles"] = { page_status: styles_page.code.to_i,
            invalid_csrf_status: styles_invalid_response.code.to_i,
            update_status: styles_update_response.code.to_i,
            restore_status: styles_restore_response.code.to_i, injected_into_html: true, restored: true }

          existing_account_logo = sql.call(db, "SELECT b.id FROM active_storage_attachments a JOIN active_storage_blobs b ON b.id=a.blob_id WHERE a.record_type='Account' AND a.record_id=#{Integer(account_before.fetch('id'))} AND a.name='logo' LIMIT 1").first
          if existing_account_logo.nil?
          logo_bytes = File.binread(File.join(repo, "once-campfire-oxcaml", "assets", "account-logo-512.png"))
          logo_boundary = "----CampfireLogo#{SecureRandom.hex(8)}"
          logo_form = [
            ["_method", "patch"], ["authenticity_token", CGI.unescapeHTML(styles_csrf)],
            ["account[name]", account_before.fetch("name")]
          ].map do |key, value|
            "--#{logo_boundary}\r\nContent-Disposition: form-data; name=\"#{key}\"\r\n\r\n#{value}\r\n"
          end.join
          logo_form << "--#{logo_boundary}\r\nContent-Disposition: form-data; name=\"account[logo]\"; filename=\"bench-logo.png\"\r\nContent-Type: image/png\r\n\r\n#{logo_bytes}\r\n--#{logo_boundary}--\r\n"
          logo_upload = Net::HTTP::Post.new("/account")
          logo_upload["Cookie"] = cookie
          logo_upload["Origin"] = base
          logo_upload["Content-Type"] = "multipart/form-data; boundary=#{logo_boundary}"
          logo_upload.body = logo_form
          invalid_logo_upload = Net::HTTP::Post.new("/account")
          invalid_logo_upload["Cookie"] = cookie
          invalid_logo_upload["Origin"] = base
          invalid_logo_upload["Content-Type"] = "multipart/form-data; boundary=#{logo_boundary}"
          invalid_logo_upload.body = logo_form.sub(CGI.unescapeHTML(styles_csrf), "invalid-csrf-token")
          invalid_logo_response = http.request(invalid_logo_upload)
          raise "oxcaml account logo upload accepted invalid CSRF: HTTP #{invalid_logo_response.code}" unless invalid_logo_response.code == "422"
          raise "oxcaml invalid-CSRF account logo upload persisted a blob" unless sql.call(db, "SELECT COUNT(*) AS n FROM active_storage_attachments WHERE record_type='Account' AND name='logo'").first.fetch("n").zero?
          logo_upload_response = http.request(logo_upload)
          raise "oxcaml account logo upload failed: HTTP #{logo_upload_response.code}" unless logo_upload_response.code == "302"
          uploaded_logo = sql.call(db, "SELECT b.id,b.key,b.content_type,a.record_type,a.record_id,a.name FROM active_storage_attachments a JOIN active_storage_blobs b ON b.id=a.blob_id WHERE a.record_type='Account' AND a.name='logo' ORDER BY a.id DESC LIMIT 1").first
          raise "oxcaml account logo did not use the Rails Account/logo association" unless uploaded_logo && uploaded_logo.fetch("record_id").to_i == Integer(account_before.fetch("id")) && uploaded_logo.fetch("content_type") == "image/png"
          logo_small = http.get("/account/logo?size=small")
          logo_large = http.get("/account/logo")
          unless logo_small.code == "200" && logo_large.code == "200" &&
              logo_small["content-type"].start_with?("image/png") && logo_large["content-type"].start_with?("image/png") &&
              logo_small.body.start_with?("\x89PNG\r\n\x1a\n".b) && logo_large.body.start_with?("\x89PNG\r\n\x1a\n".b)
            raise "oxcaml account logo variants were not served as PNG"
          end
          logo_small_dimensions = logo_small.body.byteslice(16, 8).unpack("NN")
          logo_large_dimensions = logo_large.body.byteslice(16, 8).unpack("NN")
          raise "oxcaml account logo variant dimensions mismatch" unless logo_small_dimensions == [192, 192] && logo_large_dimensions == [512, 512]
          logo_delete = Net::HTTP::Post.new("/account/logo")
          logo_delete["Cookie"] = cookie
          logo_delete["Origin"] = base
          logo_delete.set_form_data("_method" => "delete", "authenticity_token" => CGI.unescapeHTML(styles_csrf))
          logo_delete_response = http.request(logo_delete)
          raise "oxcaml account logo deletion failed: HTTP #{logo_delete_response.code}" unless logo_delete_response.code == "302"
          remaining_logo = sql.call(db, "SELECT COUNT(*) AS n FROM active_storage_attachments WHERE record_type='Account' AND record_id=#{Integer(account_before.fetch('id'))} AND name='logo' AND blob_id=#{Integer(uploaded_logo.fetch('id'))}").first.fetch("n").to_i
          raise "oxcaml account logo deletion left its attachment" unless remaining_logo.zero?
          remaining_logo_blob = sql.call(db, "SELECT COUNT(*) AS n FROM active_storage_blobs WHERE id=#{Integer(uploaded_logo.fetch('id'))}").first.fetch("n").to_i
          raise "oxcaml account logo deletion left an orphan blob" unless remaining_logo_blob.zero?
          logo_fallback = http.get("/account/logo")
          raise "oxcaml account logo did not fall back to its stock icon" unless logo_fallback.code == "200" && logo_fallback.body.start_with?("\x89PNG\r\n\x1a\n".b)
          raise "oxcaml stock account icon dimensions mismatch" unless logo_fallback.body.byteslice(16, 8).unpack("NN") == [512, 512]
          preflight["account_logo"] = { invalid_csrf_status: invalid_logo_response.code.to_i,
            upload_status: logo_upload_response.code.to_i,
            small_status: logo_small.code.to_i, large_status: logo_large.code.to_i,
            delete_status: logo_delete_response.code.to_i, fallback_status: logo_fallback.code.to_i,
            restored: true }
          else
            preflight["account_logo"] = { skipped_existing_logo: true }
          end
        end

        session_check = http.get("/account/edit", "Cookie" => cookie)
        raise "#{app} account session was lost before join-code check: HTTP #{session_check.code} #{session_check['location']}" unless session_check.code == "200"
        invalid_join_code = Net::HTTP::Post.new("/account/join_code")
        invalid_join_code["Cookie"] = cookie
        invalid_join_code["Origin"] = base
        invalid_join_code["Sec-Fetch-Site"] = "same-origin"
        invalid_join_code.set_form_data("authenticity_token" => "invalid-csrf-token")
        invalid_join_response = http.request(invalid_join_code)
        raise "#{app} join-code regeneration accepted invalid CSRF: HTTP #{invalid_join_response.code} #{invalid_join_response['location']}" unless invalid_join_response.code == "422"
        unchanged_join_code = sql.call(db, "SELECT join_code FROM accounts WHERE id=#{Integer(account_before.fetch('id'))}").first.fetch("join_code")
        raise "#{app} invalid-CSRF join-code change persisted" unless unchanged_join_code == account_before.fetch("join_code")
        regenerate_join_code = Net::HTTP::Post.new("/account/join_code")
        regenerate_join_code["Cookie"] = cookie
        regenerate_join_code["Origin"] = base
        regenerate_join_code["Sec-Fetch-Site"] = "same-origin"
        regenerate_join_code.set_form_data("authenticity_token" => CGI.unescapeHTML(csrf))
        regenerate_join_response = http.request(regenerate_join_code)
        raise "#{app} join-code regeneration failed: HTTP #{regenerate_join_response.code}" unless regenerate_join_response.code == "302"
        regenerated_join_code = sql.call(db, "SELECT join_code FROM accounts WHERE id=#{Integer(account_before.fetch('id'))}").first.fetch("join_code")
        raise "#{app} join code did not regenerate" if regenerated_join_code == account_before.fetch("join_code")
        preflight["account_join_code"] = { invalid_csrf_status: invalid_join_response.code.to_i,
          regenerate_status: regenerate_join_response.code.to_i, rotated: true }

        member_id = Integer(labels.fetch("users.loner"))
        member_before = sql.call(db, "SELECT role FROM users WHERE id=#{member_id} AND status=0 AND role<>2").first
        raise "#{app} account member fixture missing" unless member_before
        member_role_before = member_before.fetch("role").to_i
        member_role_after = member_role_before == 1 ? "member" : "administrator"
        invalid_role = Net::HTTP::Post.new("/account/users/#{member_id}")
        invalid_role["Cookie"] = cookie
        invalid_role.set_form_data("_method" => "patch", "authenticity_token" => "invalid-csrf-token",
          "user[role]" => member_role_after)
        invalid_role_response = http.request(invalid_role)
        raise "#{app} account member role accepted invalid CSRF: HTTP #{invalid_role_response.code}" unless invalid_role_response.code == "422"
        unchanged_role = sql.call(db, "SELECT role FROM users WHERE id=#{member_id}").first
        raise "#{app} invalid-CSRF role update persisted" unless unchanged_role.fetch("role").to_i == member_role_before
        change_role = Net::HTTP::Post.new("/account/users/#{member_id}")
        change_role["Cookie"] = cookie
        change_role.set_form_data("_method" => "patch", "authenticity_token" => CGI.unescapeHTML(csrf),
          "user[role]" => member_role_after)
        change_role_response = http.request(change_role)
        raise "#{app} account member role update failed: HTTP #{change_role_response.code}" unless change_role_response.code == "302"
        changed_role = sql.call(db, "SELECT role FROM users WHERE id=#{member_id}").first
        expected_role = member_role_after == "administrator" ? 1 : 0
        raise "#{app} account member role did not persist" unless changed_role.fetch("role").to_i == expected_role
        restore_role = Net::HTTP::Post.new("/account/users/#{member_id}")
        restore_role["Cookie"] = cookie
        restore_role.set_form_data("_method" => "patch", "authenticity_token" => CGI.unescapeHTML(csrf),
          "user[role]" => (member_role_before == 1 ? "administrator" : "member"))
        restore_role_response = http.request(restore_role)
        raise "#{app} account member role restore failed: HTTP #{restore_role_response.code}" unless restore_role_response.code == "302"
        preflight["account_member_role"] = { invalid_csrf_status: invalid_role_response.code.to_i,
          update_status: change_role_response.code.to_i, restored: true }
      end
      attachment_checks = {}
      outsider_cookie = begin
        lg.call("login", "--base", base, "--email", labels.fetch("emails.loner"),
          "--password", labels.fetch("passwords.all")).fetch("cookie")
      rescue => error
        raise "#{app} outsider login failed: #{error.message}"
      end
      outsider_auth_response = http.get("/users/me/sidebar", "Cookie" => outsider_cookie)
      raise "#{app} outsider login was not authenticated: HTTP #{outsider_auth_response.code}" unless outsider_auth_response.code == "200"
        { image: "messages.image", video: "messages.video", file: "messages.file" }.each do |kind, label|
          target_id = Integer(labels.fetch(label))
          target = sql.call(db, "SELECT m.id,m.room_id,m.client_message_id,m.created_at,b.id AS blob_id,b.filename,b.content_type,b.byte_size FROM messages m JOIN active_storage_attachments a ON a.record_type='Message' AND a.record_id=m.id AND a.name='attachment' JOIN active_storage_blobs b ON b.id=a.blob_id WHERE m.id=#{target_id}").first
          raise "canonical #{kind} attachment message missing" unless target
          cursor = sql.call(db, "SELECT id FROM messages WHERE room_id=#{target.fetch('room_id')} AND created_at>(SELECT created_at FROM messages WHERE id=#{target_id}) ORDER BY created_at,id LIMIT 1").first
          attachment_path = cursor ? "/rooms/#{target.fetch('room_id')}/messages?before=#{cursor.fetch('id')}" : "/rooms/#{target.fetch('room_id')}"
          response = http.get(attachment_path, "Cookie" => cookie, "Accept-Encoding" => "identity")
          raise "#{app} #{kind} attachment page: HTTP #{response.code}" unless response.code == "200"
          body = response.body
          message_html = body.split('<div id="message_').find do |part|
            part.include?("data-message-id=\"#{target_id}\"")
          end
          raise "#{app} #{kind} attachment message not rendered" unless message_html && message_html.include?(target.fetch("filename"))
          blob_url = message_html[/((?:src|href)="(\/rails\/active_storage\/blobs\/redirect\/[^" ]+)")/, 2]
          raise "#{app} #{kind} attachment URL missing" unless blob_url
          expected_attachment_blob_urls[kind] ||= blob_url
          unless blob_url == expected_attachment_blob_urls[kind]
            split_url = ->(url) do
              token, suffix = url.split("/blobs/redirect/", 2).last.split("/", 2)
              payload, mac = token.split("--", 2)
              [payload, mac, suffix]
            end
            expected_parts = split_url.call(expected_attachment_blob_urls[kind])
            actual_parts = split_url.call(blob_url)
            same_signed_id = actual_parts[0] == expected_parts[0] && actual_parts[1] == expected_parts[1]
            actual_filename = actual_parts[2].split("?", 2).first
            expected_filename = expected_parts[2].split("?", 2).first
            same_filename = URI::DEFAULT_PARSER.unescape(actual_filename) == URI::DEFAULT_PARSER.unescape(expected_filename)
            raise "#{app} #{kind} Active Storage URL differs" unless same_signed_id && same_filename
          end
          anonymous_blob_response = http.get(blob_url, "Accept-Encoding" => "identity")
          raise "#{app} #{kind} blob accepted an anonymous request: HTTP #{anonymous_blob_response.code}" unless anonymous_blob_response.code == "401"
          outsider_membership = sql.call(db, "SELECT COUNT(*) AS n FROM memberships WHERE user_id=#{Integer(labels.fetch('users.loner'))} AND room_id=#{Integer(target.fetch('room_id'))}").first.fetch("n")
          outsider_blob_response = nil
          if outsider_membership.zero?
            outsider_auth_response = http.get("/users/me/sidebar", "Cookie" => outsider_cookie)
            raise "#{app} outsider session expired before #{kind} blob check: HTTP #{outsider_auth_response.code} #{outsider_auth_response['location']}" unless outsider_auth_response.code == "200"
            outsider_blob_response = http.get(blob_url, "Cookie" => outsider_cookie, "Accept-Encoding" => "identity")
            raise "#{app} #{kind} blob escaped room membership: HTTP #{outsider_blob_response.code}" unless outsider_blob_response.code == "403"
          end
          blob_response = http.get(blob_url, "Cookie" => cookie, "Accept-Encoding" => "identity")
          unless blob_response.code == "200" && blob_response["content-type"].start_with?(target.fetch("content_type")) &&
              blob_response.body.bytesize == target.fetch("byte_size")
            raise "#{app} #{kind} blob response mismatch: HTTP #{blob_response.code}, #{blob_response["content-type"]}, #{blob_response.body.bytesize} bytes"
          end
          disposition = blob_response["content-disposition"]&.split(";", 2)&.first
          expected_attachment_dispositions[kind] ||= disposition
          raise "#{app} #{kind} content disposition differs: #{disposition.inspect}, expected #{expected_attachment_dispositions[kind].inspect}" unless disposition == expected_attachment_dispositions[kind]
          if kind == :file
            raise "#{app} file disposition missing" unless disposition == "attachment"
          end
          attachment_size = target.fetch("byte_size")
          last_start = attachment_size - 16
          range_cases = {
            prefix: ["bytes=0-15", 0, 15],
            open_ended: ["bytes=#{last_start}-", last_start, attachment_size - 1],
            suffix: ["bytes=-16", last_start, attachment_size - 1]
          }
          range_checks = {}
          range_cases.each do |range_name, (header, first_byte, last_byte)|
            range_response = http.get(blob_url, "Cookie" => cookie, "Accept-Encoding" => "identity", "Range" => header)
            expected_content_range = "bytes #{first_byte}-#{last_byte}/#{attachment_size}"
            expected_bytes = blob_response.body.byteslice(first_byte, last_byte - first_byte + 1)
            unless range_response.code == "206" && range_response["content-range"] == expected_content_range && range_response.body == expected_bytes
              raise "#{app} #{kind} #{range_name} range mismatch: HTTP #{range_response.code}, #{range_response['content-range']}, #{range_response.body.bytesize} bytes"
            end
            comparison_key = "#{kind}_#{range_name}"
            expected_attachment_range_prefixes[comparison_key] ||= range_response.body
            raise "#{app} #{kind} #{range_name} range bytes differ" unless range_response.body == expected_attachment_range_prefixes[comparison_key]
            range_checks[range_name] = { status: range_response.code.to_i, range: range_response["content-range"], bytes: range_response.body.bytesize }
          end
          attachment_checks[kind] = { status: blob_response.code.to_i, content_type: blob_response["content-type"],
            bytes: blob_response.body.bytesize, disposition: blob_response["content-disposition"],
            anonymous_status: anonymous_blob_response.code.to_i,
            outsider_status: outsider_blob_response&.code&.to_i, ranges: range_checks }
          if kind == :image || kind == :video
            if kind == :video && !message_html.include?('preload="none"')
              raise "#{app} video attachment does not disable preload"
            end
            representation_url =
              if kind == :image
                message_html[%r{src="(/rails/active_storage/representations/redirect/[^" ]+)"}, 1]
              else
                message_html[%r{poster="(/rails/active_storage/representations/redirect/[^" ]+)"}, 1]
              end
            raise "#{app} #{kind} representation URL missing" unless representation_url
            anonymous_representation = http.get(representation_url, "Accept-Encoding" => "identity")
            unless anonymous_representation.code == "401"
              raise "#{app} #{kind} representation accepted an anonymous request: HTTP #{anonymous_representation.code}"
            end
            if outsider_membership.zero?
              outsider_representation = http.get(representation_url,
                "Cookie" => outsider_cookie, "Accept-Encoding" => "identity")
              unless outsider_representation.code == "403"
                raise "#{app} #{kind} representation escaped room membership: HTTP #{outsider_representation.code}"
              end
            end
            variation_part = representation_url.split("/representations/redirect/", 2).last.split("/", 2).last.split("/", 2).first
            variation_signature = variation_part.split("--", 2).last
            raise "#{app} #{kind} representation signature missing" unless variation_signature && !variation_signature.empty?
            tampered_variation = representation_url.sub(variation_signature,
              (variation_signature.end_with?("0") ? "1" : "0") + variation_signature[1..])
            tampered_response = http.get(tampered_variation, "Cookie" => cookie,
              "Accept-Encoding" => "identity")
            unless tampered_response.code == "404"
              raise "#{app} tampered #{kind} representation was served: HTTP #{tampered_response.code}"
            end
            representation_response = http.get(representation_url, "Cookie" => cookie,
              "Accept-Encoding" => "identity")
            unless representation_response.code == "200" &&
                representation_response["content-type"].to_s.start_with?("image/") &&
                !representation_response.body.empty?
              raise "#{app} #{kind} representation mismatch: HTTP #{representation_response.code}, " \
                "#{representation_response["content-type"]}, #{representation_response.body.bytesize} bytes"
            end
            if kind == :video && !(representation_response["content-type"].start_with?("image/webp") &&
                representation_response.body.start_with?("RIFF") &&
                representation_response.body.byteslice(8, 4) == "WEBP")
              raise "#{app} video poster is not WebP"
            end
            attachment_checks["#{kind}_representation"] = {
              status: representation_response.code.to_i,
              content_type: representation_response["content-type"],
              bytes: representation_response.body.bytesize,
              anonymous_status: anonymous_representation.code.to_i,
              outsider_status: outsider_membership.zero? ? 403 : nil,
              tampered_status: tampered_response.code.to_i
            }
            blob_token = blob_url.split("/blobs/redirect/", 2).last.split("/", 2).first
            attachment_client_id = "bench-attachment-#{kind}-#{Process.pid}-#{iteration + 1}"
            attachment_post = Net::HTTP::Post.new("/rooms/#{write_room}/messages")
            attachment_post["Cookie"] = cookie
            attachment_post["Origin"] = base
            attachment_post["Sec-Fetch-Site"] = "same-origin"
            attachment_post["Accept"] = "text/vnd.turbo-stream.html"
            attachment_post.set_form_data("authenticity_token" => CGI.unescapeHTML(csrf),
              "message[body]" => "bench write attachment preflight",
              "message[client_message_id]" => attachment_client_id,
              "message[attachment]" => blob_token)
            attachment_post_response = http.request(attachment_post)
            raise "#{app} signed attachment message create failed: HTTP #{attachment_post_response.code}" unless attachment_post_response.code == "200"
            attached_message = sql.call(db, "SELECT id FROM messages WHERE client_message_id='#{attachment_client_id}'").first
            raise "#{app} signed attachment message was not persisted" unless attached_message
            attached_blob = sql.call(db, "SELECT blob_id FROM active_storage_attachments WHERE record_type='Message' AND record_id=#{attached_message.fetch('id')} AND name='attachment'").first
            unless attached_blob && attached_blob.fetch("blob_id") == target.fetch("blob_id")
              raise "#{app} #{kind} signed blob was not attached to the message " \
                "(target blob #{target.fetch('blob_id')}, attached #{attached_blob&.fetch('blob_id', nil).inspect})"
            end
            attachment_checks[:message_write] = { status: attachment_post_response.code.to_i,
              message_id: attached_message.fetch("id"), blob_id: attached_blob.fetch("blob_id") }
            attachment_posts += 1

            if %w[ruby express mojo oxcaml].include?(app)
              upload_payload = ("direct-upload-benchmark-" * 10_923).b
              upload_checksum = Base64.strict_encode64(Digest::MD5.digest(upload_payload))
              upload_metadata = { blob: { filename: "benchmark-direct-upload.bin",
                content_type: "application/octet-stream", byte_size: upload_payload.bytesize,
                checksum: upload_checksum } }
              direct_upload_request = Net::HTTP::Post.new("/rails/active_storage/direct_uploads")
              direct_upload_request["Cookie"] = cookie
              direct_upload_request["Origin"] = base
              direct_upload_request["X-CSRF-Token"] = CGI.unescapeHTML(csrf)
              direct_upload_request["Content-Type"] = "application/json"
              direct_upload_request.body = JSON.generate(upload_metadata)
              direct_upload_response = http.request(direct_upload_request)
              raise "#{app} direct upload metadata failed: HTTP #{direct_upload_response.code}" unless direct_upload_response.code == "200"
              upload_info = JSON.parse(direct_upload_response.body)
              upload_uri = URI(upload_info.fetch("direct_upload").fetch("url"))
              upload_put = Net::HTTP::Put.new(upload_uri.request_uri,
                upload_info.fetch("direct_upload").fetch("headers"))
              upload_put.body = upload_payload
              upload_response = http.request(upload_put)
              raise "#{app} direct upload bytes failed: HTTP #{upload_response.code}" unless upload_response.code == "204"
              upload_client_id = "bench-direct-upload-#{kind}-#{Process.pid}-#{iteration + 1}"
              upload_attachment = Net::HTTP::Post.new("/rooms/#{write_room}/messages")
              upload_attachment["Cookie"] = cookie
              upload_attachment["Origin"] = base
              upload_attachment["Sec-Fetch-Site"] = "same-origin"
              upload_attachment["Accept"] = "text/vnd.turbo-stream.html"
              upload_attachment.set_form_data("authenticity_token" => CGI.unescapeHTML(csrf),
                "message[body]" => "bench write direct upload attachment",
                "message[client_message_id]" => upload_client_id,
                "message[attachment]" => upload_info.fetch("signed_id"))
              upload_attachment_response = http.request(upload_attachment)
              raise "#{app} direct-upload attachment create failed: HTTP #{upload_attachment_response.code}" unless upload_attachment_response.code == "200"
              upload_message = sql.call(db, "SELECT id FROM messages WHERE client_message_id='#{upload_client_id}'").first
              raise "#{app} direct-upload message was not persisted" unless upload_message
              upload_blob_attachment = sql.call(db, "SELECT blob_id FROM active_storage_attachments WHERE record_type='Message' AND record_id=#{upload_message.fetch('id')} AND name='attachment'").first
              unless upload_blob_attachment && upload_blob_attachment.fetch("blob_id") == upload_info.fetch("id")
                raise "#{app} direct-upload blob was not attached: row=#{upload_blob_attachment.inspect}, upload_id=#{upload_info.fetch('id').inspect}"
              end
              uploaded_blob_url = "/rails/active_storage/blobs/redirect/#{upload_info.fetch('signed_id')}/benchmark-direct-upload.bin"
              uploaded_blob_response = http.get(uploaded_blob_url, "Cookie" => cookie, "Accept-Encoding" => "identity")
              unless uploaded_blob_response.code == "200" && uploaded_blob_response.body == upload_payload
                raise "#{app} uploaded blob bytes differ: HTTP #{uploaded_blob_response.code}, #{uploaded_blob_response.body.bytesize} bytes"
              end
              if app == "oxcaml"
                attachment_only_id = "bench-attachment-only-#{kind}-#{Process.pid}-#{iteration + 1}"
                attachment_only_payload = File.binread(File.join(repo, "once-campfire-oxcaml", "assets", "account-logo-512.png"))
                attachment_only_boundary = "----CampfireAttachmentOnly#{SecureRandom.hex(8)}"
                attachment_only_body = [
                  ["authenticity_token", CGI.unescapeHTML(csrf)],
                  ["message[body]", ""],
                  ["message[client_message_id]", attachment_only_id]
                ].map do |name, value|
                  "--#{attachment_only_boundary}\r\nContent-Disposition: form-data; name=\"#{name}\"\r\n\r\n#{value}\r\n"
                end.join
                attachment_only_body << "--#{attachment_only_boundary}\r\nContent-Disposition: form-data; name=\"message[attachment]\"; filename=\"attachment-only.png\"\r\nContent-Type: image/png\r\n\r\n#{attachment_only_payload}\r\n--#{attachment_only_boundary}--\r\n"
                attachment_only_request = Net::HTTP::Post.new("/rooms/#{write_room}/messages")
                attachment_only_request["Cookie"] = cookie
                attachment_only_request["Origin"] = base
                attachment_only_request["Sec-Fetch-Site"] = "same-origin"
                attachment_only_request["Accept"] = "text/vnd.turbo-stream.html"
                attachment_only_request["Content-Type"] = "multipart/form-data; boundary=#{attachment_only_boundary}"
                attachment_only_request.body = attachment_only_body
                attachment_only_response = http.request(attachment_only_request)
                raise "oxcaml attachment-only message failed: HTTP #{attachment_only_response.code}" unless attachment_only_response.code == "200"
                attachment_only_message = sql.call(db, "SELECT id FROM messages WHERE client_message_id='#{attachment_only_id}'").first
                raise "oxcaml attachment-only message was not persisted" unless attachment_only_message
                attachment_only_blob = sql.call(db, "SELECT b.content_type,b.metadata FROM active_storage_attachments a JOIN active_storage_blobs b ON b.id=a.blob_id WHERE a.record_type='Message' AND a.record_id=#{attachment_only_message.fetch('id')} AND a.name='attachment'").first
                unless attachment_only_blob && attachment_only_blob.fetch("content_type") == "image/png" &&
                    attachment_only_blob.fetch("metadata").include?("\"width\":512") && attachment_only_blob.fetch("metadata").include?("\"height\":512")
                  raise "oxcaml attachment-only image did not persist its association and dimensions"
                end
                attachment_checks[:attachment_only] = { status: attachment_only_response.code.to_i,
                  message_id: attachment_only_message.fetch("id"), content_type: attachment_only_blob.fetch("content_type"),
                  width: 512, height: 512 }
              end
              if app == "mojo"
                avatar_payload = Base64.strict_decode64("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/pWQAAAAASUVORK5CYII=")
                avatar_user = sql.call(db, "SELECT u.id FROM users u WHERE u.status=0 AND u.role<>2 AND NOT EXISTS(SELECT 1 FROM active_storage_attachments a WHERE a.record_type='User' AND a.record_id=u.id AND a.name='avatar') AND NOT EXISTS(SELECT 1 FROM memberships ms WHERE ms.user_id=u.id AND ms.room_id IN (#{room},#{write_room})) ORDER BY u.id LIMIT 1").first
                raise "#{app} avatar preflight has no unused active member" unless avatar_user
                avatar_metadata = { blob: { filename: "benchmark-avatar.png", content_type: "image/png",
                  byte_size: avatar_payload.bytesize, checksum: Base64.strict_encode64(Digest::MD5.digest(avatar_payload)) } }
                avatar_upload_request = Net::HTTP::Post.new("/rails/active_storage/direct_uploads")
                avatar_upload_request["Cookie"] = cookie
                avatar_upload_request["Origin"] = base
                avatar_upload_request["X-CSRF-Token"] = CGI.unescapeHTML(csrf)
                avatar_upload_request["Content-Type"] = "application/json"
                avatar_upload_request.body = JSON.generate(avatar_metadata)
                avatar_upload_response = http.request(avatar_upload_request)
                raise "#{app} avatar metadata upload failed: HTTP #{avatar_upload_response.code}" unless avatar_upload_response.code == "200"
                avatar_upload = JSON.parse(avatar_upload_response.body)
                avatar_uri = URI(avatar_upload.fetch("direct_upload").fetch("url"))
                avatar_put = Net::HTTP::Put.new(avatar_uri.request_uri, avatar_upload.fetch("direct_upload").fetch("headers"))
                avatar_put.body = avatar_payload
                avatar_put_response = http.request(avatar_put)
                raise "#{app} avatar bytes upload failed: HTTP #{avatar_put_response.code}" unless avatar_put_response.code == "204"
                invalid_avatar_attach = Net::HTTP::Post.new("/users/me/profile")
                invalid_avatar_attach["Cookie"] = cookie
                invalid_avatar_attach.set_form_data("_method" => "patch", "authenticity_token" => CGI.unescapeHTML(csrf),
                  "user[avatar]" => "invalid-signed-blob-id")
                invalid_avatar_attach_response = http.request(invalid_avatar_attach)
                raise "#{app} avatar attach accepted an invalid signed blob ID: HTTP #{invalid_avatar_attach_response.code}" unless invalid_avatar_attach_response.code == "422"
                invalid_avatar_rows = sql.call(db, "SELECT COUNT(*) AS n FROM active_storage_attachments WHERE record_type='User' AND record_id=#{Integer(avatar_user.fetch('id'))} AND name='avatar'").first.fetch("n").to_i
                raise "#{app} invalid avatar ID created an attachment" unless invalid_avatar_rows.zero?
                avatar_update = Net::HTTP::Post.new("/users/me/profile")
                avatar_update["Cookie"] = cookie
                avatar_update["Origin"] = base
                avatar_update["Sec-Fetch-Site"] = "same-origin"
                avatar_update.set_form_data("_method" => "patch", "authenticity_token" => CGI.unescapeHTML(csrf),
                  "user[avatar]" => avatar_upload.fetch("signed_id"))
                avatar_update_response = http.request(avatar_update)
                raise "#{app} avatar attach failed: HTTP #{avatar_update_response.code}" unless avatar_update_response.code == "302"
                avatar_user_id = Integer(avatar_user.fetch("id"))
                avatar_attachment = sql.call(db, "SELECT blob_id FROM active_storage_attachments WHERE record_type='User' AND record_id=#{avatar_user_id} AND name='avatar'").first
                raise "#{app} avatar attachment did not persist" unless avatar_attachment && avatar_attachment.fetch("blob_id").to_i == avatar_upload.fetch("id")
                avatar_page = http.get("/users/#{avatar_user_id}", "Cookie" => cookie)
                raise "#{app} avatar profile failed: HTTP #{avatar_page.code}" unless avatar_page.code == "200"
                avatar_token = avatar_page.body[/<img src="\/users\/([^\/]+)\/avatar/, 1]
                raise "#{app} avatar profile omitted its signed URL" unless avatar_token
                avatar_response = http.get("/users/#{avatar_token}/avatar", "Cookie" => cookie, "Accept-Encoding" => "identity")
                raise "#{app} uploaded avatar bytes differ: HTTP #{avatar_response.code}" unless avatar_response.code == "200" && avatar_response.body == avatar_payload
                invalid_avatar_delete = Net::HTTP::Post.new("/users/#{avatar_user_id}/avatar")
                invalid_avatar_delete["Cookie"] = cookie
                invalid_avatar_delete.set_form_data("_method" => "delete", "authenticity_token" => "invalid-csrf-token")
                invalid_avatar_delete_response = http.request(invalid_avatar_delete)
                raise "#{app} avatar delete accepted invalid CSRF: HTTP #{invalid_avatar_delete_response.code}" unless invalid_avatar_delete_response.code == "422"
                avatar_kept = sql.call(db, "SELECT COUNT(*) AS n FROM active_storage_attachments WHERE record_type='User' AND record_id=#{avatar_user_id} AND name='avatar'").first.fetch("n").to_i
                raise "#{app} invalid-CSRF avatar delete removed the attachment" unless avatar_kept == 1
                avatar_delete = Net::HTTP::Post.new("/users/#{avatar_user_id}/avatar")
                avatar_delete["Cookie"] = cookie
                avatar_delete["Origin"] = base
                avatar_delete["Sec-Fetch-Site"] = "same-origin"
                avatar_delete.set_form_data("_method" => "delete", "authenticity_token" => CGI.unescapeHTML(csrf))
                avatar_delete_response = http.request(avatar_delete)
                raise "#{app} avatar delete failed: HTTP #{avatar_delete_response.code}" unless avatar_delete_response.code == "302"
                avatar_left = sql.call(db, "SELECT COUNT(*) AS n FROM active_storage_attachments WHERE record_type='User' AND record_id=#{avatar_user_id} AND name='avatar'").first.fetch("n").to_i
                raise "#{app} avatar delete left an attachment" unless avatar_left.zero?
                preflight["profile_avatar"] = { upload_status: avatar_upload_response.code.to_i,
                  invalid_signed_id_status: invalid_avatar_attach_response.code.to_i,
                  attach_status: avatar_update_response.code.to_i, stream_status: avatar_response.code.to_i,
                  invalid_csrf_status: invalid_avatar_delete_response.code.to_i,
                  delete_status: avatar_delete_response.code.to_i, attachment_removed: true }
              end
              bad_upload_payload = upload_payload + "x"
              bad_upload_metadata = upload_metadata.merge(blob: upload_metadata.fetch(:blob).merge(
                byte_size: bad_upload_payload.bytesize))
              bad_metadata_request = Net::HTTP::Post.new("/rails/active_storage/direct_uploads")
              bad_metadata_request["Cookie"] = cookie
              bad_metadata_request["Origin"] = base
              bad_metadata_request["X-CSRF-Token"] = CGI.unescapeHTML(csrf)
              bad_metadata_request["Content-Type"] = "application/json"
              bad_metadata_request.body = JSON.generate(bad_upload_metadata)
              bad_metadata_response = http.request(bad_metadata_request)
              raise "#{app} invalid-checksum metadata failed: HTTP #{bad_metadata_response.code}" unless bad_metadata_response.code == "200"
              bad_upload_info = JSON.parse(bad_metadata_response.body)
              bad_upload_uri = URI(bad_upload_info.fetch("direct_upload").fetch("url"))
              bad_upload_put = Net::HTTP::Put.new(bad_upload_uri.request_uri,
                bad_upload_info.fetch("direct_upload").fetch("headers"))
              bad_upload_put.body = bad_upload_payload
              bad_upload_response = http.request(bad_upload_put)
              raise "#{app} invalid upload checksum accepted: HTTP #{bad_upload_response.code}" unless bad_upload_response.code == "422"
              bad_key = bad_upload_info.fetch("key")
              bad_object_path = File.join(data, "files", bad_key[0, 2], bad_key[2, 2], bad_key)
              raise "#{app} invalid upload left an object" if File.exist?(bad_object_path) || File.exist?(bad_object_path + ".upload")
              attachment_checks[:direct_upload] = { metadata_status: direct_upload_response.code.to_i,
                byte_status: upload_response.code.to_i, attachment_status: upload_attachment_response.code.to_i,
                invalid_checksum_status: bad_upload_response.code.to_i,
                blob_id: upload_info.fetch("id"), byte_size: uploaded_blob_response.body.bytesize,
                sha256: Digest::SHA256.hexdigest(uploaded_blob_response.body) }
              attachment_posts += 1
            end
          end
        end
        preflight[:message_attachments] = attachment_checks
      end
      unless options[:validation_only]
      Net::HTTP.new("127.0.0.1", options[:port], nil).start do |http|
      if %w[ruby express mojo oxcaml].include?(app)
        deactivate_user_id = Integer(labels.fetch("users.jz"))
        deactivate_user_before = sql.call(db, "SELECT status,email_address FROM users WHERE id=#{deactivate_user_id} AND role<>2").first
        raise "#{app} account deactivation fixture missing" unless deactivate_user_before && deactivate_user_before.fetch("status").to_i == 0
        direct_memberships_before = sql.call(db, "SELECT room_id FROM memberships WHERE user_id=#{deactivate_user_id} AND room_id IN (SELECT id FROM rooms WHERE type='Rooms::Direct') ORDER BY room_id").map { |item| item.fetch("room_id").to_i }
        shared_memberships_before = sql.call(db, "SELECT COUNT(*) AS n FROM memberships WHERE user_id=#{deactivate_user_id} AND room_id IN (SELECT id FROM rooms WHERE type<>'Rooms::Direct')").first.fetch("n").to_i
        push_subscriptions_before = sql.call(db, "SELECT COUNT(*) AS n FROM push_subscriptions WHERE user_id=#{deactivate_user_id}").first.fetch("n").to_i
        raise "#{app} account deactivation fixture has no shared memberships" if shared_memberships_before.zero?
        raise "#{app} account deactivation fixture has no push subscription" if push_subscriptions_before.zero?
        deactivate_cookie = lg.call("login", "--base", base, "--email", labels.fetch("emails.jz"),
          "--password", labels.fetch("passwords.all")).fetch("cookie")
        sessions_before = sql.call(db, "SELECT COUNT(*) AS n FROM sessions WHERE user_id=#{deactivate_user_id}").first.fetch("n").to_i
        raise "#{app} account deactivation login did not persist a session" if sessions_before.zero?
        deactivate_request = Net::HTTP::Post.new("/account/users/#{deactivate_user_id}")
        deactivate_request["Cookie"] = cookie
        deactivate_request.set_form_data("_method" => "delete", "authenticity_token" => CGI.unescapeHTML(csrf))
        deactivate_response = http.request(deactivate_request)
        raise "#{app} account member deactivation failed: HTTP #{deactivate_response.code}" unless deactivate_response.code == "302"
        inactive_user = sql.call(db, "SELECT status,email_address FROM users WHERE id=#{deactivate_user_id}").first
        raise "#{app} account member was not deactivated" unless inactive_user.fetch("status").to_i == 1 && inactive_user.fetch("email_address").include?("-deactivated-")
        shared_memberships_after = sql.call(db, "SELECT COUNT(*) AS n FROM memberships WHERE user_id=#{deactivate_user_id} AND room_id IN (SELECT id FROM rooms WHERE type<>'Rooms::Direct')").first.fetch("n").to_i
        direct_memberships_after = sql.call(db, "SELECT room_id FROM memberships WHERE user_id=#{deactivate_user_id} AND room_id IN (SELECT id FROM rooms WHERE type='Rooms::Direct') ORDER BY room_id").map { |item| item.fetch("room_id").to_i }
        cleanup_counts = %w[sessions searches push_subscriptions].to_h do |table|
          [table.to_sym, sql.call(db, "SELECT COUNT(*) AS n FROM #{table} WHERE user_id=#{deactivate_user_id}").first.fetch("n").to_i]
        end
        raise "#{app} account deactivation retained shared memberships" unless shared_memberships_after.zero?
        raise "#{app} account deactivation changed direct memberships" unless direct_memberships_after == direct_memberships_before
        raise "#{app} account deactivation retained related rows: #{cleanup_counts.inspect}" unless cleanup_counts.values.all?(&:zero?)
        revoked_response = http.get("/account/edit", "Cookie" => deactivate_cookie)
        raise "#{app} deactivated user session remained valid" unless revoked_response.code == "302" && revoked_response["location"] == "/session/new"
        preflight["account_member_deactivation"] = { status: deactivate_response.code.to_i,
          shared_memberships_removed: shared_memberships_before, direct_memberships_preserved: direct_memberships_after.length,
          sessions_removed: sessions_before, searches_removed: true, push_subscriptions_removed: push_subscriptions_before,
          session_revoked: true }

        join_code = sql.call(db, "SELECT join_code FROM accounts ORDER BY id LIMIT 1").first.fetch("join_code")
        join_email = "benchmark-join-#{Process.pid}-#{iteration + 1}-#{app}@example.test"
        join_page = Net::HTTP::Get.new("/join/#{join_code}")
        join_page_response = http.request(join_page)
        raise "#{app} invitation page failed: HTTP #{join_page_response.code}" unless join_page_response.code == "200"
        join_csrf = join_page_response.body[/<meta name="csrf-token" content="([^"]+)"/, 1]
        join_cookie = join_page_response.get_fields("set-cookie")&.first&.split(";")&.first
        raise "#{app} invitation page did not issue CSRF state" unless join_csrf && join_cookie
        invalid_join = Net::HTTP::Post.new("/join/#{join_code}")
        invalid_join["Cookie"] = join_cookie
        invalid_join.set_form_data("authenticity_token" => "invalid-csrf-token", "user[name]" => "Benchmark Invite",
          "user[email_address]" => join_email, "user[password]" => "benchmark-password")
        invalid_join_response = http.request(invalid_join)
        raise "#{app} invalid-CSRF invitation signup was accepted" unless invalid_join_response.code == "422"
        raise "#{app} invalid-CSRF invitation signup wrote a user" unless sql.call(db, "SELECT COUNT(*) AS n FROM users WHERE email_address='#{join_email}'").first.fetch("n").zero?
        join_request = Net::HTTP::Post.new("/join/#{join_code}")
        join_request["Cookie"] = join_cookie
        join_request.set_form_data("authenticity_token" => CGI.unescapeHTML(join_csrf), "user[name]" => "Benchmark Invite",
          "user[email_address]" => join_email, "user[password]" => "benchmark-password")
        join_response = http.request(join_request)
        raise "#{app} invitation signup failed: HTTP #{join_response.code}" unless join_response.code == "302" && join_response["location"] == "/"
        invited_user = sql.call(db, "SELECT id,role,status,password_digest FROM users WHERE email_address='#{join_email}'").first
        raise "#{app} invitation signup did not create a member" unless invited_user && invited_user.fetch("role").to_i.zero? && invited_user.fetch("status").to_i.zero? && invited_user.fetch("password_digest").start_with?("$2")
        expected_open_rooms = sql.call(db, "SELECT id FROM rooms WHERE type='Rooms::Open' ORDER BY id").map { |row| row.fetch("id").to_i }
        invited_rooms = sql.call(db, "SELECT room_id FROM memberships WHERE user_id=#{Integer(invited_user.fetch('id'))} ORDER BY room_id").map { |row| row.fetch("room_id").to_i }
        raise "#{app} invitation signup did not join every open room" unless invited_rooms == expected_open_rooms
        raise "#{app} invitation signup did not create a session" if sql.call(db, "SELECT COUNT(*) AS n FROM sessions WHERE user_id=#{Integer(invited_user.fetch('id'))}").first.fetch("n").zero?
        preflight["join_signup"] = { page_status: join_page_response.code.to_i, invalid_csrf_status: invalid_join_response.code.to_i,
          signup_status: join_response.code.to_i, member_created: true, open_room_memberships: invited_rooms.length, session_created: true }
      end
      if app == "oxcaml"
        ban_user_id = Integer(labels.fetch("users.kevin"))
        ban_profile = http.get("/users/#{ban_user_id}", "Cookie" => cookie)
        raise "oxcaml user profile unavailable for ban action: HTTP #{ban_profile.code}" unless ban_profile.code == "200" && ban_profile.body.include?("Ban Kevin")
        ban_csrf = ban_profile.body[/<meta name="csrf-token" content="([^"]+)"/, 1]
        raise "oxcaml user profile omitted CSRF token" unless ban_csrf
        original_message_count = sql.call(db, "SELECT COUNT(*) AS n FROM messages WHERE creator_id=#{ban_user_id}").first.fetch("n").to_i
        raise "oxcaml ban fixture has no user messages" if original_message_count.zero?
        original_message_ids = sql.call(db, "SELECT id FROM messages WHERE creator_id=#{ban_user_id}").map { |row| Integer(row.fetch("id")) }
        invalid_ban = Net::HTTP::Post.new("/users/#{ban_user_id}/ban")
        invalid_ban["Cookie"] = cookie
        invalid_ban.set_form_data("authenticity_token" => "invalid-csrf-token")
        invalid_ban_response = http.request(invalid_ban)
        raise "oxcaml user ban accepted invalid CSRF: HTTP #{invalid_ban_response.code}" unless invalid_ban_response.code == "422"
        raise "oxcaml invalid-CSRF ban mutated user" unless sql.call(db, "SELECT status FROM users WHERE id=#{ban_user_id}").first.fetch("status").to_i.zero?
        ban_request = Net::HTTP::Post.new("/users/#{ban_user_id}/ban")
        ban_request["Cookie"] = cookie
        ban_request["Origin"] = base
        ban_request.set_form_data("authenticity_token" => CGI.unescapeHTML(ban_csrf))
        ban_response = http.request(ban_request)
        raise "oxcaml user ban failed: HTTP #{ban_response.code}" unless ban_response.code == "302" && ban_response["location"] == "/users/#{ban_user_id}"
        banned_user = sql.call(db, "SELECT status,(SELECT COUNT(*) FROM sessions WHERE user_id=#{ban_user_id}) AS sessions,(SELECT COUNT(*) FROM messages WHERE creator_id=#{ban_user_id}) AS messages FROM users WHERE id=#{ban_user_id}").first
        remaining_fts = sql.call(db, "SELECT COUNT(*) AS n FROM message_search_index WHERE rowid IN (#{original_message_ids.join(',')})").first.fetch("n").to_i
        banned_ips = sql.call(db, "SELECT ip_address FROM bans WHERE user_id=#{ban_user_id} ORDER BY ip_address").map { |row| row.fetch("ip_address") }
        raise "oxcaml user ban did not revoke sessions/delete messages/search rows" unless banned_user.fetch("status").to_i == 2 && banned_user.fetch("sessions").to_i.zero? && banned_user.fetch("messages").to_i.zero? && remaining_fts.zero?
        raise "oxcaml user ban did not store distinct public IPs" unless banned_ips == ["203.0.113.77"]
        banned_profile = http.get("/users/#{ban_user_id}", "Cookie" => cookie)
        raise "oxcaml banned user profile missing remove-ban control" unless banned_profile.code == "200" && banned_profile.body.include?("Remove ban")
        unban_csrf = banned_profile.body[/<meta name="csrf-token" content="([^"]+)"/, 1]
        unban_request = Net::HTTP::Post.new("/users/#{ban_user_id}/ban")
        unban_request["Cookie"] = cookie
        unban_request.set_form_data("_method" => "delete", "authenticity_token" => CGI.unescapeHTML(unban_csrf))
        unban_response = http.request(unban_request)
        raise "oxcaml user unban failed: HTTP #{unban_response.code}" unless unban_response.code == "302"
        restored_ban = sql.call(db, "SELECT status,(SELECT COUNT(*) FROM bans WHERE user_id=#{ban_user_id}) AS bans FROM users WHERE id=#{ban_user_id}").first
        raise "oxcaml user unban did not restore active status/remove IP bans" unless restored_ban.fetch("status").to_i.zero? && restored_ban.fetch("bans").to_i.zero?
        preflight["user_ban"] = { profile_status: ban_profile.code.to_i,
          invalid_csrf_status: invalid_ban_response.code.to_i, ban_status: ban_response.code.to_i,
          message_count_removed: original_message_count, distinct_public_ips: banned_ips.length,
          unban_status: unban_response.code.to_i, restored: true }

        admin_bots_page = http.get("/account/bots", "Cookie" => cookie)
        raise "oxcaml account bot page failed: HTTP #{admin_bots_page.code}" unless admin_bots_page.code == "200"
        bot_csrf = admin_bots_page.body[/<meta name="csrf-token" content="([^"]+)"/, 1]
        raise "oxcaml account bot page omitted CSRF token" unless bot_csrf
        bot_name = "Benchmark Bot #{Process.pid} #{iteration + 1}"
        bot_create_path = "/account/bots"
        invalid_bot_create = Net::HTTP::Post.new(bot_create_path)
        invalid_bot_create["Cookie"] = cookie
        invalid_bot_create["Origin"] = base
        invalid_bot_create.set_form_data("authenticity_token" => "invalid-csrf-token", "user[name]" => bot_name)
        invalid_bot_response = http.request(invalid_bot_create)
        raise "oxcaml account bot accepted invalid CSRF: HTTP #{invalid_bot_response.code}" unless invalid_bot_response.code == "422"
        raise "oxcaml invalid-CSRF bot creation persisted a bot" unless sql.call(db, "SELECT COUNT(*) AS n FROM users WHERE name='#{bot_name.gsub("'", "''")}' AND role=2").first.fetch("n").zero?
        bot_create_request = Net::HTTP::Post.new(bot_create_path)
        bot_create_request["Cookie"] = cookie
        bot_create_request["Origin"] = base
        bot_create_request.set_form_data("authenticity_token" => CGI.unescapeHTML(bot_csrf), "user[name]" => bot_name,
          "user[webhook_url]" => "https://hooks.example.test/bench")
        bot_create_response = http.request(bot_create_request)
        raise "oxcaml account bot creation failed: HTTP #{bot_create_response.code}" unless bot_create_response.code == "302"
        created_bot = sql.call(db, "SELECT id,bot_token FROM users WHERE name='#{bot_name.gsub("'", "''")}' AND role=2 AND status=0").first
        raise "oxcaml account bot creation did not persist an alphanumeric 12-character key" unless created_bot && created_bot.fetch("bot_token").match?(/\A[a-zA-Z0-9]{12}\z/)
        managed_bot_id = Integer(created_bot.fetch("id"))
        expected_bot_rooms = sql.call(db, "SELECT id FROM rooms WHERE type='Rooms::Open' ORDER BY id").map { |row| row.fetch("id").to_i }
        actual_bot_rooms = sql.call(db, "SELECT room_id FROM memberships WHERE user_id=#{managed_bot_id} ORDER BY room_id").map { |row| row.fetch("room_id").to_i }
        raise "oxcaml new account bot did not join existing open rooms" unless actual_bot_rooms == expected_bot_rooms
        raise "oxcaml account bot webhook was not persisted" unless sql.call(db, "SELECT url FROM webhooks WHERE user_id=#{managed_bot_id} ORDER BY id DESC LIMIT 1").first&.fetch("url") == "https://hooks.example.test/bench"
        update_bot_request = Net::HTTP::Post.new("/account/bots/#{managed_bot_id}")
        update_bot_request["Cookie"] = cookie
        update_bot_request["Origin"] = base
        update_bot_request.set_form_data("_method" => "patch", "authenticity_token" => CGI.unescapeHTML(bot_csrf),
          "user[name]" => "#{bot_name} Updated", "user[webhook_url]" => "")
        update_bot_response = http.request(update_bot_request)
        raise "oxcaml account bot update failed: HTTP #{update_bot_response.code}" unless update_bot_response.code == "302"
        raise "oxcaml account bot update did not clear webhook" unless sql.call(db, "SELECT COUNT(*) AS n FROM webhooks WHERE user_id=#{managed_bot_id}").first.fetch("n").zero?
        old_bot_key = "#{managed_bot_id}-#{created_bot.fetch('bot_token')}"
        rotate_bot_request = Net::HTTP::Post.new("/account/bots/#{managed_bot_id}/key")
        rotate_bot_request["Cookie"] = cookie
        rotate_bot_request["Origin"] = base
        rotate_bot_request.set_form_data("_method" => "put", "authenticity_token" => CGI.unescapeHTML(bot_csrf))
        rotate_bot_response = http.request(rotate_bot_request)
        raise "oxcaml account bot key rotation failed: HTTP #{rotate_bot_response.code}" unless rotate_bot_response.code == "302"
        rotated_bot = sql.call(db, "SELECT bot_token FROM users WHERE id=#{managed_bot_id}").first.fetch("bot_token")
        raise "oxcaml account bot key rotation did not replace the key" if rotated_bot == created_bot.fetch("bot_token")
        old_key_response = http.get("/rooms/#{expected_bot_rooms.first}/#{old_bot_key}/messages")
        raise "oxcaml old account bot key still authenticates" unless old_key_response.code == "401"
        deactivation_request = Net::HTTP::Post.new("/account/bots/#{managed_bot_id}")
        deactivation_request["Cookie"] = cookie
        deactivation_request["Origin"] = base
        deactivation_request.set_form_data("_method" => "delete", "authenticity_token" => CGI.unescapeHTML(bot_csrf))
        deactivation_response = http.request(deactivation_request)
        raise "oxcaml account bot deactivation failed: HTTP #{deactivation_response.code}" unless deactivation_response.code == "302"
        inactive_bot = sql.call(db, "SELECT status,email_address FROM users WHERE id=#{managed_bot_id}").first
        remaining_bot_memberships = sql.call(db, "SELECT COUNT(*) AS n FROM memberships WHERE user_id=#{managed_bot_id} AND room_id IN (SELECT id FROM rooms WHERE type<>'Rooms::Direct')").first.fetch("n").to_i
        raise "oxcaml account bot deactivation did not anonymize and remove shared memberships" unless inactive_bot.fetch("status").to_i == 1 && inactive_bot.fetch("email_address").to_s.include?("@inactive.invalid") && remaining_bot_memberships.zero?
        preflight["account_bots"] = { page_status: admin_bots_page.code.to_i,
          invalid_csrf_status: invalid_bot_response.code.to_i, create_status: bot_create_response.code.to_i,
          update_status: update_bot_response.code.to_i, rotate_key_status: rotate_bot_response.code.to_i,
          old_key_status: old_key_response.code.to_i, deactivate_status: deactivation_response.code.to_i,
          open_room_memberships: expected_bot_rooms.length, restored: true }

        bot_room_id = Integer(labels.fetch("rooms.watercooler"))
        bot_id = Integer(labels.fetch("users.bender"))
        bot_key = "#{bot_id}-#{labels.fetch('bot_keys.bender')}"
        bot_text = "OxCaml bot API preflight #{Process.pid} #{iteration + 1}"
        bot_create = Net::HTTP::Post.new("/rooms/#{bot_room_id}/#{bot_key}/messages")
        bot_create.body = bot_text
        bot_created = http.request(bot_create)
        raise "oxcaml bot message create failed: HTTP #{bot_created.code}" unless bot_created.code == "201" && bot_created["location"]
        bot_message = JSON.parse(bot_created.body)
        bot_message_id = Integer(bot_message.fetch("id"))
        raise "oxcaml bot message JSON is incomplete" unless bot_message.dig("body", "plain_text") == bot_text && bot_message.dig("creator", "id").to_i == bot_id && bot_message.dig("creator", "role") == "bot" && bot_message.dig("room", "id").to_i == bot_room_id
        bot_row = sql.call(db, "SELECT creator_id FROM messages WHERE id=#{bot_message_id}").first
        raise "oxcaml bot message was not persisted as its bot" unless bot_row && bot_row.fetch("creator_id").to_i == bot_id
        bot_attachment_name = "oxcaml-bot-#{Process.pid}-#{iteration + 1}.txt"
        bot_attachment_bytes = "OxCaml bot attachment preflight #{Process.pid} #{iteration + 1}\n"
        bot_attachment_boundary = "----CampfireBotAttachment#{SecureRandom.hex(8)}"
        bot_attachment_request = Net::HTTP::Post.new("/rooms/#{bot_room_id}/#{bot_key}/messages")
        bot_attachment_request["Content-Type"] = "multipart/form-data; boundary=#{bot_attachment_boundary}"
        bot_attachment_request.body = "--#{bot_attachment_boundary}\r\nContent-Disposition: form-data; name=\"attachment\"; filename=\"#{bot_attachment_name}\"\r\nContent-Type: text/plain\r\n\r\n#{bot_attachment_bytes}\r\n--#{bot_attachment_boundary}--\r\n"
        bot_attachment_response = http.request(bot_attachment_request)
        raise "oxcaml bot attachment create failed: HTTP #{bot_attachment_response.code}" unless bot_attachment_response.code == "201"
        bot_attachment_message = JSON.parse(bot_attachment_response.body)
        bot_attachment_message_id = Integer(bot_attachment_message.fetch("id"))
        raise "oxcaml bot attachment plain text did not fall back to its filename" unless bot_attachment_message.dig("body", "plain_text") == bot_attachment_name
        bot_attachment_row = sql.call(db, "SELECT b.id,b.filename,b.byte_size,b.content_type,a.record_type,a.record_id,a.name FROM active_storage_attachments a JOIN active_storage_blobs b ON b.id=a.blob_id WHERE a.record_type='Message' AND a.record_id=#{bot_attachment_message_id} AND a.name='attachment'").first
        raise "oxcaml bot attachment did not persist the Rails Message/attachment association" unless bot_attachment_row && bot_attachment_row.fetch("filename") == bot_attachment_name && bot_attachment_row.fetch("byte_size").to_i == bot_attachment_bytes.bytesize && bot_attachment_row.fetch("content_type") == "text/plain"
        bot_attachment_delete = Net::HTTP::Delete.new("/rooms/#{bot_room_id}/#{bot_key}/messages/#{bot_attachment_message_id}")
        bot_attachment_deleted = http.request(bot_attachment_delete)
        raise "oxcaml bot attachment message delete failed: HTTP #{bot_attachment_deleted.code}" unless bot_attachment_deleted.code == "204"
        raise "oxcaml bot attachment deletion left a message or orphan blob" unless sql.call(db, "SELECT (SELECT COUNT(*) FROM messages WHERE id=#{bot_attachment_message_id}) + (SELECT COUNT(*) FROM active_storage_blobs WHERE id=#{Integer(bot_attachment_row.fetch('id'))}) AS n").first.fetch("n").zero?
        bot_list = http.get("/rooms/#{bot_room_id}/#{bot_key}/messages")
        listed = JSON.parse(bot_list.body).find { |message| message.fetch("id").to_i == bot_message_id }
        raise "oxcaml bot message list omitted created message" unless bot_list.code == "200" && listed
        bot_boost_request = Net::HTTP::Post.new("/rooms/#{bot_room_id}/#{bot_key}/messages/#{bot_message_id}/boosts")
        bot_boost_request.body = "👀"
        bot_boost_response = http.request(bot_boost_request)
        raise "oxcaml bot boost create failed: HTTP #{bot_boost_response.code}" unless bot_boost_response.code == "201"
        bot_boost = JSON.parse(bot_boost_response.body)
        bot_boost_id = Integer(bot_boost.fetch("id"))
        raise "oxcaml bot boost JSON mismatch" unless bot_boost.fetch("content") == "👀" && bot_boost.dig("booster", "id").to_i == bot_id && bot_boost.dig("message", "id").to_i == bot_message_id
        bot_boost_delete = Net::HTTP::Delete.new("/rooms/#{bot_room_id}/#{bot_key}/messages/#{bot_message_id}/boosts/#{bot_boost_id}")
        bot_boost_deleted = http.request(bot_boost_delete)
        raise "oxcaml bot boost delete failed: HTTP #{bot_boost_deleted.code}" unless bot_boost_deleted.code == "204"
        raise "oxcaml bot boost deletion left a row" unless sql.call(db, "SELECT COUNT(*) AS n FROM boosts WHERE id=#{bot_boost_id}").first.fetch("n").zero?
        bot_message_dom_id = sql.call(db, "SELECT client_message_id FROM messages WHERE id=#{bot_message_id}").first.fetch("client_message_id")
        preflight["cable_bot_boost_mutations"] = client.verify_cable_bot_boost_mutations(
          cookie: cookie, bot_key: bot_key, room: bot_room_id, message_id: bot_message_id,
          client_message_id: bot_message_dom_id)
        bot_update = Net::HTTP::Patch.new("/rooms/#{bot_room_id}/#{bot_key}/messages/#{bot_message_id}")
        bot_update.body = "#{bot_text} updated"
        bot_updated = http.request(bot_update)
        raise "oxcaml bot message update failed: HTTP #{bot_updated.code}" unless bot_updated.code == "200" && JSON.parse(bot_updated.body).dig("body", "plain_text") == "#{bot_text} updated"
        bot_delete = Net::HTTP::Delete.new("/rooms/#{bot_room_id}/#{bot_key}/messages/#{bot_message_id}")
        bot_deleted = http.request(bot_delete)
        raise "oxcaml bot message delete failed: HTTP #{bot_deleted.code}" unless bot_deleted.code == "204"
        raise "oxcaml bot message deletion left database rows" unless sql.call(db, "SELECT COUNT(*) AS n FROM messages WHERE id=#{bot_message_id}").first.fetch("n").zero?
        preflight["bot_messages"] = { create_status: bot_created.code.to_i,
          list_status: bot_list.code.to_i, update_status: bot_updated.code.to_i,
          attachment_create_status: bot_attachment_response.code.to_i,
          attachment_delete_status: bot_attachment_deleted.code.to_i,
          boost_create_status: bot_boost_response.code.to_i,
          boost_delete_status: bot_boost_deleted.code.to_i,
          delete_status: bot_deleted.code.to_i, persisted_as_bot: true }

        push_page = http.get("/users/me/push_subscriptions", "Cookie" => cookie)
        raise "oxcaml push-subscription page failed: HTTP #{push_page.code}" unless push_page.code == "200"
        push_csrf = push_page.body[/<meta name="csrf-token" content="([^"]+)"/, 1]
        raise "oxcaml push-subscription page omitted CSRF token" unless push_csrf
        push_endpoint = "https://fcm.googleapis.com/fcm/send/oxcaml-#{Process.pid}-#{iteration + 1}"
        invalid_push = Net::HTTP::Post.new("/users/me/push_subscriptions")
        invalid_push["Cookie"] = cookie
        invalid_push["Origin"] = base
        invalid_push.set_form_data("authenticity_token" => "invalid-csrf-token",
          "push_subscription[endpoint]" => push_endpoint,
          "push_subscription[p256dh_key]" => "bench-p256dh",
          "push_subscription[auth_key]" => "bench-auth")
        invalid_push_response = http.request(invalid_push)
        raise "oxcaml push subscription accepted invalid CSRF: HTTP #{invalid_push_response.code}" unless invalid_push_response.code == "422"
        push_create = Net::HTTP::Post.new("/users/me/push_subscriptions")
        push_create["Cookie"] = cookie
        push_create["Origin"] = base
        push_params = { "authenticity_token" => CGI.unescapeHTML(push_csrf),
          "push_subscription[endpoint]" => push_endpoint,
          "push_subscription[p256dh_key]" => "bench-p256dh",
          "push_subscription[auth_key]" => "bench-auth" }
        push_create.set_form_data(push_params)
        push_create_response = http.request(push_create)
        raise "oxcaml push subscription create failed: HTTP #{push_create_response.code}" unless push_create_response.code == "200"
        push_row = sql.call(db, "SELECT id,user_id,user_agent FROM push_subscriptions WHERE endpoint='#{push_endpoint}' AND p256dh_key='bench-p256dh' AND auth_key='bench-auth'").first
        raise "oxcaml push subscription was not persisted for current user" unless push_row && push_row.fetch("user_id").to_i == Integer(labels.fetch("users.david"))
        push_id = Integer(push_row.fetch("id"))
        duplicate_push = Net::HTTP::Post.new("/users/me/push_subscriptions")
        duplicate_push["Cookie"] = cookie
        duplicate_push["Origin"] = base
        duplicate_push.set_form_data(push_params)
        duplicate_push_response = http.request(duplicate_push)
        raise "oxcaml duplicate push subscription failed: HTTP #{duplicate_push_response.code}" unless duplicate_push_response.code == "200"
        raise "oxcaml duplicate push subscription created a second row" unless sql.call(db, "SELECT COUNT(*) AS n FROM push_subscriptions WHERE endpoint='#{push_endpoint}' AND p256dh_key='bench-p256dh' AND auth_key='bench-auth'").first.fetch("n").to_i == 1
        invalid_test_push = Net::HTTP::Post.new("/users/me/push_subscriptions/#{push_id}/test_notifications")
        invalid_test_push["Cookie"] = cookie
        invalid_test_push["Origin"] = base
        invalid_test_push.set_form_data("authenticity_token" => "invalid-csrf-token")
        invalid_test_push_response = http.request(invalid_test_push)
        raise "oxcaml test push accepted invalid CSRF: HTTP #{invalid_test_push_response.code}" unless invalid_test_push_response.code == "422"
        delete_push = Net::HTTP::Post.new("/users/me/push_subscriptions/#{push_id}")
        delete_push["Cookie"] = cookie
        delete_push["Origin"] = base
        delete_push.set_form_data("_method" => "delete", "authenticity_token" => CGI.unescapeHTML(push_csrf))
        delete_push_response = http.request(delete_push)
        raise "oxcaml push subscription delete failed: HTTP #{delete_push_response.code}" unless delete_push_response.code == "302"
        raise "oxcaml push subscription delete left a row" unless sql.call(db, "SELECT COUNT(*) AS n FROM push_subscriptions WHERE id=#{push_id}").first.fetch("n").zero?
        preflight["push_subscriptions"] = { page_status: push_page.code.to_i,
          invalid_csrf_status: invalid_push_response.code.to_i,
          invalid_test_csrf_status: invalid_test_push_response.code.to_i,
          create_status: push_create_response.code.to_i,
          duplicate_status: duplicate_push_response.code.to_i,
          delete_status: delete_push_response.code.to_i, restored: true }
      end
      end
      end
      if app == "mojo" && (options[:preflight] || options[:validation_only])
        room_messages_stream = scrape.fetch("streams").filter_map do |stream|
          channel, signed_name = stream.split("|", 2)
          signed_name if channel == "RoomMessagesChannel"
        end.first
        raise "#{app} scrape has no guarded room message stream" unless room_messages_stream
        preflight["cable_unread_notification"] = client.verify_cable_unread_notification(
          cookie: cookie, csrf: csrf, room: room, signed_stream: room_messages_stream)
      end
      preflight[:static_assets] = static_asset_checks
      if %w[mojo express oxcaml].include?(app) && !options[:validation_only]
        boosts_before_round_trip = sql.call(db, "SELECT COUNT(*) AS n FROM boosts").first.fetch("n")
        boost_mutation = client.boost_round_trip(cookie, csrf, labels.fetch("messages.unboosted"))
        remaining_boosts = sql.call(db, "SELECT COUNT(*) AS n FROM boosts").first.fetch("n")
        raise "boost create/delete did not restore preflight state" unless remaining_boosts == boosts_before_round_trip
      end
      if app == "oxcaml"
        preflight["sidebar_cable_mutations"] = client.verify_sidebar_room_lifecycle(
          cookie: cookie, csrf: csrf, user_id: labels.fetch("users.david"))
        preflight["cable_message_mutations"] = client.verify_cable_message_mutations(
          cookie: cookie, csrf: csrf, room: room)
        preflight["cable_typing"] = client.verify_cable_typing(
          cookie: cookie, room: room, user_id: labels.fetch("users.david"))
        outsider_room = sql.call(db, "SELECT r.id FROM rooms r WHERE r.type='Rooms::Direct' AND NOT EXISTS (SELECT 1 FROM memberships m WHERE m.room_id=r.id AND m.user_id=#{Integer(labels.fetch('users.david'))}) ORDER BY r.id LIMIT 1").first
        raise "OxCaml typing authorization fixture has no non-member direct room" unless outsider_room
        preflight["cable_typing_nonmember_denied"] = client.verify_cable_typing_denies_nonmember(
          cookie: cookie, room: outsider_room.fetch("id"))
        preflight["cable_read_notification"] = client.verify_cable_read_notification(
          cookie: cookie, room: room)
      end
      end
      row = { app: app, round: iteration + 1, preflight: preflight, http: [], cable: [], load_start: load_snapshot.call }
      row[:boost_mutation] = boost_mutation if boost_mutation
      acknowledged_writes = attachment_posts
      unless options[:preflight]
        if options[:suites].split(",").include?("http")
          routes.each do |name, path|
            next unless options[:routes].split(",").include?(name)
            args = path ? ["--path", path] : ["--post-room", write_room.to_s, "--csrf", csrf]
            warmup = lg.call("http", "--base", base, "--cookie", cookie, *args, "--conc", "4", "--duration", "2")
            check_sample.call(name, warmup)
            acknowledged_writes += warmup.fetch("ok") unless path
            options[:concurrencies].split(",").each do |concurrency|
              value = lg.call("http", "--base", base, "--cookie", cookie, *args, "--conc", concurrency, "--duration", options[:duration].to_s)
              check_sample.call(name, value)
              acknowledged_writes += value.fetch("ok") unless path
              row[:http] << value.merge("route" => name)
              puts "#{app} round #{iteration + 1}: #{name} #{concurrency} clients #{value.fetch('rps')} req/s"
              STDOUT.flush
            end
          end
        end
        if options[:suites].split(",").include?("cable")
          options[:cable_clients].split(",").map { |value| Integer(value) }.each do |clients|
            cable_args = ["cable", "--base", base, "--cookie", cookie, "--room", room.to_s, "--csrf", csrf,
              "--streams", scrape.fetch("streams").join(","), "--clients", clients.to_s,
              "--tput-secs", options[:cable_tput_secs].to_s, "--posters", "4"]
            if app == "mojo" && (options[:preflight] || options[:validation_only])
              cable_thread = Thread.new { lg.call(*cable_args) }
              presence_state = nil
              loop do
                presence_state = sql.call(db, "SELECT connections,connected_at FROM memberships WHERE user_id=#{Integer(labels.fetch('users.david'))} AND room_id=#{room}").first
                break if presence_state && presence_state.fetch("connections").to_i >= clients && presence_state.fetch("connected_at")
                raise "#{app} cable run ended without marking all clients present" unless cable_thread.alive?
                sleep 0.05
              end
              value = cable_thread.value
              disconnected_state = sql.call(db, "SELECT connections,connected_at FROM memberships WHERE user_id=#{Integer(labels.fetch('users.david'))} AND room_id=#{room}").first
              unless disconnected_state && disconnected_state.fetch("connections").to_i.zero? && disconnected_state.fetch("connected_at").nil?
                raise "#{app} Cable close left presence state connected: #{disconnected_state.inspect}"
              end
              preflight["presence_lifecycle"] = { connected_count: presence_state.fetch("connections").to_i,
                disconnected_count: disconnected_state.fetch("connections").to_i }
            else
              value = lg.call(*cable_args)
            end
            write_json(File.join(options[:output], "#{app}-#{iteration + 1}-cable-#{clients}.json"), value)
            raise "incomplete Cable delivery" unless value.fetch("ready") == clients && value.fetch("failed").zero? && value.fetch("latency").fetch("complete") == value.fetch("latency").fetch("messages") && value.fetch("throughput").fetch("complete") == value.fetch("throughput").fetch("posted")
            row[:cable] << value
            puts "#{app} round #{iteration + 1}: Cable #{clients} connections, #{value.fetch("latency").fetch("complete")}/#{value.fetch("latency").fetch("messages")} paced messages fully delivered"
            STDOUT.flush
          end
        end
        if options[:suites].split(",").include?("upload")
          value = JSON.parse(run("taskset", "-c", options[:client_cpus], "ruby", ENV.fetch("UPLOAD_CHECK", File.join(repo, "tmp/validation/verify_upload.rb")), "--base", base, "--reps", "5"))
          raise "incomplete upload" unless value.fetch("runs").all? { |item| item["thumb_status"] == 200 && item.fetch("width") <= 1200 && item.fetch("height") <= 800 }
          row[:upload] = value
        end
      end
      row[:logout] = client.logout(cookie, csrf) if %w[mojo express oxcaml].include?(app)
      actual_messages = sql.call(db, "SELECT COUNT(*) AS n FROM messages WHERE room_id=#{write_room}").first.fetch("n")
      raise "acknowledged HTTP writes missing" unless actual_messages - initial_messages >= acknowledged_writes
      raise "FTS entry missing" unless sql.call(db, "SELECT COUNT(*) AS n FROM messages WHERE id NOT IN (SELECT rowid FROM message_search_index)").first.fetch("n").zero?
      raise "rich text entry missing" unless sql.call(db, "SELECT COUNT(*) AS n FROM messages WHERE room_id=#{write_room} AND id>#{initial_max_id} AND id NOT IN (SELECT record_id FROM active_storage_attachments WHERE record_type='Message') AND id NOT IN (SELECT record_id FROM action_text_rich_texts WHERE record_type='Message' AND name='body')").first.fetch("n").zero?
      raise "fixture corrupt" unless sql.call(db, "PRAGMA integrity_check;").first.values == ["ok"]
      richtext_posts = sql.call(db, "SELECT COUNT(*) AS n FROM messages m JOIN action_text_rich_texts rt ON rt.record_type='Message' AND rt.record_id=m.id AND rt.name='body' WHERE m.room_id=#{write_room} AND m.id>#{initial_max_id} AND rt.body LIKE '%bench write %'").first.fetch("n")
      raise "acknowledged message body missing" if richtext_posts < acknowledged_writes
      row[:richtext_http_posts] = richtext_posts
      row[:persisted_writes] = actual_messages - initial_messages
      row[:load_end] = load_snapshot.call
      results << row
      write_json(File.join(options[:output], "#{app}-#{iteration + 1}.json"), row)
      remove_container(container)
      observer_app = nil
      remove_container(redis_container)
    end
  end
  raise "original seed changed" unless Digest::SHA256.file(File.join(options[:seed], "db/production.sqlite3")).hexdigest == original_seed_sha
  summary = apps.to_h do |app|
    rows = results.select { |row| row[:app] == app }
    values = %w[room_show messages_page sidebar search autocomplete_users avatar static_css up profile user account post_message].to_h do |name|
      samples = rows.filter_map { |row| row[:http].find { |item| item.fetch("route") == name && item.fetch("conc") == 16 }&.fetch("rps") }
      [name, samples.empty? ? nil : { median_rps: median(samples), runs: samples }]
    end
    [app, values]
  end
  write_json(File.join(options[:output], "summary.json"), metadata: metadata, results: summary)
  puts JSON.pretty_generate(summary)
  completed = true
ensure
  unless ENV["BENCH_KEEP_FAILED"] == "1" && !completed
    remove_container(container)
    remove_container(redis_container)
  end
end
