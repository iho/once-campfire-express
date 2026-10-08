import { test, before } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createServer } from "node:http";
process.env.SECRET_KEY_BASE = "core-test-secret-".repeat(8);
const temp = mkdtempSync(join(tmpdir(), "campfire-express-core-"));
process.env.CAMPFIRE_STORAGE_PATH = temp;
const { all, get, run, transaction, initialize, now } =
  await import("../src/db.js");
const domain = await import("../src/domain.js");
const { plainText, sanitize, mentionIds } = await import("../src/richtext.js");
const rails = await import("../src/rails.js");
const { createApp } = await import("../src/app.js");
const { fragment, render } = await import("../src/rendering.js");
let admin, member, outsider, open, privateRoom;
before(() => {
  initialize();
  const t = now();
  run(
    "INSERT INTO accounts(name,join_code,created_at,updated_at) VALUES(?,?,?,?)",
    "Testing",
    "join-me",
    t,
    t,
  );
  admin = domain.createUser({
    name: "Admin",
    email_address: "admin@example.test",
    password: "password",
    role: 1,
  });
  member = domain.createUser({
    name: "Member",
    email_address: "member@example.test",
    password: "password",
  });
  outsider = domain.createUser({
    name: "Outside",
    email_address: "outside@example.test",
    password: "password",
  });
  const make = (name, type) => {
    const r = run(
      "INSERT INTO rooms(name,type,creator_id,created_at,updated_at) VALUES(?,?,?,?,?)",
      name,
      type,
      admin.id,
      t,
      t,
    );
    return get("SELECT * FROM rooms WHERE id=?", Number(r.lastInsertRowid));
  };
  open = make("Open", "Rooms::Open");
  privateRoom = make("Secret", "Rooms::Closed");
  domain.grantMemberships(open, [admin.id, member.id, outsider.id]);
  domain.grantMemberships(privateRoom, [admin.id, member.id]);
});
test("synchronous nested transactions rollback together", () => {
  const n = get("SELECT count(*) n FROM users").n;
  assert.throws(() =>
    transaction(() => {
      domain.createUser({
        name: "Temp",
        email_address: "temp@example.test",
        password: "password",
      });
      throw new Error("rollback");
    }),
  );
  assert.equal(get("SELECT count(*) n FROM users").n, n);
});
test("messages preserve schema, search index, raw timestamp cursors and membership authorization", () => {
  const m = domain.createMessage(
    open.id,
    admin.id,
    "<p>Hello <strong>world</strong></p>",
    "client-1",
  );
  assert.equal(
    get(
      "SELECT body FROM action_text_rich_texts WHERE record_id=? AND record_type='Message'",
      m.id,
    ).body,
    "<p>Hello <strong>world</strong></p>",
  );
  assert.equal(
    get("SELECT rowid FROM message_search_index WHERE body MATCH 'world'")
      .rowid,
    m.id,
  );
  assert.throws(() =>
    domain.createMessage(privateRoom.id, outsider.id, "secret"),
  );
  assert.equal(domain.roomForUser(outsider, privateRoom.id), undefined);
  run(
    "UPDATE messages SET created_at=? WHERE id=?",
    "2026-01-01 00:00:00",
    m.id,
  );
  const newer = domain.createMessage(open.id, admin.id, "later");
  run(
    "UPDATE messages SET created_at=? WHERE id=?",
    "2026-01-01 00:00:01.000000",
    newer.id,
  );
  assert.deepEqual(
    domain.messagesForRoom(open.id, { after: m.id }).map((x) => x.id),
    [newer.id],
  );
  assert.deepEqual(
    domain.messagesForRoom(open.id, { before: newer.id }).map((x) => x.id),
    [m.id],
  );
});
test("updates replace FTS and deletes remove message and rich text", () => {
  let m = domain.createMessage(open.id, member.id, "obsolete");
  m = domain.updateMessage(m, "replacement");
  assert.equal(
    get("SELECT rowid FROM message_search_index WHERE body MATCH 'obsolete'"),
    undefined,
  );
  assert.equal(
    get("SELECT rowid FROM message_search_index WHERE body MATCH 'replacement'")
      .rowid,
    m.id,
  );
  domain.deleteMessage(m, { broadcast: false });
  assert.equal(domain.messageById(m.id), undefined);
  assert.equal(
    get("SELECT rowid FROM message_search_index WHERE rowid=?", m.id),
    undefined,
  );
  assert.equal(
    get(
      "SELECT id FROM action_text_rich_texts WHERE record_type='Message' AND record_id=?",
      m.id,
    ),
    undefined,
  );
});
test("sanitize discards executable markup and unsafe URL schemes", () => {
  const html = sanitize(
    '<script>evil()</script><a href="javascript:evil()" onclick="evil()">hello</a><p>good</p>',
  );
  assert.equal(html, "<a>hello</a><p>good</p>");
  assert.equal(plainText("<p>a<br>b</p><p>c</p>"), "a\nb\n\nc");
});
test("Rails signed mentions are indexed with @ and notified securely", () => {
  const token = rails.sgid("User", member.id);
  const html = `<p>Hello <action-text-attachment sgid="${token}"></action-text-attachment></p>`;
  assert.equal(plainText(html), "Hello @Member");
  assert.deepEqual([...mentionIds(html)], [member.id]);
  assert.deepEqual(
    [...mentionIds(html.replace(token, token + "x"))],
    [member.id],
  );
});
test("retained frontend compiles room/login/sidebar/profile/admin screens", () => {
  const req = {
    user: admin,
    session: {},
    csrfToken: "test-csrf",
    get: (name) => (name === "host" ? "example.test" : null),
    protocol: "http",
  };
  for (const screen of [
    "login",
    "welcome",
    "account",
    "bots",
    "bot-form",
    "custom-styles",
  ])
    assert.ok(render(req, screen, { Subject: { ID: 0 } }).includes("Campfire"));
  assert.match(render(req, "account"), /<title>Account settings<\/title>/);
  assert.ok(
    render(req, "room", {
      Room: {
        ID: open.id,
        Name: "Open",
        Type: "Rooms::Open",
        DOM: (p) => p + "_rooms_open_" + open.id,
      },
      Messages: [],
    }).includes('name="message[body]"'),
  );
  assert.ok(fragment("messages", { Messages: [] }) === "");
});
test("HTTP actual cookie login, CSRF, rooms, search, posting and private denial", async () => {
  const server = createServer(createApp());
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  let cookie = "";
  try {
    let response = await fetch(base + "/session/new");
    const html = await response.text();
    const csrf = html.match(/name="csrf-token" content="([^"]+)"/)[1];
    cookie = response.headers
      .getSetCookie()
      .map((c) => c.split(";")[0])
      .join("; ");
    response = await fetch(base + "/session", {
      method: "POST",
      redirect: "manual",
      headers: { cookie, "content-type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        email_address: member.email_address,
        password: "password",
        authenticity_token: csrf,
      }),
    });
    assert.equal(response.status, 302);
    cookie +=
      "; " +
      response.headers
        .getSetCookie()
        .map((c) => c.split(";")[0])
        .join("; ");
    response = await fetch(base + "/rooms/" + open.id, { headers: { cookie } });
    assert.equal(response.status, 200);
    assert.ok((await response.text()).includes("Lexxy") === false);
    response = await fetch(base + "/rooms/" + open.id + "/messages", {
      method: "POST",
      headers: {
        cookie,
        "content-type": "application/x-www-form-urlencoded",
        accept: "application/json",
      },
      body: new URLSearchParams({
        "message[body]": "<p>Persisted HTTP marker</p>",
        authenticity_token: csrf,
      }),
    });
    assert.equal(response.status, 201);
    const message = await response.json();
    assert.equal(message.body.plain_text, "Persisted HTTP marker");
    assert.ok(
      get(
        "SELECT rowid FROM message_search_index WHERE body MATCH 'Persisted'",
      ),
    );
    response = await fetch(base + "/rooms/" + open.id + "/messages", {
      method: "POST",
      headers: { cookie, "content-type": "application/json" },
      body: JSON.stringify({ message: { body: "without token" } }),
    });
    assert.equal(response.status, 422);
    response = await fetch(base + "/searches?q=Persisted", {
      headers: { cookie },
    });
    assert.equal(response.status, 200);
    assert.ok((await response.text()).includes("Persisted HTTP marker"));
    const outsideToken = "outside-session";
    run(
      "INSERT INTO sessions(user_id,token,created_at,updated_at,last_active_at) VALUES(?,?,?,?,?)",
      outsider.id,
      outsideToken,
      now(),
      now(),
      now(),
    );
    response = await fetch(base + "/rooms/" + privateRoom.id + "/messages", {
      redirect: "manual",
      headers: {
        cookie:
          "session_token=" +
          encodeURIComponent(rails.signCookie("session_token", outsideToken)),
      },
    });
    assert.equal(response.status, 302);

    let adminLogin = await fetch(base + "/session/new");
    const adminLoginHtml = await adminLogin.text();
    const adminCsrf = adminLoginHtml.match(
      /name="csrf-token" content="([^"]+)"/,
    )[1];
    let adminCookie = adminLogin.headers
      .getSetCookie()
      .map((value) => value.split(";")[0])
      .join("; ");
    adminLogin = await fetch(base + "/session", {
      method: "POST",
      redirect: "manual",
      headers: {
        cookie: adminCookie,
        "content-type": "application/x-www-form-urlencoded",
      },
      body: new URLSearchParams({
        email_address: admin.email_address,
        password: "password",
        authenticity_token: adminCsrf,
      }),
    });
    assert.equal(adminLogin.status, 302);
    adminCookie +=
      "; " +
      adminLogin.headers
        .getSetCookie()
        .map((value) => value.split(";")[0])
        .join("; ");
    response = await fetch(base + "/users/" + member.id, {
      headers: { cookie: adminCookie },
    });
    assert.equal(response.status, 200);
    const publicProfile = await response.text();
    assert.match(publicProfile, /\/session\/transfers\//);
    assert.match(publicProfile, /\/qr_code\//);
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
});
process.on("exit", () => rmSync(temp, { recursive: true, force: true }));
import { readFileSync } from "node:fs";
test("64 independent Rails canonical editor plaintext examples", () => {
  const vectors = JSON.parse(
    readFileSync(new URL("../compat/richtext.json", import.meta.url)),
  );
  for (const example of vectors.cases)
    assert.equal(plainText(example.body), example.plain_text, example.name);
});
import { storeUpload, blobUrl, representationUrl, purgeBlob } from "../src/storage.js";
import { messageData } from "../src/rendering.js";
test("inline native attachments preserve rich text ownership, private authorization and cleanup", () => {
  const privateMessage = domain.createMessage(
    privateRoom.id,
    admin.id,
    "private attachment",
  );
  const blob = storeUpload(
    {
      buffer: Buffer.from("private content"),
      originalname: "private.txt",
      mimetype: "text/plain",
    },
    "Message",
    privateMessage.id,
    "attachment",
  );
  const html = `<p>Attachment <action-text-attachment sgid="${rails.sgid("ActiveStorage::Blob", blob.id)}"></action-text-attachment></p>`;
  const n = get("SELECT count(*) n FROM messages").n;
  assert.throws(
    () => domain.createMessage(open.id, outsider.id, html),
    /membership/,
  );
  assert.equal(get("SELECT count(*) n FROM messages").n, n);
  const message = domain.createMessage(privateRoom.id, member.id, html);
  const rich = get(
    "SELECT id FROM action_text_rich_texts WHERE record_type='Message' AND record_id=?",
    message.id,
  );
  assert.equal(
    get(
      "SELECT blob_id FROM active_storage_attachments WHERE record_type='ActionText::RichText' AND record_id=?",
      rich.id,
    ).blob_id,
    blob.id,
  );
  assert.equal(plainText(html), "Attachment [private.txt]");
  assert.ok(String(messageData([message])[0].HTML).includes(blobUrl(blob)));
  const videoMessage = domain.createMessage(
    privateRoom.id,
    member.id,
    "video attachment",
  );
  storeUpload(
    {
      buffer: Buffer.from("video bytes"),
      originalname: "preview.mp4",
      mimetype: "video/mp4",
    },
    "Message",
    videoMessage.id,
    "attachment",
  );
  const videoHtml = String(messageData([videoMessage])[0].HTML);
  const videoBlob = get(
    "SELECT active_storage_blobs.* FROM active_storage_blobs JOIN active_storage_attachments ON active_storage_attachments.blob_id = active_storage_blobs.id WHERE active_storage_attachments.record_id = ? AND active_storage_attachments.record_type = 'Message'",
    videoMessage.id,
  );
  assert.match(videoHtml, /preload="none"/);
  assert.ok(
    videoHtml.includes(
      `poster="${representationUrl(videoBlob, [1200, 800], "webp")}"`,
    ),
  );
  domain.deleteMessage(message, { broadcast: false });
  assert.equal(
    get(
      "SELECT id FROM active_storage_attachments WHERE record_type='ActionText::RichText' AND record_id=?",
      rich.id,
    ),
    undefined,
  );
  purgeBlob(blob.id);
  assert.ok(get("SELECT id FROM active_storage_blobs WHERE id=?", blob.id));
});
test("failed image create and edit leave existing message body, attachments and FTS intact", async () => {
  const sessionToken = "atomic-media-session";
  run(
    "INSERT INTO sessions(user_id,token,created_at,updated_at,last_active_at) VALUES(?,?,?,?,?)",
    admin.id,
    sessionToken,
    now(),
    now(),
    now(),
  );
  const server = createServer(createApp());
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const base = `http://127.0.0.1:${server.address().port}`,
    auth =
      "session_token=" +
      encodeURIComponent(rails.signCookie("session_token", sessionToken));
  try {
    const response = await fetch(base + "/rooms/" + open.id, {
        headers: { cookie: auth },
      }),
      html = await response.text(),
      csrf = html.match(/name="csrf-token" content="([^"]+)"/)[1],
      cookie =
        auth +
        "; " +
        response.headers
          .getSetCookie()
          .map((c) => c.split(";")[0])
          .join("; ");
    let m = domain.createMessage(open.id, admin.id, "Original atomic body");
    const original = storeUpload(
      {
        buffer: Buffer.from("original file"),
        originalname: "original.txt",
        mimetype: "text/plain",
      },
      "Message",
      m.id,
      "attachment",
    );
    const snapshot = () =>
      Object.fromEntries(
        [
          "messages",
          "action_text_rich_texts",
          "active_storage_blobs",
          "active_storage_attachments",
          "active_storage_variant_records",
        ].map((t) => [t, get(`SELECT count(*) n FROM ${t}`).n]),
      );
    const before = snapshot();
    const form = (method) => {
      const body = new FormData();
      body.append("authenticity_token", csrf);
      if (method) body.append("_method", method);
      body.append("message[body]", "Must not persist");
      body.append(
        "message[attachment]",
        new Blob(["this is not a jpeg"], { type: "image/jpeg" }),
        "invalid.jpg",
      );
      return body;
    };
    for (const [path, method] of [
      [`/rooms/${open.id}/messages`, null],
      [`/rooms/${open.id}/messages/${m.id}`, "patch"],
    ]) {
      const reply = await fetch(base + path, {
        method: "POST",
        headers: { cookie },
        body: form(method),
      });
      assert.equal(reply.status, 422);
      assert.deepEqual(snapshot(), before);
    }
    assert.equal(
      get(
        "SELECT body FROM action_text_rich_texts WHERE record_type='Message' AND record_id=?",
        m.id,
      ).body,
      "Original atomic body",
    );
    assert.equal(
      get(
        "SELECT blob_id FROM active_storage_attachments WHERE record_type='Message' AND record_id=?",
        m.id,
      ).blob_id,
      original.id,
    );
    assert.equal(
      get("SELECT rowid FROM message_search_index WHERE body MATCH 'Original'")
        .rowid,
      m.id,
    );
    assert.equal(
      all(
        "SELECT rowid FROM message_search_index WHERE body MATCH 'persist'",
      ).some((row) => row.rowid === m.id),
      false,
    );
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
});
test("room namespaces cannot promote direct history or bypass shared room administration", async () => {
  const time = now();
  const directId = Number(
    run(
      "INSERT INTO rooms(type,creator_id,created_at,updated_at) VALUES('Rooms::Direct',?,?,?)",
      admin.id,
      time,
      time,
    ).lastInsertRowid,
  );
  const direct = get("SELECT * FROM rooms WHERE id=?", directId);
  domain.grantMemberships(direct, [admin.id, member.id]);
  const sessionToken = "namespace-member-session";
  run(
    "INSERT INTO sessions(user_id,token,created_at,updated_at,last_active_at) VALUES(?,?,?,?,?)",
    member.id,
    sessionToken,
    time,
    time,
    time,
  );
  const server = createServer(createApp());
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  const auth =
    "session_token=" +
    encodeURIComponent(rails.signCookie("session_token", sessionToken));
  try {
    const loginPage = await fetch(base + "/rooms/" + open.id, {
      headers: { cookie: auth },
    });
    const csrf = (await loginPage.text()).match(
      /name="csrf-token" content="([^"]+)"/,
    )[1];
    const cookie =
      auth +
      "; " +
      loginPage.headers
        .getSetCookie()
        .map((c) => c.split(";")[0])
        .join("; ");
    const snapshot = () =>
      JSON.stringify({
        rooms: all("SELECT * FROM rooms ORDER BY id"),
        memberships: all("SELECT * FROM memberships ORDER BY id"),
      });
    const initial = snapshot();
    const cases = [
      ["GET", "/rooms/unknown", 404],
      ["GET", `/rooms/opens/${direct.id}/edit`, 404],
      ["PATCH", `/rooms/opens/${direct.id}`, 404],
      ["DELETE", `/rooms/opens/${direct.id}`, 404],
      ["GET", `/rooms/closeds/${direct.id}/edit`, 404],
      ["PATCH", `/rooms/closeds/${direct.id}`, 404],
      ["GET", `/rooms/directs/${open.id}/edit`, 404],
      ["DELETE", `/rooms/directs/${open.id}`, 404],
      ["PATCH", `/rooms/directs/${open.id}`, 404],
      ["PATCH", `/rooms/directs/${direct.id}`, 405],
      ["PUT", `/rooms/directs/${direct.id}`, 405],
      ["DELETE", `/rooms/opens/${open.id}`, 403],
    ];
    for (const [method, path, expected] of cases) {
      const response = await fetch(base + path, {
        method,
        redirect: "manual",
        headers: {
          cookie,
          "x-csrf-token": csrf,
          "content-type": "application/x-www-form-urlencoded",
        },
        ...(method === "GET"
          ? {}
          : {
              body: new URLSearchParams({
                "room[name]": "Leaked",
                "user_ids[]": outsider.id,
              }),
            }),
      });
      assert.equal(response.status, expected, method + " " + path);
      assert.equal(
        snapshot(),
        initial,
        method + " " + path + " changed persisted access",
      );
    }
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
});

test("Attachment-only bot JSON and notification text use the original filename", async () => {
  const { messagePlainText } = await import("../src/richtext.js");
  const { serializeMessage } = await import("../src/routes.js");
  const message = domain.createMessage(open.id, admin.id, "");
  storeUpload(
    {
      buffer: Buffer.from("attachment-only"),
      originalname: "contract-file.txt",
      mimetype: "text/plain",
    },
    "Message",
    message.id,
    "attachment",
  );
  assert.equal(messagePlainText(message.id, ""), "contract-file.txt");
  assert.equal(messagePlainText(message.id, "<p>Caption</p>"), "Caption");
  const req = { protocol: "http", get: () => "example.test" };
  assert.equal(
    serializeMessage(message, req).body.plain_text,
    "contract-file.txt",
  );
});
