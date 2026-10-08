# Benchmarks

Ruby orchestrates fresh production containers, alternating their order. The common
[load generator](https://github.com/basecamp/once-campfire-verification/tree/main/loadgen)
is unchanged across implementations. From this checkout, clone and build its sibling checkout:

```sh
git clone https://github.com/basecamp/once-campfire-verification.git ../once-campfire-verification
cargo build --release --locked --manifest-path ../once-campfire-verification/loadgen/Cargo.toml
```

The runner defaults to `../once-campfire-verification/loadgen/target/release/loadgen`;
set `LOADGEN` to override that executable,
`BENCH_ENV_FILE` to the disposable fixture's environment, and `RUBY_IMAGE`,
`EXPRESS_IMAGE`, `MOJO_IMAGE`, and (when benchmarking it) `OXCAML_IMAGE` to immutable
production image IDs.

```sh
ruby bench/compare.rb --seed /path/to/parity/seed --concurrencies 16 \
  --routes room_show,messages_page,sidebar,search --duration 4
ruby bench/compare.rb --seed /path/to/parity/seed --concurrencies 16 \
  --routes post_message --duration 15
ruby bench/compare.rb --seed /path/to/parity/seed --suites cable \
  --cable-clients 100 --cable-tput-secs 0
MOJO_IMAGE=once-campfire-mojo:bench ruby bench/compare.rb --apps mojo \
  --seed /path/to/parity/seed --routes room_show,messages_page,sidebar,search,autocomplete_users,profile,user,account \
  --duration 4
EXPRESS_IMAGE=once-campfire-express:bench MOJO_IMAGE=once-campfire-mojo:bench \
  ruby bench/compare.rb --apps express,mojo --seed /path/to/parity/seed \
  --routes room_show,messages_page,sidebar,search,profile,user,account --duration 4
```

## Mojo target

Install Mojo using the [official installation instructions](https://mojolang.org/install/).
For example, in an isolated Python environment, install `uv` and run
`uv pip install mojo`; the compiler is then available as `mojo` and can run a source
file with `mojo run path/to/server.mojo`. The comparison runner expects a separately
built `once-campfire-mojo` production image. It binds the disposable fixture at
`/rails/storage` and sends the same HTTP workloads
and validation queries as for Express. Set `MOJO_BENCH_ENV` to a JSON object of
environment overrides required by that image, for example
`'{"HTTP_PORT":"25130"}'`. The fixture env file must provide its Rails-compatible
`SECRET_KEY_BASE`; the Mojo image exits during startup without it. The image must
serve the same HTTP routes and honor the
same storage mount; use `--suites http` for the currently shared HTTP checks.
The Dockerfile pins the Mojo compiler and labels the image with its compiler version
and `-O3` setting. `summary.json` records those labels in the Mojo topology alongside
the immutable image ID so performance results can be tied to the exact build.
The runner accepts `--routes profile,user` to measure the signed-in settings page and
another user's public profile; profile CSRF and persistence checks run in preflight
independently of the timed route list. `--routes account` measures the account settings
page; preflight rejects invalid-CSRF changes, verifies the name and JSON setting persist,
checks unknown settings survive, and restores the disposable fixture state. Account-admin
preflight also rotates the join code, changes a member's role and restores it, then deactivates
a separate fixture member while verifying session/search/push cleanup and membership handling;
these checks now include OxCaml. OxCaml additionally verifies that the profile's four-hour
transfer link can create an authenticated Rails session and that an expired link is rejected.
It also checks admin user-ban CSRF protection, distinct public-IP capture, session revocation,
message/FTS cleanup, and unban restoration.
For OxCaml, preflight also posts, lists, edits, and deletes a text message using the seeded
bot's Rails bot key, then checks JSON shape, creator identity, persisted cleanup, and a nested
boost create/delete round trip. OxCaml also checks administrator bot creation, name/webhook
updates, key rotation, deactivation, and open-room membership cleanup. Bot message file uploads
remain outside that check. OxCaml also checks the push-subscription page, invalid-CSRF rejection, DNS-validated
creation, idempotent re-registration, and CSRF-protected deletion/restoration.
The OxCaml route preflight also verifies `/unfurl_link` CSRF rejection, loopback URL denial,
and missing-URL handling; it checks push test-notification CSRF rejection without external
delivery. A production-image authenticated request to `https://ogp.me/`
verified Open Graph title/canonical URL/description extraction and image MIME validation;
this is a single-site smoke, not general public-site parity coverage.

The sibling `once-campfire-mojo` repository contains the native server and Docker image
recipe. It supports bcrypt sign-in, persisted sessions, Rails-compatible sign-out, a
Rails-signed `session_token`, membership checks, sidebar/search routes, an initials-SVG
avatar fallback, and transactional message/Action Text/FTS writes. The room and sidebar
expose the scraper's CSRF token and signed stream names; the room links to a stylesheet
bundle copied from the pinned Rails sources. Responses still differ from Rails in page
rendering, avatar variants, remaining assets, and message side effects.

The latest successful two-round Mojo-only production-image preflight used the canonical
Rails-generated default seed and passed the shared HTTP assertions, including attachment
authorization and signup. The latest Express/Mojo run stopped in Express while fetching a
newly created open room, before Mojo ran. The runner now also checks login-time encrypted
session and CSRF rotation; its disposable-fixture local HTTP smoke passed, but this new
assertion still needs a production-image run. Earlier successful preflights are historical
and do not establish that the latest combined run passes.

Shared Cable correctness validation passed twice for Mojo at 100, 500, and 1,000 clients,
with six subscriptions each and all 30 paced messages delivered to every client. Those
macOS runs used zero saturation seconds and are not performance comparisons. The Mojo
listener supports 512 clients per worker with a 4,096 pending-connection backlog. The
runner raises and records its own load-generator file-descriptor limit (4,096 by default)
so macOS's common 256 limit does not cap client counts. In the prior two-round app
comparison, Mojo and Express negotiated gzip and returned similar-sized room, message-page,
and search bodies, but remaining page and search markup differences mean throughput figures
are not yet comparable. Throughput comparisons are limited to Linux hosts, where server and
client CPU affinity are enforced. A manual smoke verified three ordered Turbo message
events reached all 16 clients across four Mojo workers. The benchmark records the configured
Mojo worker count in topology metadata.
Mojo preflight and Cable validation also post a disposable message over HTTP, observe the
Rails-shaped user-scoped UnreadRoomsChannel event, observe Turbo append/remove events over
the signed RoomMessagesChannel stream, and delete the message afterward.

On macOS, `bench/compare.rb` supports `--preflight` for Mojo, Express, OxCaml, and
their single-app runs using a published local port. Express correctness runs default to
one HTTP worker on macOS; the three-worker container exited with SIGBUS during the
preflight on this Docker Desktop host. It also supports
`--validation-only --apps mojo --suites cable --cable-tput-secs 0` and
`--validation-only --apps oxcaml --suites cable --cable-tput-secs 0` to validate the
shared Cable workload without collecting saturation throughput. This mode performs the required
login/scrape and database integrity checks but skips the unrelated HTTP mutation preflight.
Docker CPU sets apply,
but the host load generator cannot be pinned. Comparative throughput runs are refused
on macOS; use Linux, where server and client CPU affinity are enforced.
The latest two-round Mojo-only production-image preflight passed on the canonical Rails
seed with `MOJO_BENCH_ENV='{"HTTP_WORKERS":"1"}'`. It checks join-code rotation,
member role mutation/restoration, and deactivation cleanup, including preservation of
direct-room memberships and removal of sessions, searches, and push subscriptions. Both rounds also
passed invitation signup (invalid CSRF 422, valid signup 302, bcrypt member, four open-room
memberships, persisted session) and attachment authorization/range checks. The latest
Express/Mojo cross-app preflight stops in Express with EOF while fetching a newly created
open room, before Mojo runs. A stale Express production image caused an earlier `/users/:id` 500;
rebuilding the current image fixed that route. A current OxCaml/Express cross-app preflight
reaches video-blob authorization, where Express returns 401 for the outsider session instead
of the expected 403. Fresh isolated outsider sessions return 403, so the sequence-dependent
Express failure remains under investigation; OxCaml passes its side of the combined preflight.
The runner copies each fixture through SQLite's backup API to avoid inheriting stale WAL
sidecars. macOS validation fixtures use rollback journaling to avoid cross-OS WAL sharing;
Linux throughput fixtures keep the seed's WAL mode. The runner avoids host-side SQLite writes
after the container starts. It restores account settings and roles through the app; join-code
rotation remains only in the disposable per-app fixture.
The shared preflight now also checks invitation signup after account mutations: invalid
CSRF must leave no user row, and valid signup must create a bcrypt member, session, and
memberships in every open room. Mojo-only production-image coverage passed twice; the
combined Express/Mojo result remains pending because Express fails earlier in that run.

## OxCaml target

OxCaml is maintained in its own repository. In a fresh Express checkout, clone it at the
expected path before building; this keeps the implementation and its pinned Rails reference
independently versioned:

```sh
git clone --recurse-submodules https://github.com/iho/once-campfire-oxcaml.git once-campfire-oxcaml
```

Build that checkout as a production image, then select it in the same HTTP comparison. The
runner binds the fixture's Rails-schema database and storage directories
at `/rails/storage`, supplies `SECRET_KEY_BASE` from `BENCH_ENV_FILE`, and reads the
OxCaml source revision from `once-campfire-oxcaml/`.

```sh
docker build -t once-campfire-oxcaml:bench once-campfire-oxcaml
OXCAML_IMAGE=once-campfire-oxcaml:bench ruby bench/compare.rb --apps oxcaml \
  --seed /path/to/parity/seed --suites http \
  --routes room_show,messages_page,sidebar,search,profile,user,account,session_transfer,avatar,static_css,webmanifest,service_worker,up,post_message
```

Set `OXCAML_BENCH_ENV` to a JSON object only for additional image-specific overrides.
On Linux, the runner configures one OxCaml Eio domain per CPU in `--cpus`; macOS preflight
defaults to one domain. An explicit `WEB_WORKERS` in
`OXCAML_BENCH_ENV` overrides either default (integer 1–64), and `summary.json` records the
configured count as `topology.oxcaml.http_domains`.
The shared load generator checks authenticated route preflight, exact result windows,
persisted message writes, Action Text/FTS consistency, SQLite integrity, and Action Cable
room-stream subscriptions and delivery. OxCaml negotiates gzip for large text responses;
preflight rejects uncompressed selected HTML/CSS routes and compares the decoded stylesheet
with the pinned Rails asset. OxCaml authorizes Rails-signed room subscriptions
against current room membership, tracks presence lifecycle, and publishes committed messages
and user-scoped unread notifications through its native Eio event bus. On the Rails-generated
canonical default seed, OxCaml's HTTP preflight passed and shared Cable validation passed twice
each at 100, 500, and 1,000 clients, with six subscriptions per client and all 30 paced marked
messages delivered to all clients; no connections failed. Cable validation used
`--cable-tput-secs 0`, so these are correctness/latency checks, not throughput results. The
room-show preflight also checks the Rails layout landmarks and message action/reaction controls.
This structural check does not assert byte-for-byte or visual parity; the latest renderer changes
have not yet been rechecked against the full canonical seed. The
HTTP preflight verifies the public account-named web manifest, install shortcuts, app icons,
and service-worker push, badge, and notification-click handlers. Both endpoints are also
available as timed route selections. On the disposable Rails-shaped database, native HTTP
smoke returned 200 for both and validated their JSON/JavaScript content types. The
account settings route is available to authenticated users; preflight verifies the page,
CSRF rejection, administrator update, preserved unknown settings, and restoration. It is
also available as a timed route selection. The
OxCaml preflight additionally validates the administrator custom-styles editor, CSRF rejection,
database persistence, `<head>` style injection, and restoration. It also exercises multipart
account-logo upload, both public PNG sizes, removal, and stock-icon fallback. It validates the
public QR endpoint, and checks the account invite and absolute profile-transfer URLs link to QR
representations of those exact URLs. The
OxCaml preflight now also checks user-scoped read notifications, room-scoped typing start/stop
payloads, non-member denial, and bot boost append/remove Cable delivery. Host-native smoke
verified read/typing delivery and non-member denial; native event-bus tests cover the bot boost
events. Its bot API lifecycle also posts a multipart attachment-only message and verifies
filename fallback, the Rails Active Storage association, and orphan cleanup on bot deletion.
Production-image WebSocket mutation/notification checks pass in the OxCaml HTTP preflight; the
100/500/1,000-client production-image Cable validation has not yet been run. The OxCaml-only
HTTP preflight passes on the canonical seed. Cross-implementation HTTP preflight remains
unverified: the latest combined
run passed OxCaml and failed at Express outsider-session authorization; earlier Express runs also
exposed a macOS multi-worker SIGBUS. An exploratory two-round `post_message` comparison on an
ARM64 Linux host measured 347.1 requests/second for OxCaml (355.3, 338.8) and 257.6 for Express
(302.1, 213.1), with zero timed errors and persisted writes. That run used four pinned server
CPUs and four pinned client CPUs, but both source trees were dirty and the host differs from the
Ryzen reference system; it is not a publishable result. The old runner hard-coded OxCaml's
reported domain count as one without enforcing or recording the effective environment value.
The runner now defaults OxCaml to four Eio domains on Linux and records the configured count.
The reference-hardware comparison, clean-source rerun, remaining HTTP workloads, and Cable
saturation throughput are still outstanding. The default throughput command requires a Linux
host for CPU pinning; macOS should use `--preflight` or `--validation-only`.

To repeat the current Cable correctness gate:

```sh
OXCAML_IMAGE=once-campfire-oxcaml:bench ruby bench/compare.rb --validation-only \
  --apps oxcaml --seed /path/to/parity/.seed/default --suites cable \
  --cable-clients 100,500,1000 --cable-tput-secs 0
```

The public Rust port's `parity/bin/seed build` creates the fixture. Server processes
share four hardware threads (`--cpus`); clients use separate threads (`--client-cpus`).
The runner verifies exact ordered HTTP result windows, successful persisted writes,
FTS entries, SQLite integrity and complete WebSocket delivery. It replaces fixture
push and webhook destinations with loopback test endpoints. Raw output stays in
ignored `tmp/bench/`; no benchmark results are tracked.

HTTP preflight also exercises Active Storage direct uploads: it posts blob metadata,
streams an approximately 256 KiB payload, attaches the returned signed ID to a message,
and verifies the downloaded bytes. It sends a mismatched-checksum payload too and
checks that no partial object remains. It runs for Ruby, Express, Mojo, and OxCaml before any
timed workload; apps without a direct-upload endpoint skip this check.
The OxCaml preflight additionally uploads a multipart image with an empty message body and
checks that the attachment-only message, Rails Active Storage association, and analyzed image
dimensions persist.
The Mojo preflight also attaches a directly uploaded image to an otherwise unused
member, fetches the member's signed avatar URL to verify the bytes, confirms invalid CSRF
cannot remove the attachment, rejects a tampered signed blob ID, then removes the
attachment before the timed routes run.

The same preflight checks room-scoped user autocomplete as HTML and JSON for Ruby, Express,
Mojo, and OxCaml, including result IDs and required signed-avatar/GlobalID fields.

The OxCaml preflight also exercises profile update with invalid-CSRF rejection, a boost
create/delete round trip, logout cookie/session revocation, and a live Cable message
create/edit/delete cycle that requires append/replace/remove frames. It also verifies
global public-room and user-scoped private-room sidebar broadcasts during create, rename,
conversion, and delete. These checks run against each fresh fixture container before any
timed workload.

For Ruby, Express, Mojo, and OxCaml, the HTTP preflight also opens the open-room form,
rejects creation with an invalid CSRF token, then creates a disposable room and checks
that its membership rows cover every active user. It also creates a closed room with
selected members, creates a direct conversation, repeats the direct request to verify
participant-set deduplication, and checks persisted membership involvement. The expanded
room preflight edits the new open and closed rooms, verifies open membership stays in sync
with all active users, removes a selected closed-room member, and fetches both renamed
rooms. It then creates a message in the closed room, deletes the room, and verifies the
room, memberships, message, and FTS row are gone. It has not yet been run against the
current production images.

For Ruby, Express, and Mojo, the HTTP preflight also checks the profile form and submits
a profile update. It rejects an invalid CSRF token, persists a disposable bio value, and
confirms that an empty password field leaves the existing bcrypt digest unchanged. Mojo
remains opt-in (`--apps mojo`) while feature parity and production-image verification are
incomplete; these preflight checks do not establish comparative performance.
