require "cgi"
require "base64"
require "digest"
require "json"
require "net/http"
require "securerandom"
require "socket"

class BenchmarkHTTPClient
  def initialize(base)
    @base = URI(base)
  end

  def ready?
    connection.start { |http| http.get("/up").code == "200" }
  rescue IOError, SystemCallError, Timeout::Error, SocketError
    false
  end

  def login(labels)
    cookies = {}
    connection.start do |http|
      response = http.get("/session/new", "Accept-Encoding" => "identity")
      raise "sign-in page: HTTP #{response.code}" unless response.code == "200"
      merge_cookies(cookies, response)
      token = response.body[/<meta name="csrf-token" content="([^"]*)"/, 1]
      raise "sign-in page has no CSRF token" unless token
      request = Net::HTTP::Post.new("/session")
      request["Cookie"] = cookie_header(cookies)
      request["Origin"] = @base.to_s
      request["Sec-Fetch-Site"] = "same-origin"
      request.set_form_data(email_address: labels.fetch("emails.david"), password: labels.fetch("passwords.all"),
        authenticity_token: CGI.unescapeHTML(token))
      response = http.request(request)
      merge_cookies(cookies, response)
      raise "login failed: HTTP #{response.code}" unless response.code == "302" && cookies.key?("session_token")
    end
    cookie_header(cookies)
  end

  def logout(cookie, csrf)
    connection.start do |http|
      invalid_request = Net::HTTP::Post.new("/session")
      invalid_request["Cookie"] = cookie
      invalid_request.set_form_data("_method" => "delete", "authenticity_token" => "invalid-csrf-token")
      invalid_response = http.request(invalid_request)
      raise "logout accepted an invalid CSRF token: HTTP #{invalid_response.code}" unless invalid_response.code == "422"
      still_authenticated = http.get("/users/me/sidebar", "Cookie" => cookie)
      raise "invalid-CSRF logout revoked the session" unless still_authenticated.code == "200"

      request = Net::HTTP::Post.new("/session")
      request["Cookie"] = cookie
      request["Origin"] = @base.to_s
      request["Sec-Fetch-Site"] = "same-origin"
      request.set_form_data("_method" => "delete", "authenticity_token" => CGI.unescapeHTML(csrf))
      response = http.request(request)
      raise "logout failed: HTTP #{response.code}" unless response.code == "302" && response["location"] == "/"
      set_cookies = response.get_fields("set-cookie").to_a
      cleared = set_cookies.filter_map do |header|
        cookie, attributes = header.split(";", 2)
        name = cookie.split("=", 2).first
        name if attributes&.match?(/(?:\A|;)\s*max-age=0(?:;|\z)/i) ||
          attributes&.match?(/(?:\A|;)\s*expires=thu, 01 jan 1970/i)
      end
      raised_session_cookie = set_cookies.any? do |header|
        name, value = header.split(";", 2).first.split("=", 2)
        name == "_campfire_session" && value && !value.empty?
      end
      unless cleared.include?("session_token") && raised_session_cookie
        headers = set_cookies.map do |header|
          cookie, attributes = header.split(";", 2)
          [cookie.split("=", 2).first, attributes]
        end
        raise "logout did not clear auth and reset Rails session cookies: #{headers.inspect}"
      end
      protected_response = http.get("/users/me/sidebar", "Cookie" => cookie)
      raise "logout left the database session active" unless protected_response.code == "302" && protected_response["location"] == "/session/new"
      { invalid_csrf_status: invalid_response.code.to_i, status: response.code.to_i,
        redirect: response["location"], expired_cookies: cleared.sort,
        protected_status: protected_response.code.to_i }
    end
  end

  def boost_round_trip(cookie, csrf, message_id)
    content = "b#{Process.pid}"
    path = "/messages/#{Integer(message_id)}/boosts"
    connection.start do |http|
      form = http.get("#{path}/new", "Cookie" => cookie, "Accept-Encoding" => "identity")
      unless form.code == "200" && form.body.include?('name="boost[content]"') &&
          form.body.include?('name="authenticity_token"') && form.body.include?('id="new_boost_message_')
        raise "new boost form failed: HTTP #{form.code}"
      end

      invalid = Net::HTTP::Post.new(path)
      invalid["Cookie"] = cookie
      invalid["Accept"] = "text/vnd.turbo-stream.html"
      invalid.set_form_data("boost[content]" => content, "authenticity_token" => "invalid-csrf-token")
      invalid_response = http.request(invalid)
      raise "boost accepted an invalid CSRF token: HTTP #{invalid_response.code}" unless invalid_response.code == "422"

      request = Net::HTTP::Post.new(path)
      request["Cookie"] = cookie
      request["Origin"] = @base.to_s
      request["Sec-Fetch-Site"] = "same-origin"
      request["Accept"] = "text/vnd.turbo-stream.html"
      request.set_form_data("boost[content]" => content, "authenticity_token" => CGI.unescapeHTML(csrf))
      response = http.request(request)
      rendered = response.body
      unless response.code == "200" && response["content-type"].start_with?("text/vnd.turbo-stream.html")
        raise "boost create failed: HTTP #{response.code}" unless response.code == "302" && response["location"] == path
        rendered_response = http.get(path, "Cookie" => cookie, "Accept-Encoding" => "identity")
        raise "boost index failed: HTTP #{rendered_response.code}" unless rendered_response.code == "200"
        rendered = rendered_response.body
      end
      raise "boost create response did not render its card" unless rendered.include?(content)
      boost_id = rendered[/id="boost_(\d+)"/, 1]
      boost_id ||= response.body[/target="boost_(\d+)"/, 1]
      raise "boost create response has no persisted boost ID" unless boost_id

      delete = Net::HTTP::Post.new("#{path}/#{boost_id}")
      delete["Cookie"] = cookie
      delete["Origin"] = @base.to_s
      delete["Sec-Fetch-Site"] = "same-origin"
      delete["Accept"] = "text/vnd.turbo-stream.html"
      delete.set_form_data("_method" => "delete", "authenticity_token" => CGI.unescapeHTML(csrf))
      deleted = http.request(delete)
      unless deleted.code == "200" && deleted["content-type"].start_with?("text/vnd.turbo-stream.html") &&
          deleted.body.include?("action=\"remove\"") && deleted.body.include?("boost_#{boost_id}")
        raise "boost delete failed: HTTP #{deleted.code}"
      end
      { invalid_csrf_status: invalid_response.code.to_i, create_status: response.code.to_i,
        delete_status: deleted.code.to_i, boost_id: boost_id.to_i }
    end
  end

  def verify_cable_message_mutations(cookie:, csrf:, room:)
    socket = nil
    message_id = nil
    cleanup_needed = false
    room_response = connection.start do |http|
      http.get("/rooms/#{Integer(room)}", "Cookie" => cookie, "Accept-Encoding" => "identity")
    end
    raise "Cable mutation room page failed: HTTP #{room_response.code}" unless room_response.code == "200"
    signed_stream = room_response.body[/<turbo-cable-stream-source channel="RoomMessagesChannel" signed-stream-name="([^"]+)"/, 1]
    raise "room page has no signed message stream" unless signed_stream

    socket = cable_socket(cookie)
    buffer = +""
    identifier = JSON.generate(channel: "RoomMessagesChannel", signed_stream_name: CGI.unescapeHTML(signed_stream))
    cable_write(socket, JSON.generate(command: "subscribe", identifier: identifier))
    await_cable_type(socket, buffer, identifier, "confirm_subscription")

    client_message_id = "bench-cable-mutation-#{Process.pid}-#{SecureRandom.hex(6)}"
    message_path = "/rooms/#{Integer(room)}/messages"
    create = Net::HTTP::Post.new(message_path)
    create["Cookie"] = cookie
    create["Origin"] = @base.to_s
    create["Sec-Fetch-Site"] = "same-origin"
    create["Accept"] = "text/vnd.turbo-stream.html"
    create.set_form_data("authenticity_token" => CGI.unescapeHTML(csrf),
      "message[body]" => "Cable mutation preflight original",
      "message[client_message_id]" => client_message_id)
    created = connection.start { |http| http.request(create) }
    raise "Cable mutation message create failed: HTTP #{created.code}" unless created.code == "200"
    message_id = created.body[/data-message-id="(\d+)"/, 1]
    raise "Cable mutation create response has no persisted message ID" unless message_id
    cleanup_needed = true
    await_cable_message(socket, buffer) do |payload|
      html = JSON.parse(payload)["message"]
      html.include?("action=\"append\"") && html.include?(client_message_id)
    end

    edit = Net::HTTP::Post.new("#{message_path}/#{Integer(message_id)}")
    edit["Cookie"] = cookie
    edit["Origin"] = @base.to_s
    edit["Sec-Fetch-Site"] = "same-origin"
    edit["Accept"] = "text/vnd.turbo-stream.html"
    edit.set_form_data("_method" => "patch", "authenticity_token" => CGI.unescapeHTML(csrf),
      "message[body]" => "Cable mutation preflight edited")
    edited = connection.start { |http| http.request(edit) }
    expected_edit_location = "#{message_path}/#{Integer(message_id)}"
    unless edited.code == "302" && edited["location"] == expected_edit_location
      raise "Cable mutation message edit failed: HTTP #{edited.code}, #{edited['location'].inspect}"
    end
    await_cable_message(socket, buffer) do |payload|
      html = JSON.parse(payload)["message"]
      html.include?("action=\"replace\"") && html.include?("message_#{client_message_id}") &&
        html.include?("Cable mutation preflight edited")
    end

    delete = Net::HTTP::Post.new("#{message_path}/#{Integer(message_id)}")
    delete["Cookie"] = cookie
    delete["Origin"] = @base.to_s
    delete["Sec-Fetch-Site"] = "same-origin"
    delete["Accept"] = "text/vnd.turbo-stream.html"
    delete.set_form_data("_method" => "delete", "authenticity_token" => CGI.unescapeHTML(csrf))
    deleted = connection.start { |http| http.request(delete) }
    unless deleted.code == "302" && deleted["location"] == "/rooms/#{Integer(room)}"
      raise "Cable mutation message delete failed: HTTP #{deleted.code}, #{deleted['location'].inspect}"
    end
    cleanup_needed = false
    await_cable_message(socket, buffer) do |payload|
      html = JSON.parse(payload)["message"]
      html.include?("action=\"remove\"") && html.include?("message_#{client_message_id}")
    end

    { create_status: created.code.to_i, edit_status: edited.code.to_i,
      delete_status: deleted.code.to_i, message_id: Integer(message_id) }
  ensure
    if cleanup_needed && message_id
      cleanup = Net::HTTP::Post.new("/rooms/#{Integer(room)}/messages/#{Integer(message_id)}")
      cleanup["Cookie"] = cookie
      cleanup["Origin"] = @base.to_s
      cleanup["Sec-Fetch-Site"] = "same-origin"
      cleanup.set_form_data("_method" => "delete", "authenticity_token" => CGI.unescapeHTML(csrf))
      connection.start { |http| http.request(cleanup) } rescue nil
    end
    if socket
      cable_write(socket, "", opcode: 8) rescue nil
      socket.close rescue nil
    end
  end

  def verify_cable_bot_boost_mutations(cookie:, bot_key:, room:, message_id:, client_message_id:)
    socket = nil
    room_response = connection.start do |http|
      http.get("/rooms/#{Integer(room)}", "Cookie" => cookie, "Accept-Encoding" => "identity")
    end
    raise "bot boost Cable room page failed: HTTP #{room_response.code}" unless room_response.code == "200"
    signed_stream = room_response.body[/<turbo-cable-stream-source channel="RoomMessagesChannel" signed-stream-name="([^"]+)"/, 1]
    raise "room page has no signed message stream for bot boost check" unless signed_stream

    socket = cable_socket(cookie)
    buffer = +""
    identifier = JSON.generate(channel: "RoomMessagesChannel", signed_stream_name: CGI.unescapeHTML(signed_stream))
    cable_write(socket, JSON.generate(command: "subscribe", identifier: identifier))
    await_cable_type(socket, buffer, identifier, "confirm_subscription")

    content = "Bot Cable boost #{Process.pid} #{SecureRandom.hex(5)}"
    path = "/rooms/#{Integer(room)}/#{bot_key}/messages/#{Integer(message_id)}/boosts"
    create = Net::HTTP::Post.new(path)
    create.body = content
    created = connection.start { |http| http.request(create) }
    raise "bot boost Cable create failed: HTTP #{created.code}" unless created.code == "201"
    boost_id = Integer(JSON.parse(created.body).fetch("id"))
    await_cable_message(socket, buffer) do |payload|
      html = JSON.parse(payload)["message"]
      html.include?("action=\"append\"") && html.include?("boosts_message_#{client_message_id}") &&
        html.include?("boost_#{boost_id}") && html.include?(content)
    end

    delete = Net::HTTP::Delete.new("#{path}/#{boost_id}")
    deleted = connection.start { |http| http.request(delete) }
    raise "bot boost Cable delete failed: HTTP #{deleted.code}" unless deleted.code == "204"
    await_cable_message(socket, buffer) do |payload|
      html = JSON.parse(payload)["message"]
      html.include?("action=\"remove\"") && html.include?("boost_#{boost_id}")
    end
    { create_status: created.code.to_i, delete_status: deleted.code.to_i,
      boost_id: boost_id }
  ensure
    if socket
      cable_write(socket, "", opcode: 8) rescue nil
      socket.close rescue nil
    end
  end

  def verify_sidebar_room_lifecycle(cookie:, csrf:, user_id:)
    socket = nil
    room_id = nil
    room_kind = "Rooms::Open"
    cleanup_needed = false
    response = connection.start do |http|
      http.get("/users/me/sidebar", "Cookie" => cookie, "Accept-Encoding" => "identity")
    end
    raise "sidebar stream page failed: HTTP #{response.code}" unless response.code == "200"
    streams = response.body.scan(/<turbo-cable-stream-source channel="Turbo::StreamsChannel" signed-stream-name="([^"]+)"/).flatten
    raise "sidebar page is missing its global or user stream" unless streams.length >= 2
    user_id = Integer(user_id)
    user_gid = Base64.urlsafe_encode64("gid://campfire/User/#{user_id}", padding: false)
    stream_value = lambda do |stream|
      payload = stream.split("--", 2).first
      JSON.parse(Base64.decode64(payload))
    end
    global_stream = streams.find { |stream| stream_value.call(stream) == "rooms" }
    raise "sidebar page is missing its global stream" unless global_stream
    global_id = JSON.generate(channel: "Turbo::StreamsChannel", signed_stream_name: CGI.unescapeHTML(global_stream))
    user_stream = streams.find { |stream| stream_value.call(stream) == "#{user_gid}:rooms" }
    raise "sidebar page is missing the current user's stream" unless user_stream
    user_stream_id = JSON.generate(channel: "Turbo::StreamsChannel", signed_stream_name: CGI.unescapeHTML(user_stream))

    socket = cable_socket(cookie)
    buffer = +""
    cable_write(socket, JSON.generate(command: "subscribe", identifier: global_id))
    await_cable_type(socket, buffer, global_id, "confirm_subscription")
    cable_write(socket, JSON.generate(command: "subscribe", identifier: user_stream_id))
    await_cable_type(socket, buffer, user_stream_id, "confirm_subscription")

    expect_stream = lambda do |identifier, &predicate|
      await_cable_message(socket, buffer) do |payload|
        event = JSON.parse(payload)
        event["identifier"] == identifier && event["message"].is_a?(String) &&
          predicate.call(event["message"])
      end
    end
    post_form = lambda do |path, fields|
      request = Net::HTTP::Post.new(path)
      request["Cookie"] = cookie
      request["Origin"] = @base.to_s
      request["Sec-Fetch-Site"] = "same-origin"
      request.set_form_data(fields.merge("authenticity_token" => CGI.unescapeHTML(csrf)))
      connection.start { |http| http.request(request) }
    end

    room_name = "Cable sidebar preflight #{Process.pid}-#{SecureRandom.hex(4)}"
    created = post_form.call("/rooms/opens/new", "room[name]" => room_name)
    raise "sidebar preflight room create failed: HTTP #{created.code}" unless created.code == "302"
    room_id = created["location"]&.match(%r{\A/rooms/(\d+)\z})&.captures&.first&.to_i
    raise "sidebar preflight room redirect is invalid" unless room_id
    cleanup_needed = true
    expect_stream.call(global_id) do |html|
      html.include?("action=\"prepend\"") && html.include?("target=\"shared_rooms\"") && html.include?(room_name)
    end

    renamed = room_name + " updated"
    update = post_form.call("/rooms/opens/#{room_id}", "_method" => "patch",
      "room[name]" => renamed, "room[type]" => "Rooms::Open")
    raise "sidebar preflight public-room rename failed: HTTP #{update.code}" unless update.code == "302"
    expect_stream.call(global_id) do |html|
      html.include?("action=\"replace\"") && html.include?("target=\"room_#{room_id}_list\"") && html.include?(renamed)
    end

    close = post_form.call("/rooms/opens/#{room_id}", "_method" => "patch",
      "room[name]" => renamed, "room[type]" => "Rooms::Closed", "user_ids[]" => user_id.to_s)
    raise "sidebar preflight room privatization failed: HTTP #{close.code}" unless close.code == "302"
    room_kind = "Rooms::Closed"
    expect_stream.call(global_id) do |html|
      html.include?("action=\"remove\"") && html.include?("target=\"room_#{room_id}_list\"")
    end
    expect_stream.call(user_stream_id) do |html|
      html.include?("action=\"prepend\"") && html.include?("target=\"shared_rooms\"") && html.include?(renamed)
    end

    delete = post_form.call("/rooms/closeds/#{room_id}", "_method" => "delete")
    raise "sidebar preflight private-room delete failed: HTTP #{delete.code}" unless delete.code == "302"
    cleanup_needed = false
    expect_stream.call(user_stream_id) do |html|
      html.include?("action=\"remove\"") && html.include?("target=\"room_#{room_id}_list\"")
    end
    { create_status: created.code.to_i, rename_status: update.code.to_i,
      privatize_status: close.code.to_i, delete_status: delete.code.to_i,
      room_id: room_id }
  ensure
    if socket
      if cleanup_needed && room_id
        path = room_kind == "Rooms::Closed" ? "/rooms/closeds/#{room_id}" : "/rooms/opens/#{room_id}"
        cleanup = Net::HTTP::Post.new(path)
        cleanup["Cookie"] = cookie
        cleanup["Origin"] = @base.to_s
        cleanup["Sec-Fetch-Site"] = "same-origin"
        cleanup.set_form_data("_method" => "delete", "authenticity_token" => CGI.unescapeHTML(csrf))
        connection.start { |http| http.request(cleanup) } rescue nil
      end
      cable_write(socket, "", opcode: 8) rescue nil
      socket.close rescue nil
    end
  end

  def verify_cable_typing(cookie:, room:, user_id:)
    socket = nil
    room = Integer(room)
    user_id = Integer(user_id)
    identifier = JSON.generate(channel: "TypingNotificationsChannel", room_id: room)
    socket = cable_socket(cookie)
    buffer = +""
    cable_write(socket, JSON.generate(command: "subscribe", identifier: identifier))
    await_cable_type(socket, buffer, identifier, "confirm_subscription")

    %w[start stop].each do |action|
      cable_write(socket, JSON.generate(command: "message", identifier: identifier,
        data: JSON.generate(action: action)))
      event = JSON.parse(await_cable_message(socket, buffer) do |payload|
        message = JSON.parse(payload)
        message["identifier"] == identifier && message["message"].is_a?(Hash) &&
          message["message"]["action"] == action
      end)
      user = event.fetch("message").fetch("user")
      unless user["id"] == user_id && user["name"].is_a?(String) && !user["name"].empty?
        raise "typing notification omitted the Rails user identity"
      end
    end

    { room_id: room, actions: %w[start stop], sender_id: user_id }
  ensure
    if socket
      cable_write(socket, "", opcode: 8) rescue nil
      socket.close rescue nil
    end
  end

  def verify_cable_typing_denies_nonmember(cookie:, room:)
    socket = nil
    identifier = JSON.generate(channel: "TypingNotificationsChannel", room_id: Integer(room))
    socket = cable_socket(cookie)
    buffer = +""
    cable_write(socket, JSON.generate(command: "subscribe", identifier: identifier))
    await_cable_type(socket, buffer, identifier, "reject_subscription")
    { room_id: Integer(room), rejected: true }
  ensure
    if socket
      cable_write(socket, "", opcode: 8) rescue nil
      socket.close rescue nil
    end
  end

  def verify_cable_read_notification(cookie:, room:)
    socket = nil
    room = Integer(room)
    read_identifier = JSON.generate(channel: "ReadRoomsChannel")
    presence_identifier = JSON.generate(channel: "PresenceChannel", room_id: room)
    socket = cable_socket(cookie)
    buffer = +""
    cable_write(socket, JSON.generate(command: "subscribe", identifier: presence_identifier))
    await_cable_type(socket, buffer, presence_identifier, "confirm_subscription")
    cable_write(socket, JSON.generate(command: "subscribe", identifier: read_identifier))
    await_cable_type(socket, buffer, read_identifier, "confirm_subscription")
    cable_write(socket, JSON.generate(command: "message", identifier: presence_identifier,
      data: JSON.generate(action: "present")))
    await_cable_message(socket, buffer) do |payload|
      event = JSON.parse(payload)
      event["identifier"] == read_identifier && event["message"].is_a?(Hash) &&
        event["message"]["room_id"] == room
    end
    { room_id: room, read_notification: true }
  ensure
    if socket
      cable_write(socket, "", opcode: 8) rescue nil
      socket.close rescue nil
    end
  end

  def verify_cable_unread_notification(cookie:, csrf:, room:, signed_stream:)
    socket = nil
    room = Integer(room)
    identifier = JSON.generate(channel: "UnreadRoomsChannel")
    message_identifier = JSON.generate(channel: "RoomMessagesChannel", signed_stream_name: CGI.unescapeHTML(signed_stream))
    message_id = nil
    cleanup_needed = false
    socket = cable_socket(cookie)
    buffer = +""
    cable_write(socket, JSON.generate(command: "subscribe", identifier: identifier))
    await_cable_type(socket, buffer, identifier, "confirm_subscription")
    cable_write(socket, JSON.generate(command: "subscribe", identifier: message_identifier))
    message_subscription = JSON.parse(await_cable_message(socket, buffer) do |payload|
      reply = JSON.parse(payload)
      reply["identifier"] == message_identifier && %w[confirm_subscription reject_subscription].include?(reply["type"])
    end)
    unless message_subscription["type"] == "confirm_subscription"
      raise "RoomMessagesChannel rejected the signed room stream: #{message_subscription.inspect}"
    end

    client_message_id = "bench-unread-notification-#{Process.pid}-#{SecureRandom.hex(6)}"
    create = Net::HTTP::Post.new("/rooms/#{room}/messages")
    create["Cookie"] = cookie
    create["Origin"] = @base.to_s
    create["Sec-Fetch-Site"] = "same-origin"
    create["Accept"] = "text/vnd.turbo-stream.html"
    create.set_form_data("authenticity_token" => CGI.unescapeHTML(csrf),
      "message[body]" => "Unread room notification preflight",
      "message[client_message_id]" => client_message_id)
    created = connection.start { |http| http.request(create) }
    raise "Unread notification message create failed: HTTP #{created.code}" unless created.code == "200"
    message_id = created.body[/data-message-id="(\d+)"/, 1]
    raise "Unread notification response has no persisted message ID" unless message_id
    cleanup_needed = true
    received = {}
    while received.length < 2
      await_cable_message(socket, buffer) do |payload|
        event = JSON.parse(payload)
        if event["identifier"] == identifier
          raise "Unread notification payload mismatch: #{event.inspect}" unless event["message"].is_a?(Hash) && event["message"]["roomId"] == room
          received[:unread] = true
          true
        elsif event["identifier"] == message_identifier
          html = event["message"]
          raise "Message append broadcast mismatch" unless html.is_a?(String) && html.include?("action=\"append\"") && html.include?(client_message_id)
          received[:append] = true
          true
        else
          false
        end
      end
    end

    delete = Net::HTTP::Post.new("/rooms/#{room}/messages/#{Integer(message_id)}")
    delete["Cookie"] = cookie
    delete["Origin"] = @base.to_s
    delete["Sec-Fetch-Site"] = "same-origin"
    delete["Accept"] = "text/vnd.turbo-stream.html"
    delete.set_form_data("_method" => "delete", "authenticity_token" => CGI.unescapeHTML(csrf))
    deleted = connection.start { |http| http.request(delete) }
    unless deleted.code == "200" && deleted["content-type"].to_s.start_with?("text/vnd.turbo-stream.html") &&
        deleted.body.include?("action=\"remove\"") && deleted.body.include?(client_message_id)
      raise "Unread notification cleanup failed for message #{message_id}: HTTP #{deleted.code}, #{deleted['location'].inspect}, #{deleted.body.bytesize} bytes"
    end
    removed = false
    await_cable_message(socket, buffer) do |payload|
      event = JSON.parse(payload)
      if event["identifier"] == message_identifier
        html = event["message"]
        raise "Message remove broadcast mismatch" unless html.is_a?(String) && html.include?("action=\"remove\"") && html.include?(client_message_id)
        removed = true
        true
      else
        false
      end
    end
    cleanup_needed = false
    { room_id: room, notification: true, message_appended: received[:append], message_removed: removed,
      message_deleted: true, message_id: Integer(message_id) }
  ensure
    if cleanup_needed && message_id
      cleanup = Net::HTTP::Post.new("/rooms/#{room}/messages/#{Integer(message_id)}")
      cleanup["Cookie"] = cookie
      cleanup["Origin"] = @base.to_s
      cleanup["Sec-Fetch-Site"] = "same-origin"
      cleanup.set_form_data("_method" => "delete", "authenticity_token" => CGI.unescapeHTML(csrf))
      connection.start { |http| http.request(cleanup) } rescue nil
    end
    if socket
      cable_write(socket, "", opcode: 8) rescue nil
      socket.close rescue nil
    end
  end

  def measure(path, cookie, concurrency:, duration:)
    start = clock
    deadline = start + duration
    workers = Array.new(concurrency) do
      Thread.new do
        result = { latencies: [], statuses: Hash.new(0), bytes: 0, errors: 0 }
        while clock < deadline
          begin
            connection.start do |http|
              while clock < deadline
                requested = clock
                response = http.get(path, "Cookie" => cookie, "Accept-Encoding" => "identity")
                result[:latencies] << (clock - requested) * 1000
                result[:statuses][response.code] += 1
                result[:bytes] += response.body.bytesize
              end
            end
          rescue IOError, SystemCallError, Timeout::Error, SocketError, Net::HTTPBadResponse
            result[:errors] += 1
            sleep 0.01
          end
        end
        result
      end
    end
    samples = workers.map(&:value)
    elapsed = clock - start
    latencies = samples.flat_map { |sample| sample[:latencies] }.sort
    statuses = Hash.new(0)
    samples.each { |sample| sample[:statuses].each { |status, count| statuses[status] += count } }
    errors = samples.sum { |sample| sample[:errors] }
    raise "#{path}: HTTP statuses #{statuses}, #{errors} transport errors" unless errors.zero? && statuses.keys == [ "200" ]
    { path: path, conc: concurrency, gzip: false, secs: elapsed, rps: latencies.size / elapsed,
      ok: latencies.size, statuses: statuses, errors: errors,
      avg_bytes: samples.sum { |sample| sample[:bytes] } / latencies.size,
      latency_ms: { p50: percentile(latencies, 0.50), p95: percentile(latencies, 0.95), p99: percentile(latencies, 0.99) } }
  end

  private
    def connection
      Net::HTTP.new(@base.host, @base.port, nil).tap do |http|
        http.open_timeout = 1
        http.read_timeout = 5
        http.write_timeout = 5
        http.max_retries = 0
      end
    end

    def merge_cookies(cookies, response)
      response.get_fields("set-cookie").to_a.each do |header|
        name, value = header.split(";", 2).first.split("=", 2)
        cookies[name] = value
      end
    end

    def cookie_header(cookies)
      cookies.map { |name, value| "#{name}=#{value}" }.join("; ")
    end

    def cable_socket(cookie)
      socket = TCPSocket.new(@base.host, @base.port)
      key = Base64.strict_encode64(SecureRandom.random_bytes(16))
      socket.write("GET /cable HTTP/1.1\r\nHost: #{@base.host}:#{@base.port}\r\n" \
        "Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: #{key}\r\n" \
        "Sec-WebSocket-Version: 13\r\nSec-WebSocket-Protocol: actioncable-v1-json\r\n" \
        "Origin: #{@base}\r\nCookie: #{cookie}\r\n\r\n")
      status = socket.gets
      raise "Cable WebSocket upgrade failed: #{status.inspect}" unless status&.include?(" 101 ")
      headers = {}
      while (line = socket.gets) && line != "\r\n"
        name, value = line.split(":", 2)
        headers[name.downcase] = value.to_s.strip
      end
      expected = Base64.strict_encode64(Digest::SHA1.digest(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
      raise "Cable WebSocket accept mismatch" unless headers["sec-websocket-accept"] == expected
      socket
    rescue Exception
      socket&.close rescue nil
      raise
    end

    def cable_write(socket, payload, opcode: 1)
      bytes = payload.b
      first = 0x80 | opcode
      length = bytes.bytesize
      header = if length < 126
        [first, 0x80 | length].pack("CC")
      elsif length < 65_536
        [first, 0x80 | 126, length].pack("CCn")
      else
        [first, 0x80 | 127, length].pack("CCQ>")
      end
      mask = SecureRandom.random_bytes(4)
      masked = bytes.bytes.each_with_index.map { |byte, index| byte ^ mask.getbyte(index % 4) }.pack("C*")
      socket.write(header + mask + masked)
    end

    def cable_read(socket, buffer)
      loop do
        if buffer.bytesize >= 2
          first, second = buffer.unpack("CC")
          length = second & 0x7f
          offset = 2
          if length == 126
            return nil if buffer.bytesize < 4
            length = buffer.byteslice(2, 2).unpack1("n")
            offset = 4
          elsif length == 127
            return nil if buffer.bytesize < 10
            length = buffer.byteslice(2, 8).unpack1("Q>")
            offset = 10
          end
          masked = (second & 0x80) != 0
          mask = masked ? buffer.byteslice(offset, 4) : nil
          offset += 4 if masked
          return nil if buffer.bytesize < offset + length
          payload = buffer.byteslice(offset, length)
          if masked
            payload = payload.bytes.each_with_index.map { |byte, index| byte ^ mask.getbyte(index % 4) }.pack("C*")
          end
          buffer.slice!(0, offset + length)
          return [first & 0x0f, payload]
        end
        ready = IO.select([socket], nil, nil, 5)
        raise "timed out waiting for Cable message" unless ready
        buffer << socket.readpartial(16_384)
      end
    end

    def await_cable_type(socket, buffer, identifier, type)
      await_cable_message(socket, buffer) do |payload|
        message = JSON.parse(payload)
        message["identifier"] == identifier && message["type"] == type
      end
    end

    def await_cable_message(socket, buffer)
      deadline = clock + 5
      loop do
        remaining = deadline - clock
        raise "timed out waiting for Cable delivery" unless remaining.positive?
        frame = cable_read(socket, buffer)
        unless frame
          ready = IO.select([socket], nil, nil, remaining)
          raise "timed out waiting for Cable delivery" unless ready
          buffer << socket.readpartial(16_384)
          next
        end
        opcode, payload = frame
        if opcode == 9
          cable_write(socket, payload, opcode: 10)
          next
        end
        next unless opcode == 1
        return payload if yield(payload)
      end
    end

    def percentile(values, fraction)
      values[(values.size * fraction).ceil - 1]
    end

    def clock
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
end
