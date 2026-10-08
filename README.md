# once-campfire-express

ONCE Campfire implemented natively with Node.js 24 and Express 5. The existing SQLite
schema, uploaded files, bcrypt passwords and Rails login cookies remain compatible.
Nunjucks renders the retained Turbo/Stimulus/Lexxy frontend; native WebSockets speak
Action Cable. No other Campfire implementation runs in the application process.

```sh
git submodule update --init
docker build -t once-campfire-express .
docker run --rm -p 8080:80 -e SECRET_KEY_BASE="$(openssl rand -hex 64)" \
  -v campfire:/rails/storage once-campfire-express
```

Existing installs must reuse their `SECRET_KEY_BASE` and mount their storage at
`/rails/storage`. Preserve VAPID keys for existing push subscriptions. `WEB_WORKERS`
sets the HTTP process count; publications pass through the primary process to every
worker. A separate leased SQLite queue handles jobs. TLS terminates at a proxy;
configure `TRUSTED_PROXIES` with its addresses.

For local development, use the pinned Node version, run `npm ci`,
`npm run build:assets`, set `SECRET_KEY_BASE`, then `npm start`. Run `npm test` for
native integration and independent Rails golden-vector tests. The OxCaml benchmark
port's local development setup also requires `opam` with the pinned OxCaml switch
and `curl` for outbound link previews. The public Rails
reference is immutable and pinned at `659f957`.

See [verification](plans/contracts.md) for tested workflows and remaining limits,
and [benchmark commands](bench/README.md) for the production comparison.

## Benchmarks

Measured with 16 concurrent clients on an AMD Ryzen AI MAX+ 395,
with four hardware threads allocated to each app.

| HTTP workload (requests/sec) | Rails | [Django](https://github.com/basecamp/once-campfire-django) | [Laravel](https://github.com/basecamp/once-campfire-laravel) | [Express](https://github.com/basecamp/once-campfire-express) | [Elixir](https://github.com/basecamp/once-campfire-elixir) | [Go](https://github.com/basecamp/once-campfire-go) | [Rust](https://github.com/basecamp/once-campfire-rust) |
|---|---:|---:|---:|---:|---:|---:|---:|
| Room page | 241 | 170 | 164 | 559 | 722 | 3,860 | 36,260 |
| Messages page | 413 | 196 | 175 | 777 | 1,053 | 5,573 | 40,872 |
| Sidebar | 552 | 615 | 715 | 4,125 | 1,275 | 19,753 | 34,672 |
| Search | 435 | 315 | 305 | 1,294 | 1,156 | 7,053 | 33,299 |
| Post a message | 273 | 154 | 137 | 256 | 801 | 4,767 | 6,896 |

The separate [OxCaml port](https://github.com/iho/once-campfire-oxcaml) has passed the full
canonical-seed HTTP/Cable preflight in two rounds. An exploratory two-round post-message
comparison on ARM64 Linux measured 347 requests/second for OxCaml and 258 for Express, but
those images came from dirty working trees and the host differs from the Ryzen reference
system. The old runner hard-coded OxCaml's reported domain count as one without enforcing or
recording the effective environment value. It now configures four Eio domains on Linux.
OxCaml remains omitted from this table until a clean, reproducible run on the reference hardware
covers the published workloads.

At 100 WebSocket connections and five messages/second, median delivery to every
connection was 24 ms for Rails and 14 ms for Express. Every message reached every
connection in both runs.

## Known differences

- TLS terminates at a configured proxy.
- Attached downloads and inline attachments recheck room membership; new draft uploads
  belong to their uploader. Legacy unattached signed drafts remain usable after sign-in.
- Native media variants use a separate digest namespace, preserving original files and
  rebuilding previews as needed. Native-library media bytes can differ.
- HTML whitespace and malformed-fragment repair can differ. Full byte parity is not claimed.
- Direct-room autocomplete explicitly requests JSON, repairing the original fetch-header bug.
- Backups require a maintenance window for consistent database and file snapshots. App and
  queue snapshots are separate; external job effects have at-least-once delivery.

MIT. Templates, asset compilation and compatibility contracts draw on the public Rails
application and existing Campfire ports; vendored frontend assets retain their licenses.
